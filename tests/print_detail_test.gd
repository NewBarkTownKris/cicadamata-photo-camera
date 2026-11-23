extends SceneTree
## Synthetic print-resolution feasibility probe. Run on a private llvmpipe X11 display.

const Optics = preload("res://cicadamata_photo/camera_math.gd")
const BASE := Vector2i(160, 90)
const SCALE := 4
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	if not ok:
		printerr(message)
		failures += 1


func transitions(image: Image) -> int:
	var count := 0
	var row := image.get_height() / 2
	var bright := image.get_pixel(0, row).b > 0.5
	for x in range(1, image.get_width()):
		var next := image.get_pixel(x, row).b > 0.5
		if next != bright:
			count += 1
		bright = next
	return count


func _run() -> void:
	if DisplayServer.get_name() != "X11" or "llvmpipe" not in RenderingServer.get_video_adapter_name().to_lower():
		printerr("This synthetic probe requires a private Xvfb display and llvmpipe.")
		quit(1)
		return
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = BASE
	var source := Camera3D.new()
	source.fov = 90
	source.position = Vector3(0.2, -0.3, 0.1)
	root.add_child(source)
	source.make_current()
	var card := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(15.0, 8.5)
	card.mesh = quad
	card.position = source.position + Vector3.FORWARD * 4.0
	var shader := Shader.new()
	shader.code = """
		shader_type spatial;
		render_mode unshaded, cull_disabled;
		void fragment() {
			ALBEDO = vec3(UV.x, UV.y, step(0.5, fract(UV.x * 200.0)));
		}"""
	var material := ShaderMaterial.new()
	material.shader = shader
	card.material_override = material
	root.add_child(card)
	var effects := CanvasLayer.new()
	root.add_child(effects)
	var marker := ColorRect.new()
	marker.size = Vector2(8, 8)
	marker.color = Color.MAGENTA
	effects.add_child(marker)

	var target := SubViewport.new()
	target.size = BASE * SCALE
	target.world_3d = root.world_3d
	target.render_target_update_mode = SubViewport.UPDATE_ONCE
	target.scaling_3d_scale = 1.0
	root.add_child(target)
	var camera := Camera3D.new()
	camera.fov = source.fov
	camera.keep_aspect = source.keep_aspect
	target.add_child(camera)
	camera.global_transform = source.global_transform
	camera.make_current()
	await RenderingServer.frame_post_draw
	var native := root.get_texture().get_image()
	var print_image := target.get_texture().get_image()
	check(native.get_size() == BASE and print_image.get_size() == BASE * SCALE, "Unexpected render sizes")
	check(native.get_pixel(3, 3).is_equal_approx(Color.MAGENTA), "Root CanvasLayer marker missing")
	check(not print_image.get_pixel(12, 12).is_equal_approx(Color.MAGENTA), "Root layer entered independent target")
	var low_count := transitions(native)
	var high_count := transitions(print_image)
	check(high_count > BASE.x * 2 and high_count > low_count * 2, "4x failed to resolve new stripe detail")
	var max_error := 0.0
	for frame in [Vector2i(7, 0), Vector2i(1, 1)]:
		var base_crop := Optics.crop_rect(BASE, frame.x, bool(frame.y))
		var scaled := Rect2i(base_crop.position * SCALE, base_crop.size * SCALE)
		var result := print_image.get_region(scaled)
		check(result.get_size() == scaled.size, "Unexpected scaled crop")
		# Compare the low-frequency UV channels at corresponding 1x/4x pixel centers.
		for y in [0, base_crop.size.y / 2, base_crop.size.y - 1]:
			for x in [0, base_crop.size.x / 2, base_crop.size.x - 1]:
				var center := Vector2i(x, y)
				var expected := native.get_pixelv(base_crop.position + center)
				var sampled := result.get_pixelv(center * SCALE + Vector2i(2, 2))
				max_error = maxf(max_error, maxf(absf(expected.r - sampled.r), absf(expected.g - sampled.g)))
		print("Crop ", base_crop, " -> ", scaled)
	check(max_error < 0.015, "Composition landmarks diverged")
	print("Stripe transitions along the center row: ", low_count, " at 1x, ", high_count,
		" at 4x. Largest UV-channel discrepancy: ", max_error)
	quit(1 if failures else 0)
