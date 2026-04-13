# 瘸子玩家脚本 - 控制瘸子角色的交互和疼痛系统
# [已修改] 增加 is_local 标记，区分本地/远程
# [已修改] 远程玩家禁用相机和UI，仅接收旋转同步
# [已修改] 本地玩家每帧广播旋转和疼痛值

extends CharacterBody3D

@export var mouse_sensitivity: float = 0.003  # 鼠标灵敏度

# [新增] 多人标记 - 由 game_world.gd 在 add_child 之前设置
var is_local: bool = true

# 场景节点引用
@onready var camera: Camera3D = $Camera3D
@onready var pain_bar: ProgressBar = $UI/Stats/PainBar
@onready var pain_label: Label = $UI/Stats/PainLabel
@onready var voice_label: Label = $UI/Stats/VoiceLabel
@onready var pain_overlay: ColorRect = $UI/PainOverlay
@onready var msg_label: Label = $UI/MsgLabel

# 初始化函数
func _ready() -> void:
	# [新增] 远程玩家：禁用相机和UI
	if not is_local:
		camera.current = false
		for child in $UI.get_children():
			if child is CanvasItem:
				child.visible = false
		return

	# ── 以下仅本地玩家执行 ──
	camera.current = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	GameManager.pain_value_changed.connect(_on_pain)
	GameManager.game_over_triggered.connect(_on_over)
	GameManager.medicine_collected.connect(_on_med)
	GameManager.puzzle_solved.connect(_on_puzzle)

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

# 物理处理函数
func _physics_process(delta: float) -> void:
	# [新增] 远程玩家不处理
	if not is_local:
		return
	if GameManager.is_game_over:
		return
	GameManager.update_pain(delta)
	# [新增] 多人同步：广播位置 + 旋转 + 疼痛值
	if NetworkManager.peer != null:
		_sync_state.rpc(global_position, rotation.y, camera.rotation.x, GameManager.pain_value)

# [新增] 状态同步 RPC - 远程玩家接收
@rpc("any_peer", "unreliable_ordered", "call_remote")
func _sync_state(pos: Vector3, rot_y: float, cam_x: float, pain: float) -> void:
	global_position = pos
	rotation.y = rot_y
	if camera:
		camera.rotation.x = cam_x
	# 同步疼痛值到远程机器
	GameManager.pain_value = pain
	GameManager.pain_value_changed.emit(pain)

# 疼痛值变化处理函数
func _on_pain(value: float) -> void:
	pain_bar.value = value
	pain_label.text = "疼痛值: " + str(int(value)) + "%"
	var voice_pct = int(GameManager.get_voice_multiplier() * 100)
	voice_label.text = "语音音量: " + str(voice_pct) + "%"
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
