# 网络管理器脚本 - 使用 Steam P2P 实现跨网络远程联机
# 替代原有的 ENet 方案，通过 Steam Relay 服务器实现 NAT 穿透

extends Node

# ── 常量 ──
const LOBBY_TYPE_PRIVATE = 0   # Steam 私有大厅（仅邀请可见）
const MAX_MEMBERS = 2          # 最大玩家数

# ── 网络状态 ──
var steam_id: int = 0              # 本机 Steam ID
var lobby_id: int = 0              # 当前大厅 ID
var peer: SteamMultiplayerPeer = null  # Steam 多人对等体
var invite_code: String = ""       # 房间邀请码
var is_host: bool = false          # 是否为房主
var guest_connected: bool = false  # 是否有玩家已连接
var _steam_ok: bool = false        # Steam 是否成功初始化

# ── 邀请码 → 大厅 ID 映射（房主端维护） ──
# 注意：跨网络场景下，客户端无法直接通过邀请码找到大厅
# 需要通过 Steam Lobby 搜索 + metadata 匹配来实现
var _code_to_lobby: Dictionary = {}

# ── 信号 ──
signal player_connected()
signal player_disconnected()
signal connection_failed()
signal connection_succeeded()
signal code_verified(ok: bool)
signal steam_init_failed()

# ══════════════════════════════════════════════
#  初始化
# ══════════════════════════════════════════════

func _ready() -> void:
	_init_steam()
	# 连接 Godot 多人信号
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)

func _process(_delta: float) -> void:
	if _steam_ok:
		Steam.run_callbacks()  # 每帧驱动 Steam 回调

# ══════════════════════════════════════════════
#  Steam 初始化
# ══════════════════════════════════════════════

func _init_steam() -> void:
	# ── 重要：你需要在 Steamworks 后台创建应用并获取 App ID ──
	# 开发阶段可使用 480（Spacewar 测试 App ID）
	# 正式发布时替换为你自己的 App ID
	var init_result: Dictionary = Steam.steamInitEx(true, 480)
	print("[Steam] Init result: ", init_result)

	if init_result["status"] == 0:  # OK
		_steam_ok = true
		steam_id = Steam.getSteamID()
		print("[Steam] 初始化成功, Steam ID: ", steam_id)
		# 连接 Steam 大厅相关回调
		Steam.lobby_created.connect(_on_lobby_created)
		Steam.lobby_joined.connect(_on_lobby_joined)
		Steam.lobby_match_list.connect(_on_lobby_match_list)
		Steam.lobby_chat_update.connect(_on_lobby_chat_update)
	else:
		_steam_ok = false
		print("[Steam] 初始化失败: ", init_result)
		steam_init_failed.emit()

func is_steam_ready() -> bool:
	return _steam_ok

# ══════════════════════════════════════════════
#  邀请码生成
# ══════════════════════════════════════════════

func generate_code() -> String:
	var chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var code = ""
	for i in range(6):
		code += chars[randi() % chars.length()]
	return code

# ══════════════════════════════════════════════
#  创建房间（房主）
# ══════════════════════════════════════════════

func create_room() -> String:
	if not _steam_ok:
		return ""

	# 生成邀请码
	invite_code = generate_code()
	is_host = true
	guest_connected = false

	# 创建 Steam 大厅（私有类型，最多 2 人）
	# lobby_created 回调中会完成后续设置
	Steam.createLobby(Steam.LOBBY_TYPE_PUBLIC, MAX_MEMBERS)
	# 注意：使用 PUBLIC 类型以便客户端通过 requestLobbyList 搜索到
	# 安全性通过邀请码验证保障

	return invite_code

# Steam 大厅创建完成回调
func _on_lobby_created(result: int, this_lobby_id: int) -> void:
	if result != 1:  # k_EResultOK = 1
		print("[Steam] 创建大厅失败, result: ", result)
		invite_code = ""
		is_host = false
		return

	lobby_id = this_lobby_id
	print("[Steam] 大厅已创建, ID: ", lobby_id, ", 邀请码: ", invite_code)

	# 在大厅 metadata 中存储邀请码，供客户端搜索匹配
	Steam.setLobbyData(lobby_id, "invite_code", invite_code)
	Steam.setLobbyData(lobby_id, "game_name", "blind_and_lame")

	# 创建 SteamMultiplayerPeer 作为 Host
	_setup_steam_peer_as_host()

func _setup_steam_peer_as_host() -> void:
	peer = SteamMultiplayerPeer.new()
	var err = peer.create_host(0)  # 端口 0 表示自动
	if err != OK:
		print("[Steam] 创建 Host Peer 失败: ", err)
		return
	multiplayer.multiplayer_peer = peer
	print("[Steam] Host Peer 已就绪")

# ══════════════════════════════════════════════
#  加入房间（客户端）
# ══════════════════════════════════════════════

