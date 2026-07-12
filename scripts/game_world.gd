# 游戏世界脚本 - 管理游戏场景的初始化和游戏流程
# [已修改] 多人模式下生成双方玩家 + 远程代理可视化
# [已修改] 物品使用确定性命名以保证 RPC 路径一致
# [已修改] Ghost 区分 Host/Client 控制
# [已修改] 从关卡 PlayerSpawnPoint 读取出生点，Host 权威 + RPC 同步
# [已修改] 先 room_builder 测试关，集齐钥匙后切 house_f_1 大场景
# [已修改] 局内关卡切换逻辑已收拢至 LevelSystem/GameLevelFlow.gd，由 LevelManager 调度

extends Node3D

## ── 编辑器绑定（选中 GameWorld 根节点后在 Inspector 里拖入）──
@export_group("关卡")
## 美术大场景（通关测试关后进入）
@export var level_scene: PackedScene = preload("res://scenes/house_f_1.tscn")

@export_group("玩家 Prefab")
@export var blind_player_scene: PackedScene = preload("res://scenes/blind_player.tscn")
@export var lame_player_scene: PackedScene = preload("res://scenes/lame_player.tscn")

var _level_flow: GameLevelFlow

var _item_idx: int = 0  # 物品命名计数器
var _ghost_spawn_positions: Dictionary = {}
var _ui_layer: CanvasLayer = null
var _pause_panel: PanelContainer = null
var _fade_rect: ColorRect = null
const SPAWN_PHYSICS_WARMUP_FRAMES: int = 2
const SPAWN_RPC_FALLBACK_SEC: float = 5.0
var _spawn_release_token: int = 0
var _players_spawned: bool = false

# 初始化函数
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not NetworkManager.is_multiplayer_game:
		push_warning("[GameWorld] 已禁用单机模式，请从联机大厅开始游戏")
		call_deferred("_return_to_lobby")
		return
	_setup_game_ui()
	_level_flow = GameLevelFlow.new()
	_level_flow.name = "LevelFlow"
	add_child(_level_flow)
	_level_flow.setup(self, level_scene, false)
	_level_flow.build_initial_room()
	await get_tree().process_frame
	await _init_players_from_spawn_point()
	if _level_flow.is_tutorial():
		GameManager.advance_to_main_on_puzzle_clear = true
		_spawn_items()
		_ensure_checkpoint_trigger()
	else:
		GameManager.advance_to_main_on_puzzle_clear = false
		GameManager.puzzle_clues_enabled = false
	_save_checkpoint_now()
	GameManager.game_over_triggered.connect(_on_game_over)
	_schedule_spawn_release()


func _return_to_lobby() -> void:
	get_tree().change_scene_to_file(NetworkManager.LOBBY_SCENE)


## GameLevelFlow 调用的淡入淡出 / 存档钩子
func level_flow_fade_out(duration: float) -> void:
	await _fade_out(duration)


func level_flow_fade_in(duration: float) -> void:
	await _fade_in(duration)


func level_flow_save_checkpoint() -> void:
	_save_checkpoint_now()


func register_ghost_spawn(ghost: Node3D) -> void:
	_ghost_spawn_positions[ghost.get_path()] = ghost.global_position


## 当前阶段应使用的出生坐标
func _resolve_spawn_position() -> Vector3:
	return _level_flow.resolve_spawn_position()


## 联机：Host 读出生点 → 本地生成 → RPC 通知 Client
func _init_players_from_spawn_point() -> void:
	if _players_spawned:
		return
	var spawn_pos := _resolve_spawn_position()
	if multiplayer.is_server():
		_spawn_players_at(spawn_pos)
		_rpc_spawn_players_at.rpc(spawn_pos)
	else:
		while not _players_spawned:
			await get_tree().process_frame


@rpc("authority", "reliable", "call_remote")
func _rpc_spawn_players_at(spawn_pos: Vector3) -> void:
	# 仅 Client 收到；两端节点名必须一致，后续 RPC 路径才相同
	_spawn_players_at(spawn_pos)


