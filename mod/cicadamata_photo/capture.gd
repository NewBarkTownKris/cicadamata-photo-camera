extends RefCounted
## Main-thread shutter state and render requests. A worker owns each readback
## while accumulating or encoding it. At most one readback is outstanding.

signal finished(result: Dictionary)
signal progress(message: String)
signal band_origin(origin: Vector2)

const Optics := preload("res://cicadamata_photo/camera_math.gd")
const Finder := preload("res://cicadamata_photo/finder.gd")
const PngRows := preload("res://cicadamata_photo/png_rows.gd")
const Sum := preload("res://cicadamata_photo/shutter_sum.gd")
const EXR_SCRIPT := "res://cicadamata_photo/photo_exr.gd"
const MAX_BAND_PIXELS := 1048576
const PRINT_LIMIT := 16384
const TIMEOUT_MS := 30000

enum Stage { IDLE, RECORD, FRAME, LINEAR, WORK }
var stage := Stage.IDLE
var busy: bool:
	get: return stage != Stage.IDLE
var recording: bool:
	get: return stage == Stage.RECORD
var cancelable: bool:
	get: return busy and (_timed or (_hdr and int(_opts.get("scale", 1)) > 1))

var _window: Window
var _camera: Camera3D
var _overlay: CanvasLayer
var _linear: CompositorEffect
var _private_linear: CompositorEffect
var _private_view: SubViewport
var _render_camera: Camera3D
var _opts: Dictionary
var _layout: Dictionary
var _old: Dictionary
var _timed := false
var _hdr := false
var _banded := false
var _png_path := ""
var _stem := ""
var _reservation := ""
var _physical: Vector2i
var _base: Vector2i
var _return_pose: Transform3D
var _fov: float
var _near: float
var _far: float
var _keep: Camera3D.KeepAspect
var _visible := true
var _changed := false
var _samples: Array[Transform3D] = []
var _sample := 0
var _next_row := 0
var _band_rows := 0
var _band_pixel_limit := MAX_BAND_PIXELS
var _trim: Rect2i
var _raster: Vector2i
var _start_us := 0
var _prev_us := 0
var _prev_pose: Transform3D
var _count := 1
var _deadline := 0
var _ticket := -1
var _readback_callback: Callable
var _png: PngRows
var _exr: RefCounted
var _sum: Sum
var _thread: Thread
var _stop := false
var _worker_stamp := 0
var _mutex := Mutex.new()


static func plan(viewport_size: Vector2i, frame_index: int, portrait: bool, scale: int, timed: bool) -> Dictionary:
	var crop := Optics.crop_rect(viewport_size, frame_index, portrait)
	var size := crop.size
	if timed and maxi(size.x, size.y) > 3840:
		size = Vector2i((Vector2(size) * (3840.0 / maxi(size.x, size.y))).round())
	size *= scale
	var full := viewport_size * scale
	var limit := Vector2i(PRINT_LIMIT, PRINT_LIMIT)
	var rd := RenderingServer.get_rendering_device()
	if rd:
		var texture := rd.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D)
		if texture > 0:
			limit.x = mini(limit.x, texture)
			limit.y = mini(limit.y, texture)
		var w := rd.limit_get(RenderingDevice.LIMIT_MAX_FRAMEBUFFER_WIDTH)
		var h := rd.limit_get(RenderingDevice.LIMIT_MAX_FRAMEBUFFER_HEIGHT)
		if w > 0:
			limit.x = mini(limit.x, w)
		if h > 0:
			limit.y = mini(limit.y, h)
	var reason := ""
	if not crop.has_area() or scale < 1 or scale > 4:
		reason = "Invalid frame or capture scale"
	elif (not timed and (full.x > limit.x or full.y > limit.y)) or size.x > limit.x or size.y > limit.y:
		reason = "Capture exceeds the %d × %d renderer limit" % [limit.x, limit.y]
	return {"ok": reason.is_empty(), "reason": reason, "size":size, "crop":crop, "full":full}


