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
var remote_steam_id: int = 0
var remote_steam_ids: Dictionary = {}
var _steam_ok: bool = false
var is_multiplayer_game: bool = false
var steam_name: String = "" # 添加这一行
var _join_watch_active: bool = false
var _join_deadline_ms: int = 0
var _lobby_query_mode: String = ""
var _join_search_token: int = 0
var _cleanup_in_progress: bool = false
const CONNECT_TIMEOUT_MS: int = 20000
const LOBBY_SYNC_DELAY_SEC: float = 1.0

# ── 信号 ──
signal player_connected()
signal player_disconnected()
signal connection_failed()
signal connection_succeeded()
signal code_verified(ok: bool)
signal steam_init_failed()
signal lobby_search_result(found: bool, matched_count: int)
signal connection_timeout(message: String)
signal session_interrupted(message: String)

var _last_session_interrupt_message: String = ""

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
	print("[Net] create_room() 邀请码=", invite_code)
	Steam.createLobby(Steam.LOBBY_TYPE_PUBLIC, MAX_MEMBERS)
	return invite_code

func _on_lobby_created(result: int, this_lobby_id: int) -> void:
	print("[Net] _on_lobby_created result=", result, " lobby_id=", this_lobby_id)
	if result != 1:
		is_host = false
		connection_failed.emit()
		return
	lobby_id = this_lobby_id
	_refresh_remote_steam_ids_from_lobby()
	var set_code_ok := Steam.setLobbyData(lobby_id, "invite_code", invite_code)
	var set_code_alias_ok := Steam.setLobbyData(lobby_id, "code", invite_code)
	var set_game_ok := Steam.setLobbyData(lobby_id, "game_name", "blind_and_lame")
	Steam.setLobbyData(lobby_id, "ready", "0")
	print("[Net] lobby data set game_name=blind_and_lame invite_code=", invite_code, " set_code_ok=", set_code_ok, " set_code_alias_ok=", set_code_alias_ok, " set_game_ok=", set_game_ok)
	get_tree().create_timer(LOBBY_SYNC_DELAY_SEC).timeout.connect(func() -> void:
		if lobby_id == this_lobby_id:
			var ready_ok := Steam.setLobbyData(lobby_id, "ready", "1")
			print("[Net] lobby ready flag set after delay, ready_ok=", ready_ok, " delay_sec=", LOBBY_SYNC_DELAY_SEC)
	, CONNECT_ONE_SHOT)
	peer = SteamMultiplayerPeer.new()
	var host_err := peer.create_host(0)
	print("[Net] create_host err=", host_err)
	if host_err != OK:
		print("[Net][Error] create_host failed err=", host_err)
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = peer
	print("[Net] host peer created, waiting guest...")

func join_room_by_code(code: String) -> bool:
	if not _steam_ok: return false
	invite_code = code.to_upper()
	is_host = false
	_join_search_token += 1
	var token := _join_search_token
	print("[Net] join_room_by_code() code=", invite_code)
	_start_join_watch("search_lobby")
	print("[Net] wait ", LOBBY_SYNC_DELAY_SEC, "s before search for Steam data sync")
	get_tree().create_timer(LOBBY_SYNC_DELAY_SEC).timeout.connect(func() -> void:
		_request_lobby_list_primary(token)
	, CONNECT_ONE_SHOT)
	return true

# 【核心修复 4】参数名前加下划线，解决 "The parameter 'ip' is never used" 警告
func join_room(_ip: String, code: String) -> bool:
	return join_room_by_code(code)

func _on_lobby_match_list(lobbies: Array) -> void:
	if is_host:
		return
	if _lobby_query_mode == "debug_dump":
		print("[Net][DebugDump] total_lobbies=", lobbies.size(), " (worldwide)")
		if lobbies.is_empty():
			print("[Net][DebugDump] no lobbies found in worldwide snapshot")
		for lobby in lobbies:
			var code_value := String(Steam.getLobbyData(lobby, "code")).to_upper()
			var invite_code_value := String(Steam.getLobbyData(lobby, "invite_code")).to_upper()
			var game_value := String(Steam.getLobbyData(lobby, "game_name"))
			print("[Net][DebugDump] lobby_id=", lobby, " code=", code_value, " invite_code=", invite_code_value, " game_name=", game_value)
		_lobby_query_mode = ""
		_stop_join_watch()
		lobby_search_result.emit(false, 0)
		connection_failed.emit()
		return

	print("[Net] _on_lobby_match_list count=", lobbies.size(), " mode=", _lobby_query_mode)
	if lobbies.size() == 0:
		print("[Net][Warn] filtered result is empty, trigger worldwide debug snapshot")
		_request_lobby_list_debug_dump()
		return

	var matched_lobby_id: int = 0
	for lobby in lobbies:
		var code_value: String = String(Steam.getLobbyData(lobby, "code")).to_upper()
		var invite_code_value: String = String(Steam.getLobbyData(lobby, "invite_code")).to_upper()
		var game_value: String = String(Steam.getLobbyData(lobby, "game_name"))
		var ready_value: String = String(Steam.getLobbyData(lobby, "ready"))
		print("[Net] lobby candidate id=", lobby, " game_name=", game_value, " code=", code_value, " invite_code=", invite_code_value, " ready=", ready_value)
		if ready_value != "1":
			print("[Net] skip lobby id=", lobby, " because ready != 1")
			continue
		if game_value == "blind_and_lame" and (code_value == invite_code or invite_code_value == invite_code):
			matched_lobby_id = lobby
			break

	if matched_lobby_id == 0:
		print("[Net][Error] no matched lobby for invite_code=", invite_code)
		_request_lobby_list_debug_dump()
		return

	_lobby_query_mode = ""
	lobby_search_result.emit(true, 1)
	_start_join_watch("join_lobby")
	Steam.joinLobby(matched_lobby_id)

