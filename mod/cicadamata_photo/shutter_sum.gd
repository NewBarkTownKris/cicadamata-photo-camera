extends RefCounted
## One band is accumulated at a time on a worker thread. Display samples are
## integrated in linear light; HDR samples retain their signed floating values.

var _sum := PackedFloat32Array()
var _size := Vector2i.ZERO
var _samples := 0
var _decode := PackedFloat32Array()
var _encode := PackedByteArray()


func _display_tables() -> void:
	if _decode.size():
		return
	for i in 256:
		var v := float(i) / 255.0
		_decode.append(v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4))
	_encode.resize(65536)
	for i in 65536:
		var v := float(i) / 65535.0
		var srgb := 12.92 * v if v <= 0.0031308 else 1.055 * pow(v, 1.0 / 2.4) - 0.055
		_encode[i] = clampi(roundi(srgb * 255.0), 0, 255)


func add(image: Image, linear: bool) -> String:
	if not _samples:
		_size = image.get_size()
		if _sum.resize(_size.x * _size.y * 3) != OK:
			return "Could not allocate shutter sum"
	elif image.get_size() != _size:
		return "Shutter sample dimensions changed"
	if linear:
		image.convert(Image.FORMAT_RGBF)
		var values := image.get_data().to_float32_array()
		for i in values.size():
			_sum[i] += values[i]
	else:
		_display_tables()
		image.convert(Image.FORMAT_RGB8)
		var values := image.get_data()
		for i in values.size():
			_sum[i] += _decode[values[i]]
	_samples += 1
	return ""


func finish(linear: bool) -> Image:
	var result: Image
	var inv := 1.0 / float(_samples)
	if linear:
		for i in _sum.size():
			_sum[i] *= inv
		result = Image.create_from_data(_size.x, _size.y, false, Image.FORMAT_RGBF, _sum.to_byte_array())
	else:
		var pixels := PackedByteArray()
		pixels.resize(_sum.size())
		for i in _sum.size():
			pixels[i] = _encode[clampi(roundi(_sum[i] * inv * 65535.0), 0, 65535)]
		result = Image.create_from_data(_size.x, _size.y, false, Image.FORMAT_RGB8, pixels)
	_sum.clear()
	_samples = 0
	return result
