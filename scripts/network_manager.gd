# 网络管理器脚本 - 处理多人游戏的网络连接和房间管理

# 基本设置
extends Node

# 常量定义
const DEFAULT_PORT = 9527  # 默认端口号

# 网络相关变量
var peer: ENetMultiplayerPeer = null  # 网络对等体
var invite_code: String = ""  # 房间邀请码
var is_host: bool = false  # 是否为主机
var guest_connected: bool = false  # 是否有玩家连接

# 网络事件信号
signal player_connected()  # 玩家连接信号
signal player_disconnected()  # 玩家断开连接信号
signal connection_failed()  # 连接失败信号
signal connection_succeeded()  # 连接成功信号
signal code_verified(ok: bool)  # 邀请码验证结果信号

# 初始化函数 - 节点加载时执行
func _ready() -> void:
	# 连接网络事件信号
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)

# 生成邀请码函数
func generate_code() -> String:
	# 定义可用字符集（排除容易混淆的字符）
	var chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var code = ""
	# 生成6位随机邀请码
	for i in range(6):
		code += chars[randi() % chars.length()]
	return code

# 创建房间函数
func create_room() -> String:
	# 创建新的网络对等体
	peer = ENetMultiplayerPeer.new()
	# 创建服务器，最多允许1个客户端连接
	var err = peer.create_server(DEFAULT_PORT, 1)
	# 检查是否创建成功
	if err != OK:
		return ""
	# 设置多人游戏对等体
	multiplayer.multiplayer_peer = peer
	# 设置为主机
	is_host = true
	guest_connected = false
	# 生成邀请码
	invite_code = generate_code()
	return invite_code

# 加入房间函数
func join_room(ip: String, code: String) -> bool:
	# 创建新的网络对等体
	peer = ENetMultiplayerPeer.new()
	# 创建客户端连接
	var err = peer.create_client(ip, DEFAULT_PORT)
	# 检查是否连接成功
	if err != OK:
		return false
	# 设置多人游戏对等体
	multiplayer.multiplayer_peer = peer
	# 设置为客户端
	is_host = false
	# 保存邀请码
	invite_code = code
	return true

# 关闭房间函数
func close_room() -> void:
	# 清理网络连接
	if peer != null:
		multiplayer.multiplayer_peer = null
		peer = null
	# 重置状态
	is_host = false
	guest_connected = false
	invite_code = ""

# 玩家连接处理函数
func _on_peer_connected(_id: int) -> void:
	# 只有主机需要处理
	if is_host:
		# 设置玩家已连接
		guest_connected = true
		# 发送玩家连接信号
		player_connected.emit()

# 玩家断开连接处理函数
func _on_peer_disconnected(_id: int) -> void:
	# 只有主机需要处理
	if is_host:
		# 设置玩家已断开
		guest_connected = false
		# 发送玩家断开连接信号
		player_disconnected.emit()

# 连接到服务器处理函数
func _on_connected_to_server() -> void:
	# 向主机发送邀请码进行验证
	rpc_id(1, "_send_code_to_host", invite_code)
	# 发送连接成功信号
	connection_succeeded.emit()

# 连接失败处理函数
func _on_connection_failed() -> void:
	# 发送连接失败信号
	connection_failed.emit()
	# 关闭房间
	close_room()

# 发送邀请码到主机函数（RPC）
@rpc("any_peer", "reliable")
func _send_code_to_host(code: String) -> void:
	# 只有主机需要处理
	if not is_host:
		return
	# 获取发送者ID
	var sender_id = multiplayer.get_remote_sender_id()
	# 验证邀请码
	if code == invite_code:
		# 验证成功，通知客户端
		_code_result.rpc_id(sender_id, true)
		# 发送验证成功信号
		code_verified.emit(true)
	else:
		# 验证失败，通知客户端
		_code_result.rpc_id(sender_id, false)
		# 等待0.5秒后断开连接
		await get_tree().create_timer(0.5).timeout
		peer.disconnect_peer(sender_id)

# 邀请码验证结果处理函数（RPC）
@rpc("authority", "reliable")
func _code_result(ok: bool) -> void:
	# 发送验证结果信号
	code_verified.emit(ok)
	# 验证失败时关闭房间
	if not ok:
		await get_tree().create_timer(0.5).timeout
		close_room()

# 开始游戏函数（RPC）
@rpc("authority", "reliable", "call_local")
func start_game_all(host_role: int) -> void:
	# 根据是否为服务器设置角色
	if multiplayer.is_server():
		# 服务器（主机）使用指定的角色
		GameManager.current_role = host_role
	else:
		# 客户端使用与主机相反的角色
		if host_role == GameManager.ROLE_BLIND:
			GameManager.current_role = GameManager.ROLE_LAME
		else:
			GameManager.current_role = GameManager.ROLE_BLIND
	# 重置游戏状态
	GameManager.reset_game()
	# 切换到游戏世界场景
	get_tree().change_scene_to_file("res://scenes/game_world.tscn")

# 主机开始游戏函数
func host_start_game(host_role: int) -> void:
	# 只有主机且有玩家连接时才能开始游戏
	if is_host and guest_connected:
		# 调用RPC函数开始游戏
		start_game_all.rpc(host_role)
