extends CanvasLayer
## Display treatment using the Denshattack! Photo Camera preset values.
## See THIRD_PARTY_LICENSES/Denshattack-Photo-Camera.txt.

const NAMES := ["Neutral", "Daylight negative", "Pastel negative", "Chrome slide", "Color print",
	"Instant print", "Tungsten negative", "Cross process", "Fine monochrome", "Silver print", "Hard monochrome"]
const SATURATION := [1.0, 1.06, 0.76, 1.31, 1.17, 0.83, 0.88, 1.16, 0.0, 0.0, 0.0]
const CONTRAST := [1.0, 0.99, 0.89, 1.13, 1.06, 0.86, 1.045, 1.15, 0.97, 1.12, 1.28]
const GAINS := [Vector3.ONE, Vector3(1.055,1.01,0.94), Vector3(1.04,1.0,0.98), Vector3(1.01,1.045,1.0),
	Vector3(1.045,0.985,1.01), Vector3(1.05,1.012,0.96), Vector3(0.89,1.01,1.14), Vector3(1.04,1.065,0.91),
	Vector3.ONE, Vector3.ONE, Vector3.ONE]

var material := ShaderMaterial.new()
var _applied := Vector3i(-1, -1, -1)


func _ready() -> void:
	layer = 119
	hide()
	# Force the screen sample to include all lower canvas layers, even when
	# the title already copied its back buffer for a VHS or RGB effect.
	var copy := BackBufferCopy.new()
	copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	add_child(copy)
	var rect := ColorRect.new()
	add_child(rect)
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = """shader_type canvas_item;
	render_mode unshaded, blend_disabled;
	uniform sampler2D scene : hint_screen_texture, repeat_disable, filter_nearest;
	uniform vec3 gains = vec3(1.);
	uniform float saturation = 1.;
	uniform float contrast = 1.;
	uniform float grain = 0.;
	uniform vec2 pixel_origin = vec2(0.);
	void fragment() {
		vec3 rgb = textureLod(scene, SCREEN_UV, 0.).rgb;
		float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
		rgb = (mix(vec3(luma), rgb, saturation) - 0.5) * contrast + 0.5;
		vec2 p = floor(FRAGCOORD.xy + pixel_origin);
		float noise = fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))) - 0.5;
		COLOR = vec4(max(vec3(0.), rgb * gains + noise * grain), 1.);
	}"""
	material.shader = shader
	rect.material = material


func configure(look: int, grain: bool, iso: int) -> void:
	look = clampi(look, 0, NAMES.size() - 1)
	var next := Vector3i(look, int(grain), iso if grain else 0)
	if _applied == next:
		return
	_applied = next
	visible = look != 0 or grain
	if not visible:
		return
	material.set_shader_parameter("saturation", SATURATION[look])
	material.set_shader_parameter("contrast", CONTRAST[look])
	material.set_shader_parameter("gains", GAINS[look])
	var stops := clampf(log(maxf(100.0, iso) / 100.0) / log(2.0), 0.0, 6.0)
	material.set_shader_parameter("grain", 0.016 + 0.013 * stops if grain else 0.0)


func set_pixel_origin(origin: Vector2) -> void:
	material.set_shader_parameter("pixel_origin", origin)
