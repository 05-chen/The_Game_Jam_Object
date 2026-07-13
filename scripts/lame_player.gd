# 瘸子玩家脚本 - 控制瘸子角色的交互和疼痛系统
# [已修改] 增加 is_local 标记，区分本地/远程
# [已修改] 远程玩家禁用相机和UI
# [已修改] 疼痛值按阈值/Tier/心跳做不可靠同步；视角仅本地
# [修复] 瘸子世界坐标始终跟随瞎子，不独立移动
#
# ── 碰撞与跟随（「瞎子背瘸子」）──
# - 瘸子为「无碰撞影子」：collision_layer/mask = 0，Col 禁用，不调用 move_and_slide。
# - 挡墙、滑墙、贴地全部由 BlindPlayer 的胶囊体 + move_and_slide() 负责。
# - 瘸子每帧平滑跟随 BlindPlayer/CarryAnchor（主机与客机同一套插值，避免一端瞬移一端 lerp 手感不一致）。
# - 项目物理层约定：layer 1 = environment（关卡 StaticBody3D），layer 2 = player（瞎子）。
# TODO (Network Optimization): 待优化 - 增加远端状态快照队列与插值/缓冲，进一步平滑高延迟下的旋转与表现层同步。
# TODO (Network Optimization): 待优化 - 统一交互链路为“客户端请求 -> Authority 校验 -> 全局广播结果”，避免未来交互对象出现本地先行生效。

extends CharacterBody3D

@export var mouse_sensitivity: float = 0.003  # 鼠标灵敏度

@export_group("拾取范围")
## 横向半径倍数（瘸子背在肩上，默认比瞎子更大）
@export_range(0.2, 4.0, 0.05) var pickup_radius_scale: float = 2.0
## 身前最大距离倍数
@export_range(0.2, 3.0, 0.05) var pickup_forward_scale: float = 1.35
## 探测原点下移（米）：相机在肩上，下移后才能够地面药品
@export_range(0.0, 2.5, 0.05) var pickup_origin_lower_m: float = 1.5
## 垂直容忍半高（米）：越大越能拾取脚下/低处物品
@export_range(0.1, 2.5, 0.05) var pickup_vertical_half_m: float = 1.5
## 勾选后在运行中显示半透明拾取圆柱与数值
@export var pickup_show_debug: bool = false

## 与瞎子共用跳跃高度常量；瘸子位移由 CarryAnchor 跟随，不单独做物理跳跃
const PAIN_LERP_SPEED: float = 10.0

var is_local: bool = false
var is_spawning: bool = true
var _display_pain: float = 0.0
# 疼痛网络快照：阈值 / Tier / 心跳，避免每物理帧发包
var _last_sent_pain_for_net: float = -9999.0
var _last_sent_tier_for_net: int = -9999
var _last_pain_net_rpc_at_ms: int = 0
const PAIN_NET_DELTA_MIN: float = 5.0
const PAIN_NET_HEARTBEAT_MS: int = 1100

# [新增] 背负锚点引用 - 用于强制跟随 BlindPlayer/CarryAnchor
var _carry_anchor_ref: Node3D = null
## 平滑跟随速度（指数插值系数，帧率无关）。越大贴得越紧；仍觉滞后可试 22~25。
@export var carry_follow_lerp_speed: float = 18.0
## 与 CarryAnchor 距离超过此值时瞬移贴合（切关/传送）；平时走平滑插值，避免主机/客机卡顿感。
@export var carry_snap_distance: float = 3.0

# 场景节点引用
@onready var camera: Camera3D = $Camera3D
@onready var ui_root: CanvasLayer = $UI
@onready var pain_bar: ProgressBar = $UI/Stats/PainBar
@onready var pain_label: Label = $UI/Stats/PainLabel
@onready var voice_label: Label = $UI/Stats/VoiceLabel
@onready var pain_overlay: ColorRect = $UI/PainOverlay
@onready var msg_label: Label = $UI/MsgLabel
var _pickup_debug_root: Node3D = null

# 初始化函数
func _ready() -> void:
	add_to_group("player")
	if pain_overlay:
		pain_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 无碰撞影子：不参与挡墙/挤压，物理阻挡完全交给 BlindPlayer（见 blind_player.gd）
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
	# 仅本地瘸子：疼痛 UI 与 GameManager.pain_value 信号绑定（语音 Tier 由 VoiceChatManager 监听同一信号）
	GameManager.pain_value_changed.connect(_update_lame_pain_ui)
	GameManager.game_over_triggered.connect(_on_over)
	GameManager.medicine_collected.connect(_on_med)
	GameManager.puzzle_solved.connect(_on_puzzle)
	_update_lame_pain_ui(GameManager.pain_value)
	_display_pain = GameManager.pain_value
	if _can_control_local_camera():
		InputMouseGuard.capture_for_local_player()
	if pickup_show_debug and is_local and GameManager.current_role == GameManager.ROLE_LAME:
		_pickup_debug_root = PlayerPickupUtil.ensure_debug_root(self)


func get_pickup_probe_config() -> Dictionary:
	return {
		"radius_scale": pickup_radius_scale,
		"forward_scale": pickup_forward_scale,
		"origin_lower_m": pickup_origin_lower_m,
		"vertical_half_m": pickup_vertical_half_m,
		"use_camera_origin": true,
	}


