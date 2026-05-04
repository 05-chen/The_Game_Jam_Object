# 瘸子玩家脚本 - 控制瘸子角色的交互和疼痛系统
# [已修改] 增加 is_local 标记，区分本地/远程
# [已修改] 远程玩家禁用相机和UI，仅接收旋转同步
# [已修改] 本地玩家每帧广播旋转和疼痛值
# [修复] 瘸子世界坐标始终跟随瞎子，不独立移动
# TODO (Network Optimization): 待优化 - 增加远端状态快照队列与插值/缓冲，进一步平滑高延迟下的旋转与表现层同步。
# TODO (Network Optimization): 待优化 - 统一交互链路为“客户端请求 -> Authority 校验 -> 全局广播结果”，避免未来交互对象出现本地先行生效。

extends CharacterBody3D

@export var mouse_sensitivity: float = 0.003  # 鼠标灵敏度

# [新增] 多人标记 - 由 game_world.gd 在 add_child 之前设置
var is_local: bool = false

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
	print("[LamePlayer] _ready: is_local=", is_local, " current_role=", GameManager.current_role)
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
	
	# 5. 多人同步：仅广播旋转和疼痛值（不做位移同步）
	if NetworkManager.is_multiplayer_game:
		_sync_lame.rpc(rotation.y, camera.rotation.x, GameManager.pain_value)


# [修复版] 瘸子状态同步 RPC
@rpc("any_peer", "unreliable_ordered", "call_remote")
func _sync_lame(rot_y: float, cam_x: float, pain: float) -> void:
	# 【关键修改 1】如果是本地控制者，直接忽略来自网络的同步包，防止动作抖动
	if is_local:
		return

	# 安全检查
	if NetworkManager.is_multiplayer_game:
		var sender_id = multiplayer.get_remote_sender_id()
		if not NetworkManager.is_trusted_sender(sender_id):
			return

	# 更新远程实体的外观
	rotation.y = rot_y
	if camera:
		camera.rotation.x = cam_x
	
	# 【关键修改 2】仅更新显示效果，不改全局变量，防止逻辑冲突
	# 调用你 lame_player.gd 里已有的处理函数来更新进度条和红屏效果
	_on_pain(pain)


# 疼痛值变化处理函数
func _on_pain(value: float) -> void:
	pain_bar.value = value
	pain_label.text = "疼痛值: " + str(int(value)) + "%"
	var voice_mul := GameManager.get_voice_multiplier_from_pain(value)
	var voice_pct := int(voice_mul * 100.0)
	if value >= 80.0:
		voice_label.text = "语音状态: 失效 (>=80)"
	elif value >= 40.0:
		voice_label.text = "语音音量: " + str(voice_pct) + "% | 疼痛衰减"
	else:
		voice_label.text = "语音音量: 100% | 常开麦"

	if is_local:
		VoiceChatManager.set_local_pain_voice_policy(value)
	else:
		VoiceChatManager.set_remote_pain_voice_policy(value)

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

# 获取角色类型函数
func get_role() -> int:
	return GameManager.ROLE_LAME
