extends RefCounted
## Uncompressed OpenEXR scanlines. Works in release templates without the
## editor's optional EXR saver. Bands are supplied from top to bottom.

const PRIMARIES := [0.640, 0.330, 0.300, 0.600, 0.150, 0.060, 0.3127, 0.3290]

var error := ""
var _file: FileAccess
var _stage := ""
var _path := ""
var _lock_path := ""
var _extent := Vector2i.ZERO
var _rows := 0
var _first_scanline := 0
var _bytes_per_sample := 2
var _gain := 1.0


static func _z(value: String) -> PackedByteArray:
	var data := value.to_utf8_buffer()
	data.append(0)
	return data


static func _attribute(name: String, type: String, value: PackedByteArray) -> PackedByteArray:
	var result := _z(name)
	result.append_array(_z(type))
	result.append_array(PackedInt32Array([value.size()]).to_byte_array())
	result.append_array(value)
	return result


static func _header(size: Vector2i, metadata: Dictionary, bps: int) -> PackedByteArray:
	var header := PackedInt32Array([20000630, 2]).to_byte_array()
	var channels := PackedByteArray()
	for name: String in ["B", "G", "R"]:
		channels.append_array(_z(name))
		# Pixel type, pLinear/reserved, xSampling, ySampling.
		channels.append_array(PackedInt32Array([1 if bps == 2 else 2, 0, 1, 1]).to_byte_array())
	channels.append(0)
	header.append_array(_attribute("channels", "chlist", channels))
	header.append_array(_attribute("compression", "compression", PackedByteArray([0])))
	var window := PackedInt32Array([0, 0, size.x - 1, size.y - 1]).to_byte_array()
	header.append_array(_attribute("dataWindow", "box2i", window))
	header.append_array(_attribute("displayWindow", "box2i", window))
	header.append_array(_attribute("lineOrder", "lineOrder", PackedByteArray([0])))
	header.append_array(_attribute("pixelAspectRatio", "float", PackedFloat32Array([1.0]).to_byte_array()))
	header.append_array(_attribute("screenWindowCenter", "v2f", PackedFloat32Array([0.0, 0.0]).to_byte_array()))
	header.append_array(_attribute("screenWindowWidth", "float", PackedFloat32Array([1.0]).to_byte_array()))
	header.append_array(_attribute("chromaticities", "chromaticities", PackedFloat32Array(PRIMARIES).to_byte_array()))
	header.append_array(_attribute("colorInteropID", "string", "lin_rec709_scene".to_utf8_buffer()))
	var mode := str(metadata.get("cicadamataExposureMode", "Game"))
	header.append_array(_attribute("cicadamataExposureMode", "string", mode.to_utf8_buffer()))
	for key: String in ["expTime", "aperture", "isoSpeed", "focalLength"]:
		if key in metadata and is_finite(float(metadata[key])) and float(metadata[key]) > 0:
			header.append_array(_attribute(key, "float", PackedFloat32Array([float(metadata[key])]).to_byte_array()))
	header.append(0)
	return header


static func open_writer(path: String, size: Vector2i, metadata: Dictionary, gain: float = 1.0):
	var writer = new()
	writer._open(path, size, metadata, gain)
	return writer