func begin(camera: Camera3D, overlay: CanvasLayer, options: Dictionary, linear: CompositorEffect = null) -> String:
	if busy:
		return "A shutter is already active"
	if not is_instance_valid(camera) or not camera.get_viewport() is Window:
		return "The photo camera has no active window"
	_window = camera.get_viewport() as Window
	_camera = camera
	_render_camera = camera
	_overlay = overlay
	_opts = options.duplicate(true)
	_linear = linear
	_timed = float(_opts.get("seconds", 0.0)) >= 1.0 / 15.0
	if _timed and (_opts.seconds > 8.0 or not is_finite(_opts.seconds)):
		return "Timed shutter must be at most 8 seconds"
	_base = Finder.render_size(_window)
	_layout = plan(_base, _opts.frame_index, _opts.portrait, _opts.scale, _timed)
	if not _layout.ok:
		return _layout.reason
	var directory: String = _opts.directory
	if directory.begins_with("res://") or not directory.is_absolute_path():
		return "Choose an absolute or user:// photo destination"
	directory = ProjectSettings.globalize_path(directory)
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return "Could not create photo destination"
	var output := DirAccess.open(directory)
	if not output:
		return "Could not open photo destination"
	var bytes_free := output.get_space_left()
	var bytes_per_pixel := 16 if _opts.get("paired", false) else 4
	var output_size: Vector2i = _layout.size
	if bytes_free > 0 and bytes_free < output_size.x * output_size.y * bytes_per_pixel + 1048576:
		return "Not enough disk space for this capture"
	var token := Crypto.new().generate_random_bytes(12)
	if token.size() != 12:
		return "Cannot allocate a unique shot name"
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	_stem = directory.path_join("CICADAMATA_" + stamp + "_" + token.hex_encode())
	_reservation = directory.path_join("." + _stem.get_file() + ".lock")
	if DirAccess.make_dir_absolute(_reservation) != OK:
		return "Could not reserve photo filename"
	_png = PngRows.new()
	_png.open(_stem + ".png", output_size)
	if not _png.error.is_empty():
		var failure := _png.error
		_png.abort()
		DirAccess.remove_absolute(_reservation)
		return failure
	_png_path = ""
	_hdr = false
	_stop = false
	_changed = false
	_sum = Sum.new()
	_physical = _window.size
	_old = {"size":_window.content_scale_size, "mode":_window.content_scale_mode,
		"factor":_window.content_scale_factor, "aspect":_window.content_scale_aspect,
		"stretch":_window.content_scale_stretch, "scale_3d":_window.scaling_3d_scale,
		"mode_3d":_window.scaling_3d_mode}
	_visible = _overlay.visible if _overlay else false
	_fov = camera.fov
	_near = camera.near
	_far = camera.far
	_keep = camera.keep_aspect
	_return_pose = camera.global_transform
	_samples.clear()
	_count = 1
	stage = Stage.RECORD
	if _timed:
		_count = clampi(ceili(_opts.seconds * 60.0), 2, 64)
		_start_us = Time.get_ticks_usec()
		_prev_us = _start_us
		_prev_pose = _return_pose
		progress.emit("Recording %.2f s shutter" % _opts.seconds)
	else:
		_samples.append(_return_pose)
		_start_pass()
	return ""


func _record(now: int) -> void:
	var duration_us := roundi(_opts.seconds * 1e6)
	var current := _camera.global_transform
	while _samples.size() < _count:
		var sample_time := _start_us + roundi((_samples.size() + 0.5) * duration_us / _count)
		if sample_time > now:
			break
		var amount := clampf(float(sample_time - _prev_us) / maxi(now - _prev_us, 1), 0.0, 1.0)
		_samples.append(_prev_pose.interpolate_with(current, amount))
	_prev_us = now
	_prev_pose = current
	_return_pose = current
	if now >= _start_us + duration_us:
		_start_pass()
	else:
		progress.emit("Shutter open  %.1f s" % ((_start_us + duration_us - now) / 1e6))


