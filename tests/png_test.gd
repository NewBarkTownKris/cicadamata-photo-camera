extends SceneTree
## Synthetic readbacks only. All files live under an engine-created temporary directory.

const Shutter = preload("res://cicadamata_photo/png_shutter.gd")
const CameraMath = preload("res://cicadamata_photo/camera_math.gd")
var failures := 0
var checks := 0


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr(message)


func _initialize() -> void:
	var scratch := DirAccess.create_temp("cicadamata-png-test")
	if not scratch:
		printerr("Couldn't create the temporary PNG fixture.")
		quit(1)
		return
	var destination := scratch.get_current_dir().path_join("photos")
	var source := Image.create_empty(160, 90, false, Image.FORMAT_RGBA8)
	for y in source.get_height():
		for x in source.get_width():
			source.set_pixel(x, y, Color.from_rgba8(x, y, 255 - x, 255))
	var saved: Dictionary
	for portrait in [false, true]:
		saved = Shutter.save(source, 7, portrait, destination)
		check(saved.ok, str(saved.message))
		if not saved.ok:
			continue
		check(FileAccess.file_exists(saved.path), "published file exists")
		var opened := Image.load_from_file(saved.path)
		var expected := CameraMath.crop_rect(source.get_size(), 7, portrait)
		check(opened.get_size() == expected.size, "gate and file dimensions agree")
		check(opened.get_pixel(0, 0) == source.get_pixelv(expected.position), "first crop pixel")
		check(opened.get_pixelv(expected.size - Vector2i.ONE) == source.get_pixelv(expected.end - Vector2i.ONE), "last crop pixel")
	check(source.get_size() == Vector2i(160, 90), "caller retains original readback")
	var output := DirAccess.open(destination)
	if not output:
		quit(1)
		return
	output.include_hidden = true
	check(output.get_files().size() == 2 and output.get_directories().is_empty(), "two unique names and no transient files")
	check(not Shutter.save(null, 0, false, destination).ok, "empty readback")
	check(not Shutter.save(Image.create_empty(4, 3, false, Image.FORMAT_RGBAH), 0, false, destination).ok, "HDR cannot silently clip to PNG")
	check(not Shutter.save(source, 99, false, destination).ok, "invalid frame")
	check(not Shutter.save(source, 0, false, "photos").ok, "ambiguous relative destination")
	check(not Shutter.save(source, 0, false, "res://images").ok, "game resource path")
	if saved.get("ok", false):
		var original := FileAccess.get_file_as_bytes(saved.path)
		check(not Shutter.save(source, 0, false, saved.path).ok, "a file cannot be the destination directory")
		var stem: String = saved.path.get_file().get_basename()
		var repeated := Shutter._publish(output, source, Rect2i(Vector2i.ZERO, source.get_size()), stem)
		check(not repeated.ok and FileAccess.get_file_as_bytes(saved.path) == original, "existing photograph survives name collision")
		check(not Shutter._validate(saved.path, Vector2i.ONE), "wrong published dimensions")
		var truncated := destination.path_join("truncated.png")
		var file := FileAccess.open(truncated, FileAccess.WRITE)
		file.store_buffer(original.slice(0, -12))
		file.close()
		check(not Shutter._validate(truncated, CameraMath.crop_rect(source.get_size(), 7, true).size), "missing final PNG chunk")
		output.remove("truncated.png")
	check(output.get_files().size() == 2 and output.get_directories().is_empty(), "failed requests leave no staging files")
	for name in output.get_files():
		output.remove(name)
	scratch.remove("photos")
	print("%s PNG checks, %s failures" % [checks, failures])
	quit(1 if failures else 0)
