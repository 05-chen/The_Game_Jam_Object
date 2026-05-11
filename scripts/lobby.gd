# 大厅脚本 - 使用 Steam P2P 的跨网络联机大厅
# [已修改] 移除 IP 输入（隐藏），仅通过邀请码匹配
# [已修改] 增加 Steam 状态检查和用户名显示

extends Control

# 状态变量
var waiting_for_guest: bool = false  # 是否正在等待玩家加入
var joined_room: bool = false  # 是否已加入房间
var _error_dialog: AcceptDialog = null
var _mp_session_bar: Node = null

# 场景节点引用
@onready var create_btn: Button = %CreateBtn
@onready var join_btn: Button = %JoinBtn
@onready var back_btn: Button = %BackBtn
@onready var code_input: LineEdit = %CodeInput
@onready var status_label: Label = %StatusLabel
@onready var code_display: Label = %CodeDisplay
@onready var role_panel: VBoxContainer = %RolePanel
@onready var blind_btn: Button = %PickBlind
@onready var lame_btn: Button = %PickLame

# 初始化函数
func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# 隐藏不再需要的 IP 输入区域（保留节点兼容 .tscn）
	var ip_box = find_child("IpBox", true, false)
	if ip_box:
		ip_box.visible = false

	# 检查 Steam 是否就绪
	if not NetworkManager.is_steam_ready():
		status_label.text = "Steam 未初始化! 请确保 Steam 客户端正在运行"
		create_btn.disabled = true
		join_btn.disabled = true
		return

	# 显示当前 Steam 用户名
	var steam_name = Steam.getPersonaName()
	status_label.text = "Steam 已就绪 | 用户: " + steam_name

	# 连接按钮信号
	create_btn.pressed.connect(_on_create)
	join_btn.pressed.connect(_on_join)
	back_btn.pressed.connect(_on_back)
	blind_btn.pressed.connect(_on_pick_blind)
	lame_btn.pressed.connect(_on_pick_lame)

	# 连接网络管理器信号
	NetworkManager.player_connected.connect(_on_guest_joined)
	NetworkManager.player_disconnected.connect(_on_guest_left)
	NetworkManager.connection_failed.connect(_on_conn_failed)
	NetworkManager.connection_succeeded.connect(_on_conn_ok)
	NetworkManager.code_verified.connect(_on_code_result)
	NetworkManager.lobby_search_result.connect(_on_lobby_search_result)
	NetworkManager.connection_timeout.connect(_on_connection_timeout)

	_ensure_error_dialog()

	# 从对局返回大厅：保持 P2P / Steam 大厅，仅在大厅内显示会话条与再开局 UI
	if NetworkManager.is_multiplayer_game:
		_enter_lobby_with_active_session()
	else:
		role_panel.visible = false
		code_display.text = ""

# 创建房间函数
func _on_create() -> void:
	var code = NetworkManager.create_room()
	if code == "":
		status_label.text = "创建房间失败"
		return
	waiting_for_guest = true
	code_display.text = "邀请码: " + code
	status_label.text = "等待玩家加入... (将邀请码发给好友)"
	create_btn.disabled = true
	join_btn.disabled = true
	code_input.editable = false

# 加入房间函数（仅需邀请码，不再需要 IP）
func _on_join() -> void:
	var code = code_input.text.strip_edges().to_upper()
	if code.length() != 6:
		status_label.text = "邀请码必须为6位"
		return
	var ok = NetworkManager.join_room_by_code(code)
	if not ok:
		status_label.text = "Steam 未就绪，无法连接"
		return
	status_label.text = "正在搜索房间..."
	create_btn.disabled = true
	join_btn.disabled = true

# 玩家加入处理函数
func _on_guest_joined() -> void:
	status_label.text = "玩家已加入! 请选择你的角色"
	role_panel.visible = true

# 玩家离开处理函数
func _on_guest_left() -> void:
	status_label.text = "玩家已断开连接"
	role_panel.visible = false

# 连接成功处理函数
func _on_conn_ok() -> void:
	status_label.text = "已连接，正在验证邀请码..."

