# 网络管理器脚本 - 终极清爽修复版
extends Node

# ── 常量 ──
const MAX_MEMBERS = 2

# ── 网络状态 ──
var steam_id: int = 0
var lobby_id: int = 0
var peer: SteamMultiplayerPeer = null
var invite_code: String = ""
var is_host: bool = false
var guest_connected: bool = false
var remote_peer_id: int = 0
var _steam_ok: bool = false
var is_multiplayer_game: bool = false
var steam_name: String = "" # 添加这一行

# ── 信号 ──
signal player_connected()
signal player_disconnected()
signal connection_failed()
signal connection_succeeded()
signal code_verified(ok: bool)
signal steam_init_failed()

func _ready() -> void:
	_init_steam()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)


func _init_steam() -> void:
	# 【关键修改】不再只是检测，而是主动初始化
	# 这行代码会尝试启动 Steam 接口
	var init_result: Dictionary = Steam.steamInitEx()
	
	# 检查初始化结果（status 为 0 表示成功）
	if init_result["status"] == 0:
		_steam_ok = true
		steam_id = Steam.getSteamID()
		steam_name = Steam.getPersonaName()
		print("[Steam] 手动初始化成功: ", steam_name, " (ID: ", steam_id, ")")
		
		# 2. 第二步：连接信号（这部分保持你原有的逻辑，非常正确）
		if Steam.lobby_created.is_connected(_on_lobby_created):
			Steam.lobby_created.disconnect(_on_lobby_created)
		Steam.lobby_created.connect(_on_lobby_created)
		
		if Steam.lobby_joined.is_connected(_on_lobby_joined):
			Steam.lobby_joined.disconnect(_on_lobby_joined)
		Steam.lobby_joined.connect(_on_lobby_joined)
		
		if Steam.lobby_match_list.is_connected(_on_lobby_match_list):
			Steam.lobby_match_list.disconnect(_on_lobby_match_list)
		Steam.lobby_match_list.connect(_on_lobby_match_list)
		
	else:
		# 如果初始化失败（比如 Steam 没开），会打印具体的失败原因
		_steam_ok = false
		print("[Steam] 初始化失败，原因: ", init_result["verbal"])
		steam_init_failed.emit()
		
func is_steam_ready() -> bool:
	return _steam_ok

func is_trusted_sender(sender_id: int) -> bool:
	if not is_multiplayer_game: return false
	if multiplayer.is_server(): return sender_id == remote_peer_id
	return sender_id == 1

func send_voice_packet(packet: PackedByteArray) -> void:
	if not is_multiplayer_game or packet.is_empty(): return
	if multiplayer.is_server():
		if remote_peer_id != 0: _receive_voice_packet.rpc_id(remote_peer_id, packet)
	else:
		_receive_voice_packet.rpc_id(1, packet)

func generate_code() -> String:
	var chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var code = ""
	for i in range(6): code += chars[randi() % chars.length()]
	return code

func create_room() -> String:
	if not _steam_ok: return ""
	invite_code = generate_code()
	is_host = true
	guest_connected = false
	Steam.createLobby(Steam.LOBBY_TYPE_PUBLIC, MAX_MEMBERS)
	return invite_code

func _on_lobby_created(result: int, this_lobby_id: int) -> void:
	if result != 1:
		is_host = false
		return
	lobby_id = this_lobby_id
	Steam.setLobbyData(lobby_id, "invite_code", invite_code)
	Steam.setLobbyData(lobby_id, "game_name", "blind_and_lame")
	peer = SteamMultiplayerPeer.new()
	peer.create_host(0)
	multiplayer.multiplayer_peer = peer

func join_room_by_code(code: String) -> bool:
	if not _steam_ok: return false
	invite_code = code.to_upper()
	is_host = false
	Steam.addRequestLobbyListStringFilter("game_name", "blind_and_lame", Steam.LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListStringFilter("invite_code", invite_code, Steam.LOBBY_COMPARISON_EQUAL)
	Steam.requestLobbyList()
	return true

# 【核心修复 4】参数名前加下划线，解决 "The parameter 'ip' is never used" 警告
func join_room(_ip: String, code: String) -> bool:
	return join_room_by_code(code)

func _on_lobby_match_list(lobbies: Array) -> void:
	if is_host or lobbies.size() == 0: return
	Steam.joinLobby(lobbies[0])

func _on_lobby_joined(this_lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != 1: return
	lobby_id = this_lobby_id
	if not is_host:
		var host_steam_id = Steam.getLobbyOwner(lobby_id)
		peer = SteamMultiplayerPeer.new()
		peer.create_client(host_steam_id, 0)
		multiplayer.multiplayer_peer = peer

func close_room() -> void:
	is_multiplayer_game = false
	if lobby_id != 0: Steam.leaveLobby(lobby_id)
	multiplayer.multiplayer_peer = null
	peer = null
	remote_peer_id = 0

func _on_peer_connected(id: int) -> void:
	remote_peer_id = id
	if is_host:
		guest_connected = true
		player_connected.emit()

# 【核心修复 5】参数名前加下划线，解决 "The parameter 'id' is never used" 警告
func _on_peer_disconnected(_id: int) -> void:
	if is_host: guest_connected = false
	remote_peer_id = 0
	player_disconnected.emit()

func _on_connected_to_server() -> void:
	rpc_id(1, "_send_code_to_host", invite_code)
	connection_succeeded.emit()

func _on_connection_failed() -> void:
	close_room()
	connection_failed.emit()

@rpc("any_peer", "reliable")
func _send_code_to_host(code: String) -> void:
	if not is_host: return
	var sender_id = multiplayer.get_remote_sender_id()
	if code == invite_code:
		_code_result.rpc_id(sender_id, true)
		code_verified.emit(true)
	else:
		_code_result.rpc_id(sender_id, false)
		peer.disconnect_peer(sender_id)

@rpc("authority", "reliable")
func _code_result(ok: bool) -> void:
	code_verified.emit(ok)
	if not ok: close_room()

@rpc("any_peer", "unreliable_ordered")
func _receive_voice_packet(packet: PackedByteArray) -> void:
	if packet.is_empty(): return
	var sender_id = multiplayer.get_remote_sender_id()
	if is_trusted_sender(sender_id):
		VoiceChatManager.push_remote_voice_packet(packet)

@rpc("authority", "reliable", "call_local")
func start_game_all(host_role: int) -> void:
	is_multiplayer_game = true
	if multiplayer.is_server():
		GameManager.current_role = host_role
	else:
		GameManager.current_role = GameManager.ROLE_LAME if host_role == GameManager.ROLE_BLIND else GameManager.ROLE_BLIND
	GameManager.reset_game()
	get_tree().change_scene_to_file("res://scenes/game_world.tscn")

func host_start_game(host_role: int) -> void:
	if is_host and guest_connected:
		start_game_all.rpc(host_role)

# 添加此函数，用于每帧刷新 Steam 的底层信号
func _process(_delta: float) -> void:
	# 只有当 Steam 正常运行时才刷新
	if _steam_ok:
		Steam.run_callbacks()
