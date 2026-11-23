extends Control
## Composition guides share the PNG writer's integer crop in render-target pixels.
## All finder elements, including the help guide, belong to this one visibility toggle.

const CameraMath = preload("res://cicadamata_photo/camera_math.gd")
const MATTE := Color(0.015, 0.018, 0.019, 0.82)
const PANEL := Color(0.025, 0.032, 0.034, 0.92)
const GUIDE := Color(1.0, 1.0, 1.0, 0.68)
const INK := Color(0.94, 0.96, 0.96)
const KEY_COLOR := Color(0.70, 0.89, 0.80)
const HELP := [
	["WASD  ·  E / Q", "Move  ·  Rise / descend"],
	["Shift / Ctrl", "Fast / precise movement"],
	["Mouse / arrows", "Aim"],
	["Z / X  ·  F10", "Roll  ·  Level camera"],
	["F7  ·  [ / ]", "Lens preset  ·  Adjust field of view"],
	["F5 / F6", "Aspect ratio / rotate frame"],
	["H  ·  G  ·  R", "Finder  ·  Thirds grid  ·  Reticle"],
	["J / K or wheel  ·  L", "Manual focus  ·  Fine / coarse steps"],
	["N or middle click  ·  T", "Autofocus  ·  Continuous AF"],
	["B  ·  U / I", "Depth of field  ·  Aperture"],
	["Y", "DOF multiplier"],
	["O  ·  F4 / L3", "Exposure mode  ·  Studio"],
	["; / '  ·  , / .", "Shutter time  ·  ISO"],
	["F9 / click / A  ·  F3 / Y button", "PNG  ·  PNG and EXR"],
	["Sticks  ·  LB / RB  ·  R3", "Move and aim  ·  Height  ·  Autofocus"],
	["F2  ·  View / Back", "Choose folder  ·  Resume"],
	["F1  ·  F8", "Close help  ·  Resume game"],
]

var studio_open := false
var studio_lines: Array = []
var studio_selection := 0
var meter_ev := NAN
var focus_feedback := ""
var print_dimensions := ""

var frame_index: int = 0:
	set(value):
		if frame_index != value:
			frame_index = value
			queue_redraw()
var portrait: bool = false:
	set(value):
		if portrait != value:
			portrait = value
			queue_redraw()
var show_grid: bool = false:
	set(value):
		if show_grid != value:
			show_grid = value
			queue_redraw()
var reticle: int = 0:
	set(value):
		if reticle != value:
			reticle = value
			queue_redraw()
var help_open: bool = false:
	set(value):
		if help_open != value:
			help_open = value
			queue_redraw()
var readout: String = "":
	set(value):
		if readout != value:
			readout = value
			queue_redraw()
var status: String = "":
	set(value):
		if status != value:
			status = value
			queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_viewport().size_changed.connect(queue_redraw)


static func render_size(viewport: Viewport) -> Vector2i:
	if viewport is SubViewport:
		return (viewport as SubViewport).size
	# Godot 4.7.2 ViewportTexture.get_size() applies the canvas stretch again
	# to a Window's render size. Convert the logical extent to pixels once.
	return Vector2i((viewport.get_visible_rect().size * viewport.get_stretch_transform().get_scale()).round())


