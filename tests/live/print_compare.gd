extends RefCounted
## Loaded into the private retail test copy by probe.gd.

func progress(message: String, capture, observed: Dictionary) -> void:
	if not message.begins_with("PNG ") and not message.begins_with("EXR "):
		return
	var pass_name := "exr" if message.begins_with("EXR ") else "png"
	var band: int = capture._next_row
	if band not in observed[pass_name]:
		observed[pass_name].append(band)
	observed.samples = maxi(observed.samples, int(capture._sample) + 1)
	if capture._samples.size() > 1:
		var start: Basis = capture._samples.front().basis
		var end: Basis = capture._samples.back().basis
		observed.pose_span_degrees = rad_to_deg(start.get_rotation_quaternion().angle_to(end.get_rotation_quaternion()))
	var rd := RenderingServer.get_rendering_device()
	if rd:
		observed.gpu_peak_bytes = maxi(observed.gpu_peak_bytes, rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL))


func run(probe) -> void:
	var session = probe.session
	var studio = session.studio
	var exposure = session.exposure
	var base: Transform3D = session.camera.global_transform
	var subject: Transform3D = session.state.player.global_transform
	var fov: float = session.camera.fov
	session.frame_index = 7
	session.portrait = false
	session.dof = false
	studio.look = 0
	studio.grain = false
	exposure.mode = 1
	exposure.auto_iso = false
	exposure.compensation_thirds = 0
	exposure.iso = 100
	for label: String in ["detail_base", "detail_print", "detail_timed"]:
		var timed := label == "detail_timed"
		studio.capture_scale = 1 if label == "detail_base" else 4
		# These pairs have nearly equal exposure. The final shot deliberately
		# records a small horizontal pan to exercise integration of moving poses.
		exposure.aperture = 11.0 if timed else 2.8
		exposure.seconds = 1.0 / 8 if timed else 1.0 / 125
		session.camera.global_transform = base
		session._apply_attributes()
		session._refresh()
		await probe.delay(0.25)
		var observed := {"png": [], "exr": [], "samples": 0, "gpu_peak_bytes": 0, "pose_span_degrees": 0.0}
		var rd := RenderingServer.get_rendering_device()
		observed.gpu_start_bytes = rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL) if rd else 0
		var observe := progress.bind(session.capture, observed)
		session.capture.progress.connect(observe)
		var begin := Time.get_ticks_usec()
		probe.key_press(KEY_F3)
		if timed:
			var delivered := 0.0
			while session.capture.recording:
				await probe.get_tree().process_frame
				if session.capture.recording:
					var fraction := clampf((Time.get_ticks_usec() - begin) / (1e6 * exposure.seconds), 0.0, 1.0)
					var motion := InputEventMouseMotion.new()
					motion.screen_relative = Vector2((fraction - delivered) * deg_to_rad(1) / 0.0025, 0)
					motion.relative = motion.screen_relative
					probe.root_window.push_input(motion, true)
					delivered = fraction
		var result: Dictionary = await probe.wait_capture(label)
		session.capture.progress.disconnect(observe)
		observed.seconds = (Time.get_ticks_usec() - begin) / 1e6
		observed.pose_still = session.camera.global_transform.is_equal_approx(base)
		observed.fov_restored = is_equal_approx(session.camera.fov, fov)
		observed.subject_still = session.state.player.global_transform.is_equal_approx(subject)
		probe.report(label + "_render", observed)
		if not result.get("ok", false):
			return
