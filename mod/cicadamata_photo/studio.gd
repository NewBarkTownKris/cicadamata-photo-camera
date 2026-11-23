extends RefCounted

const Optics := preload("res://cicadamata_photo/camera_math.gd")
const Exposure := preload("res://cicadamata_photo/exposure.gd")
const Film := preload("res://cicadamata_photo/film.gd")
const Preferences := preload("res://cicadamata_photo/preferences.gd")
const MODES := ["Game", "Manual", "Aperture Priority", "Shutter Priority"]
const RETICLES := ["Optical", "Square", "Circle", "Off"]
const STRENGTHS := [1, 2, 4, 8]
const SESSION_KEYS := ["frame_index", "portrait", "show_grid", "reticle", "dof", "guides"]
const EXPOSURE_KEYS := ["mode", "aperture", "seconds", "iso", "auto_iso", "min_iso", "max_iso", "preferred_seconds", "compensation_thirds"]
const OPTIONS := {
	"mode": [0, 1, 2, 3], "aperture": Exposure.APERTURES, "seconds": Exposure.SHUTTERS, "iso": Exposure.ISOS,
	"grain_iso": Exposure.ISOS, "min_iso": Exposure.ISOS, "max_iso": Exposure.ISOS, "preferred_seconds": Exposure.SHUTTERS,
	"frame_index": [0, 1, 2, 3, 4, 5, 6, 7], "capture_scale": [1, 2, 3, 4], "reticle": [0, 1, 2, 3],
	"lens_preset": [-1, 0, 1, 2, 3, 4, 5, 6, 7], "dof_strength": STRENGTHS, "look": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
}
const ROWS := [
	["mode", "Exposure mode"], ["aperture", "Aperture"], ["seconds", "Shutter time"], ["iso", "ISO"],
	["auto_iso", "Auto ISO"], ["compensation_thirds", "EV compensation"], ["min_iso", "Auto ISO minimum"],
	["max_iso", "Auto ISO maximum"], ["preferred_seconds", "Preferred minimum shutter"], ["look", "Film look"],
	["grain", "ISO grain"], ["grain_iso", "Grain ISO in Game"], ["fringe_off", "Chromatic aberration"],
	["clean_motion", "Speed lines and radial blur"], ["frame_index", "Frame"], ["portrait", "Orientation"],
	["capture_scale", "Capture scale"], ["lens", "Lens"], ["dof", "Depth of field"], ["dof_strength", "DOF multiplier"],
	["continuous_af", "Focus mode"], ["focus_m", "Focus distance"], ["fine_focus", "Focus steps"],
	["reticle", "Reticle"], ["show_grid", "Thirds grid"], ["directory", "Screenshot folder"],
]
const OWN_KEYS := ["lens_preset", "capture_scale", "look", "grain", "grain_iso", "fringe_off", "clean_motion", "dof_strength", "directory"]
const DEFAULT_DIRECTORY := "user://CICADAMATA-Photo/Photos"

var visible := false
var picking := false
var selected := 0
var lens_preset := -1
var capture_scale := 1
var look := 0
var grain := false
var grain_iso := 100
var fringe_off := false
var clean_motion := false
var dof_strength := 1
var directory := DEFAULT_DIRECTORY
var center_distance := NAN
var plan_capture: Callable
var _saved := {}
var _film: Film
var _device := -1
var _back_device := -1
var _back_alone := false
var _picker_serial := 0
var _picker_mouse := Input.MOUSE_MODE_CAPTURED
var _picker_global: Node
var _picker_showmouse := false
var _last_save_failure := -5000


func open_session(s) -> void:
	visible = false
	picking = false
	center_distance = NAN
	_back_device = -1
	_back_alone = false
	var stored := Preferences.read()
	for key in stored:
		if key in SESSION_KEYS or key in EXPOSURE_KEYS or key in OWN_KEYS:
			_restore_value(s, key, stored[key])
	s.exposure.max_iso = maxi(s.exposure.max_iso, s.exposure.min_iso)
	if lens_preset >= 0:
		s.camera.fov = Optics.lens_fov(Optics.LENSES_MM[lens_preset], s._aspect(), s.camera.keep_aspect)
	_saved = _snapshot(s)
	_film = Film.new()
	s.add_child(_film)


