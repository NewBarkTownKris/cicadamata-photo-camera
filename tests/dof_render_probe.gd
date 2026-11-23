extends SceneTree
## Test depth discrimination in both published formats through the real session.
const Session := preload("res://cicadamata_photo/session.gd")
const Optics := preload("res://cicadamata_photo/camera_math.gd")

var failures := 0

func _initialize() -> void:
	run.call_deferred()


func check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		printerr(description)


func card(scene: Node3D, distance: float, side: float, material: ShaderMaterial) -> void:
	var mesh := MeshInstance3D.new()
	var quad := QuadMesh.new()
	var width := distance * 36.0 / 16.0
	quad.size = Vector2(width * 0.5, width * 0.75)
	mesh.mesh = quad
	mesh.material_override = material
	mesh.position = Vector3(side * width * 0.25, 0.0, -distance)
	scene.add_child(mesh)


func contrast(image: Image, fraction: float) -> float:
	# A stripe chart spans each depth plane. Measure its RMS contrast in
	# the interior, clear of the silhouette and viewport boundaries.
	var start := roundi(image.get_width() * fraction)
	var n := maxi(8, image.get_width() / 4)
	var total := 0.0
	var squared := 0.0
	var line := image.get_height() / 2
	for i in n:
		var v := image.get_pixel(start + i, line).r
		total += v
		squared += v * v
	return sqrt(maxf(0, squared / n - pow(total / n, 2)))


func press(keycode: Key) -> void:
	var key := InputEventKey.new()
	key.keycode = keycode
	key.pressed = true
	root.push_input(key, true)
	key.pressed = false
	root.push_input(key, true)


func edge_width(image: Image) -> float:
	# The isolated step in the near chart measures optical blur in pixels.
	var center := image.get_width() / 4
	var row := image.get_height() / 10
	var half_span := image.get_width() / 8
	var dark := image.get_pixel(center - half_span, row).r
	var light := image.get_pixel(center + half_span, row).r
	var width := 0.0
	for x in range(center - half_span, center + half_span):
		var fraction := inverse_lerp(dark, light, image.get_pixel(x, row).r)
		if fraction > 0.15 and fraction < 0.85:
			width += 1.0
	return width


func capture(session: Session, promote_png := false) -> Array:
	session.last_shot = {}
	var lens_before: Vector4 = session.optics_effect._lens
	press(KEY_F9 if promote_png else KEY_F3)
	if promote_png:
		press(KEY_F3)
	if session.capture.busy:
		# Also simulate a late settings refresh while a virtual print viewport
		# is active. Its width/frustum must never become a new optical gate.
		session._apply_attributes()
		check(session.optics_effect._lens.is_equal_approx(lens_before), "shutter preserves the locked lens and sensor pitch")
	var deadline := Time.get_ticks_msec() + 15000
	while session._shot_pending and Time.get_ticks_msec() < deadline:
		await process_frame
	if not session.last_shot.get("ok", false):
		printerr("DOF pair failed: ", session._status)
		return []
	return [Image.load_from_file(session.last_shot.path), Image.load_from_file(session.last_shot.exr_path)]


