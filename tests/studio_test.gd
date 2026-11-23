extends SceneTree

const Studio := preload("res://cicadamata_photo/studio.gd")
const Prefs := preload("res://cicadamata_photo/preferences.gd")
const Finder := preload("res://cicadamata_photo/finder.gd")
const Exposure := preload("res://cicadamata_photo/exposure.gd")

class Stub extends Node:
	var exposure := Exposure.new()
	var finder := Finder.new()
	var studio := Studio.new()
	var camera := Camera3D.new()
	var frame_index := 0
	var portrait := false
	var show_grid := true
	var reticle := 0
	var dof := false
	var guides := true
	var help_open := false
	var fine_focus := false
	var focus_requested := false
	var continuous_af := false
	var focus_m := 10.0
	var shots: Array = []
	var resumed := false
	var _status := ""
	func _refresh():
		studio.refresh(self, exposure.solve(0.18))
	func _apply_attributes():
		pass
	func _mm() -> float:
		return 50.0
	func _aspect() -> float:
		return 16.0/9
	func _step_focus(delta: int):
		focus_m += delta
	func request_shot(hdr: bool):
		shots.append(hdr)
	func resume_photo():
		resumed = true

var checks := 0
var failures := 0


func _initialize():
	run.call_deferred()


func check(ok: bool, message: String):
	checks += 1
	if not ok:
		printerr("FAIL ", message)
		failures += 1


func button(s: Stub, b: JoyButton, pressed: bool):
	var ev := InputEventJoypadButton.new()
	ev.device = 4
	ev.button_index = b
	ev.pressed = pressed
	s.studio.handle(s, ev)


func run():
	var s := Stub.new()
	root.add_child(s)
	s.add_child(s.camera)
	s.add_child(s.finder)
	var studio := s.studio
	studio.open_session(s)
	check(studio.capture_scale == 1 and not studio.visible, "fresh defaults")
	check(not studio._film.visible, "neutral pass hidden")
	check(Studio.stick(Vector2(0.15,0)) == Vector2.ZERO, "radial dead zone")
	check(Studio.stick(Vector2(0.6,0)).x < 0.6 and Studio.stick(Vector2(1,1)).length() <= 1.00001, "proportional sticks")
	button(s, JOY_BUTTON_LEFT_STICK, true)
	check(studio.blocks_motion() and s.finder.studio_open, "L3 opens Studio")
	var key := InputEventKey.new()
	key.pressed = true
	for code in [KEY_F3, KEY_F9, KEY_B, KEY_N, KEY_T, KEY_J, KEY_K]:
		key.keycode = code
		check(not studio.handle(s, key), "Studio passes finder shortcut %s to session" % code)
	for code in [KEY_C, KEY_V]:
		key.keycode = code
		check(not studio.handle(s, key), "Studio leaves retired shortcut %s unbound" % code)
	key.keycode = KEY_Y
	check(studio.handle(s, key) and s.dof and studio.dof_strength == 2, "DOF multiplier enables lens blur")
	button(s, JOY_BUTTON_Y, true)
	button(s, JOY_BUTTON_RIGHT_STICK, true)
	check(s.shots == [true] and s.focus_requested and studio.visible, "Studio allows controller paired capture and focus")
	s.shots.clear()
	s.focus_requested = false
	button(s, JOY_BUTTON_DPAD_RIGHT, true)
	check(s.exposure.mode == Exposure.Mode.MANUAL, "D-pad mode")
	button(s, JOY_BUTTON_DPAD_DOWN, true)
	button(s, JOY_BUTTON_DPAD_RIGHT, true)
	check(s.exposure.aperture == 3.2, "D-pad aperture")
	studio._adjust(s, "look", 1)
	studio._adjust(s, "grain", 1)
	check(studio._film.visible and studio._film.material.get_shader_parameter("grain") > 0.0, "film and grain applied")
	for i in 20:
		studio._adjust(s, "capture_scale", 1)
	check(studio.capture_scale == 4, "scale clamp")
	s.exposure.mode = Exposure.Mode.APERTURE_PRIORITY
	s.exposure.auto_iso = true
	var old_shutter := s.exposure.seconds
	studio._adjust(s, "seconds", 1)
	check(s.exposure.seconds == old_shutter, "priority owns shutter")
	studio._adjust(s, "min_iso", 1)
	check(s.exposure.min_iso == 125, "adjust Auto ISO minimum")
	studio.center_distance = 10.0
	studio._adjust(s, "continuous_af", 1)
	check(s.continuous_af and "aligned" in s.finder.focus_feedback, "AF feedback")
	s.focus_m = 1000.
	studio.center_distance = 0.5
	s._refresh()
	check("near" in s.finder.focus_feedback, "focus near feedback")
	button(s, JOY_BUTTON_LEFT_STICK, true)
	button(s, JOY_BUTTON_Y, true)
	button(s, JOY_BUTTON_A, true)
	button(s, JOY_BUTTON_RIGHT_STICK, true)
	check(s.shots == [true,false] and s.focus_requested, "controller shutters and AF")
	button(s, JOY_BUTTON_BACK, true)
	button(s, JOY_BUTTON_A, true)
	button(s, JOY_BUTTON_BACK, false)
	check(not s.resumed, "Back chord does not exit")
	button(s, JOY_BUTTON_BACK, true)
	button(s, JOY_BUTTON_BACK, false)
	check(s.resumed, "Back alone resumes")
	var chosen := OS.get_user_data_dir().path_join("Destination with spaces")
	check(DirAccess.make_dir_recursive_absolute(chosen) == OK, "destination fixture")
	studio.picking = true
	studio._picked(true, PackedStringArray([chosen]), 0, weakref(s), studio._picker_serial)
	check(studio.directory == chosen and not studio.picking, "picker selection applies in current session")
	var stale := studio._picker_serial - 1
	studio._picked(true, PackedStringArray([OS.get_user_data_dir()]), 0, weakref(s), stale)
	check(studio.directory == chosen, "stale picker result cannot change destination")
	studio._adjust(s, "lens", 1)
	check(studio.lens_preset == 4, "explicit lens selection")
	studio.close_session(s)
	var persisted := Prefs.read()
	check(persisted.capture_scale == 4 and persisted.mode == Exposure.Mode.APERTURE_PRIORITY, "persisted choices")
	check(persisted.directory == chosen and persisted.lens_preset == 4, "destination and chosen preset survive restart")
	check(not persisted.has("focus_m") and not persisted.has("continuous_af"), "session focus excluded")
	persisted.merge({"fringe_off": true, "clean_motion": true, "reticle": 2}, true)
	check(Prefs.write(persisted) == OK, "legacy profile fixture")
	studio.open_session(s)
	check(s.reticle == 2, "restore supported options from a legacy profile")
	studio._adjust(s, "reticle", 1)
	studio.close_session(s)
	persisted = Prefs.read()
	check(persisted.reticle == 3 and not persisted.has("fringe_off") and not persisted.has("clean_motion"), "omit retired options on the next save")
	check(Prefs.write({"look": 5}, "user://prefs-test.json") == OK, "first save")
	check(Prefs.write({"look": 7}, "user://prefs-test.json") == OK, "second save")
	var broken := FileAccess.open("user://prefs-test.json", FileAccess.WRITE)
	broken.store_string("{")
	broken.close()
	check(Prefs.read("user://prefs-test.json").get("look") == 5, "backup recovery")
	# A malformed scale in a loaded older file retains the fresh default.
	var fresh := Studio.new()
	fresh._restore_value(s, "capture_scale", 55)
	check(fresh.capture_scale == 1, "reject malformed scale")
	print("%d Studio/film/settings/controller checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
