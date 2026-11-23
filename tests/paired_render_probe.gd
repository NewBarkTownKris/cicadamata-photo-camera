extends SceneTree
## Integrated private-camera capture. run_linear_probe.py independently opens
## the EXR produced by this test with OpenEXR after the renderer exits.
const Capture := preload("res://cicadamata_photo/capture.gd")
const Linear := preload("res://cicadamata_photo/linear_capture.gd")
const Crop := preload("res://cicadamata_photo/camera_math.gd")
var result := {}
var failures := 0


func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL ", label)


func _initialize() -> void:
	call_deferred("probe")


func probe() -> void:
	var mesh := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(16, 16)
	mesh.mesh = quad
	mesh.position.z = -5
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = """shader_type spatial; render_mode unshaded, cull_disabled;
	void fragment() { ALBEDO = vec3(0.125 + UV.x, 2.0 + UV.y, 6.0); }"""
	material.shader = shader
	mesh.material_override = material
	root.add_child(mesh)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.make_current()
	var overlay := CanvasLayer.new()
	root.add_child(overlay)
	var effect := Linear.new()
	check(effect.install(camera), "installed root compositor")
	var shutter := Capture.new()
	shutter._band_pixel_limit = 8192
	shutter.finished.connect(func(value:Dictionary): result = value)
	var output := OS.get_cmdline_user_args()[0]
	var geom := Vector2i(96, 64)
	var crop := Crop.crop_rect(geom, 1, true)
	await RenderingServer.frame_post_draw
	var ticket := effect.arm(crop, geom, false)
	var baseline := {}
	for i in 100:
		await process_frame
		baseline = effect.take(ticket)
		if not baseline.is_empty():
			break
	if not baseline.get("ok",false):
		printerr("No reference framebuffer")
		quit(1)
		return
	var opts := {"frame_index":1, "portrait":true, "scale":4, "directory": output,
		"paired":true, "seconds":1.0/15, "metadata":{"cicadamataExposureMode":"Manual", "isoSpeed":200,
		"expTime":1.0/15, "aperture":4.0, "focalLength":50.0}, "gain":2.0}
	check(shutter.begin(camera, overlay, opts, effect).is_empty(), "started integrated print shutter")
	var deadline := Time.get_ticks_msec() + 40000
	while shutter.busy and Time.get_ticks_msec() < deadline:
		shutter.tick()
		await process_frame
	if shutter.busy:
		shutter.cancel()
	check(result.get("ok",false), "completed pair: " + str(result))
	if result.get("ok",false):
		var image := Image.load_from_file(result.exr_path)
		var png := Image.load_from_file(result.path)
		check(image and image.get_size() == crop.size * 4 and png.get_size() == image.get_size(), "pair dimensions")
		if image:
			var max_error := 0.0
			for y in crop.size.y:
				for x in [0, crop.size.x / 2, crop.size.x - 1]:
					var expected: Color = baseline.image.get_pixel(x, y) * 2.0
					var actual := image.get_pixel(4*x+2, 4*y+2)
					max_error = maxf(max_error, maxf(absf(actual.r-expected.r), absf(actual.g-expected.g)))
			print("Banded 4x EXR maximum projection error across scanlines = ", max_error)
			check(max_error < 0.035 and absf(image.get_pixel(0,0).b-12.0)<0.05, "all HDR bands preserve projection and gain")
	check(camera == root.get_camera_3d() and overlay.visible, "restored root finder")
	effect.uninstall(camera)
	await process_frame
	print("Integrated Forward+ timed print pair: ", failures, " failures")
	quit(1 if failures else 0)
