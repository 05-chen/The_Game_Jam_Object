extends Node
class_name GameLevelFlow

## 局内关卡流程（不整场景切换）：
##   测试关 room_builder → 实例化 house_f_1（Stage1）
##   → 集齐 Clue1/2/3 → 黑屏转场 switch_to_stage(2)（同场景偷梁换柱，不重新实例化 GLB）
##   → 拆 AirWall + 显示 stage2_only 分组 + 生成鬼魂。

enum Phase { TUTORIAL, MAIN }

const SPAWN_POINT_NAME := &"PlayerSpawnPoint"
const STAGE2_SPAWN_POINT_NAME := &"PlayerSpawnPoint_Stage2"
const GROUP_STAGE1_ONLY := &"stage1_only"
const GROUP_STAGE2_ONLY := &"stage2_only"
const STAGE_TRANSITION_FADE_SEC := 0.65
const MAIN_LEVEL_SCENE_PATH := "res://scenes/house_f_1.tscn"
const TUTORIAL_BLIND_SPAWN := Vector3(0, 1, 0)
const TUTORIAL_LAME_SPAWN := Vector3(2, 1, 0)
const DEFAULT_SPAWN := Vector3(0, 1, 0)
const AIR_WALL_NODE_NAME := &"AirWall"
const GHOST_SPAWN_POINT_STAGE2 := &"GhostSpawnPoint_Stage2"
const GHOST_STAGE2_NAME := &"GhostStage2"
const GHOST_SCENE: PackedScene = preload("res://scenes/ghost.tscn")
const STAGE1_CLUE_NAMES: Array[StringName] = [&"Clue1", &"Clue2", &"Clue3"]
## Stage2 通关线索（与 house_f_1.tscn 中 hospital_stage=STAGE_2 的线索节点名一致）
const STAGE2_CLUE_NAMES: Array[StringName] = [
	&"Clue4", &"Clue5", &"Clue6", &"Clue7", &"Clue8", &"Clue9",
]

var phase: Phase = Phase.TUTORIAL
var level_scene: PackedScene

var _world: Node3D
var _level_scene_path: String = ""
var _level_preload_started: bool = false
var _room_node: Node3D = null
var _level_node: Node3D = null
var _entering_main_level: bool = false
var _air_wall_removed: bool = false
var _stage2_ghost_spawned: bool = false
var _current_hospital_stage: int = 1
var _stage_transition_in_progress: bool = false
var _stage1_clues_collected: Dictionary = {}
var _stage2_clues_collected: Dictionary = {}


func setup(world: Node3D, main_level_path: String = MAIN_LEVEL_SCENE_PATH) -> void:
	_world = world
	_level_scene_path = main_level_path if main_level_path != "" else MAIN_LEVEL_SCENE_PATH
	add_to_group("game_level_flow")
	LevelManager.register_in_scene_flow(self)
	_begin_background_level_preload()


func build_initial_room() -> void:
	phase = Phase.TUTORIAL
	var room := Node3D.new()
	room.name = "TutorialRoom"
	room.set_script(load("res://scripts/room_builder.gd"))
	_world.add_child(room)
	_room_node = room


func is_tutorial() -> bool:
	return phase == Phase.TUTORIAL


func is_hospital_stage1_active() -> bool:
	return phase == Phase.MAIN and _current_hospital_stage == 1


func get_current_hospital_stage() -> int:
	return _current_hospital_stage


func get_level_node() -> Node3D:
	return _level_node


func resolve_spawn_position() -> Vector3:
	if phase == Phase.TUTORIAL:
		return TUTORIAL_BLIND_SPAWN
	var search_root: Node = _level_node if _level_node != null and is_instance_valid(_level_node) else _world
	var marker := search_root.find_child(SPAWN_POINT_NAME, true, false) as Node3D
	if marker:
		return marker.global_position
	push_warning("[GameLevelFlow] 大场景未找到 %s，使用默认坐标" % SPAWN_POINT_NAME)
	return DEFAULT_SPAWN


func get_lame_spawn_for_phase(main_spawn: Vector3) -> Vector3:
	if phase == Phase.TUTORIAL:
		return TUTORIAL_LAME_SPAWN
	return main_spawn


