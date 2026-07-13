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
##
## 碰撞与玩家配合（见 blind_player.gd / project.godot）：
## - 关卡 StaticBody3D 应使用 layer 1 (environment)，与 room_builder 一致；瞎子 collision_mask = 1 才能挡墙。
## - house_f_1 等大场景可设 auto_static_body_collision_layer = 1；无 StaticBody3D 时可开 generate_mesh_trimesh_collision。
## - 关卡根为 Node3D/StaticBody3D，不受重力影响；会掉落的是玩家 CharacterBody3D，须有地面碰撞。

const GROUP_SPAWN := "lvl_spawn"
const GROUP_PATROL := "lvl_patrol"

@export_group("导入后自动设置")
@export var apply_spawn_patrol_by_name: bool = true
@export var spawn_name_prefixes: PackedStringArray = ["Spawn", "spawn", "SPAWN", "PlayerSpawn"]
@export var patrol_name_prefixes: PackedStringArray = ["Patrol", "patrol", "WP_", "wp_"]
## 非 0 时：为子树中所有 StaticBody3D 写入 collision_layer（覆盖原值）。大场景建议设为 1，与 BlindPlayer 的 collision_mask 对应。
@export var auto_static_body_collision_layer: int = 0
## 非 0 时：为子树中所有 StaticBody3D 写入 collision_mask
@export var auto_static_body_collision_mask: int = 0
## 非空时：为所有 StaticBody3D 额外 add_to_group（便于玩法脚本用 get_nodes_in_group 收集）
@export var static_body_extra_group: String = ""
## 子树中尚无 StaticBody3D 时，为 MeshInstance3D 自动生成碰撞（默认凸包，比三角网格更适合玩家移动）。
@export var generate_mesh_trimesh_collision: bool = false
## true = 凸包碰撞（快、不易卡缝）；false = 三角网格（准但极易卡顿）
@export var mesh_collision_use_convex: bool = true
## 网格 AABB 最大边长低于此值（米）时跳过，避免给小装饰物加碰撞
@export var mesh_collision_min_extent: float = 0.35

@export_group("药品刷新")
## 大场景：本关 Type 0/1 药品全部拾取后，等待若干秒在原位重新刷新（不含 Type 2 通关线索）。
@export var enable_medicine_respawn: bool = false
@export var medicine_respawn_delay_sec: float = 5.0

var _medicines: Array[Node] = []
var _medicine_respawn_timer: Timer = null
var _medicine_respawn_pending: bool = false
var _medicine_respawn_signal_connected: bool = false


func _ready() -> void:
	LevelManager.hide_mask()
	_post_configure_imported_scene()
	if enable_medicine_respawn:
		_setup_medicine_respawn()
	if _scene_has_navigation_region():
		_init_navigation_ai()


func _exit_tree() -> void:
	_disconnect_medicine_respawn_signal()


func _setup_medicine_respawn() -> void:
	_medicines = _find_level_medicines()
	if _medicines.is_empty():
		push_warning("[LevelBase] 已开启药品刷新，但未找到可刷新的药品节点")
		return
	_medicine_respawn_timer = Timer.new()
	_medicine_respawn_timer.name = "MedicineRespawnTimer"
	_medicine_respawn_timer.one_shot = true
	_medicine_respawn_timer.wait_time = medicine_respawn_delay_sec
	_medicine_respawn_timer.timeout.connect(_on_medicine_respawn_timeout)
	add_child(_medicine_respawn_timer)
	_connect_medicine_respawn_signal()


func _connect_medicine_respawn_signal() -> void:
	if _medicine_respawn_signal_connected:
		return
	if not GameManager.medicine_collected.is_connected(_on_medicine_collected):
		GameManager.medicine_collected.connect(_on_medicine_collected)
	_medicine_respawn_signal_connected = true