func _spawn_players_at(spawn_pos: Vector3) -> void:
	if _players_spawned:
		return
	_players_spawned = true
	var peer_id := 0
	if multiplayer.multiplayer_peer != null:
		peer_id = multiplayer.get_unique_id()
	print("[GameWorld] 出生点=", spawn_pos, " role=", GameManager.current_role, " peer=", peer_id)

	var blind = blind_player_scene.instantiate()
	var lame = lame_player_scene.instantiate()
	blind.name = "BlindPlayer"
	lame.name = "LamePlayer"
	blind.is_local = (GameManager.current_role == GameManager.ROLE_BLIND)
	lame.is_local = (GameManager.current_role == GameManager.ROLE_LAME)
	blind.set_multiplayer_authority(1)
	add_child(blind)
	add_child(lame)
	blind.global_position = spawn_pos
	lame.global_position = _level_flow.get_lame_spawn_for_phase(spawn_pos)

	if not blind.is_local and not multiplayer.is_server():
		_setup_remote_proxy(blind, Color(0.3, 0.5, 1.0, 0.7))
	elif not blind.is_local and multiplayer.is_server():
		_add_player_marker(blind, Color(0.3, 0.5, 1.0, 0.7))
	if not lame.is_local:
		_setup_remote_proxy(lame, Color(0.2, 0.8, 0.3, 0.7))


func _fade_out(duration: float) -> void:
	if _fade_rect == null:
		await get_tree().create_timer(duration).timeout
		return
	_fade_rect.visible = true
	_fade_rect.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_fade_rect, "modulate:a", 1.0, duration)
	await tw.finished


func _fade_in(duration: float) -> void:
	if _fade_rect == null:
		await get_tree().create_timer(duration).timeout
		return
	var tw := create_tween()
	tw.tween_property(_fade_rect, "modulate:a", 0.0, duration)
	await tw.finished
	_fade_rect.visible = false


func _schedule_spawn_release() -> void:
	_spawn_release_token += 1
	var token := _spawn_release_token
	if multiplayer.is_server():
		_spawn_release_after_warmup(token)
	else:
		_client_spawn_release_watchdog(token)


func _spawn_release_after_warmup(token: int) -> void:
	await _wait_physics_frames(SPAWN_PHYSICS_WARMUP_FRAMES)
	if token != _spawn_release_token or not is_inside_tree():
		return
	if not multiplayer.is_server():
		return
	_rpc_finish_spawning.rpc()


func _wait_physics_frames(count: int) -> void:
	for _i in count:
		await get_tree().physics_frame


func _client_spawn_release_watchdog(token: int) -> void:
	await get_tree().create_timer(SPAWN_RPC_FALLBACK_SEC).timeout
	if token != _spawn_release_token or not is_inside_tree():
		return
	if not _any_player_still_spawning():
		return
	push_warning("[GameWorld] spawn RPC 超时兜底：客户端本地解除 is_spawning")
	_release_players_from_spawn()


func _any_player_still_spawning() -> bool:
	for player_name in ["BlindPlayer", "LamePlayer"]:
		var player := get_node_or_null(player_name)
		if player != null and player.is_spawning:
			return true
	return false


@rpc("authority", "reliable", "call_local")
func _rpc_finish_spawning() -> void:
	_release_players_from_spawn()


func _release_players_from_spawn() -> void:
	for player_name in ["BlindPlayer", "LamePlayer"]:
		var player := get_node_or_null(player_name)
		if player == null:
			continue
		player.is_spawning = false
		if player.has_method("_on_spawning_finished"):
			player._on_spawning_finished()

# 辅助函数：优化远程玩家代理
func _setup_remote_proxy(player: CharacterBody3D, color: Color) -> void:
	# 禁用远程玩家的物理碰撞，只做坐标同步
	player.collision_layer = 0
	player.collision_mask = 0
	# 调用你原本的添加胶囊标记函数
	_add_player_marker(player, color)

# [新增] 为远程玩家添加可视化胶囊标记
func _add_player_marker(player: Node3D, color: Color) -> void:
	var mesh_inst = MeshInstance3D.new()
	var capsule = CapsuleMesh.new()
	capsule.radius = 0.3
	capsule.height = 1.6
	mesh_inst.mesh = capsule
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_inst.material_override = mat
	mesh_inst.position = Vector3(0, 0.8, 0)
	mesh_inst.name = "RemoteMarker"
	player.add_child(mesh_inst)

