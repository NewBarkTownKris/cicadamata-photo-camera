extends SceneTree
## Synthetic visible-frame test. Run in a disposable project on private Xvfb.

const Session = preload("res://cicadamata_photo/session.gd")
const SIZE := Vector2i(320, 180)
var session := Session.new()
var gameplay := Camera3D.new()
var hud := ColorRect.new()
var failures := 0
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr(message)


func _setup_scene() -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = SIZE
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var player := CharacterBody3D.new()
	scene.add_child(player)
	player.add_to_group(&"player")
	var head := Node3D.new()
	head.name = "Head"
	player.add_child(head)
	gameplay.name = "Camera3D"
	head.add_child(gameplay)
	gameplay.make_current()
	var pause := Node.new()
	pause.name = "PauseController"
	player.add_child(pause)

	var world_card := MeshInstance3D.new()
	var card := QuadMesh.new()
	card.size = Vector2(14.0, 8.0)
	world_card.mesh = card
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode unshaded, cull_disabled; void fragment() { ALBEDO = vec3(UV, 0.125); }"
	var material := ShaderMaterial.new()
	material.shader = shader
	world_card.material_override = material
	scene.add_child(world_card)
	world_card.position.z = -4.0

	var ui := CanvasLayer.new()
	ui.name = "UI"
	root.add_child(ui)
	hud.name = "Crosshairs"
	hud.position = Vector2(SIZE) / 2.0 - Vector2(16, 12)
	hud.size = Vector2(32, 24)
	hud.color = Color.MAGENTA
	ui.add_child(hud)
	root.add_child(session)


func _press(key: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)


func _render() -> Image:
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _rgb(image: Image) -> PackedByteArray:
	image.convert(Image.FORMAT_RGB8)
	return image.get_data()


func _file_names() -> PackedStringArray:
	var directory := DirAccess.open(Session.OUTPUT)
	return directory.get_files() if directory else PackedStringArray()


func _run() -> void:
	if DisplayServer.get_name() != "X11" or "llvmpipe" not in RenderingServer.get_video_adapter_name().to_lower():
		printerr("This render fixture requires a private Xvfb X11 display with Mesa llvmpipe.")
		quit(1)
		return
	_setup_scene()
	await _render()
	hud.hide()
	var reference := await _render()
	check(reference.get_size() == SIZE, "synthetic reference has requested dimensions")
	check(reference.get_pixel(40, 20) != reference.get_pixel(280, 160), "3D card has spatially varying pixels")
	hud.show()
	var before := await _render()
	check(before.get_pixel(160, 90).is_equal_approx(Color.MAGENTA), "HUD sentinel appears over the world before entering")
	_press(KEY_F8)
	check(session.state != null and paused and root.get_camera_3d() != gameplay, "F8 froze the synthetic scene and switched cameras")
	if not session.state:
		quit(1)
		return
	_press(KEY_F5)
	for rotated in [false, true]:
		if rotated:
			_press(KEY_F6)
		var crop := Rect2i(100, 0, 120, 180) if rotated else Rect2i(25, 0, 270, 180)
		var expected := _rgb(reference.get_region(crop))
		var framed := await _render()
		check(_rgb(framed.get_region(crop)) != expected, "finder visibly alters pixels inside the chosen crop")
		check(not hud.is_visible_in_tree(), "game HUD is hidden in photo mode")
		var old_files := _file_names()
		_press(KEY_F9)
		var deadline := Time.get_ticks_msec() + 6000
		while session._shot_pending and Time.get_ticks_msec() < deadline:
			await process_frame
		var new_files := _file_names()
		for previous in old_files:
			new_files.remove_at(new_files.find(previous))
		check(new_files.size() == 1, "one completed F9 PNG per shutter: " + str(session._status))
		if new_files.size() == 1:
			var opened := Image.load_from_file(Session.OUTPUT.path_join(new_files[0]))
			check(opened != null and opened.get_size() == crop.size, "decoded PNG has exact chosen dimensions")
			if opened:
				check(_rgb(opened) == expected, "every PNG pixel matches the clean 3D reference crop")
		check(session.overlay.visible, "finder returns after publishing")
	_press(KEY_F8)
	for i in 6:
		await physics_frame
		if not session.state:
			break
	var restored := await _render()
	check(not paused and root.get_camera_3d() == gameplay, "resume restored the gameplay camera")
	check(restored.get_pixel(160, 90).is_equal_approx(Color.MAGENTA), "resume restored the original HUD pixels")
	print("%s rendered session checks, %s failures" % [checks, failures])
	quit(1 if failures else 0)
