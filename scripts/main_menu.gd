# 主菜单脚本 - 处理主菜单的按钮点击事件和场景切换

# 基本设置
extends Control

# 初始化函数 - 场景加载时执行
func _ready() -> void:
	# 兜底：进入主菜单时强制清理联机残留，防止演示尾声异常
	NetworkManager.hard_cleanup("enter_main_menu")
	# 连接按钮信号
	%BlindButton.pressed.connect(_on_blind)  # 瞎子角色按钮
	%LameButton.pressed.connect(_on_lame)  # 瘸子角色按钮
	%MultiButton.pressed.connect(_on_multi)  # 多人游戏按钮
	%QuitButton.pressed.connect(_on_quit)  # 退出按钮
	# 显示鼠标
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

# 选择瞎子角色函数
func _on_blind() -> void:
	# 设置当前角色为瞎子
	GameManager.current_role = GameManager.ROLE_BLIND
	# 重置游戏状态
	GameManager.reset_game()
	# 切换到游戏世界场景
	get_tree().change_scene_to_file("res://scenes/game_world.tscn")

# 选择瘸子角色函数
func _on_lame() -> void:
	# 设置当前角色为瘸子
	GameManager.current_role = GameManager.ROLE_LAME
	# 重置游戏状态
	GameManager.reset_game()
	# 切换到游戏世界场景
	get_tree().change_scene_to_file("res://scenes/game_world.tscn")

# 多人游戏函数
func _on_multi() -> void:
	# 切换到大厅场景
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")

# 退出游戏函数
func _on_quit() -> void:
	# 退出前确保联机与语音彻底释放
	NetworkManager.close_room()
	if VoiceChatManager and VoiceChatManager.has_method("shutdown_voice"):
		VoiceChatManager.shutdown_voice("quit_game")
	get_tree().quit()