func close_session(s) -> void:
	_persist(s)
	_close_picker(s)
	visible = false
	if is_instance_valid(_film):
		_film.hide()
		_film.queue_free()
	_film = null


func set_pixel_origin(origin: Vector2) -> void:
	if is_instance_valid(_film):
		_film.set_pixel_origin(origin)


func blocks_motion() -> bool:
	return visible or picking


func needs_distance() -> bool:
	return not picking


func _owner(s, key: String) -> Object:
	if key in EXPOSURE_KEYS:
		return s.exposure
	if key in OWN_KEYS:
		return self
	return s


func _restore_value(s, key: String, value: Variant) -> void:
	var owner := _owner(s, key)
	if key == "directory":
		if value is String and (value == DEFAULT_DIRECTORY or (
				value.is_absolute_path() and not value.contains("://"))) and value.length() < 4096:
			directory = value
	elif typeof(owner.get(key)) == TYPE_BOOL:
		if value is bool:
			owner.set(key, value)
	elif value is int or value is float:
		if not is_finite(value):
			return
		if key == "compensation_thirds" and value == round(value) and abs(value) <= 15:
			s.exposure.compensation_thirds = int(value)
		elif key in OPTIONS:
			for item in OPTIONS[key]:
				if is_equal_approx(float(value), float(item)):
					owner.set(key, item)
					break


func _snapshot(s) -> Dictionary:
	var settings := {}
	for keys in [SESSION_KEYS, EXPOSURE_KEYS, OWN_KEYS]:
		for key in keys:
			settings[key] = _owner(s, key).get(key)
	return settings


func _persist(s) -> void:
	var current := _snapshot(s)
	if current == _saved or Time.get_ticks_msec() - _last_save_failure < 5000:
		return
	var error := Preferences.write(current)
	if error == OK:
		_saved = current
	else:
		_last_save_failure = Time.get_ticks_msec()
		s._status = "Could not save camera settings (%s)" % error_string(error)


func _pad() -> int:
	var connected := Input.get_connected_joypads()
	if _device not in connected:
		_device = connected[0] if not connected.is_empty() else -1
	return _device


static func stick(raw: Vector2) -> Vector2:
	const DEAD_ZONE := 0.18
	var strength := minf(raw.length(), 1.0)
	if strength <= DEAD_ZONE:
		return Vector2.ZERO
	return raw.normalized() * pow((strength - DEAD_ZONE) / (1.0 - DEAD_ZONE), 1.4)


func move_axis() -> Vector2:
	var id := _pad()
	if id < 0:
		return Vector2.ZERO
	return stick(Vector2(Input.get_joy_axis(id, JOY_AXIS_LEFT_X), Input.get_joy_axis(id, JOY_AXIS_LEFT_Y)))


func aim_axis() -> Vector2:
	var id := _pad()
	if id < 0:
		return Vector2.ZERO
	return stick(Vector2(Input.get_joy_axis(id, JOY_AXIS_RIGHT_X), Input.get_joy_axis(id, JOY_AXIS_RIGHT_Y)))


func height_axis() -> float:
	var id := _pad()
	if id < 0:
		return 0.0
	return float(Input.is_joy_button_pressed(id, JOY_BUTTON_RIGHT_SHOULDER)) - float(Input.is_joy_button_pressed(id, JOY_BUTTON_LEFT_SHOULDER))


func _toggle(s) -> void:
	visible = not visible
	s.help_open = false
	s._refresh()


