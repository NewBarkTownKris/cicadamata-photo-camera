extends Node

const GameState := preload("res://cicadamata_photo/game_state.gd")
const Optics := preload("res://cicadamata_photo/camera_math.gd")
const Exposure := preload("res://cicadamata_photo/exposure.gd")
const DepthOfField := preload("res://cicadamata_photo/depth_of_field.gd")
const Finder := preload("res://cicadamata_photo/finder.gd")
const Capture := preload("res://cicadamata_photo/capture.gd")
const Studio := preload("res://cicadamata_photo/studio.gd")
const Linear := preload("res://cicadamata_photo/linear_capture.gd")
const OUTPUT := "user://CICADAMATA-Photo/Photos"
const METER_TIMEOUT_MS := 2500

var state: GameState
var camera: Camera3D
var finder: Finder
var overlay: CanvasLayer
var exposure := Exposure.new()
var focus_m := 5.0
var continuous_af := false
var focus_requested := false
var _next_af_ms := 0
var dof := false
var fine_focus := false
var frame_index := 0
var portrait := false
var show_grid := true
var reticle := 0
var guides := true
var help_open := false
var _game_attributes: CameraAttributesPractical
var _photo_attributes: CameraAttributesPractical
var _angles := Vector3.ZERO
var _last_tick := 0
var capture := Capture.new()
var studio := Studio.new()
var optics_effect: DepthOfField
var linear: Linear
var _meter_id := -1
var _meter_deadline := 0
var _next_meter := 0
var _meter_gate: Array = []
var _luminance := NAN
var _waiting_meter := false
var _pair_requested := false
var _shot_used_optical := false
var _shot_pending: bool:
	get: return capture.busy or _waiting_meter
var _resume_pending := false
var _f8_armed := false
var _neutral_tick := false
var last_shot := {}
var _status := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	studio.plan_capture = Capture.plan
	capture.finished.connect(_capture_finished)
	capture.progress.connect(_capture_progress)
	capture.band_origin.connect(studio.set_pixel_origin)
	set_process(false)
	set_physics_process(false)


func enter() -> bool:
	if state:
		return false
	var candidate := GameState.new()
	if not candidate.identify(get_tree()):
		return false
	var source := candidate.source
	if source.attributes and not source.attributes is CameraAttributesPractical:
		return false
	state = candidate
	camera = Camera3D.new()
	camera.name = "DetachedCamera"
	camera.keep_aspect = source.keep_aspect
	camera.set_perspective(source.fov, source.near, source.far)
	camera.cull_mask = source.cull_mask
	camera.environment = source.environment
	camera.compositor = source.compositor
	camera.attributes = source.attributes
	_game_attributes = source.attributes as CameraAttributesPractical
	_photo_attributes = _game_attributes.duplicate() if _game_attributes else CameraAttributesPractical.new()
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# Capture the evaluated transform, which includes the camera's offsets.
	var pose := source.get_camera_transform()
	add_child(camera)
	camera.global_transform = pose
	_angles = pose.basis.orthonormalized().get_euler(EULER_ORDER_YXZ)
	state.freeze(get_tree(), self)
	camera.make_current()
	get_tree().node_added.connect(_node_added)
	overlay = CanvasLayer.new()
	overlay.layer = 120
	add_child(overlay)
	finder = Finder.new()
	overlay.add_child(finder)
	focus_m = 5.0
	continuous_af = false
	focus_requested = false
	dof = false
	fine_focus = false
	_status = ""
	_luminance = NAN
	_next_meter = 0
	_next_af_ms = 0
	linear = Linear.new()
	optics_effect = DepthOfField.new()
	linear.install(camera, optics_effect)
	studio.open_session(self)
	_last_tick = Time.get_ticks_usec()
	_apply_attributes()
	_refresh()
	set_process(true)
	set_physics_process(true)
	return true


func _node_added(node: Node) -> void:
	if state:
		state.guard_new_node(node, self)


