# 游戏世界脚本 - 管理游戏场景的初始化和游戏流程
# [已修改] 多人模式下生成双方玩家 + 远程代理可视化
# [已修改] 物品使用确定性命名以保证 RPC 路径一致
# [已修改] Ghost 区分 Host/Client 控制

extends Node3D

var _item_idx: int = 0  # 物品命名计数器
var _ghost_spawn_positions: Dictionary = {}
var _ui_layer: CanvasLayer = null
var _pause_panel: PanelContainer = null
var _dev_label: Label = null
var _fade_rect: ColorRect = null
const SPAWN_PHYSICS_WARMUP_FRAMES: int = 2
const SPAWN_RPC_FALLBACK_SEC: float = 5.0
var _spawn_release_token: int = 0

# 初始化函数
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_room()
	_spawn_players()
	_spawn_items()
	#_spawn_ghost()
	_setup_demo_ui()
	_ensure_checkpoint_trigger()
	_save_checkpoint_now()
	GameManager.game_over_triggered.connect(_on_game_over)
	GameManager.dev_invincible_changed.connect(_on_dev_invincible_changed)
	_schedule_spawn_release()

# 构建房间函数 - 不变
func _build_room() -> void:
	var scr = load("res://scripts/room_builder.gd")
	var room = Node3D.new()
	room.set_script(scr)
	add_child(room)

func _spawn_players() -> void:
	var is_mp = NetworkManager.is_multiplayer_game
	var peer_id := 0
	if multiplayer.multiplayer_peer != null:
		peer_id = multiplayer.get_unique_id()
	print("[GameWorld] 开始生成角色，模式：", "多人" if is_mp else "单人", " current_role=", GameManager.current_role, " peer_id=", peer_id)

	if not is_mp:
		var path = "res://scenes/blind_player.tscn" if GameManager.current_role == GameManager.ROLE_BLIND else "res://scenes/lame_player.tscn"
		var player = load(path).instantiate()
		player.is_local = true
		player.position = Vector3(0, 1, 0) if GameManager.current_role == GameManager.ROLE_BLIND else Vector3(2, 1, 0)
		add_child(player)
	else:
		# ── 多人模式：核心修复 ──
		var blind = load("res://scenes/blind_player.tscn").instantiate()
		var lame = load("res://scenes/lame_player.tscn").instantiate()

		# 【关键修复 1】强制唯一且一致的命名
		# 即使是本地玩家，也要确保两端的节点路径都是 /root/GameWorld/BlindPlayer
		blind.name = "BlindPlayer"
		lame.name = "LamePlayer"

		# 【关键修复 2】在 add_child 之前设置 is_local
		# 这样当节点进入场景树触发 _ready 时，它已经知道自己是本地还是远程了
		blind.is_local = (GameManager.current_role == GameManager.ROLE_BLIND)
		lame.is_local = (GameManager.current_role == GameManager.ROLE_LAME)
		print("[GameWorld] player role map: blind.is_local=", blind.is_local, " lame.is_local=", lame.is_local)
		blind.set_multiplayer_authority(1)
		add_child(blind)
		add_child(lame)
		blind.position = Vector3(0, 1, 0)
		lame.position = Vector3(2, 1, 0)

		# 【关键修复 3】远程实体：仅客户端上的远程代理关碰撞；主机代算瞎子必须保留碰撞
		if not blind.is_local and not multiplayer.is_server():
			_setup_remote_proxy(blind, Color(0.3, 0.5, 1.0, 0.7))
		elif not blind.is_local and multiplayer.is_server():
			_add_player_marker(blind, Color(0.3, 0.5, 1.0, 0.7))
		if not lame.is_local:
			_setup_remote_proxy(lame, Color(0.2, 0.8, 0.3, 0.7))


func _schedule_spawn_release() -> void:
	_spawn_release_token += 1
	var token := _spawn_release_token
	if not NetworkManager.is_multiplayer_game:
		_spawn_release_after_warmup(token)
		return
	if multiplayer.is_server():
		_spawn_release_after_warmup(token)
	else:
		_client_spawn_release_watchdog(token)