## LevelManager → Host 调用
func request_enter_main_level() -> void:
	if phase != Phase.TUTORIAL or _entering_main_level:
		return
	if not multiplayer.is_server():
		return
	_rpc_enter_main_level.rpc()


@rpc("authority", "reliable", "call_local")
func _rpc_enter_main_level() -> void:
	if phase != Phase.TUTORIAL or _entering_main_level:
		return
	_entering_main_level = true
	_enter_main_level()


func _enter_main_level() -> void:
	await _world.level_flow_fade_out(0.4)
	_clear_tutorial_content()
	phase = Phase.MAIN
	# 测试关进度不带入医院：精神/疼痛/药计数/线索字典全部清零
	GameManager.reset_for_entering_main_level()
	GameManager.advance_to_main_on_puzzle_clear = false
	GameManager.puzzle_clues_enabled = false
	_reset_stage1_clue_progress()
	_air_wall_removed = false
	_stage2_ghost_spawned = false
	_stage_transition_in_progress = false
	_show_stage_msg("正在加载医院场景，请稍候...")
	await _load_main_level_scene()
	await _world.get_tree().process_frame
	var spawn_pos := resolve_spawn_position()
	_reposition_players(spawn_pos)
	_sync_player_displays_after_reset()
	if _world.has_method("level_flow_save_checkpoint"):
		_world.level_flow_save_checkpoint()
	await _world.level_flow_fade_in(0.4)
	_entering_main_level = false
	_refresh_role_lighting_after_level_load()
	_show_stage_msg("进入医院：状态与拾取进度已重置")


func _sync_player_displays_after_reset() -> void:
	if _world == null or not is_instance_valid(_world):
		return
	for player_name in ["BlindPlayer", "LamePlayer"]:
		var player := _world.get_node_or_null(player_name)
		if player != null and is_instance_valid(player) and player.has_method("sync_vitals_display_from_manager"):
			player.call("sync_vitals_display_from_manager")


func _refresh_role_lighting_after_level_load() -> void:
	if _world == null or not is_instance_valid(_world):
		return
	# 本机若是瞎子：关场景灯；若是瘸子：开灯 + 相机环境光
	var blind := _world.get_node_or_null("BlindPlayer")
	if blind != null and is_instance_valid(blind) and blind.has_method("refresh_blind_scene_lights"):
		blind.call("refresh_blind_scene_lights")
	var lame := _world.get_node_or_null("LamePlayer")
	if lame != null and is_instance_valid(lame) and lame.has_method("ensure_scene_lights_for_lame_view"):
		lame.call("ensure_scene_lights_for_lame_view")
		if lame.has_method("_setup_lame_view_lighting"):
			lame.call("_setup_lame_view_lighting")


func _refresh_blind_lights_after_level_load() -> void:
	_refresh_role_lighting_after_level_load()

func _begin_background_level_preload() -> void:
	if _level_scene_path == "" or _level_preload_started:
		return
	_level_preload_started = true
	if ResourceLoader.has_cached(_level_scene_path):
		level_scene = ResourceLoader.load(_level_scene_path) as PackedScene
		return
	var err := ResourceLoader.load_threaded_request(_level_scene_path)
	if err != OK:
		push_warning("[GameLevelFlow] 后台预加载失败 path=%s err=%s" % [_level_scene_path, str(err)])


func _await_level_scene_packed() -> PackedScene:
	if level_scene != null:
		return level_scene
	if _level_scene_path == "":
		push_error("[GameLevelFlow] 未配置医院场景路径")
		return null
	if not _level_preload_started:
		_begin_background_level_preload()
	while true:
		var status := ResourceLoader.load_threaded_get_status(_level_scene_path)
		match status:
			ResourceLoader.THREAD_LOAD_LOADED:
				level_scene = ResourceLoader.load_threaded_get(_level_scene_path) as PackedScene
				return level_scene
			ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				push_error("[GameLevelFlow] 线程加载医院场景失败，尝试同步加载")
				level_scene = load(_level_scene_path) as PackedScene
				return level_scene
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				await _world.get_tree().process_frame
			_:
				level_scene = load(_level_scene_path) as PackedScene
				return level_scene
	return null


