# 瘸子玩家脚本 - 控制瘸子角色的交互和疼痛系统
# [已修改] 增加 is_local 标记，区分本地/远程
# [已修改] 远程玩家禁用相机和UI，仅接收旋转同步
# [已修改] 本地玩家每帧广播旋转和疼痛值
# [修复] 瘸子世界坐标始终跟随瞎子，不独立移动

extends CharacterBody3D

@export var mouse_sensitivity: float = 0.003  # 鼠标灵敏度

# [新增] 多人标记 - 由 game_world.gd 在 add_child 之前设置
var is_local: bool = false

# [新增] 瞎子玩家引用 - 用于位置跟随
var _blind_ref: Node3D = null

# 场景节点引用
@onready var camera: Camera3D = $Camera3D
@onready var pain_bar: ProgressBar = $UI/Stats/PainBar
@onready var pain_label: Label = $UI/Stats/PainLabel
@onready var voice_label: Label = $UI/Stats/VoiceLabel
@onready var pain_overlay: ColorRect = $UI/PainOverlay
@onready var msg_label: Label = $UI/MsgLabel

# 初始化函数
func _ready() -> void:
	print("[LamePlayer] _ready: is_local=", is_local)
	if not is_local:
		# 远程玩家：禁用摄像机，防止抢夺视野 
		camera.current = false
		# 禁用本地 UI 
		for child in $UI.get_children():
			if child is CanvasItem: child.visible = false
		return
	
	# ── 仅本地玩家执行 ──
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# 寻找本地瞎子引用以便跟随
	_blind_ref = get_parent().get_node_or_null("BlindPlayer")

# 输入处理函数
func _unhandled_input(event: InputEvent) -> void:
	if not is_local:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		camera.rotate_x(-event.relative.y * mouse_sensitivity)
		camera.rotation.x = clampf(camera.rotation.x, -1.5, 1.5)
	if event.is_action_pressed("interact"):
		_try_interact()




func _physics_process(delta: float) -> void:
	# 1. 核心保护：如果不是本地玩家，绝对不执行任何计算逻辑
	# 远程实体的位置和旋转完全交给下面的 RPC 函数来被动修改
	if not is_local:
		return
		
	# 2. 游戏状态检查
	if GameManager.is_game_over:
		return

	# 3. 核心跟随逻辑（仅本地瘸子执行）
	# 确保自己始终粘在瞎子身上
	if _blind_ref == null or not is_instance_valid(_blind_ref):
		_blind_ref = get_node_or_null("../BlindPlayer")
		
	if _blind_ref and is_instance_valid(_blind_ref):
		global_position = _blind_ref.global_position

	# 4. 状态更新
	GameManager.update_pain(delta)
	
	# 5. 多人同步：广播自己的状态
	# 我们只广播旋转（Y轴身子，X轴相机）和疼痛值
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
	var voice_pct = int(GameManager.get_voice_multiplier() * 100)
	voice_label.text = "语音音量: " + str(voice_pct) + "% | 常开麦"
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
