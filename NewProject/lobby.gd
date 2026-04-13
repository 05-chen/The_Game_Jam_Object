# 大厅脚本 - 使用 Steam P2P 的跨网络联机大厅
# 移除了 IP 输入框，改为仅通过邀请码匹配

extends Control

# 状态变量
var waiting_for_guest: bool = false
var joined_room: bool = false

# 场景节点引用
@onready var create_btn: Button = %CreateBtn
@onready var join_btn: Button = %JoinBtn
@onready var back_btn: Button = %BackBtn
@onready var code_input: LineEdit = %CodeInput       # 邀请码输入框
@onready var status_label: Label = %StatusLabel
@onready var code_display: Label = %CodeDisplay
@onready var role_panel: VBoxContainer = %RolePanel
@onready var blind_btn: Button = %PickBlind
@onready var lame_btn: Button = %PickLame

# ── 注意：如果你的场景中仍有 IpInput 节点，可以保留引用但隐藏它 ──
# 如果已从场景树中移除 IpInput，则删除下面这行
@onready var ip_input: LineEdit = %IpInput if has_node("%IpInput") else null

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# 检查 Steam 是否就绪
	if not NetworkManager.is_steam_ready():
		status_label.text = "Steam 未初始化！请确保 Steam 客户端正在运行"
		create_btn.disabled = true
		join_btn.disabled = true
		NetworkManager.steam_init_failed.connect(func():
			status_label.text = "Steam 初始化失败"
		)
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

	# 初始化UI
	role_panel.visible = false
	code_display.text = ""

	# 隐藏 IP 输入框（不再需要）
	if ip_input != null:
		ip_input.visible = false
	# 同时隐藏 IP 相关的标签节点（如果存在）
	if has_node("%IpTag"):
		get_node("%IpTag").visible = false
	if has_node("%IpBox"):
		get_node("%IpBox").visible = false

# ── 创建房间 ──
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

# ── 加入房间（仅需邀请码） ──
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

# ── 网络事件回调 ──
func _on_guest_joined() -> void:
	status_label.text = "玩家已加入! 请选择你的角色"
	role_panel.visible = true

func _on_guest_left() -> void:
	status_label.text = "玩家已断开连接"
	role_panel.visible = false

func _on_conn_ok() -> void:
	status_label.text = "已连接，正在验证邀请码..."

func _on_conn_failed() -> void:
	status_label.text = "连接失败 (未找到匹配房间或网络错误)"
	_reset_ui()

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

# ── 角色选择 ──
func _on_pick_blind() -> void:
	NetworkManager.host_start_game(GameManager.ROLE_BLIND)

func _on_pick_lame() -> void:
	NetworkManager.host_start_game(GameManager.ROLE_LAME)

# ── 返回主菜单 ──
func _on_back() -> void:
	NetworkManager.close_room()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

# ── UI 重置 ──
func _reset_ui() -> void:
	create_btn.disabled = false
	join_btn.disabled = false
	code_input.editable = true
	code_display.text = ""
	role_panel.visible = false
