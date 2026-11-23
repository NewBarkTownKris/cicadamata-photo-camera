extends SceneTree
## Verify the grading pass can sample the title's finished canvas after an
## earlier screen reader has run, and that a neutral pass is pixel exact.

const Film := preload("res://cicadamata_photo/film.gd")
var checks := 0
var failures := 0


func _initialize() -> void:
	run.call_deferred()


func check(ok: bool, hint: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL ", hint)


func rect(parent: Node, color: Color) -> ColorRect:
	var node := ColorRect.new()
	parent.add_child(node)
	node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	node.color = color
	return node


func frame() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func variance(image: Image) -> float:
	var mean := 0.0
	var sq := 0.0
	var count := 0
	for y in range(4, 28):
		for x in range(4, 40):
			var level := image.get_pixel(x, y).g
			mean += level
			sq += level * level
			count += 1
	return sq / count - pow(mean / count, 2.0)


func run() -> void:
	if DisplayServer.get_name() != "X11" or not "llvmpipe" in RenderingServer.get_video_adapter_name().to_lower():
		printerr("Use the private software-display runner")
		quit(1)
		return
	root.size = Vector2i(96, 64)
	var layer := CanvasLayer.new()
	root.add_child(layer)
	rect(layer, Color.DARK_GRAY)
	var initial_copy := BackBufferCopy.new()
	initial_copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	layer.add_child(initial_copy)
	# Represents title effects applied after an existing back buffer copy.
	rect(layer, Color(0.7, 0.4, 0.2))
	var before := await frame()
	var film := Film.new()
	root.add_child(film)
	film.configure(0, false, 6400)
	var neutral := await frame()
	check(before.get_data() == neutral.get_data(), "neutral bypass")
	film.configure(9, false, 100)
	var mono := await frame()
	var pixel := mono.get_pixel(8, 8)
	check(is_equal_approx(pixel.r, pixel.g) and is_equal_approx(pixel.g, pixel.b), "silver print monochrome")
	check(pixel.r > 0.36, "look uses the later title treatment")
	film.configure(0, true, 100)
	var slow := await frame()
	film.configure(0, true, 6400)
	var fast := await frame()
	check(variance(fast) > 8.0 * variance(slow), "grain variance grows with ISO")
	film.configure(0, false, 100)
	var restored := await frame()
	check(before.get_data() == restored.get_data(), "game pixels restored")
	print("%d rendered film checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
