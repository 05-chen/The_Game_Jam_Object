extends Control

@onready var title_label: Label = %TitleLabel
@onready var status_label: Label = %StatusLabel
@onready var next_game_btn: Button = %NextGameBtn
@onready var leave_btn: Button = %LeaveBtn
@onready var disconnect_btn: Button = %DisconnectBtn

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	next_game_btn.pressed.connect(_on_next_game_pressed)
	leave_btn.pressed.connect(_on_leave_pressed)
	disconnect_btn.pressed.connect(_on_disconnect_pressed)
	disconnect_btn.visible = NetworkManager.is_multiplayer_game
	NetworkManager.player_connected.connect(_on_peer_connected)
	NetworkManager.player_disconnected.connect(_on_peer_disconnected)
	_refresh_ui()

func _refresh_ui() -> void:
	title_label.text = "联机游戏房间"
	if not NetworkManager.is_multiplayer_game:
		status_label.text = "当前不在联机房间中"
		next_game_btn.disabled = true
		return

	if NetworkManager.is_host:
		if NetworkManager.guest_connected:
			status_label.text = "队友已就绪，点击“下一次游戏”开始"
			next_game_btn.disabled = false
		else:
			status_label.text = "等待队友重新连接..."
			next_game_btn.disabled = true
	else:
		status_label.text = "已进入房间，等待房主开始下一次游戏..."
		next_game_btn.disabled = true

func _on_next_game_pressed() -> void:
	if not NetworkManager.is_multiplayer_game:
		return
	if not NetworkManager.is_host:
		status_label.text = "仅房主可以开始下一次游戏"
		return
	if not NetworkManager.guest_connected:
		status_label.text = "队友未连接，无法开始"
		return
	# 默认保持上一局角色分配：房主继续使用当前角色
	NetworkManager.host_start_game(GameManager.current_role)

func _on_leave_pressed() -> void:
	# 仅回主菜单：保留 Steam 大厅与 P2P，便于继续开局
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_disconnect_pressed() -> void:
	NetworkManager.close_room()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _on_peer_connected() -> void:
	_refresh_ui()

func _on_peer_disconnected() -> void:
	_refresh_ui()
