extends RefCounted

const PATH := "user://CICADAMATA-Photo/studio.json"
const VERSION := 1
const MAX_BYTES := 32768


static func _read(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_BYTES:
		return null
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return null
	var data: Variant = json.data
	if data is Dictionary and data.get("version") == VERSION and data.get("settings") is Dictionary:
		return data.settings
	return null


static func read(path: String = PATH) -> Dictionary:
	for candidate in [path, path + ".bak"]:
		var data: Variant = _read(candidate)
		if data is Dictionary:
			return data
	return {}


static func write(settings: Dictionary, path: String = PATH) -> Error:
	var abs_path := ProjectSettings.globalize_path(path)
	var error := DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	if error != OK:
		return error
	var temp_path := abs_path + ".tmp"
	var backup := abs_path + ".bak"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({"version": VERSION, "settings": settings}))
	file.flush()
	error = file.get_error()
	file.close()
	if error == OK and _read(temp_path) == null:
		error = ERR_FILE_CORRUPT
	if error == OK and _read(abs_path) != null:
		error = DirAccess.rename_absolute(abs_path, backup)
	if error == OK:
		error = DirAccess.rename_absolute(temp_path, abs_path)
	if error != OK:
		DirAccess.remove_absolute(temp_path)
	return error