func _spawn_release_after_warmup(token: int) -> void:
	await _wait_physics_frames(SPAWN_PHYSICS_WARMUP_FRAMES)
	if token != _spawn_release_token or not is_inside_tree():
		return
	if not NetworkManager.is_multiplayer_game:
		_release_players_from_spawn()
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

# [已修改] 生成幽灵函数 - 区分 Host/Client
func _spawn_ghost() -> void:
	var scn = load("res://scenes/ghost.tscn")
	var g = scn.instantiate()
	g.name = "Ghost"
	g.position = Vector3(5, 1, -5)
	# 多人模式下，Ghost AI 仅在 Host 端运行
	if NetworkManager.is_multiplayer_game:
		g.is_host_controlled = multiplayer.is_server()
		g.set_multiplayer_authority(1)
	add_child(g)
	_ghost_spawn_positions[g.get_path()] = g.global_position

# 胜利：单机回主菜单；联机回联机大厅（不断开房间）。失败：单机检查点复活；联机同样回大厅
func _on_game_over(won: bool) -> void:
	if won:
		await get_tree().create_timer(2.0).timeout
		if NetworkManager.is_multiplayer_game:
			get_tree().change_scene_to_file("res://scenes/lobby.tscn")
		else:
			get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
		return
	if NetworkManager.is_multiplayer_game:
		await get_tree().create_timer(2.0).timeout
		get_tree().change_scene_to_file("res://scenes/lobby.tscn")
		return
	_request_respawn_from_checkpoint()

# 输入处理函数 - 暂停 + 开发者快捷键
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_request_toggle_pause()
		elif event.keycode == KEY_G:
			_request_toggle_invincible()
		elif event.keycode == KEY_K:
			_request_clear_ghosts()
		elif event.keycode == KEY_P:
			_request_reset_status()

func _request_toggle_invincible() -> void:
	if NetworkManager.is_multiplayer_game:
		_request_toggle_invincible_rpc.rpc_id(1)
	else:
		_apply_invincible.rpc(not GameManager.dev_invincible)

@rpc("any_peer", "reliable")
func _request_toggle_invincible_rpc() -> void:
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	if NetworkManager.is_multiplayer_game:
		var sender_id := multiplayer.get_remote_sender_id()
		if not NetworkManager.is_trusted_sender(sender_id):
			return
	_apply_invincible.rpc(not GameManager.dev_invincible)

@rpc("authority", "reliable", "call_local")
func _apply_invincible(enabled: bool) -> void:
	GameManager.set_dev_invincible(enabled)

func _request_clear_ghosts() -> void:
	if NetworkManager.is_multiplayer_game:
		_request_clear_ghosts_rpc.rpc_id(1)
	else:
		_apply_clear_ghosts.rpc()

@rpc("any_peer", "reliable")
func _request_clear_ghosts_rpc() -> void:
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	if NetworkManager.is_multiplayer_game:
		var sender_id := multiplayer.get_remote_sender_id()
		if not NetworkManager.is_trusted_sender(sender_id):
			return
	_apply_clear_ghosts.rpc()

@rpc("authority", "reliable", "call_local")
func _apply_clear_ghosts() -> void:
	for g in get_tree().get_nodes_in_group("ghost_ai"):
		if g is Node3D:
			var ghost := g as Node3D
			ghost.global_position = Vector3(0, -100, 0)

func _request_reset_status() -> void:
	if NetworkManager.is_multiplayer_game:
		_request_reset_status_rpc.rpc_id(1)
	else:
		_apply_reset_status.rpc()

@rpc("any_peer", "reliable")
func _request_reset_status_rpc() -> void:
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	if NetworkManager.is_multiplayer_game:
		var sender_id := multiplayer.get_remote_sender_id()
		if not NetworkManager.is_trusted_sender(sender_id):
			return
	_apply_reset_status.rpc()

@rpc("authority", "reliable", "call_local")
func _apply_reset_status() -> void:
	GameManager.mental_health = GameManager.mental_health_max
	GameManager.pain_value = 0.0
	GameManager.target_mental_health = GameManager.mental_health_max
	GameManager.target_pain_value = 0.0
	GameManager.is_game_over = false
	GameManager.is_game_won = false
	GameManager.mental_health_changed.emit(GameManager.mental_health)
	GameManager.pain_value_changed.emit(GameManager.pain_value)

