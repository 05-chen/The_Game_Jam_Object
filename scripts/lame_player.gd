# 瘸子玩家脚本 - 控制瘸子角色的交互和疼痛系统

# 基本属性设置
extends CharacterBody3D

@export var mouse_sensitivity: float = 0.003  # 鼠标灵敏度

# 场景节点引用
@onready var camera: Camera3D = $Camera3D  # 相机节点
@onready var pain_bar: ProgressBar = $UI/Stats/PainBar  # 疼痛值条
@onready var pain_label: Label = $UI/Stats/PainLabel  # 疼痛值标签
@onready var voice_label: Label = $UI/Stats/VoiceLabel  # 语音音量标签
@onready var pain_overlay: ColorRect = $UI/PainOverlay  # 疼痛效果覆盖层
@onready var msg_label: Label = $UI/MsgLabel  # 消息标签

# 初始化函数 - 游戏开始时执行
func _ready() -> void:
	# 捕获鼠标
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# 连接游戏事件信号
	GameManager.pain_value_changed.connect(_on_pain)
	GameManager.game_over_triggered.connect(_on_over)
	GameManager.medicine_collected.connect(_on_med)
	GameManager.puzzle_solved.connect(_on_puzzle)

# 输入处理函数 - 处理鼠标和键盘输入
func _unhandled_input(event: InputEvent) -> void:
	# 处理鼠标移动（视角控制）
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)  # 左右旋转
		camera.rotate_x(-event.relative.y * mouse_sensitivity)  # 上下旋转
		camera.rotation.x = clampf(camera.rotation.x, -1.5, 1.5)  # 限制上下视角
	# 处理交互按键
	if event.is_action_pressed("interact"):
		_try_interact()

# 物理处理函数 - 每帧执行
func _physics_process(delta: float) -> void:
	# 游戏结束时停止处理
	if GameManager.is_game_over:
		return
	# 更新疼痛值
	GameManager.update_pain(delta)

# 疼痛值变化处理函数
func _on_pain(value: float) -> void:
	# 更新UI显示
	pain_bar.value = value
	pain_label.text = "疼痛值: " + str(int(value)) + "%"
	# 计算并显示语音音量
	var voice_pct = int(GameManager.get_voice_multiplier() * 100)
	voice_label.text = "语音音量: " + str(voice_pct) + "%"
	# 疼痛效果覆盖层
	if value > 60.0:
		# 疼痛值超过60%时显示红色覆盖层
		var intensity = (value - 60.0) / 40.0 * 0.3  # 计算覆盖层透明度
		pain_overlay.color = Color(1, 0, 0, intensity)
	else:
		# 疼痛值较低时隐藏覆盖层
		pain_overlay.color = Color(1, 0, 0, 0)

# 交互尝试函数 - 检测和处理与物体的交互
func _try_interact() -> void:
	# 获取物理空间
	var space = get_world_3d().direct_space_state
	# 射线检测起点和终点（比瞎子角色更远的检测距离）
	var from = camera.global_position
	var to = from - camera.global_transform.basis.z * 5.0
	# 创建射线检测参数
	var params = PhysicsRayQueryParameters3D.create(from, to, 8)
	# 执行射线检测
	var hit = space.intersect_ray(params)
	# 处理检测结果
	if hit.size() > 0:
		var obj = hit["collider"]
		# 如果物体有interact方法，则调用它
		if obj.has_method("interact"):
			obj.interact(GameManager.ROLE_LAME)

# 游戏结束处理函数
func _on_over(won: bool) -> void:
	# 显示鼠标
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# 根据游戏结果显示不同消息
	if won:
		msg_label.text = "逃离成功!"
	else:
		msg_label.text = "游戏结束..."
	# 显示消息
	msg_label.visible = true

# 药物收集处理函数
func _on_med(role: int) -> void:
	# 只有当药物是给瘸子角色时才显示消息
	if role == GameManager.ROLE_LAME:
		_show_msg("止疼药已服用! 疼痛值降低!")

# 谜题解决处理函数
func _on_puzzle(total: int) -> void:
	# 显示谜题解决消息，包含进度
	_show_msg("谜题已解开! (" + str(total) + "/" + str(GameManager.puzzles_required) + ")")

# 消息显示函数 - 显示临时消息
func _show_msg(text: String) -> void:
	# 设置消息文本
	msg_label.text = text
	# 显示消息
	msg_label.visible = true
	# 创建动画，2秒后隐藏消息
	var tw = create_tween()
	tw.tween_interval(2.0)
	tw.tween_callback(func() -> void: msg_label.visible = false)

# 获取角色类型函数
func get_role() -> int:
	return GameManager.ROLE_LAME