func _load_main_level_scene() -> void:
	if _level_node != null and is_instance_valid(_level_node):
		return
	var packed := await _await_level_scene_packed()
	if packed == null:
		push_error("[GameLevelFlow] level_scene 未绑定")
		return
	var level := packed.instantiate()
	level.name = "Level"
	_world.add_child(level)
	_level_node = level
	call_deferred("_on_hospital_level_ready")


func _on_hospital_level_ready() -> void:
	if _level_node == null or not is_instance_valid(_level_node):
		return
	_ensure_builtin_stage_groups()
	switch_to_stage(1)


func _ensure_builtin_stage_groups() -> void:
	var ghost_spawn := _level_node.find_child(GHOST_SPAWN_POINT_STAGE2, true, false)
	if ghost_spawn != null and not ghost_spawn.is_in_group(GROUP_STAGE2_ONLY):
		ghost_spawn.add_to_group(GROUP_STAGE2_ONLY)


## 集中切换医院 Stage1 / Stage2 分组显隐与交互（不重新实例化大场景）
func switch_to_stage(stage_num: int) -> void:
	var stage := clampi(stage_num, 1, 2)
	_current_hospital_stage = stage
	GameManager.is_stage_2 = (stage == 2)
	match stage:
		1:
			_set_group_interaction(GROUP_STAGE1_ONLY, true)
			_set_group_interaction(GROUP_STAGE2_ONLY, false)
		2:
			_set_group_interaction(GROUP_STAGE1_ONLY, false)
			_set_group_interaction(GROUP_STAGE2_ONLY, true)
	_refresh_level_medicine_respawn_pool()
	print("[GameLevelFlow] 已切换至医院 Stage%d" % stage)


func _set_group_interaction(group_name: StringName, active: bool) -> void:
	var tree := get_tree()
	if tree == null:
		return
	for node in tree.get_nodes_in_group(group_name):
		if node == null or not is_instance_valid(node):
			continue
		# 药品/线索已自带完整绝育，勿再套 set_node_physics_active（会把 layer 存成 0）
		if node.has_method("set_stage_interaction_active"):
			node.call("set_stage_interaction_active", active)
			continue
		if node is Node3D:
			(node as Node3D).visible = active
			set_node_physics_active(node as Node3D, active)
		elif node is CanvasItem:
			(node as CanvasItem).visible = active
			node.set_process(active)
			node.set_physics_process(active)


## 动态物理绝育：未激活节点从物理世界「消失」，避免上百个 Stage2 物体持续碰撞计算
func set_node_physics_active(node: Node3D, active: bool) -> void:
	if node == null or not is_instance_valid(node):
		return
	node.set_process(active)
	node.set_physics_process(active)
	_sterilize_physics_recursive(node, active)


## 非药品节点后备路径（兼容旧调用）
func _set_generic_node_interaction(node: Node, active: bool) -> void:
	if node is CanvasItem:
		(node as CanvasItem).visible = active
	if node is Node3D:
		(node as Node3D).visible = active
		set_node_physics_active(node as Node3D, active)
		return
	node.set_process(active)
	node.set_physics_process(active)
	_sterilize_physics_recursive(node, active)


func _sterilize_physics_recursive(node: Node, active: bool) -> void:
	if not is_instance_valid(node):
		return
	if node is CollisionShape3D:
		(node as CollisionShape3D).set_deferred("disabled", not active)
	if node is Area3D:
		var area := node as Area3D
		area.monitoring = active
		area.monitorable = active
		_set_collision_object_layers(area, active)
	elif node is CollisionObject3D:
		_set_collision_object_layers(node as CollisionObject3D, active)
	for child in node.get_children():
		_sterilize_physics_recursive(child, active)


func _set_collision_object_layers(body: CollisionObject3D, active: bool) -> void:
	if not active:
		if not body.has_meta("_stage_saved_layer"):
			body.set_meta("_stage_saved_layer", body.collision_layer)
			body.set_meta("_stage_saved_mask", body.collision_mask)
		body.collision_layer = 0
		body.collision_mask = 0
	else:
		body.collision_layer = int(body.get_meta("_stage_saved_layer", body.collision_layer if body.collision_layer != 0 else 1))
		body.collision_mask = int(body.get_meta("_stage_saved_mask", 0))


