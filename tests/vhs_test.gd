extends SceneTree

const State := preload("res://cicadamata_photo/game_state.gd")
# Purpose-built fixture with separate sample offsets and a material override.
const SOURCE := """
shader_type canvas_item;
uniform float strength = 0.25;
void fragment() {
	float black_offset = 0.12;
	float x_offset = 0.45;
	vec2 first = UV + vec2(black_offset,0.0);
	vec2 second = UV + vec2(x_offset,0.0);
	COLOR = vec4(first.x, second.x, strength, 1.0);
}
"""

var failures := 0


func check(pass_: bool, reason: String) -> void:
	if not pass_:
		failures += 1
		printerr("FAIL ", reason)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var ui := CanvasLayer.new()
	ui.name = "UI"
	root.add_child(ui)
	var target := ColorRect.new()
	target.name = "VHS"
	target.hide()
	ui.add_child(target)
	var shader := Shader.new()
	shader.code = SOURCE
	shader.take_over_path(State.VHS_SHADER)
	var original := ShaderMaterial.new()
	original.shader = shader
	original.set_shader_parameter("strength", 0.625)
	target.material = original
	var other := ColorRect.new()
	ui.add_child(other)
	other.material = original
	var photo := Node.new()
	root.add_child(photo)
	var state := State.new()
	state.source = Camera3D.new()
	root.add_child(state.source)
	state.freeze(self, photo)
	state.apply_effects(true, false)
	var local := target.material as ShaderMaterial
	check(local != original and local.shader != shader, "per-node shader and material")
	check(local.shader.code == SOURCE.replace(State.VHS_CHROMA_UV, State.VHS_LUMA_UV), "sole chroma UV edit")
	check(local.get_shader_parameter("strength") == 0.625, "uniform override preserved")
	check(not target.visible and other.material == original and original.shader.code == SOURCE, "visibility and shared material intact")
	state.apply_effects(false, false)
	check(target.material == original and not target.visible, "exact material restored")
	target.show()
	state.apply_effects(true, false)
	var replacement := original.duplicate() as ShaderMaterial
	replacement.set_shader_parameter("strength", 0.75)
	target.material = replacement
	await process_frame
	await process_frame
	check(target.material != replacement and target.material.get_shader_parameter("strength") == 0.75, "game reassignment during override")
	ui.remove_child(target)
	var next := ColorRect.new()
	next.name = "VHS"
	ui.add_child(next)
	next.material = original
	await process_frame
	await process_frame
	check(target.material == replacement and target.visible, "removed node retains its latest retail material")
	check(next.material != original and next.visible, "replacement VHS node acquired")
	var unrelated := CanvasItemMaterial.new()
	next.material = unrelated
	state.apply_effects(false, false)
	check(next.material == unrelated, "toggle preserves newer unrelated material")
	next.material = replacement
	state.apply_effects(true, false)
	state.restore(self, null)
	check(next.material == replacement and next.visible, "session exit restores exact latest material")
	check(not process_frame.is_connected(state._update_vhs), "session exit disconnects watcher")
	target.free()
	if not failures:
		print("Native VHS fringe material substitution passed")
	quit(1 if failures else 0)
