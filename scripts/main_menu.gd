# 主菜单脚本 - 处理主菜单的按钮点击事件和场景切换
# [已关闭单机] 测试请从「联机大厅」进入

extends Control

func _ready() -> void:
	if not NetworkManager.is_multiplayer_game:
		NetworkManager.hard_cleanup("enter_main_menu")
	_show_interrupt_popup_if_needed()
	# 单机入口已禁用
	%BlindButton.visible = false
	%BlindButton.disabled = true
	%LameButton.visible = false
	%LameButton.disabled = true
	%MultiButton.pressed.connect(_on_multi)
	%QuitButton.pressed.connect(_on_quit)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _show_interrupt_popup_if_needed() -> void:
	var msg := NetworkManager.consume_session_interrupt_message()
	if msg == "":
		return
	var dlg := AcceptDialog.new()
	dlg.title = "联机提示"
	dlg.dialog_text = msg
	add_child(dlg)
	dlg.popup_centered()

# func _on_blind() -> void:
# 	GameManager.current_role = GameManager.ROLE_BLIND
# 	GameManager.reset_game()
# 	get_tree().change_scene_to_file("res://scenes/game_world.tscn")

# func _on_lame() -> void:
# 	GameManager.current_role = GameManager.ROLE_LAME
# 	GameManager.reset_game()
# 	get_tree().change_scene_to_file("res://scenes/game_world.tscn")

func _on_multi() -> void:
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")

func _on_quit() -> void:
	NetworkManager.close_room()
	if VoiceChatManager and VoiceChatManager.has_method("shutdown_voice"):
		VoiceChatManager.shutdown_voice("quit_game")
	get_tree().quit()