# [已修改] 生成物品函数 - 使用确定性命名
func _spawn_items() -> void:
	_item_idx = 0
	# 类型0：心理药物
	_make_item(Vector3(-5, 1.2, -5), 0)
	_make_item(Vector3(5, 1.2, -3), 0)
	_make_item(Vector3(-3, 1.2, 6), 0)
	# 类型1：止痛药
	_make_item(Vector3(5, 1.2, 5), 1)
	_make_item(Vector3(-6, 1.2, 0), 1)
	_make_item(Vector3(3, 1.2, -6), 1)
	# 类型2：钥匙碎片
	_make_item(Vector3(0, 1.2, -5), 2)
	_make_item(Vector3(-5, 1.2, 2), 2)
	_make_item(Vector3(6, 1.2, 0), 2)

# [已修改] 创建物品函数 - 确定性命名
func _make_item(pos: Vector3, type_id: int) -> void:
	var scn = load("res://scenes/medicine_item.tscn")
	var item = scn.instantiate()
	item.name = "Item_%d" % _item_idx
	_item_idx += 1
	item.position = pos
	item.medicine_type = type_id
	add_child(item)

# 胜利/失败：联机回大厅
func _on_game_over(won: bool) -> void:
	await get_tree().create_timer(2.0).timeout
	get_tree().change_scene_to_file(NetworkManager.LOBBY_SCENE)

# 输入处理：仅 ESC 暂停菜单
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_request_toggle_pause()

func _request_toggle_pause() -> void:
	if multiplayer.is_server():
		_apply_pause_state.rpc(not GameManager.is_paused)
	else:
		_request_toggle_pause_rpc.rpc_id(1)

@rpc("any_peer", "reliable")
func _request_toggle_pause_rpc() -> void:
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	if NetworkManager.is_multiplayer_game:
		var sender_id := multiplayer.get_remote_sender_id()
		if not NetworkManager.is_trusted_sender(sender_id):
			return
	_apply_pause_state.rpc(not GameManager.is_paused)

@rpc("authority", "reliable", "call_local")
func _apply_pause_state(paused: bool) -> void:
	GameManager.set_paused(paused)
	get_tree().paused = paused
	if paused and VoiceChatManager and VoiceChatManager.has_method("pause_voice"):
		VoiceChatManager.pause_voice("pause_game")
	elif not paused and VoiceChatManager and VoiceChatManager.has_method("resume_voice"):
		VoiceChatManager.resume_voice("unpause_game")
	if paused:
		InputMouseGuard.release_for_ui()
	else:
		InputMouseGuard.capture_for_local_player()
	_update_pause_ui()

func _request_respawn_from_checkpoint() -> void:
	if multiplayer.is_server():
		if GameManager.has_checkpoint():
			_apply_respawn.rpc()
	else:
		_request_respawn_rpc.rpc_id(1)

@rpc("any_peer", "reliable")
func _request_respawn_rpc() -> void:
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	if NetworkManager.is_multiplayer_game:
		var sender_id := multiplayer.get_remote_sender_id()
		if not NetworkManager.is_trusted_sender(sender_id):
			return
	if not GameManager.has_checkpoint():
		return
	_apply_respawn.rpc()

@rpc("authority", "reliable", "call_local")
func _apply_respawn() -> void:
	_start_fade_and_respawn()

func _start_fade_and_respawn() -> void:
	_fade_rect.visible = true
	_fade_rect.modulate.a = 1.0
	_do_respawn_now()
	await get_tree().create_timer(1.0).timeout
	_fade_rect.modulate.a = 0.0
	_fade_rect.visible = false

func _do_respawn_now() -> void:
	if not GameManager.has_checkpoint():
		return
	var blind = get_node_or_null("BlindPlayer")
	var lame = get_node_or_null("LamePlayer")
	if blind:
		blind.global_position = GameManager.checkpoint_data.get("blind_pos", blind.global_position)
	if lame:
		lame.global_position = GameManager.checkpoint_data.get("lame_pos", lame.global_position)
	GameManager.apply_checkpoint_state()
	_reset_ghosts_to_spawn()

