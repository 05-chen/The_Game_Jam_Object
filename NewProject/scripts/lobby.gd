# 大厅脚本 - 处理多人游戏的房间创建、加入和角色选择

# 基本设置
extends Control

# 状态变量
var waiting_for_guest: bool = false  # 是否正在等待玩家加入
var joined_room: bool = false  # 是否已加入房间

# 场景节点引用
@onready var create_btn: Button = %CreateBtn  # 创建房间按钮
@onready var join_btn: Button = %JoinBtn  # 加入房间按钮
@onready var back_btn: Button = %BackBtn  # 返回按钮
@onready var ip_input: LineEdit = %IpInput  # IP地址输入框
@onready var code_input: LineEdit = %CodeInput  # 邀请码输入框
@onready var status_label: Label = %StatusLabel  # 状态标签
@onready var code_display: Label = %CodeDisplay  # 邀请码显示标签
@onready var role_panel: VBoxContainer = %RolePanel  # 角色选择面板
@onready var blind_btn: Button = %PickBlind  # 选择瞎子角色按钮
@onready var lame_btn: Button = %PickLame  # 选择瘸子角色按钮

# 初始化函数 - 场景加载时执行
func _ready() -> void:
	# 显示鼠标
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
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
	# 初始化UI状态
	role_panel.visible = false
	code_display.text = ""
	status_label.text = ""

# 创建房间函数
func _on_create() -> void:
	# 调用网络管理器创建房间
	var code = NetworkManager.create_room()
	# 检查是否创建成功
	if code == "":
		status_label.text = "创建房间失败 (端口可能被占用)"
		return
	# 设置状态并更新UI
	waiting_for_guest = true
	code_display.text = "邀请码: " + code
	status_label.text = "等待玩家加入..."
	# 禁用相关控件
	create_btn.disabled = true
	join_btn.disabled = true
	ip_input.editable = false
	code_input.editable = false

# 加入房间函数
func _on_join() -> void:
	# 获取并处理输入
	var ip = ip_input.text.strip_edges()
	var code = code_input.text.strip_edges().to_upper()
	# 验证输入
	if ip == "":
		status_label.text = "请输入主机 IP 地址"
		return
	if code.length() != 6:
		status_label.text = "邀请码必须为6位"
		return
	# 调用网络管理器加入房间
	var ok = NetworkManager.join_room(ip, code)
	if not ok:
		status_label.text = "连接失败"
		return
	# 更新UI状态
	status_label.text = "正在连接..."
	create_btn.disabled = true
	join_btn.disabled = true

# 玩家加入处理函数
func _on_guest_joined() -> void:
	# 更新状态并显示角色选择面板
	status_label.text = "玩家已加入! 请选择你的角色"
	role_panel.visible = true

# 玩家离开处理函数
func _on_guest_left() -> void:
	# 更新状态并隐藏角色选择面板
	status_label.text = "玩家已断开连接"
	role_panel.visible = false

# 连接成功处理函数
func _on_conn_ok() -> void:
	# 更新状态
	status_label.text = "已连接 正在验证邀请码..."

# 连接失败处理函数
func _on_conn_failed() -> void:
	# 更新状态并重置UI
	status_label.text = "连接失败 请检查IP地址"
	_reset_ui()

# 邀请码验证结果处理函数
func _on_code_result(ok: bool) -> void:
	if ok:
		# 验证成功
		if NetworkManager.is_host:
			return  # 主机不需要处理
		joined_room = true
		status_label.text = "验证成功! 等待房主选择角色开始游戏..."
		create_btn.disabled = true
		join_btn.disabled = true
	else:
		# 验证失败
		if not NetworkManager.is_host:
			status_label.text = "邀请码错误!"
			_reset_ui()

# 选择瞎子角色函数
func _on_pick_blind() -> void:
	# 通知网络管理器开始游戏，并选择瞎子角色
	NetworkManager.host_start_game(GameManager.ROLE_BLIND)

# 选择瘸子角色函数
func _on_pick_lame() -> void:
	# 通知网络管理器开始游戏，并选择瘸子角色
	NetworkManager.host_start_game(GameManager.ROLE_LAME)

# 返回主菜单函数
func _on_back() -> void:
	# 关闭房间
	NetworkManager.close_room()
	# 切换到主菜单场景
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

# 重置UI函数
func _reset_ui() -> void:
	# 恢复控件状态
	create_btn.disabled = false
	join_btn.disabled = false
	ip_input.editable = true
	code_input.editable = true
	code_display.text = ""
	role_panel.visible = false