func run() -> void:
	root.size = Vector2i(384, 192)
	root.msaa_3d = Viewport.MSAA_2X
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var player := CharacterBody3D.new()
	scene.add_child(player)
	player.add_to_group(&"player")
	var head := Node3D.new()
	head.name = "Head"
	player.add_child(head)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.fov = Optics.lens_fov(16.0, 2, camera.keep_aspect)
	camera.near = 0.05
	camera.attributes = CameraAttributesPractical.new()
	head.add_child(camera)
	camera.make_current()
	var controller := Node.new()
	controller.name = "PauseController"
	player.add_child(controller)
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = """shader_type spatial;
	render_mode unshaded, cull_disabled;
	void fragment() {
		float chart = abs(UV.y - 0.5) > 0.15 ? step(0.5, UV.x) : step(0.5, fract(UV.x * 40.0));
		ALBEDO = vec3(0.05 + 1.95 * chart);
	}"""
	material.shader = shader
	card(scene, 0.28, -1, material)
	card(scene, 7.0, 1, material)

	var session := Session.new()
	root.add_child(session)
	if not session.enter():
		printerr("Could not enter optics fixture")
		quit(1)
		return
	session.studio.directory = OS.get_cmdline_user_args()[0]
	session.exposure.aperture = 3.5
	session.studio.dof_strength = 4
	session.frame_index = 0
	session.studio.capture_scale = 1
	session._apply_attributes()
	var clear := await capture(session, true)
	session._key(KEY_B)
	session.focus_m = 0.28
	session._apply_attributes()
	var near := await capture(session)
	session.studio.dof_strength = 1
	session._apply_attributes()
	var weak := await capture(session)
	session.studio.dof_strength = 4
	session.exposure.aperture = 16.0
	session._apply_attributes()
	var stopped := await capture(session)
	session.exposure.aperture = 3.5
	session.focus_m = 7.0
	session._apply_attributes()
	var far := await capture(session)
	# At f/1.4 the near edge is wide enough in the base capture to measure
	# the print radius independently in both display and scene-linear images.
	session.exposure.aperture = 1.4
	session._apply_attributes()
	var base_edge := await capture(session)
	# Force horizontal print bands in the 4× private HDR viewport.
	session.studio.capture_scale = 4
	session.capture._band_pixel_limit = 32768
	session._apply_attributes()
	var print_pair := await capture(session)
	if clear.size() == 2 and near.size() == 2 and far.size() == 2 and weak.size() == 2 and stopped.size() == 2 and base_edge.size() == 2 and print_pair.size() == 2:
		for i in 2:
			var clear_near := contrast(clear[i], 0.125)
			var clear_far := contrast(clear[i], 0.625)
			var near_sharp := contrast(near[i], 0.125) / clear_near
			var far_blur := contrast(near[i], 0.625) / clear_far
			var far_sharp := contrast(far[i], 0.625) / clear_far
			var near_blur := contrast(far[i], 0.125) / clear_near
			print(["PNG","EXR"][i], " focal contrast relative to off: ", [near_sharp, far_blur, near_blur, far_sharp])
			check(near_sharp > 0.97 and far_sharp > 0.97, "The selected focal plane must remain sharp")
			check(far_blur < 0.65 and near_blur < 0.65, "Both foreground and background must defocus")
			check(contrast(weak[i], 0.625) / clear_far > far_blur + 0.2, "The blur multiplier must affect captured detail")
			check(contrast(stopped[i], 0.625) / clear_far > far_blur + 0.2, "Closing the aperture must reduce optical blur")
			check(print_pair[i].get_size() == Vector2i(1536, 768), "Expected a 4× print")
			check(contrast(print_pair[i], 0.125) < clear_near * 0.65, "4× blurred foreground")
			check(contrast(print_pair[i], 0.625) > clear_far * 0.97, "4× sharp background")
			var base_radius := edge_width(base_edge[i])
			var print_radius := edge_width(print_pair[i]) / 4.0
			print(["PNG","EXR"][i], " defocused edge width in base pixels: ", [base_radius, print_radius])
			check(base_radius >= 4.0 and absf(print_radius - base_radius) < 0.25 * base_radius,
				"4× print preserves the blur radius at a common optical scale")
	else:
		failures += 1
	# A rapid off/on pair releases the old render context and re-creates it
	# for the next capture without losing focus or holding the print scratch.
	session._key(KEY_B)
	session._key(KEY_B)
	session.studio.capture_scale = 1
	var reenabled := await capture(session)
	check(reenabled.size() == 2 and contrast(reenabled[1], 0.625) > 0.5, "rapidly re-enabled optics")
	# Simulate a failed device allocation on the render pass. The finder and
	# saved pair must identify the display-only native blur fallback.
	session.optics_effect._unavailable("synthetic resource failure")
	var fallback := await capture(session)
	check(fallback.size() == 2 and "unavailable in EXR" in session._status, "EXR warns on optical fallback")
	check(session.camera.attributes.dof_blur_far_enabled and "display only" in session.finder.readout, "native display fallback")
	session.leave()
	check(root.get_camera_3d() == camera and not camera.attributes.dof_blur_far_enabled, "Restored gameplay camera")
	await process_frame
	print("Forward+ two-depth optical test: ", failures, " failures")
	quit(1 if failures else 0)
