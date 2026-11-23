extends SceneTree
## A synthetic root-viewport print capture. Only the private software-display
## runner invokes this test. No game resources or physical display are needed.

const BASE := Vector2i(160, 96)
const LOGICAL := Vector2i(80, 48)
var checks := 0
var failures := 0


func _initialize() -> void:
	run.call_deferred()


func check(value: bool, description: String) -> void:
	checks += 1
	if not value:
		failures += 1
		printerr("FAIL ", description)


func panel(parent: Node, color: Color) -> ColorRect:
	var rect := ColorRect.new()
	parent.add_child(rect)
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.color = color
	return rect


func read_frame() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func add_stripe_chart() -> void:
	var camera := Camera3D.new()
	camera.fov = 90.0
	root.add_child(camera)
	camera.make_current()
	var card := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(7, 4.2)
	card.mesh = quad
	card.position.z = -2.0
	var shader := Shader.new()
	shader.code = """shader_type spatial;
	render_mode unshaded, cull_disabled;
	void fragment() { ALBEDO = vec3(1.0, 0.0, step(0.5, fract(UV.x * 180.0))); }"""
	var material := ShaderMaterial.new()
	material.shader = shader
	card.material_override = material
	root.add_child(card)


func stripe_transitions(image: Image) -> int:
	# Sample the right half where the canvas grade overlays the striped 3D card.
	var mid := image.get_size() / 2
	var last := image.get_pixel(mid.x, mid.y).b > 0.5
	var count := 0
	for x in range(mid.x + 1, image.get_width()):
		var current := image.get_pixel(x, mid.y).b > 0.5
		if last != current:
			count += 1
		last = current
	return count


func run() -> void:
	if DisplayServer.get_name() != "X11" or not "llvmpipe" in RenderingServer.get_video_adapter_name().to_lower():
		printerr("This fixture requires the private Xvfb software-display runner.")
		quit(1)
		return
	root.size = BASE
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root.content_scale_size = LOGICAL
	# A fullscreen pass samples the root back buffer and swaps red and green.
	var chart := Control.new()
	root.add_child(chart)
	chart.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_stripe_chart()
	var landmark := panel(chart, Color.BLUE)
	landmark.anchor_right = 0.5
	var fixed := ColorRect.new()
	chart.add_child(fixed)
	fixed.size = Vector2(8, 8)
	fixed.color = Color.WHITE
	var effect := CanvasLayer.new()
	root.add_child(effect)
	var grade := panel(effect, Color.WHITE)
	var shader := Shader.new()
	shader.code = """shader_type canvas_item;
	uniform sampler2D scene_color : hint_screen_texture, repeat_disable, filter_nearest;
	void fragment() {
		vec3 rgb = textureLod(scene_color, SCREEN_UV, 0.0).rgb;
		COLOR = vec4(rgb.g, rgb.r, rgb.b, 1.0);
	}"""
	var material := ShaderMaterial.new()
	material.shader = shader
	grade.material = material

	var before: Image = await read_frame()
	check(before.get_size() == BASE, "source render dimensions")
	check(before.get_pixel(12, 4) == Color.WHITE, "8 logical pixels span 16 source pixels")
	for scale_factor in [2, 3, 4]:
		root.content_scale_size = BASE * scale_factor
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
		var shot: Image = await read_frame()
		var size := shot.get_size()
		check(size == BASE * scale_factor, "native root readback at %sx" % scale_factor)
		check(DisplayServer.window_get_size() == BASE, "private window size at %sx" % scale_factor)
		check(shot.get_pixel(size.x / 4, size.y / 2) == Color.BLUE, "anchored landmark at %sx" % scale_factor)
		var graded := shot.get_pixel(3 * size.x / 4, size.y / 2)
		check(graded.g == 1.0 and graded.r == 0.0, "root screen effect at %sx" % scale_factor)
		check(shot.get_pixel(12 * scale_factor, 4 * scale_factor) != Color.WHITE, "fixed-pixel element changes relative size")
		if scale_factor == 4:
			var saved := Image.new()
			check(saved.load_png_from_buffer(shot.save_png_to_buffer()) == OK, "PNG round-trip")
			saved.convert(shot.get_format())
			check(saved.get_size() == size and saved.get_data() == shot.get_data(), "verified print pixels")
			var low := stripe_transitions(before)
			var high := stripe_transitions(saved)
			check(high > BASE.x / 2 and high > low, "new 3D detail survives the root screen effect and PNG")
			print("Root 3D stripe transitions in the graded right half: %d at 1x, %d at 4x" % [low, high])
	root.content_scale_size = LOGICAL
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	var after: Image = await read_frame()
	check(after.get_size() == BASE and after.get_data() == before.get_data(), "original pixel output restored")
	print("%d print root checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