func _draw() -> void:
	var pixels := render_size(get_viewport())
	if pixels.x <= 0 or pixels.y <= 0 or size.x <= 0 or size.y <= 0:
		return
	var crop := CameraMath.crop_rect(pixels, frame_index, portrait)
	if not crop.has_area():
		return
	var to_local := size / Vector2(pixels)
	var frame := Rect2(Vector2(crop.position) * to_local, Vector2(crop.size) * to_local)
	var ui_scale := minf(size.x / 840.0, size.y / 500.0)
	_draw_frame(frame, ui_scale)
	_draw_reticle(frame.get_center(), ui_scale)
	var font := ThemeDB.fallback_font
	var font_size := maxi(1, roundi(14.0 * ui_scale))
	var line_height := ceilf(font.get_height(font_size)) + 3.0 * ui_scale
	var pad := 9.0 * ui_scale
	if is_finite(meter_ev):
		_draw_meter(font, font_size, ui_scale, pad)
	if studio_open:
		_draw_studio(font, font_size, line_height, pad)
	elif help_open:
		_draw_help(font, font_size, line_height, pad)
	var lines := PackedStringArray()
	if not readout.is_empty():
		lines.append_array(readout.split("\n", false))
	if not focus_feedback.is_empty() and not studio_open:
		lines.append(focus_feedback)
	if not status.is_empty():
		lines.append_array(status.split("\n", false))
	if not help_open and not studio_open:
		var framing: String = CameraMath.FRAME_NAMES[frame_index]
		if portrait and frame_index != 0 and frame_index != 3:
			framing += " rotated"
		var dimensions := print_dimensions if not print_dimensions.is_empty() else "%d × %d" % [crop.size.x, crop.size.y]
		lines.append("%s   %s     ·     F1  Controls     F4  Studio     F8  Resume" % [framing, dimensions])
	if not lines.is_empty():
		_draw_readout(font, font_size, lines, line_height, pad)


func _draw_frame(frame: Rect2, ui_scale: float) -> void:
	if frame.position.y > 0:
		draw_rect(Rect2(0, 0, size.x, frame.position.y), MATTE)
	if frame.end.y < size.y:
		draw_rect(Rect2(0, frame.end.y, size.x, size.y - frame.end.y), MATTE)
	if frame.position.x > 0:
		draw_rect(Rect2(0, frame.position.y, frame.position.x, frame.size.y), MATTE)
	if frame.end.x < size.x:
		draw_rect(Rect2(frame.end.x, frame.position.y, size.x - frame.end.x, frame.size.y), MATTE)
	if frame_index != 0:
		draw_rect(frame, GUIDE, false, ui_scale)
	if show_grid:
		for third in [1.0 / 3.0, 2.0 / 3.0]:
			var x: float = frame.position.x + frame.size.x * third
			var y: float = frame.position.y + frame.size.y * third
			_guide_line(Vector2(x, frame.position.y), Vector2(x, frame.end.y), ui_scale)
			_guide_line(Vector2(frame.position.x, y), Vector2(frame.end.x, y), ui_scale)


func _guide_line(start: Vector2, finish: Vector2, ui_scale: float) -> void:
	draw_line(start, finish, Color(0, 0, 0, 0.45), ui_scale * 2.5, true)
	draw_line(start, finish, GUIDE, ui_scale, true)


func _draw_reticle(center: Vector2, ui_scale: float) -> void:
	var radius := 9.0 * ui_scale
	match reticle:
		0:
			for direction: Vector2 in [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]:
				_guide_line(center + direction * radius * 0.45, center + direction * radius, ui_scale)
		1:
			var bounds := Rect2(center - Vector2.ONE * radius, Vector2.ONE * radius * 2)
			draw_rect(bounds, Color(0, 0, 0, 0.45), false, 2.5 * ui_scale)
			draw_rect(bounds, GUIDE, false, ui_scale)
		2:
			draw_arc(center, radius, 0, TAU, 40, Color(0, 0, 0, 0.45), 2.5 * ui_scale, true)
			draw_arc(center, radius, 0, TAU, 40, GUIDE, ui_scale, true)