func _apply_collision_shapes_recursive(node: Node, active: bool) -> void:
	_sterilize_physics_recursive(node, active)


func _refresh_level_medicine_respawn_pool() -> void:
	if _level_node == null or not is_instance_valid(_level_node):
		return
	if _level_node.has_method("refresh_medicine_respawn_pool"):
		_level_node.call("refresh_medicine_respawn_pool")


func _reset_stage1_clue_progress() -> void:
	_stage1_clues_collected.clear()
	_stage2_clues_collected.clear()
	GameManager.collected_clues.clear()
	GameManager.is_stage_2 = false


## 拾取 Stage1 线索（medicine_type=2 且 hospital_stage=STAGE_1）时调用
func notify_stage1_clue_collected(clue_name: String) -> void:
	if phase != Phase.MAIN or _current_hospital_stage != 1:
		return
	if not STAGE1_CLUE_NAMES.has(StringName(clue_name)):
		push_warning("[GameLevelFlow] 未知 Stage1 线索: %s" % clue_name)
		return
	if _stage1_clues_collected.has(clue_name):
		return
	_stage1_clues_collected[clue_name] = true
	GameManager.register_clue_collected(clue_name)
	var total: int = _stage1_clues_collected.size()
	_show_stage_msg("获得线索 %s（%d/%d）" % [clue_name, total, STAGE1_CLUE_NAMES.size()])
	print("[GameLevelFlow] Stage1 线索已收集: %s (%d/%d)" % [clue_name, total, STAGE1_CLUE_NAMES.size()])
	if total < STAGE1_CLUE_NAMES.size():
		return
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	request_unlock_stage2()


## 拾取 Stage2 线索（medicine_type=2 且 hospital_stage=STAGE_2）时调用
func notify_stage2_clue_collected(clue_name: String) -> void:
	if phase != Phase.MAIN or _current_hospital_stage != 2:
		return
	if STAGE2_CLUE_NAMES.is_empty():
		push_warning("[GameLevelFlow] 收到 Stage2 线索 %s，但 STAGE2_CLUE_NAMES 尚未配置" % clue_name)
		_show_stage_msg("获得线索 %s" % clue_name)
		return
	if not STAGE2_CLUE_NAMES.has(StringName(clue_name)):
		push_warning("[GameLevelFlow] 未知 Stage2 线索: %s" % clue_name)
		return
	if _stage2_clues_collected.has(clue_name):
		return
	_stage2_clues_collected[clue_name] = true
	GameManager.register_clue_collected(clue_name)
	var total: int = _stage2_clues_collected.size()
	_show_stage_msg("获得线索 %s（%d/%d）" % [clue_name, total, STAGE2_CLUE_NAMES.size()])
	print("[GameLevelFlow] Stage2 线索已收集: %s (%d/%d)" % [clue_name, total, STAGE2_CLUE_NAMES.size()])
	if total < STAGE2_CLUE_NAMES.size():
		return
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	request_stage2_victory()


## Stage2 线索全部集齐：Host 裁决胜利（广播 + 黑屏/胜利窗口）
func request_stage2_victory() -> void:
	if phase != Phase.MAIN or _current_hospital_stage != 2:
		return
	if GameManager.is_game_over:
		return
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	_show_stage_msg("全部线索已收集，成功逃离医院！")
	print("[GameLevelFlow] Stage2 通关 → 触发胜利")
	GameManager.trigger_game_over(true)


## Stage1 通关后由玩法脚本调用，无快捷键、无自动触发。
func request_unlock_stage2() -> void:
	if phase != Phase.MAIN:
		return
	if _current_hospital_stage >= 2:
		return
	if _stage_transition_in_progress:
		return
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	_rpc_unlock_stage2.rpc()


@rpc("authority", "reliable", "call_local")
func _rpc_unlock_stage2() -> void:
	if phase != Phase.MAIN:
		return
	if _current_hospital_stage >= 2 or _stage_transition_in_progress:
		return
	_perform_stage2_transition()