func handle(s, event: InputEvent) -> bool:
	if picking:
		return true
	if event is InputEventJoypadMotion:
		_device = event.device
		if _back_device == event.device and absf(event.axis_value) > 0.3:
			_back_alone = false
		return true
	if event is InputEventJoypadButton:
		_device = event.device
		return _joy_button(s, event)
	if _back_device >= 0 and ((event is InputEventKey and event.pressed) or (event is InputEventMouseButton and event.pressed)):
		_back_alone = false
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_F4 and not event.echo:
			_toggle(s)
			return true
		if event.keycode == KEY_F2 and not event.echo:
			_pick(s)
			return true
		if visible and event.keycode in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE]:
			match event.keycode:
				KEY_UP: _navigate(s, -1)
				KEY_DOWN: _navigate(s, 1)
				KEY_LEFT: _adjust(s, ROWS[selected][0], -1)
				KEY_RIGHT: _adjust(s, ROWS[selected][0], 1)
				KEY_ENTER, KEY_KP_ENTER: _adjust(s, ROWS[selected][0], 1)
				KEY_ESCAPE: _toggle(s)
			return true
		if event.echo:
			return false
		match event.keycode:
			KEY_F7: _adjust(s, "lens", 1)
			KEY_BRACKETLEFT, KEY_BRACKETRIGHT:
				lens_preset = -1
				return false
			KEY_C: _adjust(s, "fringe_off", 1)
			KEY_V: _adjust(s, "clean_motion", 1)
			KEY_Y: _adjust(s, "dof_strength", 1)
			KEY_U: _adjust(s, "aperture", -1)
			KEY_I: _adjust(s, "aperture", 1)
			KEY_SEMICOLON: _adjust(s, "seconds", -1)
			KEY_APOSTROPHE: _adjust(s, "seconds", 1)
			KEY_COMMA: _adjust(s, "iso", -1)
			KEY_PERIOD: _adjust(s, "iso", 1)
			_: return false
		return true
	if visible:
		return true
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var step := 1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1
		if event.ctrl_pressed and event.alt_pressed:
			_adjust(s, "iso", step)
		elif event.alt_pressed:
			_adjust(s, "seconds", step)
		elif event.shift_pressed or event.ctrl_pressed:
			_adjust(s, "aperture", step)
		else:
			return false
		return true
	return false


func _joy_button(s, event: InputEventJoypadButton) -> bool:
	if event.button_index == JOY_BUTTON_BACK:
		if event.pressed:
			_back_device = event.device
			_back_alone = true
			for button in range(JOY_BUTTON_MAX):
				if button != JOY_BUTTON_BACK and Input.is_joy_button_pressed(event.device, button):
					_back_alone = false
		elif _back_device == event.device:
			if _back_alone:
				s.resume_photo()
			_back_device = -1
			_back_alone = false
		return true
	if not event.pressed:
		return true
	if _back_device >= 0:
		_back_alone = false
	if event.button_index == JOY_BUTTON_LEFT_STICK:
		_toggle(s)
	elif event.button_index == JOY_BUTTON_Y:
		s.request_shot(true)
	elif event.button_index == JOY_BUTTON_RIGHT_STICK:
		s.focus_requested = true
	elif visible:
		match event.button_index:
			JOY_BUTTON_DPAD_UP: _navigate(s, -1)
			JOY_BUTTON_DPAD_DOWN: _navigate(s, 1)
			JOY_BUTTON_DPAD_LEFT: _adjust(s, ROWS[selected][0], -1)
			JOY_BUTTON_DPAD_RIGHT, JOY_BUTTON_A: _adjust(s, ROWS[selected][0], 1)
			JOY_BUTTON_B: _toggle(s)
	elif event.button_index == JOY_BUTTON_A:
		s.request_shot(false)
	return true


func _navigate(s, direction: int) -> void:
	selected = posmod(selected + direction, ROWS.size())
	s._refresh()