func _start_pass() -> void:
	_next_row = 0
	var full: Vector2i = _layout.full
	var full_pixels := full.x * full.y
	# For timed/HDR shots replay each pose through an overlapping strip, bounding
	# both the render target and the floating accumulator. For display stills
	# prefer a full frame to keep root canvas SCREEN_UV and temporal effects.
	_banded = (_timed or _hdr) and (full_pixels > 2 * _band_pixel_limit or _layout.size != _layout.crop.size * _opts.scale)
	if not _banded and _opts.scale > 1 and full_pixels > 8 * MAX_BAND_PIXELS:
		var rd := RenderingServer.get_rendering_device()
		var available: int = OS.get_memory_info().get("available", -1)
		var device_headroom := -1
		if rd:
			var total := rd.get_device_total_memory()
			if total > 0:
				device_headroom = maxi(0, total - rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL))
		# Allow space for HDR/color, depth, post buffers and the currently
		# displayed view. If the device budget is unknown, use strips.
		_banded = device_headroom < full_pixels * 80 or (available > 0 and available < full_pixels * 12)
	if _hdr:
		_restore_root()
		if _overlay:
			_overlay.visible = _visible
		band_origin.emit(Vector2.ZERO)
	# A separate HDR camera can replay poses and strips while the photographer
	# sees their final composition, progress and the option to cancel.
	if _hdr and (_timed or _opts.scale > 1):
		var issue := _create_private_view()
		if not issue.is_empty():
			_fail(issue)
			return
	elif _overlay and not _hdr:
		_overlay.hide()
	_prepare_band()


func _create_private_view() -> String:
	_private_view = SubViewport.new()
	_private_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_private_view.world_3d = _camera.get_world_3d()
	_private_view.msaa_3d = _window.msaa_3d
	_private_view.mesh_lod_threshold = _window.mesh_lod_threshold
	_camera.add_child(_private_view)
	_render_camera = Camera3D.new()
	_render_camera.keep_aspect = _keep
	_render_camera.set_perspective(_fov, _near, _far)
	_render_camera.cull_mask = _camera.cull_mask
	_render_camera.environment = _camera.environment
	_render_camera.attributes = _camera.attributes
	_render_camera.compositor = _camera.compositor
	_render_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_private_view.add_child(_render_camera)
	_render_camera.make_current()
	if not _linear.has_method("install"):
		return "" # A caller may supply an already independent readback source.
	_private_linear = _linear.get_script().new()
	if not _private_linear.call("install", _render_camera):
		return "Unable to initialize the print HDR viewport"
	return ""


func _set_virtual_size(size: Vector2i) -> void:
	if _private_view:
		_private_view.size = size
		return
	if not _changed:
		_window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
		_window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
		_window.content_scale_factor = 1.0
		_window.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		_window.scaling_3d_scale = 1.0
		_changed = true
	_window.content_scale_size = size
	_window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT


func _prepare_band() -> void:
	var size: Vector2i = _layout.size
	var crop: Rect2i = _layout.crop
	_sample = 0
	if not _banded:
		_band_rows = size.y
		_raster = _layout.full
		_trim = Rect2i(crop.position * int(_opts.scale), size)
		if _opts.scale > 1 or _private_view:
			_set_virtual_size(_raster)
		_render_camera.set_perspective(_fov, _near, _far)
		if not _hdr:
			band_origin.emit(Vector2.ZERO)
	else:
		_band_rows = mini(size.y - _next_row, maxi(1, _band_pixel_limit / size.x))
		var overlap := 16 * int(_opts.scale)
		var top := maxi(0, _next_row - overlap)
		var end := mini(size.y, _next_row + _band_rows + overlap)
		_raster = Vector2i(size.x, end - top)
		_trim = Rect2i(0, _next_row - top, size.x, _band_rows)
		_set_virtual_size(_raster)
		# Map the strip back into the original near plane; this preserves the
		# full optical gate even when the 3840px timed base was rounded.
		var pitch := 2.0 * _near * tan(deg_to_rad(_fov) * 0.5)
		pitch /= _base.y if _keep == Camera3D.KEEP_HEIGHT else _base.x
		var slice_start := Vector2(crop.position) + Vector2(0, float(top) * crop.size.y / size.y)
		var extent := Vector2(crop.size.x, float(end - top) * crop.size.y / size.y)
		var center := (slice_start + extent * 0.5 - Vector2(_base) * 0.5) * pitch
		# KEEP_WIDTH fixes the horizontal near-plane span in Godot's frustum API.
		_render_camera.keep_aspect = Camera3D.KEEP_WIDTH
		_render_camera.set_frustum(extent.x * pitch, Vector2(center.x, -center.y), _near, _far)
		if not _hdr:
			band_origin.emit(Vector2(crop.position) * Vector2(size) / Vector2(crop.size) + Vector2(0, top))
	_queue_frame()