func leave() -> void:
	if not state:
		return
	_cancel_meter()
	_waiting_meter = false
	if capture.busy:
		capture.cancel("Photo mode closed")
	linear.uninstall(camera)
	optics_effect.close()
	optics_effect = null
	linear = null
	studio.close_session(self)
	_resume_pending = false
	_f8_armed = false
	_neutral_tick = false
	get_tree().node_added.disconnect(_node_added)
	state.restore(get_tree(), camera)
	state = null
	if is_instance_valid(camera):
		camera.queue_free()
	if is_instance_valid(overlay):
		overlay.hide()
		overlay.queue_free()
	camera = null
	overlay = null
	finder = null
	_photo_attributes = null
	_game_attributes = null
	set_process(false)
	set_physics_process(false)


func _exit_tree() -> void:
	if state:
		leave()


func _intact() -> bool:
	return (is_instance_valid(state.scene) and state.scene == get_tree().current_scene
			and is_instance_valid(state.player) and state.player.is_inside_tree()
			and is_instance_valid(state.source) and state.source.is_inside_tree()
			and state.player.get_node_or_null("Head/Camera3D") == state.source
			and is_instance_valid(camera) and camera.is_inside_tree()
			and camera == get_viewport().get_camera_3d() and get_tree().paused)


func _process(_delta: float) -> void:
	if not _intact():
		leave()
		return
	if capture.busy:
		if capture.recording:
			_move_camera()
		capture.tick()
		return
	if _resume_pending:
		return
	_update_meter()
	if not _shot_pending and not studio.blocks_motion():
		_move_camera()
	else:
		_last_tick = Time.get_ticks_usec()


func _move_camera() -> void:
	var now := Time.get_ticks_usec()
	var elapsed := clampf(float(now - _last_tick) / 1e6, 0.0, 0.1)
	_last_tick = now
	var speed := 6.0
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= 4.0
	if Input.is_key_pressed(KEY_CTRL):
		speed *= 0.2
	var move := Vector3(_keys(KEY_D, KEY_A), 0.0, _keys(KEY_S, KEY_W))
	var stick := studio.move_axis()
	move.x += stick.x
	move.z += stick.y
	var vertical := _keys(KEY_E, KEY_Q) + studio.height_axis()
	var displacement := camera.basis * move + Vector3.UP * vertical
	camera.position += displacement.limit_length(1.0) * speed * elapsed
	var aim := Vector2(_keys(KEY_RIGHT, KEY_LEFT), _keys(KEY_DOWN, KEY_UP))
	_turn((aim + studio.aim_axis()) * elapsed * 1.25)
	_angles.z += _keys(KEY_Z, KEY_X) * elapsed
	camera.basis = Basis.from_euler(_angles, EULER_ORDER_YXZ)


func _keys(positive: Key, negative: Key) -> float:
	return float(Input.is_physical_key_pressed(positive)) - float(Input.is_physical_key_pressed(negative))


func _aspect() -> float:
	var size := get_viewport().get_visible_rect().size
	return size.aspect() if size.y > 0.0 else 1.0


func _mm() -> float:
	return Optics.focal_length(camera.fov, _aspect(), camera.keep_aspect)


func _turn(motion: Vector2) -> void:
	var sensitivity := minf(1.0, 35.0 / _mm())
	_angles.y -= motion.x * sensitivity
	_angles.x = clampf(_angles.x - motion.y * sensitivity, -PI / 2 + 0.001, PI / 2 - 0.001)


