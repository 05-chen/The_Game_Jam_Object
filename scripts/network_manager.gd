# 网络管理器脚本 - 使用 Steam P2P 实现跨网络远程联机
# [已修改] ENetMultiplayerPeer → SteamMultiplayerPeer
# [已修改] 通过 Steam Lobby + metadata 匹配房间，无需 IP 地址

extends Node

# ── 常量 ──
const MAX_MEMBERS = 2  # 最大玩家数

# ── 网络状态 ──
var steam_id: int = 0                      # 本机 Steam ID
var lobby_id: int = 0                      # 当前 Steam 大厅 ID
var peer: SteamMultiplayerPeer = null      # Steam 多人对等体
var invite_code: String = ""               # 房间邀请码
var is_host: bool = false                  # 是否为房主
var guest_connected: bool = false          # 是否有玩家已连接
var remote_peer_id: int = 0                # 对方的 peer ID
var _steam_ok: bool = false                # Steam 是否成功初始化

# [新增] 多人游戏激活标记 - 不依赖 peer 对象，场景切换后仍可靠
var is_multiplayer_game: bool = false

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
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)

func _process(_delta: float) -> void:
	if _steam_ok:
		Steam.run_callbacks()

# ══════════════════════════════════════════════
#  Steam 初始化
# ══════════════════════════════════════════════

func _init_steam() -> void:
	# 开发阶段使用 480 (Spacewar 测试 ID)
	# 正式发布时替换为你自己的 App ID
	var init_result: Dictionary = Steam.steamInitEx(true, 480)
	print("[Steam] Init result: ", init_result)
	if init_result["status"] == 0:
		_steam_ok = true
		steam_id = Steam.getSteamID()
		print("[Steam] 初始化成功, Steam ID: ", steam_id)
		Steam.lobby_created.connect(_on_lobby_created)
		Steam.lobby_joined.connect(_on_lobby_joined)
		Steam.lobby_match_list.connect(_on_lobby_match_list)
	else:
		_steam_ok = false
		print("[Steam] 初始化失败: ", init_result)
		steam_init_failed.emit()

func is_steam_ready() -> bool:
	return _steam_ok

func is_trusted_sender(sender_id: int) -> bool:
	if not is_multiplayer_game:
		return false
	if multiplayer.is_server():
		return sender_id == remote_peer_id and remote_peer_id != 0
	return sender_id == 1

func send_voice_packet(packet: PackedByteArray) -> void:
	if not is_multiplayer_game:
		return
	if packet.is_empty():
		return
	if multiplayer.is_server():
		if remote_peer_id == 0:
			return
		_receive_voice_packet.rpc_id(remote_peer_id, packet)
	else:
		_receive_voice_packet.rpc_id(1, packet)

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
	invite_code = generate_code()
	is_host = true
	guest_connected = false
	# 创建 PUBLIC 类型 Steam 大厅，以便客户端通过 requestLobbyList 搜索到
	# 安全性通过邀请码二次验证保障
	Steam.createLobby(Steam.LOBBY_TYPE_PUBLIC, MAX_MEMBERS)
	return invite_code

func _on_lobby_created(result: int, this_lobby_id: int) -> void:
	if result != 1:
		print("[Steam] 创建大厅失败, result: ", result)
		invite_code = ""
		is_host = false
		return
	lobby_id = this_lobby_id
	print("[Steam] 大厅已创建, ID: ", lobby_id, ", 邀请码: ", invite_code)
	# 在大厅 metadata 中存储邀请码和游戏标识
	Steam.setLobbyData(lobby_id, "invite_code", invite_code)
	Steam.setLobbyData(lobby_id, "game_name", "blind_and_lame")
	# 创建 SteamMultiplayerPeer 作为 Host
	peer = SteamMultiplayerPeer.new()
	var err = peer.create_host(0)
	if err != OK:
		print("[Steam] 创建 Host Peer 失败: ", err)
		return
	multiplayer.multiplayer_peer = peer
	print("[Steam] Host Peer 已就绪")

# ══════════════════════════════════════════════
#  加入房间（客户端）
# ══════════════════════════════════════════════