func _on_lobby_joined(this_lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	print("[Net] _on_lobby_joined response=", response, " lobby_id=", this_lobby_id)
	if response != 1:
		print("[Net][Error] join_lobby failed response_code=", response)
		connection_failed.emit()
		return
	lobby_id = this_lobby_id
	_refresh_remote_steam_ids_from_lobby()
	if not is_host:
		var host_steam_id = Steam.getLobbyOwner(lobby_id)
		remote_steam_id = host_steam_id
		remote_steam_ids[host_steam_id] = true
		print("[Net] join as client, host_steam_id=", host_steam_id)
		peer = SteamMultiplayerPeer.new()
		var client_err := peer.create_client(host_steam_id, 0)
		print("[Net] create_client err=", client_err)
		if client_err != OK:
			print("[Net][Error] connect_to_host failed err=", client_err, " host_steam_id=", host_steam_id)
			connection_failed.emit()
			return
		_start_join_watch("connect_to_host")
		multiplayer.multiplayer_peer = peer

func close_room() -> void:
	hard_cleanup("close_room")

func hard_cleanup(reason: String = "manual") -> void:
	if _cleanup_in_progress:
		return
	_cleanup_in_progress = true
	print("[Net] hard_cleanup reason=", reason)
	
	_stop_join_watch()
	is_multiplayer_game = false
	# 1) 先关闭所有 P2P 会话，避免 listen socket 残留
	_close_steam_p2p_session()
	# 2) 再释放 Godot 的 multiplayer peer
	multiplayer.multiplayer_peer = null
	if peer and peer.has_method("close"):
		peer.close()
	if lobby_id != 0:
		Steam.leaveLobby(lobby_id)
	# 3) 同步硬切语音采集，防止后台残留
	if VoiceChatManager:
		if VoiceChatManager.has_method("stop_voice_capture"):
			VoiceChatManager.stop_voice_capture("close_room")
		elif VoiceChatManager.has_method("shutdown_voice"):
			VoiceChatManager.shutdown_voice("close_room")
	peer = null
	lobby_id = 0
	invite_code = ""
	is_host = false
	guest_connected = false
	remote_peer_id = 0
	remote_steam_id = 0
	remote_steam_ids.clear()
	_lobby_query_mode = ""
	_join_search_token += 1
	_cleanup_in_progress = false

func _on_peer_connected(id: int) -> void:
	remote_peer_id = id
	_refresh_remote_steam_ids_from_lobby()
	_stop_join_watch()
	print("[Net] _on_peer_connected id=", id, " is_host=", is_host, " local_peer_id=", multiplayer.get_unique_id(), " lobby_id=", lobby_id, " steam_id=", steam_id, " remote_peer_id=", remote_peer_id, " remote_steam_ids=", remote_steam_ids.keys())
	if is_host:
		guest_connected = true
		player_connected.emit()

# 【核心修复 5】参数名前加下划线，解决 "The parameter 'id' is never used" 警告
func _on_peer_disconnected(_id: int) -> void:
	print("[Net] _on_peer_disconnected id=", _id, " is_host=", is_host, " local_peer_id=", multiplayer.get_unique_id(), " lobby_id=", lobby_id, " remote_peer_id(before_clear)=", remote_peer_id)
	if is_host: guest_connected = false
	remote_peer_id = 0
	if not is_host and is_multiplayer_game:
		_last_session_interrupt_message = "联机连接已中断，已为你安全返回主菜单。"
		session_interrupted.emit(_last_session_interrupt_message)
		hard_cleanup("peer_disconnected_guest")
	player_disconnected.emit()

func _on_connected_to_server() -> void:
	_stop_join_watch()
	print("[Net] connected_to_server, sending invite code to host")
	if multiplayer.multiplayer_peer == null:
		push_error("[Net] _on_connected_to_server but multiplayer_peer is null")
		connection_failed.emit()
		return
	rpc_id(1, "_send_code_to_host", invite_code)
	connection_succeeded.emit()

func _on_connection_failed() -> void:
	_stop_join_watch()
	print("[Net] _on_connection_failed is_host=", is_host, " lobby_id=", lobby_id, " steam_ok=", _steam_ok, " remote_peer_id=", remote_peer_id, " invite_code=", invite_code)
	_last_session_interrupt_message = "联机连接失败，已为你安全清理网络状态。"
	session_interrupted.emit(_last_session_interrupt_message)
	hard_cleanup("connection_failed")
	connection_failed.emit()

@rpc("any_peer", "reliable")
func _send_code_to_host(code: String) -> void:
	if not is_host: return
	var sender_id = multiplayer.get_remote_sender_id()
	print("[Net] _send_code_to_host sender=", sender_id, " code=", code)
	if code == invite_code:
		_code_result.rpc_id(sender_id, true)
		code_verified.emit(true)
	else:
		_code_result.rpc_id(sender_id, false)
		peer.disconnect_peer(sender_id)

@rpc("authority", "reliable")
func _code_result(ok: bool) -> void:
	print("[Net] _code_result ok=", ok)
	if ok:
		_stop_join_watch()
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
	if VoiceChatManager and VoiceChatManager.has_method("startup_voice"):
		VoiceChatManager.startup_voice("start_game_all")
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
	if _join_watch_active and Time.get_ticks_msec() >= _join_deadline_ms:
		_join_watch_active = false
		print("[Net][Timeout] connection stage timed out, code=", invite_code, " lobby_id=", lobby_id)
		connection_timeout.emit("连接超时，请检查网络或防火墙")
		close_room()
		connection_failed.emit()

func _start_join_watch(stage: String) -> void:
	_join_watch_active = true
	_join_deadline_ms = Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	print("[Net] start join watch stage=", stage, " timeout_ms=", CONNECT_TIMEOUT_MS, " deadline=", _join_deadline_ms)

func _stop_join_watch() -> void:
	if _join_watch_active:
		print("[Net] stop join watch")
	_join_watch_active = false
	_join_deadline_ms = 0

func _request_lobby_list_primary(token: int) -> void:
	if token != _join_search_token:
		return
	if is_host:
		return
	_lobby_query_mode = "primary"
	Steam.addRequestLobbyListDistanceFilter(Steam.LOBBY_DISTANCE_FILTER_WORLDWIDE)
	Steam.addRequestLobbyListStringFilter("game_name", "blind_and_lame", Steam.LOBBY_COMPARISON_EQUAL)
	print("[Net] requestLobbyList primary worldwide search, token=", token)
	Steam.requestLobbyList()

func _request_lobby_list_debug_dump() -> void:
	_lobby_query_mode = "debug_dump"
	Steam.addRequestLobbyListDistanceFilter(Steam.LOBBY_DISTANCE_FILTER_WORLDWIDE)
	print("[Net] requestLobbyList debug worldwide snapshot")
	Steam.requestLobbyList()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		hard_cleanup("wm_close")

func _close_steam_p2p_session() -> void:
	if remote_steam_ids.is_empty() and remote_steam_id == 0:
		return
	var ids_to_close: Array = remote_steam_ids.keys()
	if ids_to_close.is_empty() and remote_steam_id != 0:
		ids_to_close.append(remote_steam_id)
	for sid in ids_to_close:
		var target_id := int(sid)
		if target_id == 0:
			continue
		if Steam.has_method("closeP2PSessionWithUser"):
			Steam.call("closeP2PSessionWithUser", target_id)
			print("[Net] closeP2PSessionWithUser remote_steam_id=", target_id)
		elif Steam.has_method("closeP2PSession"):
			Steam.call("closeP2PSession", target_id)
			print("[Net] closeP2PSession remote_steam_id=", target_id)
		else:
			push_error("[Net] no close P2P API available in current GodotSteam")

func _refresh_remote_steam_ids_from_lobby() -> void:
	if lobby_id == 0:
		return
	if not Steam.has_method("getNumLobbyMembers") or not Steam.has_method("getLobbyMemberByIndex"):
		return
	var member_count := int(Steam.call("getNumLobbyMembers", lobby_id))
	if member_count <= 0:
		return
	for i in range(member_count):
		var sid := int(Steam.call("getLobbyMemberByIndex", lobby_id, i))
		if sid != 0 and sid != steam_id:
			remote_steam_ids[sid] = true
			remote_steam_id = sid

func consume_session_interrupt_message() -> String:
	var msg := _last_session_interrupt_message
	_last_session_interrupt_message = ""
	return msg