func _draw_help(font: Font, font_size: int, line_height: float, pad: float) -> void:
	var key_width := 0.0
	var action_width := 0.0
	for row: Array in HELP:
		key_width = maxf(key_width, font.get_string_size(row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
		action_width = maxf(action_width, font.get_string_size(row[1], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var panel_width := minf(size.x - 2 * pad, key_width + action_width + 5 * pad)
	draw_rect(Rect2(pad, pad, panel_width, HELP.size() * line_height + 2 * pad), PANEL)
	var baseline := 2 * pad + font.get_ascent(font_size)
	var action_x := 4 * pad + key_width
	for row: Array in HELP:
		draw_string(font, Vector2(2 * pad, baseline), row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, KEY_COLOR)
		draw_string(font, Vector2(action_x, baseline), row[1], HORIZONTAL_ALIGNMENT_LEFT, panel_width - action_x, font_size, INK)
		baseline += line_height


func _draw_readout(font: Font, font_size: int, lines: PackedStringArray, line_height: float, pad: float) -> void:
	var text_width := 0.0
	for line in lines:
		text_width = maxf(text_width, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	text_width = minf(text_width, size.x - 4 * pad)
	var height := line_height * lines.size() + 2 * pad
	var top := size.y - height - pad
	draw_rect(Rect2(pad, top, text_width + 2 * pad, height), PANEL)
	var baseline := top + pad + font.get_ascent(font_size)
	for line in lines:
		draw_string(font, Vector2(2 * pad, baseline), line, HORIZONTAL_ALIGNMENT_LEFT, text_width, font_size, INK)
		baseline += line_height


func _draw_studio(font: Font, font_size: int, line_height: float, pad: float) -> void:
	if studio_lines.is_empty():
		return
	var count := clampi(floori((size.y * 0.72 - pad * 4) / line_height) - 2, 3, studio_lines.size())
	var first := clampi(studio_selection - count / 2, 0, studio_lines.size() - count)
	var panel_width := minf(size.x - pad * 2, maxf(400 * pad / 9, size.x * 0.49))
	var panel_height := (count + 2) * line_height + 3 * pad
	draw_rect(Rect2(pad, pad, panel_width, panel_height), PANEL)
	var baseline := pad * 2 + font.get_ascent(font_size)
	draw_string(font, Vector2(2 * pad, baseline), "Studio   %d / %d" % [studio_selection + 1, studio_lines.size()],
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, KEY_COLOR)
	draw_string(font, Vector2(2 * pad, baseline), "F3 / Y button   PNG + EXR",
		HORIZONTAL_ALIGNMENT_RIGHT, panel_width - 2 * pad, font_size, KEY_COLOR)
	var value_x := pad + panel_width * 0.54
	baseline += line_height + pad * 0.5
	for i in range(first, first + count):
		var row: Array = studio_lines[i]
		if i == studio_selection:
			draw_rect(Rect2(pad * 1.5, baseline - font.get_ascent(font_size), panel_width - pad, line_height),
				Color(0.18, 0.29, 0.26, 0.98))
		var color := Color(0.64, 0.68, 0.67) if row[2] else INK
		draw_string(font, Vector2(2 * pad, baseline), row[0], HORIZONTAL_ALIGNMENT_LEFT, value_x - 3 * pad, font_size, color)
		draw_string(font, Vector2(value_x, baseline), row[1], HORIZONTAL_ALIGNMENT_LEFT, panel_width - value_x, font_size, color)
		baseline += line_height
	draw_string(font, Vector2(2 * pad, baseline + pad * 0.5), "↑ ↓ Select    ← → Adjust    F4 / L3 Close",
		HORIZONTAL_ALIGNMENT_LEFT, panel_width - 2 * pad, font_size, KEY_COLOR)


func _draw_meter(font: Font, font_size: int, ui_scale: float, pad: float) -> void:
	var width := 135.0 * ui_scale
	var position := Vector2(size.x - width - pad * 3, pad)
	draw_rect(Rect2(position, Vector2(width + 2 * pad, 4.5 * pad)), PANEL)
	var start := position + Vector2(pad, 3.5 * pad)
	draw_string(font, position + Vector2(pad, 2 * pad), "EV  %+.1f" % meter_ev, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, INK)
	for tick in range(-9, 10):
		var x := start.x + width * (tick + 9) / 18.0
		var height := (0.9 if tick % 3 == 0 else 0.45) * pad
		draw_line(Vector2(x, start.y), Vector2(x, start.y - height), GUIDE, maxf(ui_scale, 0.5))
	var ix := start.x + width * (clampf(meter_ev, -3.0, 3.0) + 3.0) / 6.0
	draw_line(Vector2(ix, start.y + pad * 0.5), Vector2(ix, start.y - pad), KEY_COLOR, 2.5 * ui_scale)
