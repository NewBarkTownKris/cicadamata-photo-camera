extends CompositorEffect
## Captures Godot's Forward+ resolved 3D color after transparents, before
## tonemapping and CanvasLayers. Scene gain is applied after the readback.

const READ_SHADER := """
#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(set=0, binding=0) uniform sampler2D scene_color;
layout(set=0, binding=1, std430) writeonly buffer Samples { uvec2 pixels[]; };
layout(push_constant, std430) uniform Parameters {
	ivec2 crop_origin; ivec2 crop_size;
	ivec2 raster; ivec2 output_size;
	int row; int rows; int _pad_a; int _pad_b;
} p;
void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (xy.x >= p.output_size.x || xy.y >= p.rows) return;
	vec2 point = (vec2(xy.x, xy.y + p.row) + 0.5) / vec2(p.output_size);
	vec2 uv = (vec2(p.crop_origin) + point * vec2(p.crop_size)) / vec2(p.raster);
	vec4 v = textureLod(scene_color, uv, 0.0);
	pixels[xy.y * p.output_size.x + xy.x] = uvec2(packHalf2x16(v.rg), packHalf2x16(vec2(v.b, 1.0)));
}"""
const GAIN_SHADER := """
#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(rgba16f, set=0, binding=0) uniform image2D scene_color;
layout(push_constant, std430) uniform Parameters { float gain; float a; float b; float c; } p;
void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(xy, imageSize(scene_color)))) return;
	vec4 color = imageLoad(scene_color, xy);
	imageStore(scene_color, xy, vec4(color.rgb * p.gain, color.a));
}"""
const METER_SIDE := 32
# Bound individual readback buffers on devices with small SSBO limits.
const READBACK_BYTES := 8 * 1024 * 1024

var _mutex := Mutex.new()
var _serial := 0
var _request := {}
var _result := {}
var _gain := 1.0
var _installed := false
var _original: Compositor
var _private: Compositor
# Render-thread owned resources.
var _sampler := RID()
var _read_shader := RID()
var _read_pipeline := RID()
var _gain_shader := RID()
var _gain_pipeline := RID()
var _failure := ""


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true


func install(camera: Camera3D, optical_effect: CompositorEffect = null) -> bool:
	if _installed or camera == null or not camera.is_inside_tree():
		return false
	if not RenderingServer.get_rendering_device() or RenderingServer.get_current_rendering_method() != "forward_plus":
		return false
	_original = camera.compositor
	var inherited := _original
	if not inherited:
		var group := "_world_compositor_%d" % camera.get_world_3d().scenario.get_id()
		var environment := camera.get_tree().get_first_node_in_group(group) as WorldEnvironment
		if environment:
			inherited = environment.compositor
	var effects: Array[CompositorEffect] = []
	if inherited:
		# A private band camera may inherit the detached camera's compositor.
		# Its HDR request and gain belong to this camera exclusively.
		for effect: CompositorEffect in inherited.compositor_effects:
			if effect and effect.get_script() != get_script():
				effects.append(effect)
	if optical_effect:
		effects.append(optical_effect)
	effects.append(self)
	_private = Compositor.new()
	_private.compositor_effects = effects
	_installed = true
	camera.compositor = _private
	return true


func uninstall(camera: Camera3D) -> void:
	if not _installed:
		return
	_mutex.lock()
	_installed = false
	_request = {}
	_result = {}
	_serial += 1
	_mutex.unlock()
	if is_instance_valid(camera) and camera.compositor == _private:
		camera.compositor = _original
	# Break the private compositor's reference to this effect.
	_private.compositor_effects = []
	_private = null
	_original = null
	# A method Callable stores an ObjectID. Bind a strong Resource reference
	# as well so the queued cleanup outlives session teardown on a separate
	# render thread and executes after earlier render callbacks.
	RenderingServer.call_on_render_thread(_free_gpu.bind(self))


func is_available() -> bool:
	return _installed and RenderingServer.get_rendering_device() != null


func set_gain(value: float) -> void:
	_mutex.lock()
	_gain = value if is_finite(value) and value > 0.0 else 1.0
	_mutex.unlock()


func arm(crop: Rect2i, raster: Vector2i, meter_only: bool = false) -> int:
	_mutex.lock()
	_serial += 1
	var id := _serial
	_result = {}
	if not _installed:
		_result = _failed("Scene-linear capture requires Forward+ and a RenderingDevice")
	elif not crop.has_area() or not Rect2i(Vector2i.ZERO, raster).encloses(crop):
		_result = _failed("Invalid scene-linear capture crop")
	_request = {"id": id, "crop": crop, "raster": raster, "meter": meter_only} if _result.is_empty() else {}
	_mutex.unlock()
	return id


func take(id: int) -> Dictionary:
	_mutex.lock()
	var result := {}
	if id != _serial:
		result = _failed("Capture superseded")
	else:
		result = _result
		_result = {}
	_mutex.unlock()
	return result


func cancel(id: int) -> void:
	_mutex.lock()
	if id == _serial:
		_serial += 1
		_request = {}
		_result = {}
	_mutex.unlock()


static func _failed(message: String) -> Dictionary:
	return {"ok": false, "message": message, "image": null, "luminance": NAN}


static func luminance(image: Image) -> float:
	if image == null or image.is_empty():
		return NAN
	var stops := PackedFloat64Array()
	var cells := Vector2i(mini(METER_SIDE, image.get_width()), mini(METER_SIDE, image.get_height()))
	for y in cells.y:
		for x in cells.x:
			var point := Vector2i((Vector2(x + 0.5, y + 0.5) / Vector2(cells)) * Vector2(image.get_size()))
			var color := image.get_pixelv(point)
			var value := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			if not is_finite(value):
				return NAN
			if value > 0:
				stops.append(log(value))
	if stops.is_empty():
		return 0.0
	stops.sort()
	var low := floori(stops.size() * 0.10)
	var high := stops.size() - floori(stops.size() * 0.05)
	var log_total := 0.0
	for i in range(low, high):
		log_total += stops[i]
	return exp(log_total / (high - low))