func _reset_ghosts_to_spawn() -> void:
	for g in get_tree().get_nodes_in_group("ghost_ai"):
		var ghost := g as Node3D
		var reset_pos: Vector3 = _ghost_spawn_positions.get(ghost.get_path(), ghost.global_position) as Vector3
		if ghost.has_method("reset_to_initial_state"):
			ghost.reset_to_initial_state(reset_pos)
		elif ghost.has_method("reset_ai_state"):
			ghost.reset_ai_state(reset_pos)
		else:
			ghost.global_position = reset_pos

func _save_checkpoint_now() -> void:
	var blind = get_node_or_null("BlindPlayer")
	var lame = get_node_or_null("LamePlayer")
	if blind == null or lame == null:
		return
	GameManager.save_checkpoint(blind.global_position, lame.global_position)

func notify_checkpoint_reached(_checkpoint_node: Node) -> void:
	if multiplayer.is_server():
		_save_checkpoint_now()
	else:
		_request_save_checkpoint_rpc.rpc_id(1)

@rpc("any_peer", "reliable")
func _request_save_checkpoint_rpc() -> void:
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	if NetworkManager.is_multiplayer_game:
		var sender_id := multiplayer.get_remote_sender_id()
		if not NetworkManager.is_trusted_sender(sender_id):
			return
	_save_checkpoint_now()

func _setup_game_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_ui_layer)

	_fade_rect = ColorRect.new()
	_fade_rect.anchors_preset = Control.PRESET_FULL_RECT
	_fade_rect.color = Color(0, 0, 0, 1)
	_fade_rect.visible = false
	_ui_layer.add_child(_fade_rect)

	_pause_panel = PanelContainer.new()
	_pause_panel.visible = false
	_pause_panel.size = Vector2(260, 180)
	_pause_panel.position = Vector2(20, 40)
	_pause_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_ui_layer.add_child(_pause_panel)

	var vb := VBoxContainer.new()
	_pause_panel.add_child(vb)

	var title := Label.new()
	title.text = "暂停"
	vb.add_child(title)

	var btn_resume := Button.new()
	btn_resume.text = "继续游戏"
	btn_resume.pressed.connect(func() -> void: _request_toggle_pause())
	vb.add_child(btn_resume)

	var btn_retry := Button.new()
	btn_retry.text = "从存档点重试"
	btn_retry.pressed.connect(func() -> void:
		_request_respawn_from_checkpoint()
		if GameManager.is_paused:
			_request_toggle_pause()
	)
	vb.add_child(btn_retry)

	var btn_lobby := Button.new()
	btn_lobby.text = "返回大厅"
	btn_lobby.pressed.connect(func() -> void: _request_return_lobby())
	vb.add_child(btn_lobby)

func _update_pause_ui() -> void:
	if _pause_panel:
		_pause_panel.visible = GameManager.is_paused
		if GameManager.is_paused:
			InputMouseGuard.release_for_ui()

func _request_return_lobby() -> void:
	if multiplayer.is_server():
		_apply_return_lobby.rpc()
	else:
		_request_return_lobby_rpc.rpc_id(1)

@rpc("any_peer", "reliable")
func _request_return_lobby_rpc() -> void:
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	if NetworkManager.is_multiplayer_game:
		var sender_id := multiplayer.get_remote_sender_id()
		if not NetworkManager.is_trusted_sender(sender_id):
			return
	_apply_return_lobby.rpc()

@rpc("authority", "reliable", "call_local")
func _apply_return_lobby() -> void:
	GameManager.set_paused(false)
	get_tree().paused = false
	InputMouseGuard.release_for_ui()
	get_tree().change_scene_to_file(NetworkManager.LOBBY_SCENE)

func _ensure_checkpoint_trigger() -> void:
	var existing := get_node_or_null("Checkpoint")
	if existing != null:
		return
	var area := Area3D.new()
	area.name = "Checkpoint"
	# 勿与瞎子出生点 (0,1,0) 重叠，否则一进场景就触发存档
	area.position = Vector3(4, 1.0, 0)
	area.collision_mask = 2
	area.script = load("res://scripts/checkpoint_trigger.gd")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.5, 2.0, 2.5)
	shape.shape = box
	area.add_child(shape)
	add_child(area)
