extends SceneTree
## Run with both the synthetic display and the real capture state machine.
const Capture := preload("res://cicadamata_photo/capture.gd")
const Optics := preload("res://cicadamata_photo/camera_math.gd")
const SIZE := Vector2i(160, 90)
var camera := Camera3D.new()
var layer := CanvasLayer.new()
var shutter := Capture.new()
var result := {}
var failures := 0
var dir: DirAccess

class FakeLinear extends CompositorEffect:
	var crop: Rect2i
	var sequence := 0
	func arm(rect: Rect2i, _size: Vector2i, _meter: bool) -> int:
		crop = rect
		sequence += 1
		return sequence
	func take(_ticket: int) -> Dictionary:
		var image := Image.create_empty(crop.size.x, crop.size.y, false, Image.FORMAT_RGBH)
		image.fill(Color(4, 0.5, 0.25))
		return {"ok":true, "image":image}
	func cancel(_ticket: int) -> void:
		pass


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL ", message)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() != "X11" or not "llvmpipe" in RenderingServer.get_video_adapter_name().to_lower():
		quit(1)
		return
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = SIZE
	camera.fov = 80.0
	root.add_child(camera)
	camera.make_current()
	var quad := QuadMesh.new()
	quad.size = Vector2(16, 10)
	var mesh := MeshInstance3D.new()
	mesh.position.z = -4.0
	mesh.mesh = quad
	var shader := Shader.new()
	shader.code = """shader_type spatial; render_mode unshaded, cull_disabled;
	void fragment() { ALBEDO = vec3(UV, 0.25); }"""
	var material := ShaderMaterial.new()
	material.shader = shader
	mesh.material_override = material
	root.add_child(mesh)
	root.add_child(layer)
	var marker := ColorRect.new()
	marker.color = Color.MAGENTA
	marker.size = Vector2(20, 20)
	marker.position = Vector2(70, 35)
	layer.add_child(marker)
	dir = DirAccess.create_temp("cicada-render-shutter")
	shutter.finished.connect(func(r:Dictionary): result = r)
	layer.hide()
	await RenderingServer.frame_post_draw
	var reference := root.get_texture().get_image()
	layer.show()
	var opts := {"frame_index":7, "portrait":false, "scale":4, "directory":dir.get_current_dir(),
		"paired":true, "seconds":0.0, "metadata":{"cicadamataExposureMode":"Game"}}
	var fake := FakeLinear.new()
	var hdr_status: Array[String] = []
	shutter.progress.connect(func(message:String):
		if message.begins_with("EXR "):
			hdr_status.append(message)
			check(layer.visible and root.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED,
				"native-size finder visible during private EXR replay")
	)
	check(shutter.begin(camera, layer, opts, fake).is_empty(), "begin 4x pair")
	await _wait()
	check(result.get("ok",false), "4x pair: " + str(result))
	check(not hdr_status.is_empty() and hdr_status[0].contains("520 × 192"), "EXR progress shows dimensions")
	if result.get("ok",false):
		var png := Image.load_from_file(result.path)
		check(png.get_size() == Vector2i(520,192), "4x locked panorama")
		check(png.get_pixel(260,96) != Color.MAGENTA, "overlay excluded from 4x shot")
		var exr := Image.load_from_file(result.exr_path)
		check(exr != null and exr.get_size() == png.get_size(), "paired dimensions")
		if exr:
			check(is_equal_approx(exr.get_pixel(0,0).r,4.0), "HDR survives")
	check(root.size == SIZE and root.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED and layer.visible, "root and overlay restored")
	opts.paired = false
	check(shutter.begin(camera, layer, opts, fake).is_empty(), "start PNG before paired shortcut")
	var locked_stem := shutter._stem
	check(shutter.promote_to_pair().is_empty() and shutter.promote_to_pair().is_empty(), "paired shortcut is idempotent")
	check(not opts.paired and shutter._stem == locked_stem, "upgrading keeps the locked shot")
	await _wait()
	check(result.get("ok",false) and result.path == locked_stem + ".png"
		and result.exr_path == locked_stem + ".exr", "both files from the original shutter")
	opts.paired = true
	check(shutter.begin(camera, layer, opts, fake).is_empty(), "start cancelable EXR print")
	var until := Time.get_ticks_msec() + 5000
	while not shutter.cancelable and shutter.busy and Time.get_ticks_msec() < until:
		shutter.tick()
		await process_frame
	check(shutter.cancelable and layer.visible, "cancel enabled after PNG publication")
	shutter.cancel()
	check(not result.ok and FileAccess.file_exists(result.path) and result.exr_path.is_empty(), "scaled EXR cancel keeps PNG")
	check(result.message.contains("during EXR at") and result.message.contains("%"), "cancellation identifies the EXR phase")
	opts.paired = false
	opts.scale = 1
	opts.seconds = 1.0 / 15.0
	# Force multiple horizontal bands in this tiny test.
	shutter._band_pixel_limit = 600
	check(shutter.begin(camera, layer, opts).is_empty(), "begin timed")
	await _wait()
	check(result.get("ok",false), "timed PNG")
	if result.get("ok",false):
		var png := Image.load_from_file(result.path)
		var crop := Optics.crop_rect(SIZE, opts.frame_index, opts.portrait)
		var target := reference.get_region(crop)
		var error := 0.0
		for y in target.get_height():
			for x in target.get_width():
				var a := png.get_pixel(x,y)
				var b := target.get_pixel(x,y)
				error = maxf(error,maxf(absf(a.r-b.r), absf(a.g-b.g)))
		check(error < 0.012, "band projection aligns across every row, max error %f" % error)
	check(camera.keep_aspect == Camera3D.KEEP_HEIGHT and is_equal_approx(camera.fov,80.0), "restored original projection")
	opts.seconds = 1.0
	check(shutter.begin(camera, layer, opts).is_empty(), "start cancel test")
	shutter.cancel()
	check(not shutter.busy and not result.ok and layer.visible, "timed cancel restores session")
	opts.seconds = 0.0
	opts.paired = true
	check(shutter.begin(camera, layer, opts).is_empty(), "begin unsupported pair")
	await _wait()
	check(not result.ok and FileAccess.file_exists(result.path) and result.exr_path == "", "PNG survives failed EXR")
	check(dir.get_directories().is_empty(), "no reservation or partial work")
	for path in dir.get_files():
		check(not path.contains(".part"), "no staging residue")
	print("Rendered print, banded timed and partial-pair checks: ", failures, " failures")
	quit(1 if failures else 0)


func _wait() -> void:
	var until := Time.get_ticks_msec() + 15000
	while shutter.busy and Time.get_ticks_msec() < until:
		shutter.tick()
		await process_frame
	if shutter.busy:
		shutter.cancel()
		check(false, "shutter timed out")