func _input(event: InputEvent) -> void:
	if state and studio.picking:
		return
	if not state and event is InputEventJoypadButton and event.button_index == JOY_BUTTON_BACK and event.pressed:
		if enter():
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.keycode == KEY_F8 and not event.echo:
		if not state:
			if event.pressed and enter():
				get_viewport().set_input_as_handled()
			return
		# Arm on the second press and resume on release so the gesture is consumed.
		if event.pressed:
			_f8_armed = true
		elif _f8_armed:
			_f8_armed = false
			resume_photo()
		get_viewport().set_input_as_handled()
		return
	if not state:
		return
	get_viewport().set_input_as_handled()
	if _resume_pending or not _intact():
		return
	if _shot_pending:
		var wants_pair: bool = (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3
			or event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_Y)
		if wants_pair:
			if _waiting_meter:
				_pair_requested = true
			elif capture.busy:
				var issue: String = capture.promote_to_pair()
				if not issue.is_empty():
					_status = issue
					push_warning("[CICADAMATA Photo] " + issue)
					_refresh()
		if capture.recording and event is InputEventMouseMotion:
			_turn(event.screen_relative * 0.0025)
		if event is InputEventJoypadButton and event.button_index == JOY_BUTTON_BACK:
			studio.handle(self, event)
		return
	if studio.handle(self, event):
		return
	if event is InputEventMouseMotion:
		_turn(event.screen_relative * 0.0025)
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT: request_shot()
			MOUSE_BUTTON_MIDDLE: focus_requested = true
			MOUSE_BUTTON_WHEEL_UP: _step_focus(-1)
			MOUSE_BUTTON_WHEEL_DOWN: _step_focus(1)
	elif event is InputEventKey and event.pressed and not event.echo:
		_key(event.keycode)


func _key(key: Key) -> void:
	match key:
		KEY_F9, KEY_F3:
			request_shot(key == KEY_F3)
			return
		KEY_F1: help_open = not help_open
		KEY_H: guides = not guides
		KEY_G: show_grid = not show_grid
		KEY_R: reticle = (reticle + 1) % 4
		KEY_F5: frame_index = (frame_index + 1) % Optics.FRAME_NAMES.size()
		KEY_F6: portrait = not portrait
		KEY_F10: _angles.z = 0.0
		KEY_F7:
			var next_mm: int = Optics.LENSES_MM[0]
			for lens: int in Optics.LENSES_MM:
				if lens > _mm() + 0.05:
					next_mm = lens
					break
			camera.fov = Optics.lens_fov(next_mm, _aspect(), camera.keep_aspect)
		KEY_BRACKETLEFT: camera.fov = clampf(camera.fov - 1.0, 1.0, 150.0)
		KEY_BRACKETRIGHT: camera.fov = clampf(camera.fov + 1.0, 1.0, 150.0)
		KEY_N: focus_requested = true
		KEY_T: continuous_af = not continuous_af
		KEY_L: fine_focus = not fine_focus
		KEY_J: _step_focus(-1)
		KEY_K: _step_focus(1)
		KEY_B: dof = not dof
		KEY_O:
			exposure.mode = (int(exposure.mode) + 1) % Studio.MODES.size() as Exposure.Mode
		_: return
	_apply_attributes()
	_refresh()


func _step_focus(direction: int) -> void:
	continuous_af = false
	focus_m = clampf(focus_m * pow(1.01 if fine_focus else 1.2, direction), 0.1, camera.far)
	_apply_attributes()
	_refresh()


func _physics_process(_delta: float) -> void:
	if not state or _shot_pending or not _intact():
		return
	if _resume_pending:
		_resume_when_released()
		return
	var now := Time.get_ticks_msec()
	if not focus_requested and (now < _next_af_ms or (not continuous_af and not studio.needs_distance())):
		return
	var adjust_focus := focus_requested or continuous_af
	focus_requested = false
	_next_af_ms = now + 200
	var center := get_viewport().get_visible_rect().get_center()
	var origin := camera.project_ray_origin(center)
	var direction := camera.project_ray_normal(center)
	var exclusions: Array[RID] = [state.player.get_rid()]
	var object_area := state.player.get_node_or_null("ObjectArea") as CollisionObject3D
	if object_area:
		exclusions.append(object_area.get_rid())
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * camera.far, 0xffffffff, exclusions)
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	studio.center_distance = clampf((hit.position - origin).dot(direction), 0.1, camera.far) if hit.has("position") else NAN
	if adjust_focus:
		if is_finite(studio.center_distance):
			focus_m = studio.center_distance
			_status = "Focus acquired"
			_apply_attributes()
		else:
			_status = "No focus target"
	_refresh()