func _compile(rd: RenderingDevice, source: String) -> RID:
	var glsl := RDShaderSource.new()
	glsl.source_compute = source
	var spirv := rd.shader_compile_spirv_from_source(glsl)
	if not spirv.compile_error_compute.is_empty():
		_failure = spirv.compile_error_compute
		push_warning("[CICADAMATA Photo] " + _failure)
		return RID()
	return rd.shader_create_from_spirv(spirv)


func _prepare(rd: RenderingDevice) -> bool:
	if not _failure.is_empty():
		return false
	if _read_pipeline.is_valid():
		return true
	var sampler := RDSamplerState.new()
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_sampler = rd.sampler_create(sampler)
	_read_shader = _compile(rd, READ_SHADER)
	_gain_shader = _compile(rd, GAIN_SHADER)
	if _read_shader.is_valid():
		_read_pipeline = rd.compute_pipeline_create(_read_shader)
	if _gain_shader.is_valid():
		_gain_pipeline = rd.compute_pipeline_create(_gain_shader)
	if not _read_pipeline.is_valid() or not _gain_pipeline.is_valid() or not _sampler.is_valid():
		if _failure.is_empty():
			_failure = "Could not initialize HDR compute pipelines"
		return false
	return true


static func _uniform(type: RenderingDevice.UniformType, binding: int, ids: Array[RID]) -> RDUniform:
	var result := RDUniform.new()
	result.uniform_type = type
	result.binding = binding
	for id: RID in ids:
		result.add_id(id)
	return result


static func _dispatch(rd: RenderingDevice, pipeline: RID, uniforms: RID, args: PackedByteArray, extent: Vector2i) -> void:
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	rd.compute_list_set_push_constant(list, args, args.size())
	rd.compute_list_dispatch(list, ceili(extent.x / 8.0), ceili(extent.y / 8.0), 1)
	rd.compute_list_end()


func _read(rd: RenderingDevice, color: RID, request: Dictionary, target_size: Vector2i) -> Dictionary:
	var crop: Rect2i = request.crop
	var raster: Vector2i = request.raster
	if target_size != raster:
		return _failed("Render size changed before HDR readback (%s vs %s)" % [target_size, raster])
	var extent := Vector2i(METER_SIDE, METER_SIDE) if request.meter else crop.size
	var stride := extent.x * 8
	var rows := mini(extent.y, maxi(1, READBACK_BYTES / stride))
	var buffer := rd.storage_buffer_create(stride * rows)
	if not buffer.is_valid():
		return _failed("HDR readback allocation failed")
	var uniforms := rd.uniform_set_create([
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_sampler, color]),
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1, [buffer])], _read_shader, 0)
	if not uniforms.is_valid():
		rd.free_rid(buffer)
		return _failed("Could not bind HDR scene color")
	var result := PackedByteArray()
	for start in range(0, extent.y, rows):
		_mutex.lock()
		var current: bool = request.id == _serial
		_mutex.unlock()
		if not current:
			break
		var count := mini(rows, extent.y - start)
		var params := PackedInt32Array([crop.position.x, crop.position.y, crop.size.x, crop.size.y,
			raster.x, raster.y, extent.x, extent.y, start, count, 0, 0]).to_byte_array()
		_dispatch(rd, _read_pipeline, uniforms, params, Vector2i(extent.x, count))
		var data := rd.buffer_get_data(buffer, 0, count * stride)
		if data.size() != count * stride:
			break
		result.append_array(data)
	rd.free_rid(uniforms)
	rd.free_rid(buffer)
	if result.size() != extent.y * stride:
		return _failed("Incomplete HDR readback")
	var image := Image.create_from_data(extent.x, extent.y, false, Image.FORMAT_RGBAH, result)
	var meter := luminance(image)
	if not is_finite(meter):
		return _failed("Nonfinite scene-linear luminance")
	return {"ok": true, "message": "", "luminance": meter, "image": null if request.meter else image}


func _render_callback(kind: int, render_data: RenderData) -> void:
	if kind != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	_mutex.lock()
	var active := _installed
	var request := _request
	_request = {}
	var gain := _gain
	_mutex.unlock()
	if not active or (request.is_empty() and gain == 1.0):
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var rd := RenderingServer.get_rendering_device()
	var result := {}
	if not rd or not buffers or not _prepare(rd):
		result = _failed("HDR compositor unavailable: " + _failure)
	else:
		var color := buffers.get_color_layer(0)
		if not color.is_valid():
			result = _failed("Missing resolved scene color")
		else:
			if not request.is_empty():
				result = _read(rd, color, request, buffers.get_target_size())
			if gain != 1.0:
				var uniforms := UniformSetCacheRD.get_cache(_gain_shader, 0, [_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [color])])
				if uniforms.is_valid():
					_dispatch(rd, _gain_pipeline, uniforms, PackedFloat32Array([gain, 0.0, 0.0, 0.0]).to_byte_array(), buffers.get_internal_size())
	if not request.is_empty():
		_mutex.lock()
		if _serial == request.id:
			_result = result
		_mutex.unlock()


func _free_gpu(_keep_alive: CompositorEffect) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd:
		for rid: RID in [_read_shader, _gain_shader, _sampler]:
			if rid.is_valid():
				rd.free_rid(rid)
	_read_shader = RID()
	_gain_shader = RID()
	_sampler = RID()
	_read_pipeline = RID()
	_gain_pipeline = RID()
	_failure = ""