func _disconnect_medicine_respawn_signal() -> void:
	if not _medicine_respawn_signal_connected:
		return
	if GameManager.medicine_collected.is_connected(_on_medicine_collected):
		GameManager.medicine_collected.disconnect(_on_medicine_collected)
	_medicine_respawn_signal_connected = false


func _on_medicine_collected(_role: int) -> void:
	if not enable_medicine_respawn or _medicine_respawn_pending:
		return
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	if _medicines.is_empty() or not _all_level_medicines_collected():
		return
	_medicine_respawn_pending = true
	_medicine_respawn_timer.start()


func _find_level_medicines() -> Array[Node]:
	var result: Array[Node] = []
	for node in find_children("*", "StaticBody3D", true, false):
		if node.has_method("is_respawnable_medicine") and node.call("is_respawnable_medicine"):
			result.append(node)
	return result


func _all_level_medicines_collected() -> bool:
	for med in _medicines:
		if med == null or not is_instance_valid(med):
			continue
		if not med.has_method("is_fully_collected") or not med.call("is_fully_collected"):
			return false
	return true


func _on_medicine_respawn_timeout() -> void:
	if NetworkManager.is_multiplayer_game:
		if multiplayer.is_server():
			_rpc_respawn_level_medicines.rpc()
	else:
		_respawn_level_medicines_local()


@rpc("authority", "reliable", "call_local")
func _rpc_respawn_level_medicines() -> void:
	_respawn_level_medicines_local()


func _respawn_level_medicines_local() -> void:
	_medicine_respawn_pending = false
	for med in _medicines:
		if med != null and is_instance_valid(med) and med.has_method("reset_for_respawn"):
			med.call("reset_for_respawn")
	print("[LevelBase] Type 0/1 药品已在原位刷新（数量=%d）" % _medicines.size())


func _post_configure_imported_scene() -> void:
	if apply_spawn_patrol_by_name:
		_register_spawn_patrol_groups_by_name(self)
	if generate_mesh_trimesh_collision:
		_generate_trimesh_collisions_from_meshes()
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


func _generate_trimesh_collisions_from_meshes() -> void:
	if not find_children("*", "StaticBody3D", true, false).is_empty():
		return
	var env_layer := auto_static_body_collision_layer if auto_static_body_collision_layer != 0 else 1
	var created := 0
	for mesh_node in find_children("*", "MeshInstance3D", true, false):
		var mi := mesh_node as MeshInstance3D
		if mi.mesh == null or not mi.visible:
			continue
		var mesh_aabb := mi.mesh.get_aabb()
		var mesh_scale := mi.transform.basis.get_scale().abs()
		var scaled_size := Vector3(
			mesh_aabb.size.x * mesh_scale.x,
			mesh_aabb.size.y * mesh_scale.y,
			mesh_aabb.size.z * mesh_scale.z
		)
		if maxf(scaled_size.x, maxf(scaled_size.y, scaled_size.z)) < mesh_collision_min_extent:
			continue
		var shape: Shape3D = null
		if mesh_collision_use_convex:
			shape = mi.mesh.create_convex_shape(true)
		else:
			shape = mi.mesh.create_trimesh_shape()
		if shape == null:
			continue
		var body := StaticBody3D.new()
		body.name = String(mi.name) + "_Phys"
		body.collision_layer = env_layer
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		var parent := mi.get_parent()
		if parent == null:
			body.queue_free()
			continue
		parent.add_child(body)
		body.transform = mi.transform
		created += 1
	if created > 0:
		print("[LevelBase] 自动生成碰撞体 %d 个（%s）" % [
			created,
			"凸包" if mesh_collision_use_convex else "三角网格"
		])


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


## 关卡终点触发器连接此方法 → 整场景切换（level_array 下一项）。
## 测试关→医院 不走这里，见 GameManager.stage_cleared → LevelManager.notify_tutorial_stage_cleared。
func _on_goal_reached() -> void:
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	GameManager.is_game_active = false
	LevelManager.advance()