func _apply_attributes() -> void:
	# The print shutter temporarily sets an off-center frustum and changes
	# the root viewport dimensions. Keep the lens, aperture and sensor pitch
	# from the finder until the original camera and viewport are restored.
	if capture.busy:
		return
	var shot := exposure.solve(_luminance)
	if linear:
		linear.set_gain(shot.gain if shot.ready else 1.0)
	var focal := _mm()
	var nearest := maxf(camera.near, maxf(0.1, (focal + 1.0) / 1000.0))
	focus_m = clampf(focus_m, nearest, camera.far)
	var raster_width := Finder.render_size(get_viewport()).x
	var optical_blur := optics_effect.configure(dof and linear.is_available(), focus_m, focal,
		shot.aperture, studio.dof_strength, raster_width)
	if not dof and exposure.mode == Exposure.Mode.GAME:
		camera.attributes = _game_attributes
		return
	camera.attributes = _photo_attributes
	var base_gain := _game_attributes.exposure_multiplier if _game_attributes else 1.0
	_photo_attributes.exposure_multiplier = base_gain * (shot.gain if shot.ready and not linear.is_available() else 1.0)
	_photo_attributes.auto_exposure_enabled = (_game_attributes != null
		and _game_attributes.auto_exposure_enabled and exposure.mode == Exposure.Mode.GAME)
	if not dof:
		_photo_attributes.dof_blur_near_enabled = _game_attributes != null and _game_attributes.dof_blur_near_enabled
		_photo_attributes.dof_blur_far_enabled = _game_attributes != null and _game_attributes.dof_blur_far_enabled
		if _game_attributes:
			for key in ["dof_blur_amount", "dof_blur_near_distance", "dof_blur_near_transition",
					"dof_blur_far_distance", "dof_blur_far_transition"]:
				_photo_attributes.set(key, _game_attributes.get(key))
		return
	if optical_blur:
		# Optical DOF already ran before the HDR tap. Suppress any inherited
		# camera blur so the display receives exactly the same optical pass.
		_photo_attributes.dof_blur_near_enabled = false
		_photo_attributes.dof_blur_far_enabled = false
		return
	# Forward+ can still use Godot's physical depth kernel when a driver
	# cannot allocate the custom compositor. It uses a 64-pixel base radius.
	_photo_attributes.dof_blur_near_enabled = true
	_photo_attributes.dof_blur_far_enabled = true
	_photo_attributes.dof_blur_near_distance = focus_m
	_photo_attributes.dof_blur_far_distance = focus_m
	_photo_attributes.dof_blur_near_transition = -1.0
	_photo_attributes.dof_blur_far_transition = -1.0
	var diameter_mm := focal * focal / (shot.aperture * (focus_m * 1000.0 - focal))
	_photo_attributes.dof_blur_amount = clampf(0.5 * diameter_mm * raster_width * studio.dof_strength /
		(Optics.SENSOR_WIDTH_MM * 64.0), 0.0, 1.0)


func _refresh() -> void:
	if capture.busy:
		_capture_progress(_status)
		return
	finder.frame_index = frame_index
	finder.portrait = portrait
	finder.show_grid = show_grid
	finder.reticle = reticle
	finder.help_open = help_open
	var shot := exposure.solve(_luminance)
	var blur_label := "Off"
	if dof:
		blur_label = "%d×" % studio.dof_strength
		if not optics_effect.enabled:
			blur_label += " display only" if RenderingServer.get_current_rendering_method() != "gl_compatibility" else " (requires Forward+)"
	finder.readout = "%.1f mm  |  %s  |  f/%s  |  %s  |  ISO %d  |  %s %.2f m  |  DOF %s" % [
		_mm(), Studio.MODES[exposure.mode], shot.aperture, Studio.shutter_text(shot.seconds), shot.iso,
		"AF-C" if continuous_af else "Focus", focus_m, blur_label]
	finder.status = _status
	overlay.visible = guides or studio.visible or _resume_pending
	studio.refresh(self, shot)
	finder.queue_redraw()


func _gate() -> Array:
	return [camera.global_transform, camera.fov, frame_index, portrait, Finder.render_size(get_viewport())]


func _cancel_meter() -> void:
	if _meter_id >= 0:
		linear.cancel(_meter_id)
		_meter_id = -1