func _queue_frame() -> void:
	_render_camera.global_transform = _samples[_sample]
	_deadline = Time.get_ticks_msec() + TIMEOUT_MS
	if _hdr:
		stage = Stage.LINEAR
		if _private_view:
			_ticket = _linear_source().call("arm", _trim, _raster, false)
			_private_view.render_target_update_mode = SubViewport.UPDATE_ONCE
		else:
			# Finish a draw at this pose before the threaded compositor consumes
			# a root request. Its previous frame may still be in flight.
			_readback_callback = _settle_linear
			RenderingServer.frame_pre_draw.connect(_readback_callback, CONNECT_ONE_SHOT)
	else:
		stage = Stage.FRAME
		if _overlay:
			_overlay.hide()
		_readback_callback = _arm_display
		RenderingServer.frame_pre_draw.connect(_readback_callback, CONNECT_ONE_SHOT)
	var size: Vector2i = _layout.size
	progress.emit("%s %d × %d  ·  rows %d–%d  ·  sample %d/%d" % [
		"EXR" if _hdr else "PNG", size.x, size.y, _next_row + 1, _next_row + _band_rows, _sample + 1, _count])


func _linear_source() -> CompositorEffect:
	return _private_linear if _private_linear else _linear


func _settle_linear() -> void:
	if stage == Stage.LINEAR:
		_readback_callback = _arm_linear
		RenderingServer.frame_post_draw.connect(_readback_callback, CONNECT_ONE_SHOT)


func _arm_linear() -> void:
	if stage == Stage.LINEAR:
		_ticket = _linear_source().call("arm", _trim, _raster, false)


func _arm_display() -> void:
	if stage == Stage.FRAME:
		_readback_callback = _read_display
		RenderingServer.frame_post_draw.connect(_readback_callback, CONNECT_ONE_SHOT)


func _read_display() -> void:
	if stage != Stage.FRAME:
		return
	if not _valid_window():
		_fail("Viewport changed during capture")
		return
	var image := _window.get_texture().get_image()
	if image == null or image.is_empty() or image.get_size() != _raster:
		_fail("Viewport readback dimensions changed")
		return
	if image.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
		_fail("Display PNG requires an SDR RGB8 or RGBA8 viewport")
		return
	if _trim != Rect2i(Vector2i.ZERO, _raster):
		image = image.get_region(_trim)
	_deliver(image)


func _deliver(image: Image) -> void:
	if not image or image.get_size() != _trim.size:
		_fail("Incomplete capture sample")
		return
	stage = Stage.WORK
	# Once readback owns its pixels the finder can display development
	# progress without appearing in the exposure. Hide it before the next draw.
	if _overlay and (_timed or _opts.scale > 1):
		_overlay.visible = _visible
	_worker_stamp = Time.get_ticks_msec()
	_thread = Thread.new()
	if _thread.start(_consume.bind(image), Thread.PRIORITY_LOW) != OK:
		_thread = null
		_fail("Could not start photo development worker")


func _consume(image: Image) -> String:
	if _count > 1:
		var problem := _sum.add(image, _hdr)
		if not problem.is_empty() or _sample + 1 < _count:
			return problem
		image = _sum.finish(_hdr)
	# Bound the encoder's temporary buffers and cancellation latency. This
	# worker never accesses the scene tree or renderer.
	var rows := maxi(1, 131072 / image.get_width())
	for y in range(0, image.get_height(), rows):
		_mutex.lock()
		var stop := _stop
		_worker_stamp = Time.get_ticks_msec()
		_mutex.unlock()
		if stop:
			return "Capture canceled"
		var stripe := image if rows >= image.get_height() else image.get_region(Rect2i(
			0, y, image.get_width(), mini(rows, image.get_height() - y)))
		var error: String = _exr.call("append", stripe) if _hdr else _png.append(stripe)
		if not error.is_empty():
			return error
	return ""


func _valid_window() -> bool:
	return (is_instance_valid(_window) and _window.size == _physical
		and is_instance_valid(_camera) and _camera.is_inside_tree()
		and _camera == _window.get_camera_3d()
		and (_changed or Finder.render_size(_window) == _base))


