# 瘸子玩家脚本 - 控制瘸子角色的交互和疼痛系统
# [已修改] 增加 is_local 标记，区分本地/远程
# [已修改] 远程玩家禁用相机和UI
# [已修改] 疼痛值按阈值/Tier/心跳做不可靠同步；视角仅本地
# [修复] 瘸子世界坐标始终跟随瞎子，不独立移动
# TODO (Network Optimization): 待优化 - 增加远端状态快照队列与插值/缓冲，进一步平滑高延迟下的旋转与表现层同步。
# TODO (Network Optimization): 待优化 - 统一交互链路为“客户端请求 -> Authority 校验 -> 全局广播结果”，避免未来交互对象出现本地先行生效。

extends CharacterBody3D

@export var mouse_sensitivity: float = 0.003  # 鼠标灵敏度

# [新增] 多人标记 - 由 game_world.gd 在 add_child 之前设置
var is_local: bool = false
# 语音阶梯同步：仅 Tier 变化时发 RPC，避免每帧传音量
var last_synced_tier: int = -1
# 疼痛网络快照：阈值 / Tier / 心跳，避免每物理帧发包
var _last_sent_pain_for_net: float = -9999.0
var _last_sent_tier_for_net: int = -9999
var _last_pain_net_rpc_at_ms: int = 0
const PAIN_NET_DELTA_MIN: float = 5.0
const PAIN_NET_HEARTBEAT_MS: int = 1100

# [新增] 背负锚点引用 - 用于强制跟随 BlindPlayer/CarryAnchor
var _carry_anchor_ref: Node3D = null
@export var carry_follow_lerp_speed: float = 12.0

# 场景节点引用
@onready var camera: Camera3D = $Camera3D
@onready var ui_root: CanvasLayer = $UI
@onready var pain_bar: ProgressBar = $UI/Stats/PainBar
@onready var pain_label: Label = $UI/Stats/PainLabel
@onready var voice_label: Label = $UI/Stats/VoiceLabel
@onready var pain_overlay: ColorRect = $UI/PainOverlay
@onready var msg_label: Label = $UI/MsgLabel

# 初始化函数
func _ready() -> void:
	add_to_group("player")
	# 无论本地/远程，都禁用瘸子的碰撞，避免干扰瞎子移动
	collision_layer = 0
	collision_mask = 0
	if has_node("Col"):
		$Col.set_deferred("disabled", true)
	# 预缓存 CarryAnchor 引用
	_carry_anchor_ref = get_node_or_null("../BlindPlayer/CarryAnchor")
	if not is_local:
		camera.current = false
		if ui_root:
			ui_root.visible = false
		else:
			for child in $UI.get_children():
				if child is CanvasItem:
					child.visible = false
		return
	if GameManager.current_role != GameManager.ROLE_LAME:
		camera.current = false
		if ui_root:
			ui_root.visible = false
		return
	if ui_root:
		ui_root.visible = true
	camera.current = true
	camera.make_current()
	var listener := AudioListener3D.new()
	camera.add_child(listener)
	listener.make_current()
	if pain_overlay:
		pain_overlay.color = Color(1, 0, 0, 0)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	GameManager.pain_value_changed.connect(_on_pain)
	GameManager.game_over_triggered.connect(_on_over)
	GameManager.medicine_collected.connect(_on_med)
	GameManager.puzzle_solved.connect(_on_puzzle)
	_on_pain(GameManager.pain_value)

# 输入处理函数
func _unhandled_input(event: InputEvent) -> void:
	if not is_local or not GameManager.is_game_active:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		camera.rotate_x(-event.relative.y * mouse_sensitivity)
		camera.rotation.x = clampf(camera.rotation.x, -1.5, 1.5)
	if event.is_action_pressed("interact"):
		_try_interact()




func _physics_process(delta: float) -> void:
	# 1. 每帧强制跟随 BlindPlayer/CarryAnchor（本地与远程都执行）
	if _carry_anchor_ref == null or not is_instance_valid(_carry_anchor_ref):
		_carry_anchor_ref = get_node_or_null("../BlindPlayer/CarryAnchor")
	if _carry_anchor_ref and is_instance_valid(_carry_anchor_ref):
		# 只同步位置，保留本地旋转与镜头控制；使用插值减少网络抖动
		var target_pos := _carry_anchor_ref.global_position
		var weight := clampf(delta * carry_follow_lerp_speed, 0.0, 1.0)
		global_position = global_position.lerp(target_pos, weight)

	if not is_local:
		return
	if not GameManager.is_game_active or GameManager.is_game_over:
		return

	GameManager.update_pain(delta)

	if NetworkManager.is_multiplayer_game:
		_maybe_network_sync_pain()


