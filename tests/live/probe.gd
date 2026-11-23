extends Node
## Packed only into a private test copy; exits the retail executable when done.

var results := {}
var session
var root_window: Window

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("run")

func report(key: String, value: Variant) -> void:
	results[key] = value
	var file := FileAccess.open("user://photo-live-results.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(results, "  "))
	print("[Photo live] ", key, " ", value)

func key_press(code: Key) -> void:
	if code in [KEY_F3, KEY_F9] and session:
		session.last_shot = {}
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	root_window.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root_window.push_input(event, true)

func delay(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout

func run() -> void:
	root_window = get_tree().root
	session = root_window.get_node("CICADAMATAPhoto")
	await delay(3)
	report("startup", get_tree().current_scene.scene_file_path if get_tree().current_scene else "no scene")
	report("adapter", RenderingServer.get_video_adapter_name())
	report("renderer", RenderingServer.get_current_rendering_driver_name())
	var scenario := OS.get_cmdline_user_args()
	# Let the title's own menu and level-transition code initialize the HUD,
	# lighting, player and save slot. The input goes only to this private copy.
	var global := root_window.get_node("global")
	global.call("_goto_menu")
	await delay(2.0)
	report("menu", str(get_tree().current_scene.scene_file_path))
	global.call("_startlevel", "lvl_4_2" if "optics" in scenario else "lvl_1_1")
	var deadline := Time.get_ticks_msec() + 65000
	while Time.get_ticks_msec() < deadline:
		await delay(0.25)
		var player := get_tree().get_first_node_in_group(&"player")
		if get_tree().current_scene and player and get_tree().current_scene.is_ancestor_of(player):
			break
	await delay(4)
	report("level", str(get_tree().current_scene.scene_file_path))
	if "optics" in scenario:
		root_window.mode = Window.MODE_EXCLUSIVE_FULLSCREEN
		await delay(1)
		report("display_size", str(DisplayServer.screen_get_size(root_window.current_screen)))
		report("window_size", str(root_window.size))
	if "print" in scenario or ("optics" in scenario and root_window.get_texture().get_image().get_size() != Vector2i(3840,2160)):
		root_window.content_scale_size = Vector2i(3840,2160)
		root_window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
		root_window.content_scale_factor = 1.0
		root_window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
		await delay(1.0)
	var rig_was_visible := false
	var initial_view := Transform3D()
	deadline = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		await delay(0.15)
		var active := root_window.get_camera_3d()
		if active:
			initial_view = active.get_camera_transform()
			var rig := active.get_node_or_null("RigFPS") as Node3D
			rig_was_visible = rig.visible if rig else false
		key_press(KEY_F8)
		if session.state:
			break
	if not session.state:
		var cam := root_window.get_camera_3d()
		report("error", "entry refused at %s; camera %s, paused %s" % [get_tree().current_scene, cam.get_path() if cam else "-", get_tree().paused])
		get_tree().quit(1)
		return
	report("entry", str(session.state.source.get_path()))
	report("size", str(root_window.get_texture().get_image().get_size()))
	var source: Camera3D = session.state.source
	report("matched_entry", session.camera.global_transform.is_equal_approx(initial_view))
	var rig := source.get_node_or_null("RigFPS") as Node3D
	report("hidden_rig", is_instance_valid(rig) and not rig.visible)
	var pose: Transform3D = session.state.player.global_transform
	report("frozen", get_tree().paused)
	await delay(0.25)
	report("player_still", pose.is_equal_approx(session.state.player.global_transform))
	key_press(KEY_N)
	await delay(0.12)
	report("focus", session._status)
	key_press(KEY_F5)
	key_press(KEY_F6)
	key_press(KEY_F9)
	await delay(0.2)
	while session._shot_pending and Time.get_ticks_msec() < deadline:
		await delay(0.05)
	report("shutter", session._status)
	if "matrix" in scenario:
		await advanced()
	elif "print" in scenario:
		await large_print()
	elif "detail" in scenario:
		await load("res://cicadamata_photo/print_compare.gd").new().run(self)
	elif "optics" in scenario:
		await load("res://cicadamata_photo/optics_export.gd").new().run(self)
	elif "picker" in scenario:
		key_press(KEY_F2)
		report("picker_open", session.studio.picking)
		var until := Time.get_ticks_msec() + 60000
		while session.studio.picking and Time.get_ticks_msec() < until:
			await delay(0.1)
		report("directory", session.studio.directory)
		key_press(KEY_F9)
		await wait_capture("picker_png")
	key_press(KEY_F8)
	await delay(0.5)
	report("restored_view", not get_tree().paused and root_window.get_camera_3d() == source)
	report("restored_rig", is_instance_valid(rig) and rig.visible == rig_was_visible)
	report("done", true)
	await delay(0.5)
	get_tree().quit()

func wait_capture(label: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 240000
	while session._shot_pending and Time.get_ticks_msec() < deadline:
		await delay(0.025)
	var result: Dictionary = session.last_shot.duplicate()
	result["status"] = session._status
	result["timeout"] = session._shot_pending
	report(label, result)
	return result

func joy(button: JoyButton) -> void:
	if button in [JOY_BUTTON_A, JOY_BUTTON_Y] and session:
		session.last_shot = {}
	var event := InputEventJoypadButton.new()
	event.device = 0
	event.button_index = button
	event.pressed = true
	root_window.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root_window.push_input(event, true)

func advanced() -> void:
	if not "studio" in session:
		return
	var st = session.studio
	var ex = session.exposure
	key_press(KEY_F4)
	var was_open: bool = st.visible
	joy(JOY_BUTTON_DPAD_DOWN)
	joy(JOY_BUTTON_DPAD_UP)
	key_press(KEY_F4)
	report("studio", was_open and not st.visible)
	key_press(KEY_F7)
	key_press(KEY_B)
	key_press(KEY_Y)
	report("optics_controls", {"mm":session._mm(), "dof":session.dof, "dof_strength":st.dof_strength})
	# Use one fixed composition for the linear bracket and both priority shots.
	ex.aperture = 2.8
	ex.iso = 100
	ex.seconds = 1.0 / 125
	ex.auto_iso = false
	ex.mode = 1
	session.frame_index = 1
	session.portrait = true
	st.capture_scale = 1
	var base := session.camera.global_transform as Transform3D
	var base_fov: float = session.camera.fov
	session._apply_attributes()
	session._refresh()
	await delay(0.5)
	report("luminance", session._luminance)
	key_press(KEY_F3)
	await wait_capture("iso100")
	for i in 3:
		key_press(KEY_PERIOD)
	key_press(KEY_F3)
	await wait_capture("iso200")
	ex.mode = 2
	ex.auto_iso = true
	ex.min_iso = 100
	ex.max_iso = 6400
	session._apply_attributes()
	joy(JOY_BUTTON_Y)
	await wait_capture("aperture_priority")
	ex.mode = 3
	session.camera.translate_object_local(Vector3(0.08, 0, 0))
	session._apply_attributes()
	key_press(KEY_F3)
	await wait_capture("shutter_priority")
	ex.mode = 0
	ex.auto_iso = false
	session.frame_index = 7
	session.portrait = false
	st.capture_scale = 4
	st.look = 2
	st.grain = true
	session._apply_attributes()
	session._refresh()
	key_press(KEY_F3)
	await wait_capture("print4")
	report("print_restored", absf(base_fov - session.camera.fov) < 0.001)
	st.capture_scale = 1
	st.look = 0
	st.grain = false
	ex.mode = 1
	ex.iso = 100
	ex.seconds = 1.0 / 15
	session._apply_attributes()
	session._refresh()
	key_press(KEY_F3)
	await get_tree().process_frame
	session.camera.translate_object_local(Vector3(0.2, 0, 0))
	await wait_capture("timed")
	ex.seconds = 4.0
	session._apply_attributes()
	key_press(KEY_F3)
	await delay(0.15)
	key_press(KEY_F8)
	await delay(0.3)
	report("canceled_and_resumed", not session.state and not get_tree().paused)
	key_press(KEY_F8)
	await delay(0.2)
	report("second_entry", session.state != null)
	if session.state:
		ex.mode = 0
		ex.seconds = 1.0 / 125
		session.frame_index = 0
		session.portrait = false
		session.camera.global_transform = base
		session._apply_attributes()
		joy(JOY_BUTTON_A)
		await wait_capture("controller_png")

func large_print() -> void:
	var start := Time.get_ticks_msec()
	session.frame_index = 7
	session.portrait = false
	session.studio.capture_scale = 4
	session.exposure.mode = 0
	session._apply_attributes()
	session._refresh()
	key_press(KEY_F3)
	await wait_capture("uhd_print")
	report("print_seconds", (Time.get_ticks_msec() - start) / 1000.0)
