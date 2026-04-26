# 游戏世界脚本 - 管理游戏场景的初始化和游戏流程
# [已修改] 多人模式下生成双方玩家 + 远程代理可视化
# [已修改] 物品使用确定性命名以保证 RPC 路径一致
# [已修改] Ghost 区分 Host/Client 控制

extends Node3D

var _item_idx: int = 0  # 物品命名计数器

# 初始化函数
func _ready() -> void:
	_build_room()
	_spawn_players()
	_spawn_items()
	_spawn_ghost()
	GameManager.game_over_triggered.connect(_on_game_over)

# 构建房间函数 - 不变
func _build_room() -> void:
	var scr = load("res://scripts/room_builder.gd")
	var room = Node3D.new()
	room.set_script(scr)
	add_child(room)

func _spawn_players() -> void:
	var is_mp = NetworkManager.is_multiplayer_game
	print("[GameWorld] 开始生成角色，模式：", "多人" if is_mp else "单人")

	if not is_mp:
		# ── 单人模式保持不变 ──
		var path = "res://scenes/blind_player.tscn" if GameManager.current_role == GameManager.ROLE_BLIND else "res://scenes/lame_player.tscn"
		var player = load(path).instantiate()
		player.position = Vector3(0, 1, 0)
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

		# 将节点添加进场景
		add_child(blind)
		add_child(lame)

		# 【关键修复 3】远程实体优化：关闭物理碰撞
		# 防止由于网络同步的位置与本地物理引擎发生冲突，导致“瞬移”或“抖动”
		if not blind.is_local:
			_setup_remote_proxy(blind, Color(0.3, 0.5, 1.0, 0.7))
		if not lame.is_local:
			_setup_remote_proxy(lame, Color(0.2, 0.8, 0.3, 0.7))

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
	add_child(g)

# [已修改] 游戏结束处理 - 多人模式下关闭房间
func _on_game_over(_won: bool) -> void:
	await get_tree().create_timer(4.0).timeout
	if NetworkManager.is_multiplayer_game:
		get_tree().change_scene_to_file("res://scenes/game_room.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

# 输入处理函数 - 暂停
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause_game"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
