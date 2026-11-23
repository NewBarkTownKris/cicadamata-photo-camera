extends SceneTree
## Run via run_linear_probe.py on a private Vulkan display.
const Linear := preload("res://cicadamata_photo/linear_capture.gd")
const Exr := preload("res://cicadamata_photo/photo_exr.gd")
var failures := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		printerr(label)

func _initialize() -> void:
	probe.call_deferred()

func read(effect, meter: bool) -> Dictionary:
	var ticket: int = effect.arm(Rect2i(12, 16, 40, 16), Vector2i(96, 64), meter)
	for i in 60:
		await process_frame
		var result: Dictionary = effect.take(ticket)
		if not result.is_empty():
			return result
	return {"ok":false, "message":"Compositor timeout"}

func probe() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var card := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(16, 16)
	card.mesh = quad
	card.position.z = -5
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = """shader_type spatial;
	render_mode unshaded, cull_disabled;
	void fragment() { ALBEDO = vec3(0.125 + UV.x, 2.0 + UV.y, 6.0); }"""
	material.shader = shader
	card.material_override = material
	scene.add_child(card)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.make_current()
	var effect := Linear.new()
	if not effect.install(camera):
		printerr("Could not install Forward+ effect")
		quit(1)
		return
	await RenderingServer.frame_post_draw
	var baseline: Dictionary = await read(effect, false)
	check(baseline.ok, str(baseline.get("message")))
	if baseline.ok:
		var image: Image = baseline.image
		check(image.get_size() == Vector2i(40, 16), "cropped resolution")
		check(absf(image.get_pixel(20, 10).b - 6) < 0.05, "HDR scene range")
		check(image.get_pixel(39, 0).r > image.get_pixel(0, 0).r, "horizontal projection")
		check(image.get_pixel(0, 15).g > image.get_pixel(0, 0).g, "top-to-bottom readback")
		var display1 := root.get_texture().get_image().get_pixel(32, 24).r
		effect.set_gain(2.0)
		var plus: Dictionary = await read(effect, false)
		check(plus.ok and plus.image.get_data() == image.get_data(), "meter source independent of creative gain")
		var display2 := root.get_texture().get_image().get_pixel(32, 24).r
		check(display2 > display1, "positive display exposure bracket")
		var meter: Dictionary = await read(effect, true)
		check(meter.ok and meter.image == null and absf(meter.luminance - baseline.luminance) < 0.05, "meter tracks the crop")
		var destination := OS.get_cmdline_user_args()[0]
		check(Exr.save(image, destination, {"cicadamataExposureMode":"Manual", "aperture":2.8, "isoSpeed":200, "expTime":1.0/125, "focalLength":35.0}, 2.0).ok, "save actual GPU capture")
		print("Linear probe center = ", image.get_pixel(20, 10), " meter = ", baseline.luminance, " display bracket = ", display1, " -> ", display2)
	effect.uninstall(camera)
	await process_frame
	print("Forward+ capture: ", failures, " failures")
	quit(1 if failures else 0)
