extends SceneTree
## Pure optics/exposure and a Camera3D projection in a headless, empty project.

const Optics = preload("res://cicadamata_photo/camera_math.gd")
const Exposure = preload("res://cicadamata_photo/exposure.gd")
var failures := 0
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr(message)


func _run() -> void:
	var size := Vector2i(3840, 2160)
	check(Optics.crop_rect(size, 0, true) == Rect2i(0, 0, 3840, 2160), "native portrait toggle")
	check(Optics.crop_rect(size, 7, false) == Rect2i(2, 372, 3835, 1416), "65:24 frame")
	check(Optics.crop_rect(Vector2i(1921, 1081), 1, true) == Rect2i(600, 0, 720, 1080), "portrait frame")
	check(Optics.crop_rect(Vector2i(80, 42), 6, false) == Rect2i(1, 4, 77, 33), "21:9 uses full pixels")
	check(not Optics.crop_rect(Vector2i(24, 24), 7, false).has_area(), "unrepresentable wide frame")
	check(not Optics.crop_rect(size, -1, false).has_area(), "invalid preset")
	check(not Optics.crop_rect(Vector2i.ZERO, 0, false).has_area(), "empty viewport")

	var viewport := SubViewport.new()
	root.add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	for dimensions: Vector2i in [Vector2i(1920, 1080), Vector2i(640, 480), Vector2i(720, 1280)]:
		viewport.size = dimensions
		var aspect := float(dimensions.x) / dimensions.y
		for keep_aspect: int in [Camera3D.KEEP_WIDTH, Camera3D.KEEP_HEIGHT]:
			camera.keep_aspect = keep_aspect
			for lens: int in Optics.LENSES_MM:
				camera.fov = Optics.lens_fov(lens, aspect, keep_aspect)
				# Camera3D's actual projection matrix maps a point on the horizontal
				# gate edge to x=1. This independently checks both aspect conventions.
				var projected := camera.get_camera_projection().x.x * 18.0 / lens
				check(is_equal_approx(projected, 1.0), "horizontal angle for %s mm @ %s, axis %s" % [lens, dimensions, keep_aspect])
				check(is_equal_approx(Optics.focal_length(camera.fov, aspect, keep_aspect), lens), "inverse focal length")
	viewport.free()
	check(Optics.circle_of_confusion_mm(50, 2.8, 1.5, 1.5) == 0.0, "sharp on focus plane")
	var blur := Optics.circle_of_confusion_mm(50, 2.8, 1.5, 2.5)
	check(blur > 0.03 and is_equal_approx(Optics.circle_of_confusion_mm(50, 5.6, 1.5, 2.5), blur / 2.0), "aperture controls defocus")
	check(is_inf(Optics.circle_of_confusion_mm(200, 2.8, 0.1, 2.5)), "unreachable focus plane")

	var exposure := Exposure.new()
	check(exposure.solve().gain == 1.0 and exposure.solve().ready, "Game passes gain through without a meter")
	exposure.mode = Exposure.Mode.MANUAL
	exposure.aperture = 4.0
	exposure.seconds = 1.0 / 64.0
	var manual := exposure.solve(0.18)
	check(manual.ready and is_equal_approx(manual.gain, 1.0), "manual EV100 10 with no gain")
	check(is_zero_approx(manual.meter_error_ev), "middle-gray reference")
	exposure.iso = 200
	check(is_equal_approx(exposure.solve().gain, 2.0), "doubling ISO doubles linear signal")
	exposure.compensation_thirds = 3
	check(is_equal_approx(exposure.solve().gain, 4.0), "+1 EV doubles signal once")
	exposure.auto_iso = true
	check(not exposure.solve().ready, "manual Auto ISO needs a meter")
	check(exposure.solve(0.18).iso == 200, "manual Auto ISO accounts for compensation")
	exposure.compensation_thirds = 0
	exposure.mode = Exposure.Mode.APERTURE_PRIORITY
	exposure.aperture = 4.0
	exposure.preferred_seconds = 1.0 / 125.0
	exposure.min_iso = 100
	exposure.max_iso = 800
	var bright := exposure.solve(0.18)
	check(bright.iso == 200 and is_equal_approx(bright.seconds, 1.0/125), "Auto ISO protects preferred shutter")
	var dim := exposure.solve(0.18 / 16.0)
	check(dim.iso == 800 and dim.seconds > bright.seconds and dim.aperture == bright.aperture, "aperture priority at ISO ceiling")
	check(absf(dim.meter_error_ev) < 0.17, "aperture priority rounding")
	exposure.mode = Exposure.Mode.SHUTTER_PRIORITY
	exposure.seconds = 1.0 / 250
	var shutter := exposure.solve(0.18)
	check(shutter.iso == 100 and shutter.seconds == exposure.seconds, "shutter priority uses base ISO")
	check(is_equal_approx(shutter.aperture, 2.0) and absf(shutter.meter_error_ev) < 0.17, "shutter priority aperture")
	check(not exposure.solve(-0.2).ready and not exposure.solve(INF).ready, "unavailable metering")
	var black := exposure.solve(0.0)
	check(black.ready and black.iso == exposure.max_iso and black.aperture == Exposure.APERTURES[0], "black sample reaches camera limits")
	print("%s camera math checks, %s failures" % [checks, failures])
	quit(1 if failures else 0)
