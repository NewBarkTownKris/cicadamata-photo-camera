extends RefCounted
## Integration points from build 25963814. Each entry records the original
## object, so a new level cannot inherit visibility or camera state from an old one.

const HUD := [
	"UI", "Crosshairs", "CrosshairsDot", "AimAssist", "Hitmarkers", "DmgIndicator",
	"Subtitles", "SubtitlesJoy", "Hint", "JoyeusePrompt", "JoyeusePattern", "JoyeuseNum",
	"MataIc", "MataText", "Transferring", "aegis", "Panel", "FakeDash", "FakeJump",
	"FakePortrait", "JoyeuseText", "RingCornerSpawn",
]
const FIRST_PERSON := ["RigFPS", "MeshInstance3D", "CorePixel", "WhiteFlashPixel", "DamagePixel"]

var scene: Node
var source: Camera3D
var player: CharacterBody3D
var mouse_mode: Input.MouseMode
var _global: Node
var _show_mouse := false
var _hidden: Array[Node] = []
var _process_modes := {}


func identify(tree: SceneTree) -> bool:
	if tree.paused or not is_instance_valid(tree.current_scene):
		return false
	source = tree.root.get_camera_3d()
	if not is_instance_valid(source) or source.projection != Camera3D.PROJECTION_PERSPECTIVE:
		return false
	scene = tree.current_scene
	var head := source.get_parent()
	player = head.get_parent() as CharacterBody3D if head else null
	if not player or not player.is_in_group(&"player") or (scene != player and not scene.is_ancestor_of(player)):
		return false
	if player.get_node_or_null("Head/Camera3D") != source or not player.has_node("PauseController"):
		return false
	if ("active" in player and not player.get("active")) or ("death" in player and player.get("death")):
		return false
	var pause_menu := tree.root.get_node_or_null("UI/Pause") as Control
	return not (pause_menu and pause_menu.is_visible_in_tree())


func _hide(node: Node) -> void:
	if node is CanvasItem or node is CanvasLayer or node is Node3D:
		if node.get("visible"):
			_hidden.append(node)
			node.set("visible", false)


func _pause_override(node: Node) -> void:
	if node.process_mode in [Node.PROCESS_MODE_ALWAYS, Node.PROCESS_MODE_WHEN_PAUSED]:
		_process_modes[node.get_instance_id()] = node.process_mode
		node.process_mode = Node.PROCESS_MODE_PAUSABLE


func freeze(tree: SceneTree, photo: Node) -> void:
	mouse_mode = Input.mouse_mode
	tree.paused = true
	# The retail global polls Steam callbacks while paused. Its only other
	# process duty on this build is the cursor, controlled by showmouse.
	_global = tree.root.get_node_or_null("global")
	if _global and "showmouse" in _global:
		_show_mouse = _global.get("showmouse")
		_global.set("showmouse", false)
	else:
		_global = null
	# Godot's pause menu and other explicit overrides can still poll Input
	# while the tree is paused. Keep collision objects in the world for AF.
	var pending := tree.root.get_children()
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node == photo:
			continue
		if node != _global:
			_pause_override(node)
		pending.append_array(node.get_children())
	for path: String in HUD:
		_hide(tree.root.get_node_or_null("UI/" + path))
	for path: String in ["SaveIcon", "UnlockNotif", "DebugMenu"]:
		_hide(tree.root.get_node_or_null(path))
	for path: String in FIRST_PERSON:
		_hide(source.get_node_or_null(path))
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func guard_new_node(node: Node, photo: Node) -> void:
	if node != photo and not photo.is_ancestor_of(node):
		_pause_override(node)


func restore(tree: SceneTree, detached: Camera3D) -> void:
	# Respect another camera that has already taken control during a transition.
	if (tree.current_scene == scene and is_instance_valid(source) and source.is_inside_tree()
			and is_instance_valid(detached) and tree.root.get_camera_3d() == detached):
		source.make_current()
	for node in _hidden:
		if is_instance_valid(node) and node.is_inside_tree() and not node.get("visible"):
			node.set("visible", true)
	_hidden.clear()
	for id: int in _process_modes:
		var node := instance_from_id(id) as Node
		if node and node.process_mode == Node.PROCESS_MODE_PAUSABLE:
			node.process_mode = _process_modes[id]
	_process_modes.clear()
	# The entry guard only accepts an unpaused tree. A newly opened native
	# pause menu owns its pause and cursor on focus loss.
	var menu := tree.root.get_node_or_null("UI/Pause") as Control
	if is_instance_valid(_global) and not _global.get("showmouse"):
		_global.set("showmouse", _show_mouse)
	if not (menu and menu.is_visible_in_tree()):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = mouse_mode
		tree.paused = false