func _automatic(s, key: String) -> bool:
	var e: Exposure = s.exposure
	match key:
		"aperture": return e.mode == Exposure.Mode.SHUTTER_PRIORITY
		"seconds": return e.mode in [Exposure.Mode.GAME, Exposure.Mode.APERTURE_PRIORITY]
		"iso": return e.mode == Exposure.Mode.GAME or e.auto_iso
		"auto_iso", "compensation_thirds": return e.mode == Exposure.Mode.GAME
		"min_iso", "max_iso": return e.mode == Exposure.Mode.GAME or not e.auto_iso
		"preferred_seconds": return e.mode != Exposure.Mode.APERTURE_PRIORITY or not e.auto_iso
		"grain_iso": return not grain or e.mode != Exposure.Mode.GAME
		_: return false


func _adjust(s, key: String, step: int) -> void:
	if _automatic(s, key):
		return
	if key == "directory":
		_pick(s)
		return
	var owner := _owner(s, key)
	var e: Exposure = s.exposure
	match key:
		"lens":
			var mm: float = s._mm()
			var lens: float = Optics.LENSES_MM.front() if step > 0 else Optics.LENSES_MM.back()
			for i in Optics.LENSES_MM.size():
				var candidate: float = Optics.LENSES_MM[i if step > 0 else -1-i]
				if (candidate - mm) * step > 0.05:
					lens = candidate
					break
			lens_preset = Optics.LENSES_MM.find(int(lens))
			s.camera.fov = Optics.lens_fov(lens, s._aspect(), s.camera.keep_aspect)
		"focus_m": s._step_focus(step)
		"compensation_thirds": e.compensation_thirds = clampi(e.compensation_thirds + step, -15, 15)
		_:
			var value: Variant = owner.get(key)
			if value is bool:
				owner.set(key, not value)
			elif key in OPTIONS:
				var choices: Array = OPTIONS[key]
				var index := choices.find(value)
				if key in ["frame_index", "reticle", "look", "mode", "dof_strength"]:
					index = posmod(index + step, choices.size())
				else:
					index = clampi(index + step, 0, choices.size() - 1)
				owner.set(key, choices[index])
				if key == "dof_strength":
					s.dof = true
				elif key == "min_iso":
					e.max_iso = maxi(e.max_iso, e.min_iso)
				elif key == "max_iso":
					e.min_iso = mini(e.min_iso, e.max_iso)
	s._apply_attributes()
	s._refresh()