func _perform_stage2_transition() -> void:
	_stage_transition_in_progress = true
	await _world.level_flow_fade_out(STAGE_TRANSITION_FADE_SEC)
	_remove_air_wall_local()
	switch_to_stage(2)
	_spawn_stage2_ghost_local()
	var spawn_pos := resolve_stage2_spawn_position()
	_reposition_players(spawn_pos)
	if _world.has_method("level_flow_save_checkpoint"):
		_world.level_flow_save_checkpoint()
	await _world.level_flow_fade_in(STAGE_TRANSITION_FADE_SEC)
	_stage_transition_in_progress = false
	_show_stage_msg("第一阶段完成，危险区域已开放...")


func resolve_stage2_spawn_position() -> Vector3:
	var search_root: Node = _level_node if _level_node != null and is_instance_valid(_level_node) else _world
	var marker := search_root.find_child(STAGE2_SPAWN_POINT_NAME, true, false) as Node3D
	if marker:
		return marker.global_position
	marker = search_root.find_child(GHOST_SPAWN_POINT_STAGE2, true, false) as Node3D
	if marker:
		return marker.global_position
	push_warning("[GameLevelFlow] 未找到 Stage2 出生点，保持玩家原位")
	return resolve_spawn_position()


func _find_stage2_ghost() -> CharacterBody3D:
	var search_root: Node = _level_node if _level_node != null and is_instance_valid(_level_node) else _world
	if search_root == null:
		return null
	return search_root.find_child(GHOST_STAGE2_NAME, true, false) as CharacterBody3D


func broadcast_stage2_ghost_progress(ratio: float) -> void:
	if not multiplayer.is_server() or GameManager.is_game_over:
		return
	if not GameManager.are_session_players_valid():
		return
	_relay_stage2_ghost_progress.rpc(ratio)


func broadcast_stage2_ghost_position(pos: Vector3) -> void:
	if not multiplayer.is_server() or GameManager.is_game_over:
		return
	if not GameManager.are_session_players_valid():
		return
	_relay_stage2_ghost_position.rpc(pos)


func broadcast_stage2_ghost_state(new_state: int, patrol_ratio: float, world_pos: Vector3) -> void:
	if not multiplayer.is_server() or GameManager.is_game_over:
		return
	if not GameManager.are_session_players_valid():
		return
	_relay_stage2_ghost_state.rpc(new_state, patrol_ratio, world_pos)


@rpc("authority", "unreliable", "call_remote")
func _relay_stage2_ghost_progress(ratio: float) -> void:
	if GameManager.is_game_over:
		return
	var ghost := _find_stage2_ghost()
	if ghost != null and is_instance_valid(ghost) and ghost.has_method("apply_progress_sync"):
		ghost.apply_progress_sync(ratio)


@rpc("authority", "unreliable", "call_remote")
func _relay_stage2_ghost_position(pos: Vector3) -> void:
	if GameManager.is_game_over:
		return
	var ghost := _find_stage2_ghost()
	if ghost != null and is_instance_valid(ghost) and ghost.has_method("apply_position_sync"):
		ghost.apply_position_sync(pos)


@rpc("authority", "reliable", "call_remote")
func _relay_stage2_ghost_state(new_state: int, patrol_ratio: float, world_pos: Vector3) -> void:
	if GameManager.is_game_over:
		return
	var ghost := _find_stage2_ghost()
	if ghost != null and is_instance_valid(ghost) and ghost.has_method("apply_state_sync"):
		ghost.apply_state_sync(new_state, patrol_ratio, world_pos)


@rpc("authority", "reliable", "call_local")
func _rpc_remove_air_wall() -> void:
	_remove_air_wall_local()


func _remove_air_wall_local() -> void:
	if _air_wall_removed:
		return
	var wall := _world.find_child(AIR_WALL_NODE_NAME, true, false)
	if wall == null:
		push_warning("[GameLevelFlow] 未找到 %s，请在大场景中手动创建该 StaticBody3D" % AIR_WALL_NODE_NAME)
		return
	_air_wall_removed = true
	wall.queue_free()