func join_room_by_code(code: String) -> bool:
	if not _steam_ok:
		return false
	invite_code = code.to_upper()
	is_host = false
	# 通过 Steam Lobby 搜索匹配邀请码的大厅
	Steam.addRequestLobbyListStringFilter("game_name", "blind_and_lame", Steam.LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListStringFilter("invite_code", invite_code, Steam.LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListResultCountFilter(1)
	Steam.requestLobbyList()
	return true

# 兼容旧接口
func join_room(ip: String, code: String) -> bool:
	return join_room_by_code(code)

func _on_lobby_match_list(lobbies: Array) -> void:
	if is_host:
		return
	if lobbies.size() == 0:
		print("[Steam] 未找到匹配的大厅, 邀请码: ", invite_code)
		connection_failed.emit()
		return
	var target_lobby = lobbies[0]
	print("[Steam] 找到大厅: ", target_lobby, ", 正在加入...")
	Steam.joinLobby(target_lobby)

func _on_lobby_joined(this_lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != 1:
		print("[Steam] 加入大厅失败, response: ", response)
		connection_failed.emit()
		return
	lobby_id = this_lobby_id
	print("[Steam] 已加入大厅: ", lobby_id)
	if not is_host:
		var host_steam_id = Steam.getLobbyOwner(lobby_id)
		print("[Steam] 房主 Steam ID: ", host_steam_id)
		peer = SteamMultiplayerPeer.new()
		var err = peer.create_client(host_steam_id, 0)
		if err != OK:
			print("[Steam] 创建 Client Peer 失败: ", err)
			connection_failed.emit()
			return
		multiplayer.multiplayer_peer = peer

# ══════════════════════════════════════════════
#  关闭房间
# ══════════════════════════════════════════════

func close_room() -> void:
	is_multiplayer_game = false
	if lobby_id != 0:
		Steam.leaveLobby(lobby_id)
		lobby_id = 0
	if peer != null:
		multiplayer.multiplayer_peer = null
		peer = null
	is_host = false
	guest_connected = false
	invite_code = ""
	remote_peer_id = 0

# ══════════════════════════════════════════════
#  Godot 多人连接回调
# ══════════════════════════════════════════════

func _on_peer_connected(id: int) -> void:
	remote_peer_id = id
	if is_host:
		guest_connected = true
		player_connected.emit()
	print("[Network] Peer 已连接: ", id)

func _on_peer_disconnected(id: int) -> void:
	if is_host:
		guest_connected = false
		player_disconnected.emit()
	remote_peer_id = 0
	print("[Network] Peer 已断开: ", id)

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
		peer.disconnect_peer(sender_id)

@rpc("authority", "reliable")
func _code_result(ok: bool) -> void:
	code_verified.emit(ok)
	if not ok:
		await get_tree().create_timer(0.5).timeout
		close_room()

@rpc("any_peer", "unreliable_ordered")
func _receive_voice_packet(packet: PackedByteArray) -> void:
	if packet.is_empty():
		return
	var sender_id = multiplayer.get_remote_sender_id()
	if not is_trusted_sender(sender_id):
		return
	VoiceChatManager.push_remote_voice_packet(packet)

# ══════════════════════════════════════════════
#  开始游戏 (RPC)
# ══════════════════════════════════════════════

@rpc("authority", "reliable", "call_local")
func start_game_all(host_role: int) -> void:
	# [新增] 在场景切换前标记为多人游戏
	is_multiplayer_game = true
	if multiplayer.is_server():
		GameManager.current_role = host_role
	else:
		if host_role == GameManager.ROLE_BLIND:
			GameManager.current_role = GameManager.ROLE_LAME
		else:
			GameManager.current_role = GameManager.ROLE_BLIND
	print("[Network] start_game_all: role=", GameManager.current_role, " is_mp=", is_multiplayer_game, " peer=", peer)
	GameManager.reset_game()
	get_tree().change_scene_to_file("res://scenes/game_world.tscn")

func host_start_game(host_role: int) -> void:
	if is_host and guest_connected:
		start_game_all.rpc(host_role)