func _pick(s) -> void:
	if picking:
		return
	if not DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		s._status = "Folder selection requires a native file dialog"
		s._refresh()
		return
	picking = true
	_picker_serial += 1
	_picker_mouse = Input.mouse_mode
	_picker_global = s.get_tree().root.get_node_or_null("global")
	if _picker_global and "showmouse" in _picker_global:
		_picker_showmouse = _picker_global.get("showmouse")
		_picker_global.set("showmouse", true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var path := ProjectSettings.globalize_path(directory)
	if not DirAccess.dir_exists_absolute(path):
		path = OS.get_user_data_dir()
	var error := DisplayServer.file_dialog_show("Choose screenshot folder", path, "", false,
		DisplayServer.FILE_DIALOG_MODE_OPEN_DIR, PackedStringArray(), _picked.bind(weakref(s), _picker_serial), s.get_window().get_window_id())
	if error != OK:
		_close_picker(s)
		s._status = "Could not open folder picker (%s)" % error_string(error)
		s._refresh()


func _close_picker(_s) -> void:
	if picking:
		picking = false
		_picker_serial += 1
		if is_instance_valid(_picker_global) and "showmouse" in _picker_global:
			_picker_global.set("showmouse", _picker_showmouse)
		Input.mouse_mode = _picker_mouse
		_picker_global = null


func _picked(ok: bool, paths: PackedStringArray, _filter: int, weak_session: WeakRef, serial: int) -> void:
	var s = weak_session.get_ref()
	if s == null or not picking or serial != _picker_serial:
		return
	_close_picker(s)
	if ok and not paths.is_empty() and DirAccess.dir_exists_absolute(paths[0]):
		directory = paths[0]
		s._status = "Screenshot folder: %s" % directory
	s._refresh()


static func shutter_text(seconds: float) -> String:
	return "1/%d s" % roundi(1.0 / seconds) if seconds <= 0.25 else "%s s" % seconds


func _value(s, key: String, reading: Exposure.Reading) -> String:
	var owner := _owner(s, key)
	match key:
		"mode": return MODES[s.exposure.mode]
		"look": return Film.NAMES[look]
		"lens": return "%.1f mm" % s._mm()
		"frame_index": return Optics.FRAME_NAMES[s.frame_index]
		"portrait": return "Rotated" if s.portrait else "Landscape"
		"reticle": return RETICLES[s.reticle]
		"fringe_off": return "Off" if fringe_off else "Game"
		"clean_motion": return "Clean" if clean_motion else "Game"
		"continuous_af": return "Continuous AF" if s.continuous_af else "Locked"
		"fine_focus": return "Fine (1%)" if s.fine_focus else "Coarse (20%)"
		"focus_m": return "%.2f m" % s.focus_m
		"compensation_thirds": return "%+.2f EV" % (s.exposure.compensation_thirds / 3.0)
		"preferred_seconds": return shutter_text(s.exposure.preferred_seconds)
		"aperture": return "f/%s" % (reading.aperture if reading.ready else s.exposure.aperture)
		"seconds": return shutter_text(reading.seconds if reading.ready else s.exposure.seconds)
		"iso": return str(reading.iso if reading.ready else s.exposure.iso)
		"dof_strength": return "%d×" % dof_strength
		"capture_scale": return "%d×   %s" % [capture_scale, s.finder.print_dimensions]
		"directory": return ProjectSettings.globalize_path(directory)
		_:
			var value: Variant = owner.get(key)
			if value is bool:
				return "On" if value else "Off"
			return str(value)


func refresh(s, reading: Exposure.Reading) -> void:
	if not s.finder or not is_instance_valid(_film):
		return
	if s.state and s.state.has_method("apply_effects"):
		s.state.apply_effects(fringe_off, clean_motion)
	_film.configure(look, grain, grain_iso if s.exposure.mode == Exposure.Mode.GAME else reading.iso)
	_persist(s)
	var finder = s.finder
	finder.studio_open = visible
	finder.meter_ev = reading.meter_error_ev
	if is_nan(finder.meter_ev) and is_finite(reading.metered_ev100):
		finder.meter_ev = reading.metered_ev100 - reading.camera_ev100
	finder.focus_feedback = ""
	if is_finite(center_distance):
		var offset: float = center_distance - s.focus_m
		var aligned := Optics.circle_of_confusion_mm(s._mm(), reading.aperture, s.focus_m, center_distance) < 0.03
		var relation := "aligned" if aligned else ("near" if offset < 0.0 else "far")
		finder.focus_feedback = "Center %.2f m · %s" % [center_distance, relation]
	var pixels: Vector2i = finder.render_size(s.get_viewport())
	var crop := Optics.crop_rect(pixels, s.frame_index, s.portrait)
	var size := crop.size * capture_scale
	finder.print_dimensions = "%d × %d" % [size.x, size.y]
	if plan_capture.is_valid():
		var timed: bool = s.exposure.mode != Exposure.Mode.GAME and reading.seconds >= 1.0 / 15
		var plan: Dictionary = plan_capture.call(pixels, s.frame_index, s.portrait, capture_scale, timed)
		if plan.ok:
			size = plan.size
			finder.print_dimensions = "%d × %d" % [size.x, size.y]
		else:
			finder.print_dimensions = plan.reason
	finder.studio_lines = []
	if visible:
		for row in ROWS:
			finder.studio_lines.append([row[1], _value(s, row[0], reading), _automatic(s, row[0])])
	finder.studio_selection = selected
	finder.queue_redraw()