func _request_toggle_pause() -> void:
	if NetworkManager.is_multiplayer_game:
		_request_toggle_pause_rpc.rpc_id(1)
	else:
		_apply_pause_state.rpc(not GameManager.dev_paused)

@rpc("any_peer", "reliable")
func _request_toggle_pause_rpc() -> void:
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	if NetworkManager.is_multiplayer_game:
		var sender_id := multiplayer.get_remote_sender_id()
		if not NetworkManager.is_trusted_sender(sender_id):
			return
	_apply_pause_state.rpc(not GameManager.dev_paused)

@rpc("authority", "reliable", "call_local")
func _apply_pause_state(paused: bool) -> void:
	GameManager.set_dev_pause(paused)
	get_tree().paused = paused
	if paused and VoiceChatManager and VoiceChatManager.has_method("shutdown_voice"):
		VoiceChatManager.shutdown_voice("pause_game")
	if paused:
		InputMouseGuard.release_for_ui()
	else:
		InputMouseGuard.capture_for_local_player()
	_update_pause_ui()

func _request_respawn_from_checkpoint() -> void:
	if NetworkManager.is_multiplayer_game:
		# Host 端不能对自己发 rpc_id(1)，直接走本地 Authority 流程
		if multiplayer.is_server():
			if GameManager.has_checkpoint():
				_apply_respawn.rpc()
		else:
			_request_respawn_rpc.rpc_id(1)
	else:
		_apply_respawn.rpc()

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
	if NetworkManager.is_multiplayer_game:
		_request_save_checkpoint_rpc.rpc_id(1)
	else:
		_save_checkpoint_now()

@rpc("any_peer", "reliable")
func _request_save_checkpoint_rpc() -> void:
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	if NetworkManager.is_multiplayer_game:
		var sender_id := multiplayer.get_remote_sender_id()
		if not NetworkManager.is_trusted_sender(sender_id):
			return
	_save_checkpoint_now()

func _on_dev_invincible_changed(enabled: bool) -> void:
	if _dev_label:
		_dev_label.visible = enabled

func _setup_demo_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_ui_layer)

	_fade_rect = ColorRect.new()
	_fade_rect.anchors_preset = Control.PRESET_FULL_RECT
	_fade_rect.color = Color(0, 0, 0, 1)
	_fade_rect.visible = false
	_ui_layer.add_child(_fade_rect)

	_dev_label = Label.new()
	_dev_label.text = "[DEV]"
	_dev_label.position = Vector2(8, 8)
	_dev_label.modulate = Color(1, 0.3, 0.3, 0.9)
	_dev_label.visible = GameManager.dev_invincible
	_ui_layer.add_child(_dev_label)

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
		if GameManager.dev_paused:
			_request_toggle_pause()
	)
	vb.add_child(btn_retry)

	var btn_lobby := Button.new()
	btn_lobby.text = "返回大厅"
	btn_lobby.pressed.connect(func() -> void: _request_return_lobby())
	vb.add_child(btn_lobby)

func _update_pause_ui() -> void:
	if _pause_panel:
		_pause_panel.visible = GameManager.dev_paused
		if GameManager.dev_paused:
			InputMouseGuard.release_for_ui()

func _request_return_lobby() -> void:
	if NetworkManager.is_multiplayer_game:
		_request_return_lobby_rpc.rpc_id(1)
	else:
		_apply_return_lobby.rpc()

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
	GameManager.set_dev_pause(false)
	get_tree().paused = false
	InputMouseGuard.release_for_ui()
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")

func _ensure_checkpoint_trigger() -> void:
	var existing := get_node_or_null("Checkpoint")
	if existing != null:
		return
	var area := Area3D.new()
	area.name = "Checkpoint"
	area.position = Vector3(0, 1.0, 0)
	area.collision_mask = 2
	area.script = load("res://scripts/checkpoint_trigger.gd")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.5, 2.0, 2.5)
	shape.shape = box
	area.add_child(shape)
	add_child(area)
