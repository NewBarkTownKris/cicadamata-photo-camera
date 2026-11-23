extends SceneTree
const Linear := preload("res://cicadamata_photo/linear_capture.gd")
const Exr := preload("res://cicadamata_photo/photo_exr.gd")
var failures := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		printerr(label)

func _initialize() -> void:
	var fixture := Image.create_empty(3, 2, false, Image.FORMAT_RGBAH)
	fixture.fill(Color(2, 4, 8, 1))
	check(is_equal_approx(Linear.luminance(fixture), 2 * 0.2126 + 4 * 0.7152 + 8 * 0.0722), "linear Rec.709 luminance")
	var path := "user://scanlines.exr"
	var writer = Exr.open_writer(path, Vector2i(3, 4), {"cicadamataExposureMode": "Manual", "aperture": 4.0}, 2.0)
	check(writer.error.is_empty(), "open EXR")
	check(writer.append(fixture).is_empty(), "first band")
	fixture.fill(Color(4, 16, 32, 1))
	check(writer.append(fixture).is_empty(), "second band")
	check(writer.finish().ok, "publish complete EXR")
	var image := Image.load_from_file(path)
	check(image != null and image.get_size() == Vector2i(3, 4), "EXR decode")
	if image:
		check(image.get_pixel(1, 0).is_equal_approx(Color(4, 8, 16, 1)), "float color/gain")
		check(image.get_pixel(2, 2).is_equal_approx(Color(8, 32, 64, 1)), "band order")
	check(not Exr.save(fixture, path, {}).ok, "preserve completed file")
	writer = Exr.open_writer("user://incomplete.exr", Vector2i(3, 4), {}, 1)
	writer.append(fixture)
	check(not writer.finish().ok and not FileAccess.file_exists("user://incomplete.exr"), "incomplete EXR removed")
	writer = Exr.open_writer("user://incomplete.exr", Vector2i(3, 4), {}, 1)
	check(writer.error.is_empty(), "cleanup allows retry")
	writer.abort()
	check(Exr.save(fixture, "user://half.exr", {}).ok, "half EXR")
	image = Image.load_from_file("user://half.exr")
	check(image != null and image.get_pixel(0, 0).b == 32, "game half-float range")
	print("EXR and meter fixture: ", failures, " failures")
	quit(1 if failures else 0)
