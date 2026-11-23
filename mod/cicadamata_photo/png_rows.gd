extends RefCounted
## Incremental RGB PNG encoder. The deflater retains its dictionary across bands.
## The caller owns a unique capture stem; publication is a sibling rename.

var error := ""
var _path: String
var _stage: String
var _file: FileAccess
var _zip := StreamPeerGZIP.new()
var _size: Vector2i
var _rows := 0
var _pending := PackedByteArray()
var _streaming := false
var _owns_stage := false
var _crc_table := PackedInt64Array()


func open(path: String, size: Vector2i) -> void:
	_path = path
	_stage = path.get_base_dir().path_join("." + path.get_file() + ".part")
	_size = size
	if size.x < 1 or size.y < 1 or FileAccess.file_exists(path) or FileAccess.file_exists(_stage):
		error = "PNG path or dimensions unavailable"
		return
	_file = FileAccess.open(_stage, FileAccess.WRITE)
	if not _file:
		error = "Cannot create PNG staging file: " + error_string(FileAccess.get_open_error())
		return
	_owns_stage = true
	_file.big_endian = true
	_file.store_buffer(PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10]))
	for n in 256:
		var crc := n
		for unused in 8:
			crc = (crc >> 1) ^ (0xedb88320 if (crc & 1) else 0)
		_crc_table.append(crc)
	var header := StreamPeerBuffer.new()
	header.big_endian = true
	header.put_u32(size.x)
	header.put_u32(size.y)
	header.put_data(PackedByteArray([8, 2, 0, 0, 0]))
	_chunk("IHDR", header.data_array)
	_chunk("sRGB", PackedByteArray([0]))
	if _zip.start_compression(true, 262144) != OK:
		error = "Cannot initialize PNG compressor"


func _chunk(kind: String, data: PackedByteArray) -> void:
	var crc := 0xffffffff
	var name_bytes := kind.to_ascii_buffer()
	for byte in name_bytes:
		crc = _crc_table[(crc ^ byte) & 255] ^ (crc >> 8)
	for byte in data:
		crc = _crc_table[(crc ^ byte) & 255] ^ (crc >> 8)
	_file.store_32(data.size())
	_file.store_buffer(name_bytes)
	_file.store_buffer(data)
	_file.store_32(crc ^ 0xffffffff)
	if _file.get_error() != OK:
		error = "Could not write PNG data"


func _drain() -> void:
	var size := _zip.get_available_bytes()
	if size:
		var block := _zip.get_data(size)
		if block[0] != OK:
			error = "Could not read compressed PNG data"
			return
		_chunk("IDAT", block[1])


func append(image: Image) -> String:
	if not error.is_empty():
		return error
	if image.get_width() != _size.x or _rows + image.get_height() > _size.y:
		return "PNG band dimensions do not match the locked frame"
	if image.get_format() != Image.FORMAT_RGB8:
		image.convert(Image.FORMAT_RGB8)
	var pixels := image.get_data()
	var stride := _size.x * 3
	for y in image.get_height():
		_pending.append(0) # PNG filter None
		_pending.append_array(pixels.slice(y * stride, (y + 1) * stride))
		if _pending.size() >= 131072:
			_streaming = true
			if _zip.put_data(_pending) != OK:
				return "Could not compress PNG scanlines"
			_pending.clear()
			_drain()
			if not error.is_empty():
				return error
	_rows += image.get_height()
	return ""


func finish() -> Dictionary:
	if error.is_empty() and _rows != _size.y:
		error = "Incomplete PNG row count"
	if error.is_empty():
		if not _streaming:
			_chunk("IDAT", _pending.compress(FileAccess.COMPRESSION_DEFLATE))
		else:
			if not _pending.is_empty() and _zip.put_data(_pending) != OK:
				error = "Could not finish PNG rows"
			_drain()
			if _zip.finish() != OK:
				error = "Could not finish PNG stream"
			else:
				_drain()
		_pending.clear()
	if error.is_empty():
		_chunk("IEND", PackedByteArray())
		_file.flush()
		var expected_length := _file.get_position()
		_file.close()
		_file = null
		var check := FileAccess.open(_stage, FileAccess.READ)
		var complete := false
		if check and check.get_length() == expected_length:
			check.big_endian = true
			check.seek(16)
			complete = check.get_32() == _size.x and check.get_32() == _size.y
			check.seek_end(-12)
			complete = complete and check.get_buffer(12).hex_encode() == "0000000049454e44ae426082"
		check = null
		if not complete:
			error = "PNG validation failed"
		elif FileAccess.file_exists(_path) or DirAccess.rename_absolute(_stage, _path) != OK:
			error = "Could not publish the completed PNG"
	if not error.is_empty():
		abort()
		return {"ok":false, "message":error, "path":""}
	return {"ok":true, "message":"Saved " + _path.get_file(), "path":_path}


func abort() -> void:
	if _file:
		_file.close()
		_file = null
	_zip.clear()
	if _owns_stage and FileAccess.file_exists(_stage):
		DirAccess.remove_absolute(_stage)