# 连接失败处理函数
func _on_conn_failed() -> void:
	status_label.text = "连接失败 (未找到匹配房间或网络错误)"
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show_error_popup("连接失败，请检查房间邀请码、Steam 在线状态或网络环境。")
	_reset_ui()

# 邀请码验证结果处理函数
func _on_code_result(ok: bool) -> void:
	if ok:
		if NetworkManager.is_host:
			return
		joined_room = true
		status_label.text = "验证成功! 等待房主选择角色开始游戏..."
		create_btn.disabled = true
		join_btn.disabled = true
	else:
		if not NetworkManager.is_host:
			status_label.text = "邀请码错误!"
			_reset_ui()

func _on_lobby_search_result(found: bool, matched_count: int) -> void:
	if found:
		status_label.text = "找到房间 %d 个，正在加入..." % matched_count
	else:
		status_label.text = "未找到匹配邀请码的房间"
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_show_error_popup("未找到匹配邀请码的房间，请确认房主已创建成功。")
		_reset_ui()

# 选择瞎子角色函数
func _on_pick_blind() -> void:
	NetworkManager.host_start_game(GameManager.ROLE_BLIND)

# 选择瘸子角色函数
func _on_pick_lame() -> void:
	NetworkManager.host_start_game(GameManager.ROLE_LAME)

## 对局结束后回到大厅时恢复 UI；会话条与「断开联机」仅在大厅出现
func _enter_lobby_with_active_session() -> void:
	_add_mp_session_bar()
	create_btn.disabled = true
	join_btn.disabled = true
	code_input.editable = false
	if NetworkManager.is_host:
		if NetworkManager.invite_code != "":
			code_display.text = "邀请码: " + NetworkManager.invite_code
		if NetworkManager.guest_connected:
			status_label.text = "对局已结束；请房主选择角色开始下一局"
			role_panel.visible = true
		else:
			status_label.text = "对局已结束；等待队友连接..."
			role_panel.visible = false
		waiting_for_guest = false
	else:
		joined_room = true
		role_panel.visible = false
		status_label.text = "对局已结束；等待房主选择角色开始下一局"


func _add_mp_session_bar() -> void:
	if _mp_session_bar != null and is_instance_valid(_mp_session_bar):
		return
	var main: VBoxContainer = $Main
	var bar := HBoxContainer.new()
	bar.name = "MpSessionBar"
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	var lab := Label.new()
	lab.text = "联机会话进行中 — "
	bar.add_child(lab)
	var disc := Button.new()
	disc.text = "断开联机（留在大厅）"
	disc.pressed.connect(_on_disconnect_mp_pressed)
	bar.add_child(disc)
	main.add_child(bar)
	main.move_child(bar, 1)
	_mp_session_bar = bar


func _on_disconnect_mp_pressed() -> void:
	NetworkManager.close_room()
	if _mp_session_bar != null and is_instance_valid(_mp_session_bar):
		_mp_session_bar.queue_free()
		_mp_session_bar = null
	waiting_for_guest = false
	joined_room = false
	_reset_ui()
	var steam_name := Steam.getPersonaName()
	status_label.text = "Steam 已就绪 | 用户: " + steam_name


# 返回主菜单：主动退出联机并回到首页
func _on_back() -> void:
	NetworkManager.close_room()
	if _mp_session_bar != null and is_instance_valid(_mp_session_bar):
		_mp_session_bar.queue_free()
		_mp_session_bar = null
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

# 重置 UI 函数
func _reset_ui() -> void:
	create_btn.disabled = false
	join_btn.disabled = false
	code_input.editable = true
	code_display.text = ""
	role_panel.visible = false

func _on_connection_timeout(message: String) -> void:
	status_label.text = message
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show_error_popup(message)
	_reset_ui()

func _ensure_error_dialog() -> void:
	if _error_dialog != null:
		return
	_error_dialog = AcceptDialog.new()
	_error_dialog.title = "连接提示"
	_error_dialog.dialog_text = ""
	add_child(_error_dialog)

func _show_error_popup(message: String) -> void:
	_ensure_error_dialog()
	_error_dialog.dialog_text = message
	_error_dialog.popup_centered()
