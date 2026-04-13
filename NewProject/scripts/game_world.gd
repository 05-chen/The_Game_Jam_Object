# 游戏世界脚本 - 管理游戏场景的初始化和游戏流程

# 基本设置
extends Node3D

# 初始化函数 - 游戏世界加载时执行
func _ready() -> void:
	# 构建游戏房间
	_build_room()
	# 生成玩家角色
	_spawn_player()
	# 生成游戏物品
	_spawn_items()
	# 生成幽灵敌人
	_spawn_ghost()
	# 连接游戏结束事件
	GameManager.game_over_triggered.connect(_on_game_over)

# 构建房间函数 - 创建游戏地图
func _build_room() -> void:
	# 加载房间构建器脚本
	var scr = load("res://scripts/room_builder.gd")
	# 创建房间节点
	var room = Node3D.new()
	# 为房间节点设置脚本
	room.set_script(scr)
	# 将房间添加到场景
	add_child(room)

# 生成玩家函数 - 根据角色类型创建玩家
func _spawn_player() -> void:
	# 根据当前角色选择对应的场景文件
	var path := ""
	if GameManager.current_role == GameManager.ROLE_BLIND:
		path = "res://scenes/blind_player.tscn"
	else:
		path = "res://scenes/lame_player.tscn"
	
	# 加载并实例化玩家场景
	var scn = load(path)
	var player = scn.instantiate()
	
	# 设置统一的101初始位置
	player.position = Vector3(0, 1, 0)
	
	# 将玩家添加到"player"组
	player.add_to_group("player")
	
	# 将玩家添加到场景
	add_child(player)

# 生成物品函数 - 创建游戏中的各种物品
func _spawn_items() -> void:
	# 生成各种类型的物品，参数分别是位置和物品类型
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

# 创建物品函数 - 生成单个物品
func _make_item(pos: Vector3, type_id: int) -> void:
	# 加载物品场景
	var scn = load("res://scenes/medicine_item.tscn")
	# 实例化物品
	var item = scn.instantiate()
	# 设置物品位置
	item.position = pos
	# 设置物品类型
	item.medicine_type = type_id
	# 将物品添加到场景
	add_child(item)

# 生成幽灵函数 - 创建敌人
func _spawn_ghost() -> void:
	# 加载幽灵场景
	var scn = load("res://scenes/ghost.tscn")
	# 实例化幽灵
	var g = scn.instantiate()
	# 设置幽灵初始位置
	g.position = Vector3(5, 1, -5)
	# 将幽灵添加到场景
	add_child(g)

# 游戏结束处理函数
func _on_game_over(_won: bool) -> void:
	# 等待4秒
	await get_tree().create_timer(4.0).timeout
	# 切换回主菜单场景
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

# 输入处理函数 - 处理暂停游戏的输入
func _unhandled_input(event: InputEvent) -> void:
	# 检测暂停游戏按键
	if event.is_action_pressed("pause_game"):
		# 切换鼠标模式
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE  # 显示鼠标
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED  # 捕获鼠标
