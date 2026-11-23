extends RefCounted
## Photographic settings and scene-linear exposure, adapted from Denshattack!
## Photo Camera. See THIRD_PARTY_LICENSES/Denshattack-Photo-Camera.txt.
##
## Supply luminance from the current crop, before display grading and gain.
## The virtual reference of 0.18 at EV100 10 must be calibrated against gameplay.

enum Mode { GAME, MANUAL, APERTURE_PRIORITY, SHUTTER_PRIORITY }
const REFERENCE_EV100 := 10.0
const REFERENCE_GRAY := 0.18
const APERTURES := [1.0, 1.1, 1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5,
	4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8.0, 9.0, 10.0, 11.0, 13.0, 14.0, 16.0]
const ISOS := [100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600,
	2000, 2500, 3200, 4000, 5000, 6400]
const SHUTTERS := [8.0, 6.0, 5.0, 4.0, 3.2, 2.5, 2.0, 1.6, 1.3, 1.0, 0.8, 0.6,
	0.5, 0.4, 0.3, 0.25, 0.2, 1.0/6, 1.0/8, 1.0/10, 1.0/13, 1.0/15, 1.0/20,
	1.0/25, 1.0/30, 1.0/40, 1.0/50, 1.0/60, 1.0/80, 1.0/100, 1.0/125, 1.0/160,
	1.0/200, 1.0/250, 1.0/320, 1.0/400, 1.0/500, 1.0/640, 1.0/800, 1.0/1000,
	1.0/1250, 1.0/1600, 1.0/2000, 1.0/2500, 1.0/3200, 1.0/4000, 1.0/5000,
	1.0/6400, 1.0/8000, 1.0/10000, 1.0/12500, 1.0/16000, 1.0/20000, 1.0/25000,
	1.0/32000]

var mode := Mode.GAME
var aperture: float = 2.8
var seconds: float = 1.0 / 125.0
var iso: int = 100
var auto_iso := false
var min_iso: int = 100
var max_iso: int = 6400
var preferred_seconds: float = 1.0 / 125.0
var compensation_thirds: int = 0


class Reading:
	var ready: bool
	var aperture: float
	var seconds: float
	var iso: int
	var gain: float = 1.0
	var camera_ev100: float
	var metered_ev100: float = NAN
	var meter_error_ev: float = NAN


static func _nearest(choices: Array, target: float, low: float = 0.0, high: float = INF) -> float:
	var best: float = NAN
	var smallest_error := INF
	for value: float in choices:
		if value < low or value > high:
			continue
		var error := absf(log(value) - log(target))
		if error < smallest_error:
			best = value
			smallest_error = error
	return best


func _iso_for_preferred_shutter(desired: float) -> int:
	for sensitivity: int in ISOS:
		if sensitivity >= min_iso and sensitivity >= desired:
			return mini(sensitivity, max_iso)
	return max_iso


## Missing, negative or nonfinite luminance means no meter is available.
## A valid black sample is floored to keep priority modes usable in total darkness.
func solve(linear_luminance: float = NAN) -> Reading:
	var shot := Reading.new()
	shot.aperture = aperture
	shot.seconds = seconds
	shot.iso = min_iso if auto_iso else iso
	var has_meter := is_finite(linear_luminance) and linear_luminance >= 0.0
	var fixed_manual := mode == Mode.MANUAL and not auto_iso
	shot.ready = mode == Mode.GAME or fixed_manual or has_meter
	var compensation := clampi(compensation_thirds, -15, 15) / 3.0
	if has_meter:
		shot.metered_ev100 = REFERENCE_EV100 + log(maxf(1e-12, linear_luminance) / REFERENCE_GRAY) / log(2.0)
		var light := pow(2.0, shot.metered_ev100 - compensation)
		match mode:
			Mode.APERTURE_PRIORITY:
				if auto_iso:
					shot.iso = _iso_for_preferred_shutter(100.0 * aperture * aperture / (light * preferred_seconds))
				shot.seconds = _nearest(SHUTTERS, 100.0 * aperture * aperture / (light * shot.iso))
			Mode.SHUTTER_PRIORITY:
				if auto_iso:
					var widest: float = APERTURES[0]
					shot.iso = roundi(_nearest(ISOS, 100.0 * widest * widest / (light * seconds), min_iso, max_iso))
				shot.aperture = _nearest(APERTURES, sqrt(light * seconds * shot.iso / 100.0))
			Mode.MANUAL:
				if auto_iso:
					shot.iso = roundi(_nearest(ISOS, 100.0 * aperture * aperture / (light * seconds), min_iso, max_iso))
	shot.camera_ev100 = log(shot.aperture * shot.aperture / shot.seconds * 100.0 / shot.iso) / log(2.0)
	if mode != Mode.GAME:
		var gain_ev := REFERENCE_EV100 - shot.camera_ev100
		if fixed_manual:
			gain_ev += compensation
		shot.gain = pow(2.0, gain_ev)
		if has_meter:
			shot.meter_error_ev = shot.metered_ev100 - REFERENCE_EV100 + gain_ev - compensation
	return shot
