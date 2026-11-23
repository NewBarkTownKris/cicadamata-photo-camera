extends RefCounted
## Executed only by the private retail fixture after entering lvl_4_2.
const Optics := preload("res://cicadamata_photo/camera_math.gd")
const NEAR_PLANE_M := 0.28

func set_lens(s, index: int) -> void:
	s.studio.lens_preset = index
	s.camera.fov = Optics.lens_fov(Optics.LENSES_MM[index], s._aspect(), s.camera.keep_aspect)
	s._apply_attributes()
	s._refresh()


func focus_on_level(probe) -> float:
	var s = probe.session
	var original: Vector3 = s._angles
	var best_score := -1.0
	var best_angles := original
	var best_depth := NAN
	var show_guides: bool = s.guides
	s.guides = false
	set_lens(s, 4)
	# The level spawns below a detailed billboard. Test several real views
	# at the narrower lens so both focal lengths contain measurable detail.
	for offset: Vector2 in [Vector2.ZERO, Vector2(0, 5), Vector2(0, 9), Vector2(0, 13),
			Vector2(3, 8), Vector2(-3, 8), Vector2(12, 10), Vector2(-15, 7)]:
		s._angles = original + Vector3(deg_to_rad(offset.y), deg_to_rad(offset.x), 0)
		await probe.delay(0.1)
		probe.key_press(KEY_N)
		await probe.delay(0.3)
		if not is_finite(s.studio.center_distance) or s.studio.center_distance < 1.0:
			continue
		var im: Image = probe.root_window.get_texture().get_image()
		im.resize(320, 180, Image.INTERPOLATE_BILINEAR)
		var score := 0.0
		for y in range(76, 105, 2):
			for x in range(108, 213):
				score += absf(im.get_pixel(x, y).get_luminance() - im.get_pixel(x-1, y).get_luminance())
		if score > best_score:
			best_score = score
			best_angles = s._angles
			best_depth = s.studio.center_distance
	s._angles = best_angles
	s.guides = show_guides
	set_lens(s, 0)
	await probe.delay(0.2)
	probe.report("subject_texture_score", best_score)
	return best_depth


func pair(probe, label: String) -> bool:
	var s = probe.session
	probe.report(label + "_settings", {"dof": s.dof, "focus_m": s.focus_m, "mm": s._mm(),
		"strength": s.studio.dof_strength, "scale": s.studio.capture_scale, "near_clip": s.camera.near})
	var start := Time.get_ticks_msec()
	probe.key_press(KEY_F3)
	var shot: Dictionary = await probe.wait_capture(label)
	probe.report(label + "_seconds", (Time.get_ticks_msec() - start) / 1000.0)
	return shot.get("ok", false) and not str(shot.get("exr_path", "")).is_empty()


func marker(parent, left: float, right: float, color: Color) -> ColorRect:
	var rect := ColorRect.new()
	parent.add_child(rect)
	rect.color = color
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.z_index = 512
	rect.set_anchor_and_offset(SIDE_RIGHT, right, 0)
	rect.set_anchor_and_offset(SIDE_LEFT, left, 0)
	rect.set_anchor_and_offset(SIDE_BOTTOM, 0.52, 0)
	rect.set_anchor_and_offset(SIDE_TOP, 0.48, 0)
	return rect


func run(probe) -> void:
	var s = probe.session
	var st = s.studio
	var ex = s.exposure
	var config := ConfigFile.new()
	var config_error := config.load("user://CicadaDisplay.ini")
	probe.report("pixelzoom", config_error == OK and bool(config.get_value("Display", "PixelZoom", false)))
	st.directory = OS.get_executable_path().get_base_dir().path_join("Photo Test Output")
	st.look = 0
	st.grain = false
	st.capture_scale = 1
	st.dof_strength = 1
	ex.mode = 1
	ex.iso = 100
	ex.aperture = 3.5
	ex.seconds = 1.0 / 250
	ex.auto_iso = false
	ex.compensation_thirds = 0
	s.frame_index = 7
	s.portrait = false
	s.continuous_af = false
	s.dof = false
	set_lens(s, 0)
	var subject_m := await focus_on_level(probe)
	if not is_finite(subject_m):
		probe.report("error", "Could not acquire a level surface for the focus comparison")
		return
	var camera_pose: Transform3D = s.camera.global_transform
	var player_pose: Transform3D = s.state.player.global_transform
	probe.report("subject_m", subject_m)
	probe.report("subject_world", str(camera_pose.origin - camera_pose.basis.z * subject_m))

	# Record a distinctive pattern in the finder itself, then check the saved
	# image for it independently. The Studio and both swatches share its layer.
	st.capture_scale = 4
	s._refresh()
	probe.key_press(KEY_F4)
	probe.report("optics_studio_open", st.visible)
	var magenta := marker(s.overlay, 0.485, 0.500, Color.MAGENTA)
	var cyan := marker(s.overlay, 0.500, 0.515, Color.CYAN)
	await probe.delay(0.4)
	var before: Image = probe.root_window.get_texture().get_image()
	var size := before.get_size()
	var m := before.get_pixel(int(0.493 * size.x), size.y / 2)
	var c := before.get_pixel(int(0.507 * size.x), size.y / 2)
	probe.report("source_marker_rgb", [[m.r,m.g,m.b],[c.r,c.g,c.b]])
	probe.report("marker_in_finder", m.r > 0.95 and m.b > 0.95 and m.g < 0.05 and c.r < 0.05 and c.g > 0.95 and c.b > 0.95)
	before = null
	var exported := await pair(probe, "studio_manual_print")
	magenta.queue_free()
	cyan.queue_free()
	if not exported:
		probe.report("error", "Studio F3 did not produce the manual print pair")
		return
	if st.visible:
		probe.key_press(KEY_F4)
	st.capture_scale = 1
	# A second exposure identifies HDR and checks that the manual print has
	# consistent radiometry even when the chosen 1/250 s frame is dim.
	ex.iso = 1600
	set_lens(s, 0)
	await probe.delay(0.25)
	if not await pair(probe, "exposed_reference"):
		return
	ex.iso = 100
	for index: int in [0, 4]:
		set_lens(s, index)
		for setting: String in ["off", "near", "subject", "control"]:
			var want_dof := setting in ["near", "subject"]
			if s.dof != want_dof:
				probe.key_press(KEY_B)
			s.focus_m = NEAR_PLANE_M if setting == "near" else subject_m
			s._apply_attributes()
			s._refresh()
			await probe.delay(0.22)
			var label := "focus_%s_%s" % [Optics.LENSES_MM[index], setting]
			if s.dof != want_dof or not await pair(probe, label):
				probe.report("error", "Focus toggle or paired capture failed: " + label)
				return
	set_lens(s, 0)
	st.capture_scale = 4
	probe.key_press(KEY_B)
	s.focus_m = NEAR_PLANE_M
	s._apply_attributes()
	s._refresh()
	await probe.delay(0.25)
	if not s.dof or not await pair(probe, "focus_print_near"):
		probe.report("error", "Scaled optical print failed")
		return
	probe.report("optics_pose_fixed", camera_pose.is_equal_approx(s.camera.global_transform))
	probe.report("optics_player_fixed", player_pose.is_equal_approx(s.state.player.global_transform))
