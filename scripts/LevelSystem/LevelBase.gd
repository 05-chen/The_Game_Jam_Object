extends Node3D
class_name LevelBase

## 关卡根脚本：挂在「Blender 导出 → Godot 导入」的 3D 关卡根节点上（常见做法：在 .tscn 里实例化 .glb，再把本脚本挂到该实例或父节点）。
##
## 官方文档（建议对照阅读）：
## - 导入 3D 场景（glTF 等）：https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_3d_scenes/index.html
## - 场景树与节点遍历：[Node](https://docs.godotengine.org/en/stable/classes/class_node.html)（get_children、递归访问）
## - 分组：[Groups](https://docs.godotengine.org/en/stable/tutorials/scripting/groups.html)
## - 导航（若关卡含 NavigationRegion3D）：[Navigation](https://docs.godotengine.org/en/stable/tutorials/navigation/index.html)
##
## 本脚本在 _ready 时可选执行「导入后整理」：按节点命名前缀加入 `lvl_spawn` / `lvl_patrol` 组；可选批量设置 StaticBody3D 的碰撞层/掩码。
## 与 [PointTag] 配合：在 Blender 里为标记空物体命名后导出，或在 Godot 里给 Marker3D 挂 PointTag 脚本。

const GROUP_SPAWN := "lvl_spawn"
const GROUP_PATROL := "lvl_patrol"

@export_group("导入后自动设置")
@export var apply_spawn_patrol_by_name: bool = true
@export var spawn_name_prefixes: PackedStringArray = ["Spawn", "spawn", "SPAWN", "PlayerSpawn"]
@export var patrol_name_prefixes: PackedStringArray = ["Patrol", "patrol", "WP_", "wp_"]
## 非 0 时：为子树中所有 StaticBody3D 写入 collision_layer（覆盖原值，请与项目 physics 层设计一致）
@export var auto_static_body_collision_layer: int = 0
## 非 0 时：为子树中所有 StaticBody3D 写入 collision_mask
@export var auto_static_body_collision_mask: int = 0
## 非空时：为所有 StaticBody3D 额外 add_to_group（便于玩法脚本用 get_nodes_in_group 收集）
@export var static_body_extra_group: String = ""


func _ready() -> void:
	LevelManager.hide_mask()
	_post_configure_imported_scene()
	if _scene_has_navigation_region():
		_init_navigation_ai()


func _post_configure_imported_scene() -> void:
	if apply_spawn_patrol_by_name:
		_register_spawn_patrol_groups_by_name(self)
	if auto_static_body_collision_layer != 0 or auto_static_body_collision_mask != 0 or static_body_extra_group.strip_edges() != "":
		_apply_static_body_physics_and_groups(self)


func _register_spawn_patrol_groups_by_name(node: Node) -> void:
	for child in node.get_children():
		_register_spawn_patrol_groups_by_name(child)
	if node == self:
		return
	if not node is Node3D:
		return
	var node_name := String(node.name)
	if _begins_with_any_prefix(node_name, spawn_name_prefixes):
		if not node.is_in_group(GROUP_SPAWN):
			node.add_to_group(GROUP_SPAWN)
	elif _begins_with_any_prefix(node_name, patrol_name_prefixes):
		if not node.is_in_group(GROUP_PATROL):
			node.add_to_group(GROUP_PATROL)


func _begins_with_any_prefix(node_name: String, prefixes: PackedStringArray) -> bool:
	for p in prefixes:
		var prefix := String(p)
		if prefix != "" and node_name.begins_with(prefix):
			return true
	return false


func _apply_static_body_physics_and_groups(node: Node) -> void:
	for child in node.get_children():
		_apply_static_body_physics_and_groups(child)
	if not node is StaticBody3D:
		return
	var body := node as StaticBody3D
	if auto_static_body_collision_layer != 0:
		body.collision_layer = auto_static_body_collision_layer
	if auto_static_body_collision_mask != 0:
		body.collision_mask = auto_static_body_collision_mask
	var g := static_body_extra_group.strip_edges()
	if g != "" and not body.is_in_group(g):
		body.add_to_group(g)


func _scene_has_navigation_region() -> bool:
	return not find_children("*", "NavigationRegion3D", true, false).is_empty()


func _init_navigation_ai() -> void:
	pass


func _on_goal_reached() -> void:
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	GameManager.is_game_active = false
	LevelManager.advance()
