extends CompositorEffect
## Optical blur in scene-linear light. The HDR reader runs immediately afterward.
## The root finder and each print strip supply their own projection and depth.

const HDR := preload("res://cicadamata_photo/linear_capture.gd")
const SHADER := """
#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(set=0, binding=0) uniform sampler2D scene;
layout(set=0, binding=1) uniform sampler2D depth;
layout(rgba16f, set=0, binding=2) uniform writeonly image2D destination;
layout(push_constant, std430) uniform Lens {
	float focus_m; float infinity_radius; float max_radius; float projection_b;
	float projection_a; float copy_pass; float pad0; float pad1;
} p;
float distance_at(ivec2 pixel) {
	float z = texelFetch(depth, pixel, 0).r;
	// get_cam_projection() already contains Vulkan reverse-Z correction.
	return p.projection_b / (z + p.projection_a);
}
void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(destination);
	if (any(greaterThanEqual(xy, size))) return;
	vec4 center = texelFetch(scene, xy, 0);
	if (p.copy_pass > 0.0) { imageStore(destination, xy, center); return; }
	float z = distance_at(xy);
	float radius = min(p.max_radius, p.infinity_radius * abs(1.0 - p.focus_m / z));
	if (radius < 0.25) { imageStore(destination, xy, center); return; }
	vec3 sum = center.rgb;
	float weight = 1.0;
	// Sample a disk in pixel space. Reject nearer layers when gathering the
	// background so a sharply focused silhouette retains its edge.
	int taps = clamp(int(ceil(radius * 2.0)), 8, 48);
	for (int i = 0; i < taps; ++i) {
		float angle = 2.39996323 * float(i);
		vec2 offset = radius * sqrt((float(i) + 0.5) / float(taps)) * vec2(cos(angle), sin(angle));
		vec2 sample_xy = clamp(vec2(xy) + vec2(0.5) + offset, vec2(0.5), vec2(size) - vec2(0.5));
		float sample_z = distance_at(ivec2(sample_xy));
		if (sample_z < z * 0.985) continue;
		sum += textureLod(scene, sample_xy / vec2(size), 0.0).rgb;
		weight += 1.0;
	}
	imageStore(destination, xy, vec4(sum / weight, center.a));
}
"""

var _context: StringName
var _mutex := Mutex.new()
var _lens := Vector4.ZERO # focus distance, focal length in mm, scaled inverse f-number, base width
var _failed := false
# The following resources belong to the render thread.
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _depth_sampler := RID()
var _buffers := {} # Weak references; a completed print can release its viewport immediately.


func _init() -> void:
	_context = StringName("cicadamata_photo_dof_%d" % get_instance_id())
	enabled = false
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true


func configure(active: bool, focus_m: float, focal_mm: float, aperture: float, strength: float, base_width: int) -> bool:
	_mutex.lock()
	_lens = Vector4(focus_m, focal_mm, strength / aperture, base_width)
	var available := not _failed
	_mutex.unlock()
	var next := active and available
	if enabled != next:
		enabled = next
		if not next:
			RenderingServer.call_on_render_thread(_release_buffers.bind(self))
	return next


func has_failed() -> bool:
	_mutex.lock()
	var failed := _failed
	_mutex.unlock()
	return failed


func _unavailable(reason: String) -> void:
	_mutex.lock()
	if not _failed:
		push_warning("[CICADAMATA Photo] Optical compositor unavailable: " + reason)
	_failed = true
	_mutex.unlock()


func _prepare(rd: RenderingDevice) -> bool:
	if _pipeline.is_valid():
		return true
	var source := RDShaderSource.new()
	source.source_compute = SHADER
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		_unavailable(spirv.compile_error_compute)
		return false
	_shader = rd.shader_create_from_spirv(spirv)
	if _shader.is_valid():
		_pipeline = rd.compute_pipeline_create(_shader)
	var sampler := RDSamplerState.new()
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_sampler = rd.sampler_create(sampler)
	# Depth filtering support varies by Vulkan format. The shader reads the
	# exact depth of each pixel while interpolating scene color separately.
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_depth_sampler = rd.sampler_create(sampler)
	if not _pipeline.is_valid() or not _sampler.is_valid() or not _depth_sampler.is_valid():
		_unavailable("could not create the depth-of-field pipeline")
		return false
	return true


func _render_callback(kind: int, data: RenderData) -> void:
	if kind != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	_mutex.lock()
	var lens := _lens
	var failed := _failed
	_mutex.unlock()
	if failed or lens.y <= 0.0:
		return
	var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
	var rd := RenderingServer.get_rendering_device()
	if not buffers or not rd or not _prepare(rd):
		return
	var size := buffers.get_internal_size()
	var scratch := buffers.get_texture(_context, &"blurred") if buffers.has_texture(_context, &"blurred") else RID()
	if not scratch.is_valid():
		scratch = buffers.create_texture(_context, &"blurred", RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT,
			RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
		if not scratch.is_valid():
			_unavailable("could not allocate the scene-linear blur buffer")
			return
		for id in _buffers.keys():
			if _buffers[id].get_ref() == null:
				_buffers.erase(id)
		_buffers[buffers.get_instance_id()] = weakref(buffers)
	var projection := data.get_render_scene_data().get_cam_projection()
	# The X projection coefficient includes the off-center strip's field of
	# view. It converts lens millimetres to pixels without using strip height.
	var pixels_per_mm := absf(projection.x.x) * size.x / (2.0 * lens.y)
	var radius := 0.5 * pixels_per_mm * lens.y * lens.y * lens.z / (lens.x * 1000.0 - lens.y)
	var scale := pixels_per_mm * 36.0 / maxf(1.0, lens.w)
	# Match the shutter's overlap budget so neighboring strips sample the
	# same scene at their joins. Cap the kernel even on unbounded displays.
	var params := PackedFloat32Array([lens.x, radius, minf(64.0, 16.0 * scale), projection.w.z,
		projection.z.z, 0.0, 0.0, 0.0])
	for view in buffers.get_view_count():
		var depth := buffers.get_depth_layer(view)
		var scene := buffers.get_color_layer(view)
		if not depth.is_valid() or not scene.is_valid():
			_unavailable("missing resolved color or depth")
			return
		for copy in 2:
			var input := scene if copy == 0 else scratch
			var output := scratch if copy == 0 else scene
			var uniforms := UniformSetCacheRD.get_cache(_shader, 0, [
				HDR._uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_sampler, input]),
				HDR._uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_depth_sampler, depth]),
				HDR._uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [output])])
			if not uniforms.is_valid():
				_unavailable("could not bind the scene-linear DOF textures")
				return
			params[5] = float(copy)
			HDR._dispatch(rd, _pipeline, uniforms, params.to_byte_array(), size)


func close() -> void:
	enabled = false
	RenderingServer.call_on_render_thread(_release.bind(self))


func _release_buffers(_keep_alive: Resource) -> void:
	for ref: WeakRef in _buffers.values():
		var buffers := ref.get_ref() as RenderSceneBuffersRD
		if buffers:
			buffers.clear_context(_context)
	_buffers.clear()


func _release(keep_alive: Resource) -> void:
	_release_buffers(keep_alive)
	var rd := RenderingServer.get_rendering_device()
	if rd:
		for rid: RID in [_pipeline, _shader, _sampler, _depth_sampler]:
			if rid.is_valid():
				rd.free_rid(rid)
