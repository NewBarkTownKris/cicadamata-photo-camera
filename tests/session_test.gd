extends SceneTree
const Session := preload("res://cicadamata_photo/session.gd")
class SteamService extends Node:
	var showmouse := true

var failures := 0
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL ", message)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var session := Session.new()
	root.add_child(session)
	check(not session.enter(), "no playable camera")
	var player := CharacterBody3D.new()
	scene.add_child(player)
	player.add_to_group(&"player")
	var head := Node3D.new()
	head.name = "Head"
	player.add_child(head)
	var source := Camera3D.new()
	source.name = "Camera3D"
	source.position = Vector3(2, 3, -4)
	source.rotation = Vector3(0.2, -0.6, 0.14)
	source.fov = 37.85
	source.h_offset = 0.2
	source.v_offset = -0.15
	source.attributes = CameraAttributesPractical.new()
	source.attributes.exposure_multiplier = 2.0
	head.add_child(source)
	source.make_current()
	var controller := Node.new()
	controller.name = "PauseController"
	controller.process_mode = Node.PROCESS_MODE_ALWAYS
	player.add_child(controller)
	var rig := Node3D.new()
	rig.name = "RigFPS"
	source.add_child(rig)
	var global := SteamService.new()
	global.name = "global"
	global.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(global)
	var ui := CanvasLayer.new()
	ui.name = "UI"
	root.add_child(ui)
	var crosshair := ColorRect.new()
	crosshair.name = "Crosshairs"
	ui.add_child(crosshair)
	var hint := Label.new()
	hint.name = "Hint"
	hint.hide()
	ui.add_child(hint)
	var vhs := ColorRect.new()
	vhs.name = "VHS"
	ui.add_child(vhs)
	var menu := Control.new()
	menu.name = "Pause"
	ui.add_child(menu)
	check(not session.enter(), "native pause menu")
	menu.hide()
	paused = true
	check(not session.enter(), "already paused")
	paused = false

	var original_transform := source.get_camera_transform()
	var wall := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 4.0, 0.2)
	collider.shape = box
	wall.add_child(collider)
	scene.add_child(wall)
	wall.global_transform = original_transform.translated_local(Vector3(0.0, 0.0, -8.0))
	await physics_frame
	await physics_frame
	check(session.enter(), "enter")
	check(paused and root.get_camera_3d() == session.camera, "frozen and detached")
	check(session.camera.get_camera_transform().is_equal_approx(original_transform), "evaluated source pose, including offsets")
	check(session.camera.fov == source.fov and session.camera.attributes == source.attributes, "game lens and treatment")
	check(not rig.visible and not crosshair.visible and not hint.visible and vhs.visible, "HUD and source rig suppressed")
	check(not controller.can_process(), "game controller blocked during pause")
	check(global.can_process() and not global.showmouse, "Steam service stays active while mod owns cursor")
	check(session.can_process(), "session can process while paused")
	check(not session.enter(), "re-entry guard")
	session._key(KEY_F7)
	check(not is_equal_approx(session.camera.fov, source.fov), "lens preset detaches")
	session._key(KEY_O)
	session._key(KEY_PERIOD)
	check(session.camera.attributes != source.attributes and source.attributes.exposure_multiplier == 2.0, "isolated manual attributes")
	session._key(KEY_B)
	check(session.camera.attributes.dof_blur_near_enabled and not source.attributes.dof_blur_near_enabled, "isolated DOF")
	session._key(KEY_J)
	check(session.focus_m < 5.0, "manual focus")
	session._key(KEY_T)
	check(session.continuous_af, "continuous focus enabled")
	session._physics_process(0.01)
	check(absf(session.focus_m - 7.9) < 0.05, "center ray acquired collision in paused physics world")
	var hit_distance := session.focus_m
	session.camera.rotate_y(PI)
	session.focus_requested = true
	session._physics_process(0.01)
	check(session.focus_m == hit_distance, "miss retained last focus")
	session.request_shot()
	check(session._shot_pending and not session.overlay.visible, "shutter locks and hides all guides")
	session.request_shot()
	session.capture._deadline = 0
	session._process(0.01)
	check(not session._shot_pending and session.overlay.visible, "render timeout recovers")
	InputMap.add_action("shoot")
	Input.action_press("shoot")
	var key := InputEventKey.new()
	key.keycode = KEY_F8
	key.pressed = true
	root.push_input(key)
	key.pressed = false
	root.push_input(key)
	for i in 3:
		await physics_frame
	check(paused and session.state != null, "held fire keeps gameplay frozen during resume")
	Input.action_release("shoot")
	for i in 6:
		await physics_frame
		if not session.state:
			break
	check(global.showmouse, "original Steam service cursor policy restored")
	check(not paused and source == root.get_camera_3d(), "original camera and simulation restored")
	check(controller.process_mode == Node.PROCESS_MODE_ALWAYS, "pause controller restored")
	check(rig.visible and crosshair.visible and not hint.visible and vhs.visible, "exact visibility restoration")
	check(source.get_camera_transform().is_equal_approx(original_transform) and is_equal_approx(source.fov, 37.85), "original pose")
	await process_frame
	check(session.enter(), "second session")
	var other := Camera3D.new()
	scene.add_child(other)
	other.make_current()
	session._process(0.01)
	check(not session.state and not paused and root.get_camera_3d() == other, "replacement camera kept")
	source.make_current()
	await process_frame
	check(session.enter(), "third session")
	rig.free()
	source.free()
	session._process(0.01)
	check(not session.state and not paused and crosshair.visible, "recovers after freed gameplay camera")
	print("%d session checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