func tick() -> void:
	if not busy:
		return
	if not _valid_window():
		_fail("Viewport or camera changed during capture")
		return
	match stage:
		Stage.RECORD:
			_record(Time.get_ticks_usec())
		Stage.FRAME, Stage.LINEAR:
			if Time.get_ticks_msec() >= _deadline:
				_fail("Render readback timed out")
				return
			if stage == Stage.LINEAR and _ticket >= 0:
				var result: Dictionary = _linear_source().call("take", _ticket)
				if not result.is_empty():
					_ticket = -1
					if result.ok:
						_deliver(result.image)
					else:
						_fail(result.message)
		Stage.WORK:
			_mutex.lock()
			var stalled := Time.get_ticks_msec() - _worker_stamp > TIMEOUT_MS
			_mutex.unlock()
			if stalled:
				_fail("Photo development timed out")
				return
			if _thread and not _thread.is_alive():
				var problem: String = _thread.wait_to_finish()
				_thread = null
				if not problem.is_empty():
					_fail(problem)
				else:
					_advance()


func _advance() -> void:
	_sample += 1
	if _sample < _count:
		_queue_frame()
		return
	_next_row += _band_rows
	if _next_row < _layout.size.y:
		_prepare_band()
		return
	var result: Dictionary = _exr.call("finish") if _hdr else _png.finish()
	if not result.ok:
		_fail(result.message)
		return
	if _hdr:
		_end(true, "Saved PNG + EXR", result.path)
		return
	_png_path = result.path
	if not _opts.get("paired", false):
		_end(true, "Saved " + _png_path.get_file())
		return
	if not _linear:
		_fail("Scene-linear readback unavailable")
		return
	var exr_script = load(EXR_SCRIPT)
	if not exr_script:
		_fail("EXR encoder unavailable")
		return
	_exr = exr_script.open_writer(_stem + ".exr", _layout.size, _opts.get("metadata", {}), _opts.get("gain", 1.0))
	if not _exr or not str(_exr.get("error")).is_empty():
		_fail(str(_exr.get("error")) if _exr else "Could not open EXR writer")
		return
	_hdr = true
	_start_pass()


func cancel() -> void:
	if busy:
		_fail("Capture canceled")


func _fail(reason: String) -> void:
	_end(false, reason if _png_path.is_empty() else "PNG kept. " + reason)


func _end(ok: bool, message: String, exr_path := "") -> void:
	stage = Stage.IDLE
	for sig: Signal in [RenderingServer.frame_pre_draw, RenderingServer.frame_post_draw]:
		if _readback_callback.is_valid() and sig.is_connected(_readback_callback):
			sig.disconnect(_readback_callback)
	_readback_callback = Callable()
	if _linear and _ticket >= 0:
		_linear_source().call("cancel", _ticket)
	_ticket = -1
	if _thread:
		_mutex.lock()
		_stop = true
		_mutex.unlock()
		_thread.wait_to_finish()
		_thread = null
	if _png:
		_png.abort()
		_png = null
	if _exr and exr_path.is_empty():
		_exr.call("abort")
	_exr = null
	if not _reservation.is_empty():
		DirAccess.remove_absolute(_reservation)
	_reservation = ""
	if _private_linear:
		_private_linear.call("uninstall", _render_camera if is_instance_valid(_render_camera) else null)
		_private_linear = null
	if is_instance_valid(_private_view):
		_private_view.queue_free()
	_private_view = null
	_render_camera = null
	_restore_root()
	band_origin.emit(Vector2.ZERO)
	if is_instance_valid(_overlay):
		_overlay.visible = _visible
	_camera = null
	_window = null
	_overlay = null
	_linear = null
	_sum = null
	_samples.clear()
	finished.emit({"ok":ok, "message":message, "path":_png_path, "exr_path":exr_path})


func _restore_root() -> void:
	if is_instance_valid(_camera) and _camera.is_inside_tree():
		_camera.keep_aspect = _keep
		_camera.set_perspective(_fov, _near, _far)
		_camera.global_transform = _return_pose
	if _changed and is_instance_valid(_window):
		_window.content_scale_size = _old.size
		_window.content_scale_mode = _old.mode
		_window.content_scale_factor = _old.factor
		_window.content_scale_aspect = _old.aspect
		_window.content_scale_stretch = _old.stretch
		_window.scaling_3d_mode = _old.mode_3d
		_window.scaling_3d_scale = _old.scale_3d
	_changed = false