## 全网手动生成：Host / Client 各自在本地 PathFollow3D 下实例化同名鬼魂
@rpc("authority", "reliable", "call_local")
func _rpc_spawn_stage2_ghost() -> void:
	_spawn_stage2_ghost_local()


func _spawn_stage2_ghost_local() -> void:
	if _stage2_ghost_spawned:
		return
	if _world == null or not is_instance_valid(_world):
		return
	var search_root: Node = _level_node if _level_node != null and is_instance_valid(_level_node) else _world
	if search_root == null or not is_instance_valid(search_root):
		return
	if search_root.find_child(GHOST_STAGE2_NAME, true, false) != null:
		_stage2_ghost_spawned = true
		return
	var spawn_point := search_root.find_child(GHOST_SPAWN_POINT_STAGE2, true, false)
	if spawn_point == null:
		push_warning("[GameLevelFlow] 未找到 %s，无法生成第二关鬼魂" % GHOST_SPAWN_POINT_STAGE2)
		return
	var path_follow := spawn_point.find_child("PathFollow3D", true, false) as PathFollow3D
	if path_follow == null:
		push_warning("[GameLevelFlow] %s 下未找到 PathFollow3D" % GHOST_SPAWN_POINT_STAGE2)
		return
	# 先复位轨道到远端起点，再生成鬼魂，杜绝「开局贴脸」
	path_follow.progress_ratio = 0.0
	var ghost: CharacterBody3D = GHOST_SCENE.instantiate() as CharacterBody3D
	if ghost == null:
		push_error("[GameLevelFlow] GHOST_SCENE 实例化失败")
		return
	ghost.name = GHOST_STAGE2_NAME
	path_follow.add_child(ghost)
	ghost.position = Vector3.ZERO
	if ghost.has_method("bind_path_follow"):
		ghost.bind_path_follow(path_follow)
	if multiplayer.is_server():
		ghost.is_host_controlled = true
		ghost.set_multiplayer_authority(1)
	# 黑屏期间：强制对齐巡逻起点后再打开 AI
	if ghost.has_method("activate_stage2_ai"):
		ghost.call("activate_stage2_ai")
	_register_ghost_for_checkpoint(ghost)
	_stage2_ghost_spawned = true
	print("[GameLevelFlow] Stage2 鬼魂已生成 @ PathFollow3D (server=%s)" % str(multiplayer.is_server()))


func _register_ghost_for_checkpoint(ghost: Node3D) -> void:
	if not _world.has_method("register_ghost_spawn"):
		return
	_world.call("register_ghost_spawn", ghost)


func _clear_tutorial_content() -> void:
	if _room_node != null and is_instance_valid(_room_node):
		_room_node.queue_free()
		_room_node = null
	var checkpoint := _world.get_node_or_null("Checkpoint")
	if checkpoint:
		checkpoint.queue_free()
	for child in _world.get_children():
		if String(child.name).begins_with("Item_"):
			child.queue_free()


func _reposition_players(spawn_pos: Vector3) -> void:
	if _world == null or not is_instance_valid(_world):
		return
	var blind := _world.get_node_or_null("BlindPlayer") as Node3D
	var lame := _world.get_node_or_null("LamePlayer") as Node3D
	if is_instance_valid(blind):
		blind.global_position = spawn_pos
		if blind is CharacterBody3D:
			(blind as CharacterBody3D).velocity = Vector3.ZERO
	if is_instance_valid(lame):
		# 优先贴到 CarryAnchor，避免与瞎子叠在同一点穿模
		var anchor := blind.get_node_or_null("CarryAnchor") as Node3D if is_instance_valid(blind) else null
		if anchor != null:
			lame.global_position = anchor.global_position
		else:
			lame.global_position = get_lame_spawn_for_phase(spawn_pos)
		if lame is CharacterBody3D:
			(lame as CharacterBody3D).velocity = Vector3.ZERO


func _show_stage_msg(text: String) -> void:
	if _world == null or not is_instance_valid(_world):
		return
	for player_name in ["BlindPlayer", "LamePlayer"]:
		var player := _world.get_node_or_null(player_name)
		if player != null and is_instance_valid(player) and player.has_method("_show_msg"):
			player.call("_show_msg", text)
