extends SceneTree
const Capture = preload("res://cicadamata_photo/capture.gd")
const Png = preload("res://cicadamata_photo/png_rows.gd")
const Sum = preload("res://cicadamata_photo/shutter_sum.gd")
var failures := 0


func check(ok: bool, description: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL ", description)


func _initialize() -> void:
	var plan := Capture.plan(Vector2i(1920,1080), 7, false, 4, false)
	check(plan.ok and plan.size == Vector2i(7540,2784) and plan.crop.position == Vector2i(17,192), "locked panorama crop")
	check(not Capture.plan(Vector2i(5000,2500), 7, false, 4, false).ok, "full target dimension bound")
	check(Capture.plan(Vector2i(5120,2560), 0, false, 4, true).size == Vector2i(15360,7680), "timed base cap")
	var dir := DirAccess.create_temp("photo-stream-png")
	var shot := dir.get_current_dir().path_join("shot.png")
	var rng := RandomNumberGenerator.new()
	rng.seed = 9282
	for size in [Vector2i(50, 45), Vector2i(301, 299)]:
		var rgb := PackedByteArray()
		rgb.resize(size.x * size.y * 3)
		for i in rgb.size():
			rgb[i] = rng.randi() & 255
		var image := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGB8, rgb)
		var writer := Png.new()
		writer.open(shot, size)
		for y in range(0, size.y, 10):
			check(writer.append(image.get_region(Rect2i(0, y, size.x, mini(10,size.y-y)))).is_empty(), "PNG stripe")
		var result := writer.finish()
		check(result.ok, result.message)
		var published := Image.load_from_file(shot)
		check(published.get_data() == rgb, "decoded pixels match noisy source")
		dir.remove("shot.png")
	var partial := Png.new()
	partial.open(shot,Vector2i(4,4))
	partial.abort()
	check(dir.get_files().is_empty(), "aborted staging cleaned")
	var sum := Sum.new()
	var image := Image.create_empty(1,1,false,Image.FORMAT_RGB8)
	image.fill(Color.BLACK)
	sum.add(image,false)
	image.fill(Color.WHITE)
	sum.add(image,false)
	check(sum.finish(false).get_data()[0] == 188, "linear-light display average")
	image = Image.create_empty(1,1,false,Image.FORMAT_RGBF)
	image.fill(Color(-0.25,0,8))
	sum.add(image,true)
	image.fill(Color(0,0,16))
	sum.add(image,true)
	var hdr := sum.finish(true).get_pixel(0,0)
	check(is_equal_approx(hdr.r,-0.125) and is_equal_approx(hdr.b,12), "signed HDR sum")
	print("Print bounds, timed accumulation and streamed PNG checks: ", failures, " failures")
	quit(1 if failures else 0)
