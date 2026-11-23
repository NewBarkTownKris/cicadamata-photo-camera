extends RefCounted
## Full-frame equivalents use a 36 mm gate across the uncropped viewport.
## The viewfinder and the PNG writer must use the same integer crop.

const LENSES_MM := [16, 24, 35, 50, 85, 135, 200, 600]
const FRAME_NAMES := ["Viewport", "3:2", "4:3", "1:1", "16:9", "5:4", "21:9", "65:24"]
const RATIOS := [
	Vector2i.ZERO, Vector2i(3, 2), Vector2i(4, 3), Vector2i.ONE,
	Vector2i(16, 9), Vector2i(5, 4), Vector2i(7, 3), Vector2i(65, 24),
]
const SENSOR_WIDTH_MM := 36.0


static func crop_rect(size: Vector2i, frame_index: int, portrait: bool) -> Rect2i:
	if size.x <= 0 or size.y <= 0 or frame_index < 0 or frame_index >= RATIOS.size():
		return Rect2i()
	if frame_index == 0:
		return Rect2i(Vector2i.ZERO, size)
	var ratio: Vector2i = RATIOS[frame_index]
	if portrait:
		ratio = Vector2i(ratio.y, ratio.x)
	@warning_ignore("integer_division")
	var scale := mini(size.x / ratio.x, size.y / ratio.y)
	if scale < 1:
		return Rect2i()
	var cropped := ratio * scale
	return Rect2i((size - cropped) / 2, cropped)


static func lens_fov(focal_mm: float, viewport_aspect: float, keep_aspect: int) -> float:
	var gate := SENSOR_WIDTH_MM
	if keep_aspect == Camera3D.KEEP_HEIGHT:
		gate /= viewport_aspect
	return rad_to_deg(2.0 * atan(gate / (2.0 * focal_mm)))


static func focal_length(fov_degrees: float, viewport_aspect: float, keep_aspect: int) -> float:
	var gate := SENSOR_WIDTH_MM
	if keep_aspect == Camera3D.KEEP_HEIGHT:
		gate /= viewport_aspect
	return gate / (2.0 * tan(deg_to_rad(fov_degrees) * 0.5))


## Magnitude of the circle of confusion on the 36 mm sensor; distances are metres.
## A point with a diameter below about 0.03 mm is conventionally considered sharp.
static func circle_of_confusion_mm(
	focal_mm: float, aperture: float, focus_m: float, subject_m: float
) -> float:
	var focus_mm := focus_m * 1000.0
	if focus_mm <= focal_mm or focal_mm <= 0.0 or aperture <= 0.0 or subject_m <= 0.0:
		return INF
	return focal_mm * focal_mm * absf(1.0 - focus_m / subject_m) / (aperture * (focus_mm - focal_mm))