func _on_spawning_finished() -> void:
	velocity = Vector3.ZERO
	if _can_control_local_camera():
		InputMouseGuard.capture_for_local_player()

# 输入处理函数
func _unhandled_input(event: InputEvent) -> void:
	if not _can_control_local_camera():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_apply_look(event.relative)
	if event.is_action_pressed("interact"):
		_try_interact()


func _can_control_local_camera() -> bool:
	return is_local \
		and not is_spawning \
		and GameManager.is_game_active \
		and not GameManager.is_game_over \
		and GameManager.current_role == GameManager.ROLE_LAME \
		and not GameManager.is_paused


func _process(delta: float) -> void:
	if GameManager.is_paused:
		return
	if is_local and GameManager.current_role == GameManager.ROLE_LAME:
		var target_pain := GameManager.target_pain_value
		if not NetworkManager.is_multiplayer_game or _is_local_lame_pain_authority():
			target_pain = GameManager.pain_value
		_display_pain = lerpf(_display_pain, target_pain, clampf(PAIN_LERP_SPEED * delta, 0.0, 1.0))
		_apply_pain_overlay_from_display()
	if pickup_show_debug and is_local and GameManager.current_role == GameManager.ROLE_LAME:
		PlayerPickupUtil.sync_debug_visual(self, _pickup_debug_root, false)


func _apply_look(relative: Vector2) -> void:
	rotate_y(-relative.x * mouse_sensitivity)
	camera.rotate_x(-relative.y * mouse_sensitivity)
	camera.rotation.x = clampf(camera.rotation.x, -1.5, 1.5)




func _physics_process(delta: float) -> void:
	if is_spawning:
		velocity = Vector3.ZERO
		return
	if GameManager.is_paused:
		velocity = Vector3.ZERO
		return
	_sync_to_carry_anchor(delta)
	if not is_local:
		return
	if not GameManager.is_game_active or GameManager.is_game_over:
		return
	GameManager.update_pain(delta)
	if NetworkManager.is_multiplayer_game:
		_maybe_network_sync_pain()


## 平滑跟随 CarryAnchor：主机/客机统一指数插值；无碰撞，不参与挡墙。
## 公式 weight = 1 - exp(-carry_follow_lerp_speed * delta)，比线性 lerp 更顺且不依赖帧率。
func _sync_to_carry_anchor(delta: float) -> void:
	if _carry_anchor_ref == null or not is_instance_valid(_carry_anchor_ref):
		_carry_anchor_ref = get_node_or_null("../BlindPlayer/CarryAnchor")
	if _carry_anchor_ref == null or not is_instance_valid(_carry_anchor_ref):
		return
	var target_pos := _carry_anchor_ref.global_position
	# 切关/传送等超大位移：直接贴合，避免从远处慢慢飘过来
	if global_position.distance_to(target_pos) >= carry_snap_distance:
		global_position = target_pos
	else:
		var weight := 1.0 - exp(-carry_follow_lerp_speed * delta)
		global_position = global_position.lerp(target_pos, clampf(weight, 0.0, 1.0))
	velocity = Vector3.ZERO


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


## 联机：call_remote，接收端镜像 pain/target（模拟端本地仍每帧 update_pain，不增发包）
@rpc("any_peer", "unreliable_ordered", "call_remote")
func _sync_lame_pain(pain: float) -> void:
	if not NetworkManager.is_multiplayer_game:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not NetworkManager.is_trusted_sender(sender_id):
		return
	GameManager.sync_pain_target_from_network(pain)


## 本地瘸子端负责 pain 公式模拟（主机/客户端谁扮演瘸子谁权威，与瞎子「主机算移动」对称）
func _is_local_lame_pain_authority() -> bool:
	return is_local and GameManager.current_role == GameManager.ROLE_LAME


# 仅本地瘸子：刷新疼痛条/遮罩/说明文字（语音由 VoiceChatManager + pain_value_changed 驱动）
func _update_lame_pain_ui(value: float) -> void:
	if is_local and GameManager.current_role == GameManager.ROLE_LAME:
		# 本地瘸子（模拟端）：HUD 跟权威 pain_value；对端靠 lerp target
		if not NetworkManager.is_multiplayer_game or _is_local_lame_pain_authority():
			_display_pain = value
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
	_apply_pain_overlay_from_display()


func _apply_pain_overlay_from_display() -> void:
	if pain_overlay == null or not is_local:
		return
	var value := _display_pain
	if value > 60.0:
		var intensity := (value - 60.0) / 40.0 * 0.3
		pain_overlay.color = Color(1, 0, 0, intensity)
	else:
		pain_overlay.color = Color(1, 0, 0, 0)

# 交互尝试函数
func _try_interact() -> void:
	var hit := PlayerPickupUtil.find_best_pickup_target(self, GameManager.ROLE_LAME, false)
	if hit.is_empty():
		return
	var target: Node = hit["target"]
	var from: Vector3 = hit["origin"]
	if target.has_method("interact"):
		target.interact(GameManager.ROLE_LAME, from, true)


func _on_over(won: bool) -> void:
	InputMouseGuard.release_for_ui()
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


# 获取角色类型函数
func get_role() -> int:
	return GameManager.ROLE_LAME