# 新版加入接口：只需要邀请码，不需要 IP 地址
func join_room_by_code(code: String) -> bool:
	if not _steam_ok:
		return false

	invite_code = code.to_upper()
	is_host = false

	# 通过 Steam Lobby 搜索匹配邀请码的大厅
	# 添加过滤条件
	Steam.addRequestLobbyListStringFilter("game_name", "blind_and_lame", Steam.LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListStringFilter("invite_code", invite_code, Steam.LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListResultCountFilter(1)
	Steam.requestLobbyList()

	return true

# 兼容旧接口（ip 参数将被忽略）
func join_room(ip: String, code: String) -> bool:
	return join_room_by_code(code)

# Steam 大厅列表搜索结果回调
func _on_lobby_match_list(lobbies: Array) -> void:
	if is_host:
		return  # 房主不处理搜索结果

	if lobbies.size() == 0:
		print("[Steam] 未找到匹配的大厅, 邀请码: ", invite_code)
		connection_failed.emit()
		return

	# 找到匹配的大厅，加入它
	var target_lobby = lobbies[0]
	print("[Steam] 找到大厅: ", target_lobby, ", 正在加入...")
	Steam.joinLobby(target_lobby)

# Steam 加入大厅回调
func _on_lobby_joined(this_lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != 1:  # k_EChatRoomEnterResponseSuccess = 1
		print("[Steam] 加入大厅失败, response: ", response)
		connection_failed.emit()
		return

	lobby_id = this_lobby_id
	print("[Steam] 已加入大厅: ", lobby_id)

	if not is_host:
		# 客户端：获取房主的 Steam ID 并连接
		var host_steam_id = Steam.getLobbyOwner(lobby_id)
		print("[Steam] 房主 Steam ID: ", host_steam_id)

		peer = SteamMultiplayerPeer.new()
		var err = peer.create_client(host_steam_id, 0)
		if err != OK:
			print("[Steam] 创建 Client Peer 失败: ", err)
			connection_failed.emit()
			return
		multiplayer.multiplayer_peer = peer
		print("[Steam] Client Peer 已创建，正在连接到房主...")

# Steam 大厅成员变化回调
func _on_lobby_chat_update(this_lobby_id: int, changed_id: int, making_id: int, chat_state: int) -> void:
	match chat_state:
		1:  # 成员加入
			print("[Steam] 成员加入大厅: ", changed_id)
		2:  # 成员离开
			print("[Steam] 成员离开大厅: ", changed_id)
		8:  # 成员断开
			print("[Steam] 成员断开: ", changed_id)

# ══════════════════════════════════════════════
#  关闭房间
# ══════════════════════════════════════════════

func close_room() -> void:
	# 离开 Steam 大厅
	if lobby_id != 0:
		Steam.leaveLobby(lobby_id)
		lobby_id = 0
	# 清理 Godot 多人连接
	if peer != null:
		multiplayer.multiplayer_peer = null
		peer = null
	# 重置状态
	is_host = false
	guest_connected = false
	invite_code = ""

# ══════════════════════════════════════════════
#  Godot 多人连接回调
# ══════════════════════════════════════════════

func _on_peer_connected(_id: int) -> void:
	if is_host:
		guest_connected = true
		player_connected.emit()
		print("[Network] 玩家已连接, peer_id: ", _id)

func _on_peer_disconnected(_id: int) -> void:
	if is_host:
		guest_connected = false
		player_disconnected.emit()
		print("[Network] 玩家已断开, peer_id: ", _id)

func _on_connected_to_server() -> void:
	print("[Network] 已连接到服务器，发送邀请码验证...")
	rpc_id(1, "_send_code_to_host", invite_code)
	connection_succeeded.emit()

func _on_connection_failed() -> void:
	connection_failed.emit()
	close_room()

# ══════════════════════════════════════════════
#  邀请码验证 (RPC)
# ══════════════════════════════════════════════

@rpc("any_peer", "reliable")
func _send_code_to_host(code: String) -> void:
	if not is_host:
		return
	var sender_id = multiplayer.get_remote_sender_id()
	if code == invite_code:
		_code_result.rpc_id(sender_id, true)
		code_verified.emit(true)
	else:
		_code_result.rpc_id(sender_id, false)
		await get_tree().create_timer(0.5).timeout
		# 踢出验证失败的玩家
		peer.disconnect_peer(sender_id)
		# 从 Steam 大厅中移除（如果需要）

@rpc("authority", "reliable")
func _code_result(ok: bool) -> void:
	code_verified.emit(ok)
	if not ok:
		await get_tree().create_timer(0.5).timeout
		close_room()

# ══════════════════════════════════════════════
#  开始游戏 (RPC)
# ══════════════════════════════════════════════

@rpc("authority", "reliable", "call_local")
func start_game_all(host_role: int) -> void:
	if multiplayer.is_server():
		GameManager.current_role = host_role
	else:
		if host_role == GameManager.ROLE_BLIND:
			GameManager.current_role = GameManager.ROLE_LAME
		else:
			GameManager.current_role = GameManager.ROLE_BLIND
	GameManager.reset_game()
	get_tree().change_scene_to_file("res://scenes/game_world.tscn")

func host_start_game(host_role: int) -> void:
	if is_host and guest_connected:
		start_game_all.rpc(host_role)