func _maybe_network_sync_pain() -> void:
	var p := GameManager.pain_value
	var tier := GameManager.pain_to_voice_tier(p)
	var now := Time.get_ticks_msec()
	var delta_big := absf(p - _last_sent_pain_for_net) >= PAIN_NET_DELTA_MIN
	var tier_changed := tier != _last_sent_tier_for_net
	var heartbeat := now - _last_pain_net_rpc_at_ms >= PAIN_NET_HEARTBEAT_MS
	if not (delta_big or tier_changed or heartbeat):
		return
	_last_sent_pain_for_net = p
	_last_sent_tier_for_net = tier
	_last_pain_net_rpc_at_ms = now
	_sync_lame_pain.rpc(p)


# 仅同步疼痛 UI；视角完全本地，不跨网络传旋转
@rpc("any_peer", "unreliable_ordered", "call_remote")
func _sync_lame_pain(pain: float) -> void:
	if is_local:
		return
	if NetworkManager.is_multiplayer_game:
		var sender_id := multiplayer.get_remote_sender_id()
		if not NetworkManager.is_trusted_sender(sender_id):
			return
	_on_pain(pain)


# 疼痛值变化处理函数
func _on_pain(value: float) -> void:
	pain_bar.value = value
	pain_label.text = "疼痛值: " + str(int(value)) + "%"
	var tier := GameManager.pain_to_voice_tier(value)
	var voice_mul := GameManager.voice_tier_to_linear_gain(tier)
	var voice_pct := int(voice_mul * 100.0)
	match tier:
		0:
			voice_label.text = "语音阶梯: Tier0 | 疼痛满值 | 静音/本机禁发"
		1:
			voice_label.text = "语音阶梯: Tier1 | 疼痛80~100 | 远端约 -20dB (" + str(voice_pct) + "%)"
		2:
			voice_label.text = "语音阶梯: Tier2 | 疼痛50~80 | 远端约 -12dB (" + str(voice_pct) + "%)"
		3:
			voice_label.text = "语音阶梯: Tier3 | 疼痛20~50 | 远端约 -6dB (" + str(voice_pct) + "%)"
		_:
			voice_label.text = "语音阶梯: Tier4 | 疼痛0~20 | 远端 0dB | 疼痛低音量最大"

	if is_local:
		VoiceChatManager.set_local_pain_voice_policy(value)
		if GameManager.current_role == GameManager.ROLE_LAME:
			VoiceChatManager.set_voice_transmit_enabled(tier != 0)
			if NetworkManager.is_multiplayer_game:
				if tier != last_synced_tier:
					last_synced_tier = tier
					c_sync_voice_volume.rpc(tier)
			else:
				last_synced_tier = tier
	elif not is_local:
		# 仅远程代理更新 UI；对端听到的阶梯音量由 c_sync_voice_volume 同步，避免每帧用疼痛重算带宽
		pass

	if value > 60.0:
		var intensity = (value - 60.0) / 40.0 * 0.3
		pain_overlay.color = Color(1, 0, 0, intensity)
	else:
		pain_overlay.color = Color(1, 0, 0, 0)

# 交互尝试函数
func _try_interact() -> void:
	var space = get_world_3d().direct_space_state
	var from = camera.global_position
	var to = from - camera.global_transform.basis.z * 5.0
	var params = PhysicsRayQueryParameters3D.create(from, to, 8)
	var hit = space.intersect_ray(params)
	if hit.size() > 0:
		var obj = hit["collider"]
		if obj.has_method("interact"):
			obj.interact(GameManager.ROLE_LAME)

# 游戏结束处理函数
func _on_over(won: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if won:
		msg_label.text = "逃离成功!"
	else:
		msg_label.text = "游戏结束..."
	msg_label.visible = true

# 药物收集处理函数
func _on_med(role: int) -> void:
	if role == GameManager.ROLE_LAME:
		_show_msg("止疼药已服用! 疼痛值降低!")

# 谜题解决处理函数
func _on_puzzle(total: int) -> void:
	_show_msg("谜题已解开! (" + str(total) + "/" + str(GameManager.puzzles_required) + ")")

# 消息显示函数
func _show_msg(text: String) -> void:
	msg_label.text = text
	msg_label.visible = true
	var tw = create_tween()
	tw.tween_interval(2.0)
	tw.tween_callback(func() -> void: msg_label.visible = false)

@rpc("any_peer", "reliable", "call_remote")
func c_sync_voice_volume(tier: int) -> void:
	if not NetworkManager.is_multiplayer_game:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not NetworkManager.is_trusted_sender(sender_id):
		return
	VoiceChatManager.set_remote_voice_tier(tier)


# 获取角色类型函数
func get_role() -> int:
	return GameManager.ROLE_LAME
