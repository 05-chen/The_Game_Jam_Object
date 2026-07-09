extends Node
class_name GameLevelFlow

## 局内关卡流程（不整场景切换）：测试关 room_builder → 实例化 house_f_1 → 拆 AirWall 等。
## 由 [LevelManager] 在 GameManager.stage_cleared 时触发；RPC 挂在本节点（GameWorld 子节点）上。

enum Phase { TUTORIAL, MAIN }

const SPAWN_POINT_NAME := &"PlayerSpawnPoint"
const TUTORIAL_BLIND_SPAWN := Vector3(0, 1, 0)
const TUTORIAL_LAME_SPAWN := Vector3(2, 1, 0)
const DEFAULT_SPAWN := Vector3(0, 1, 0)
const AIR_WALL_NODE_NAME := &"AirWall"

var phase: Phase = Phase.TUTORIAL
var level_scene: PackedScene
var skip_tutorial: bool = false

var _world: Node3D
var _room_node: Node3D = null
var _level_node: Node3D = null
var _entering_main_level: bool = false
var _air_wall_removed: bool = false


func setup(world: Node3D, main_level_scene: PackedScene, skip: bool) -> void:
	_world = world
	level_scene = main_level_scene
	skip_tutorial = skip
	LevelManager.register_in_scene_flow(self)


func build_initial_room() -> void:
	if skip_tutorial and level_scene:
		phase = Phase.MAIN
		_load_main_level_scene()
		return
	phase = Phase.TUTORIAL
	var room := Node3D.new()
	room.name = "TutorialRoom"
	room.set_script(load("res://scripts/room_builder.gd"))
	_world.add_child(room)
	_room_node = room


func is_tutorial() -> bool:
	return phase == Phase.TUTORIAL


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
	GameManager.advance_to_main_on_puzzle_clear = false
	GameManager.puzzles_solved = 0
	_load_main_level_scene()
	await _world.get_tree().process_frame
	_unlock_stage_by_removing_air_wall()
	var spawn_pos := resolve_spawn_position()
	_reposition_players(spawn_pos)
	if _world.has_method("level_flow_save_checkpoint"):
		_world.level_flow_save_checkpoint()
	await _world.level_flow_fade_in(0.4)
	_entering_main_level = false
	_show_stage_msg("测试关完成，进入医院...")


func _load_main_level_scene() -> void:
	if _level_node != null and is_instance_valid(_level_node):
		return
	if level_scene == null:
		push_error("[GameLevelFlow] level_scene 未绑定")
		return
	var level := level_scene.instantiate()
	level.name = "Level"
	_world.add_child(level)
	_level_node = level


func _unlock_stage_by_removing_air_wall() -> void:
	if _air_wall_removed:
		return
	if not multiplayer.is_server():
		return
	_rpc_remove_air_wall.rpc()


@rpc("any_peer", "call_local")
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
	var blind := _world.get_node_or_null("BlindPlayer") as Node3D
	var lame := _world.get_node_or_null("LamePlayer") as Node3D
	if blind:
		blind.global_position = spawn_pos
		if blind is CharacterBody3D:
			(blind as CharacterBody3D).velocity = Vector3.ZERO
	if lame:
		lame.global_position = spawn_pos
		if lame is CharacterBody3D:
			(lame as CharacterBody3D).velocity = Vector3.ZERO


func _show_stage_msg(text: String) -> void:
	for player_name in ["BlindPlayer", "LamePlayer"]:
		var player := _world.get_node_or_null(player_name)
		if player != null and player.has_method("_show_msg"):
			player.call("_show_msg", text)