func _open(path: String, size: Vector2i, metadata: Dictionary, gain: float) -> void:
	if size.x <= 0 or size.y <= 0 or size.x > 16384 or size.y > 16384 or not is_finite(gain) or gain <= 0:
		error = "Invalid EXR size or exposure"
		return
	if not path.is_absolute_path() or path.begins_with("res://") or path.get_extension().to_lower() != "exr":
		error = "Expected an absolute EXR destination"
		return
	_path = ProjectSettings.globalize_path(path)
	_extent = size
	_gain = gain
	_bytes_per_sample = 2 if metadata.get("cicadamataExposureMode", "Game") == "Game" and gain == 1.0 else 4
	if FileAccess.file_exists(_path) or DirAccess.dir_exists_absolute(_path):
		error = "EXR destination is already in use"
		return
	var lock := _path + ".lock"
	if DirAccess.make_dir_recursive_absolute(_path.get_base_dir()) != OK or DirAccess.make_dir_absolute(lock) != OK:
		error = "Could not reserve EXR destination"
		return
	_lock_path = lock
	_stage = _lock_path.path_join("pending.exr")
	_file = FileAccess.open(_stage, FileAccess.WRITE)
	if not _file:
		error = "Could not open staged EXR"
		abort()
		return
	var header := _header(size, metadata, _bytes_per_sample)
	_first_scanline = header.size() + 8 * size.y
	var stride := 8 + _bytes_per_sample * 3 * size.x
	var offsets := PackedInt64Array()
	offsets.resize(size.y)
	for y in size.y:
		offsets[y] = _first_scanline + y * stride
	if not _file.store_buffer(header) or not _file.store_buffer(offsets.to_byte_array()):
		error = "Could not write EXR header"
		abort()


func append(image: Image) -> String:
	if not error.is_empty():
		return error
	if not _file or not image or image.get_width() != _extent.x or _rows + image.get_height() > _extent.y:
		error = "Mismatched EXR scanline band"
		return error
	if image.get_format() not in [Image.FORMAT_RGBAH, Image.FORMAT_RGBH, Image.FORMAT_RGBAF, Image.FORMAT_RGBF]:
		error = "EXR needs a floating-point RGB source"
		return error
	var width := _extent.x
	var stride := width * 3 * _bytes_per_sample
	var row := PackedByteArray()
	row.resize(8 + stride)
	row.encode_u32(4, stride)
	for y in image.get_height():
		row.encode_u32(0, _rows)
		for x in width:
			var v := image.get_pixel(x, y)
			if not (is_finite(v.r) and is_finite(v.g) and is_finite(v.b)):
				error = "EXR contains a nonfinite color sample"
				return error
			if _bytes_per_sample == 2:
				row.encode_half(8 + x * 2, v.b)
				row.encode_half(8 + (width + x) * 2, v.g)
				row.encode_half(8 + (2 * width + x) * 2, v.r)
			else:
				row.encode_float(8 + x * 4, v.b * _gain)
				row.encode_float(8 + (width + x) * 4, v.g * _gain)
				row.encode_float(8 + (2 * width + x) * 4, v.r * _gain)
		if not _file.store_buffer(row):
			error = "EXR scanline write failed"
			return error
		_rows += 1
	return ""


func abort() -> void:
	if _file:
		_file.close()
		_file = null
	if _stage != "" and FileAccess.file_exists(_stage):
		DirAccess.remove_absolute(_stage)
	if _lock_path != "" and DirAccess.dir_exists_absolute(_lock_path):
		DirAccess.remove_absolute(_lock_path)
	_stage = ""
	_lock_path = ""


func finish() -> Dictionary:
	var expected := _first_scanline + _extent.y * (8 + _extent.x * _bytes_per_sample * 3)
	if error.is_empty():
		if not _file or _rows != _extent.y:
			error = "EXR scanlines incomplete"
		else:
			_file.flush()
			if _file.get_length() != expected or _file.get_error() != OK:
				error = "EXR length or flush verification failed"
			_file.close()
			_file = null
	if error.is_empty() and (FileAccess.file_exists(_path) or DirAccess.rename_absolute(_stage, _path) != OK):
		error = "Could not publish EXR"
	abort()
	return {"ok": error.is_empty(), "message": "Saved " + _path.get_file() if error.is_empty() else error,
		"path": _path if error.is_empty() else ""}


static func save(image: Image, path: String, metadata: Dictionary, gain: float = 1.0) -> Dictionary:
	if not image or image.is_empty():
		return {"ok": false, "path": "", "message": "Empty EXR source"}
	var writer = open_writer(path, image.get_size(), metadata, gain)
	writer.append(image)
	return writer.finish()
