extends RefCounted
## Receives an SDR display readback after the session has hidden its overlays.

const CameraMath = preload("res://cicadamata_photo/camera_math.gd")
const PNG_END := "0000000049454e44ae426082"


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "message": message, "path": ""}


static func _validate(staged_path: String, expected: Vector2i) -> bool:
	# Some PNG decoders can recover pixels even if the final chunk was cut off.
	var file := FileAccess.open(staged_path, FileAccess.READ)
	if file == null or file.get_length() < 45:
		return false
	file.seek_end(-12)
	var complete := file.get_buffer(12).hex_encode() == PNG_END
	file.close()
	if not complete:
		return false
	var decoded := Image.new()
	return decoded.load(staged_path) == OK and decoded.get_size() == expected


static func _exists(directory: DirAccess, name: String) -> bool:
	return directory.file_exists(name) or directory.dir_exists(name) or directory.is_link(name)


static func _publish(
	directory: DirAccess, image: Image, crop: Rect2i, stem: String
) -> Dictionary:
	var final_name := stem + ".png"
	var staged_name := "." + stem + ".part.png"
	if _exists(directory, final_name) or _exists(directory, staged_name):
		return _failure("The capture name is already in use.")
	var staged_path := directory.get_current_dir().path_join(staged_name)
	var cropped := image if crop.size == image.get_size() else image.get_region(crop)
	var written := cropped.save_png(staged_path)
	var result: Dictionary
	if written != OK:
		result = _failure("Couldn't write the PNG (%s)." % error_string(written))
	elif not _validate(staged_path, crop.size):
		result = _failure("The saved PNG failed its completeness or size check.")
	elif _exists(directory, final_name):
		result = _failure("A file appeared at the selected capture name.")
	else:
		var published := directory.rename(staged_name, final_name)
		if published == OK:
			var path := directory.get_current_dir().path_join(final_name)
			return {"ok": true, "message": "Saved %s" % final_name, "path": path}
		result = _failure("Couldn't publish the PNG (%s)." % error_string(published))
	if directory.file_exists(staged_name) and directory.remove(staged_name) != OK:
		result.message += " Couldn't remove %s." % staged_path
	return result


static func save(image: Image, frame_index: int, portrait: bool, directory: String) -> Dictionary:
	if image == null or image.is_empty():
		return _failure("The viewport returned an empty image.")
	if image.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
		return _failure("PNG requires an 8-bit RGB or RGBA display image.")
	var crop := CameraMath.crop_rect(image.get_size(), frame_index, portrait)
	if not crop.has_area():
		return _failure("The selected frame does not fit the captured image.")
	if directory.begins_with("res://") or not directory.is_absolute_path():
		return _failure("Choose an absolute capture directory or a user:// directory.")
	var absolute := ProjectSettings.globalize_path(directory)
	var created := DirAccess.make_dir_recursive_absolute(absolute)
	if created != OK:
		return _failure("Couldn't create the capture directory (%s)." % error_string(created))
	var output := DirAccess.open(absolute)
	if output == null:
		return _failure("Couldn't open the capture directory (%s)." % error_string(DirAccess.get_open_error()))
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	var token := Crypto.new().generate_random_bytes(12)
	if token.size() != 12:
		return _failure("Couldn't allocate a unique capture name.")
	var stem := "CICADAMATA_%s_%s" % [stamp, token.hex_encode()]
	# mkdir reserves this name atomically across mod instances on the same filesystem.
	var reservation := "." + stem + ".lock"
	var reserved := output.make_dir(reservation)
	if reserved != OK:
		return _failure("Couldn't reserve the capture name (%s)." % error_string(reserved))
	var result := _publish(output, image, crop, stem)
	if output.remove(reservation) != OK:
		result.message += " Couldn't remove the reservation %s." % absolute.path_join(reservation)
	return result