func _arm_meter() -> void:
	_meter_gate = _gate()
	var size: Vector2i = _meter_gate.back()
	_meter_id = linear.arm(Optics.crop_rect(size, frame_index, portrait), size, true)
	_meter_deadline = Time.get_ticks_msec() + METER_TIMEOUT_MS


func _update_meter() -> void:
	if not linear.is_available():
		return
	var now := Time.get_ticks_msec()
	if _meter_id < 0:
		if now >= _next_meter:
			_arm_meter()
		return
	var result := linear.take(_meter_id)
	if result.is_empty() and now < _meter_deadline:
		return
	_cancel_meter()
	_next_meter = now + 300
	if result.get("ok", false):
		if _waiting_meter and _gate() != _meter_gate:
			_arm_meter()
			return
		_luminance = result.luminance
		_apply_attributes()
		_refresh()
		if _waiting_meter:
			_waiting_meter = false
			_start_shot(_pair_requested)
	elif _waiting_meter:
		_waiting_meter = false
		_status = result.get("message", "Scene meter timed out")
		_refresh()


func request_shot(paired := false) -> void:
	if not state or _shot_pending or not _intact():
		return
	_cancel_meter()
	if exposure.mode != Exposure.Mode.GAME and (exposure.auto_iso or exposure.mode != Exposure.Mode.MANUAL):
		if not linear.is_available():
			_status = "Metered exposure requires Forward+"
			_refresh()
			return
		_waiting_meter = true
		_pair_requested = paired
		_arm_meter()
		return
	_start_shot(paired)


func _start_shot(paired: bool) -> void:
	if dof and optics_effect.has_failed():
		_apply_attributes()
	_shot_used_optical = optics_effect.enabled
	var shot := exposure.solve(_luminance)
	var meta := {"cicadamataExposureMode": Studio.MODES[exposure.mode], "focalLength": _mm()}
	if exposure.mode != Exposure.Mode.GAME:
		meta.merge({"expTime": shot.seconds, "aperture": shot.aperture, "isoSpeed": shot.iso})
	var seconds := shot.seconds if exposure.mode != Exposure.Mode.GAME and shot.seconds >= 1.0/15 else 0.0
	var error := capture.begin(camera, overlay, {"frame_index":frame_index, "portrait":portrait,
		"scale":studio.capture_scale, "directory":studio.directory, "paired":paired, "seconds":seconds,
		"gain":shot.gain, "metadata":meta}, linear)
	if not error.is_empty():
		push_warning("[CICADAMATA Photo] " + error)
		_status = error
		_refresh()


func _capture_progress(message: String) -> void:
	_status = message
	finder.status = message
	finder.queue_redraw()


func _capture_finished(result: Dictionary) -> void:
	if result.ok and dof and optics_effect:
		if _shot_used_optical and optics_effect.has_failed():
			result.message += " · Optical DOF unavailable during capture"
		elif not _shot_used_optical and not result.exr_path.is_empty():
			result.message += " · Optical DOF unavailable in EXR"
	last_shot = result
	_status = result.message
	if not result.path.is_empty():
		print("[CICADAMATA Photo] ", _status, " ", result.path, " ", result.exr_path)
	elif not result.ok:
		push_warning("[CICADAMATA Photo] " + _status)
	_last_tick = Time.get_ticks_usec()
	if state and is_instance_valid(finder) and is_instance_valid(camera):
		_refresh()


func resume_photo() -> void:
	_resume_pending = true
	if _waiting_meter:
		_waiting_meter = false
		_cancel_meter()
	if capture.cancelable:
		capture.cancel("Canceled with resume control")


func _resume_when_released() -> void:
	# Consuming events does not clear Godot's Input singleton. The player
	# polls mapped actions (including fire/aim) on its first physics tick.
	for action in InputMap.get_actions():
		if (Input.is_action_pressed(action) or Input.is_action_just_pressed(action)
				or Input.is_action_just_released(action)):
			_neutral_tick = false
			if _status != "Release held controls to resume":
				_status = "Release held controls to resume"
				_refresh()
			return
	# An entire neutral physics tick also drains same-frame clicks and releases
	# before the shipped player regains its polling callbacks.
	if _neutral_tick:
		leave()
	else:
		_neutral_tick = true
