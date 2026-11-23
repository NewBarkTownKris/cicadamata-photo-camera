extends SceneTree
## Run with Godot --headless --path <mod fixture> --script <this file>.

const Finder = preload("res://cicadamata_photo/finder.gd")

var failures := 0


func _initialize() -> void:
	run.call_deferred()


func check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1


func run() -> void:
	root.content_scale_size = Vector2i(640, 360)
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	root.size = Vector2i(1920, 1080)
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var finder := Finder.new()
	layer.add_child(finder)
	for mode in [Window.CONTENT_SCALE_MODE_DISABLED, Window.CONTENT_SCALE_MODE_VIEWPORT, Window.CONTENT_SCALE_MODE_CANVAS_ITEMS]:
		root.content_scale_mode = mode
		await process_frame
		var expected := Vector2i(640, 360) if mode == Window.CONTENT_SCALE_MODE_VIEWPORT else Vector2i(1920, 1080)
		check(Finder.render_size(root) == expected, "Incorrect render size for mode %s" % mode)
		check(finder.size == root.get_visible_rect().size, "Finder must fill the logical viewport")
	check(finder.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Finder must pass through camera input")
	check(finder.focus_mode == Control.FOCUS_NONE, "Finder must not take keyboard focus")
	var viewport := SubViewport.new()
	viewport.size = Vector2i(913, 517)
	viewport.size_2d_override = Vector2i(320, 180)
	viewport.size_2d_override_stretch = true
	root.add_child(viewport)
	check(Finder.render_size(viewport) == Vector2i(913, 517), "Use SubViewport render dimensions")
	finder.frame_index = 7
	finder.portrait = true
	finder.show_grid = true
	finder.help_open = true
	finder.readout = "85 mm     f/2.8"
	finder.status = "Saved PNG"
	for mode in range(4):
		finder.reticle = mode
		await process_frame
	if failures == 0:
		print("Finder layout checks passed.")
	quit(1 if failures else 0)
