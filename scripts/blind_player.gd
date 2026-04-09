# 瞎子玩家脚本 - 控制瞎子角色的移动、视野和交互

# 基本属性设置
extends CharacterBody3D

@export var move_speed: float = 4.0  # 移动速度
@export var mouse_sensitivity: float = 0.003  # 鼠标灵敏度

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")  # 重力设置

# 场景节点引用
@onready var camera: Camera3D = $Camera3D  # 相机节点
@onready var health_bar: ProgressBar = $UI/Stats/HealthBar  # 健康条
@onready var health_label: Label = $UI/Stats/HealthLabel  # 健康值标签
@onready var msg_label: Label = $UI/MsgLabel  # 消息标签

var spot_light: SpotLight3D = null  # 聚光灯引用（用于视野）

# 初始化函数 - 游戏开始时执行
func _ready() -> void:
	# 捕获鼠标
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# 连接游戏事件信号
	GameManager.mental_health_changed.connect(_on_health)
	GameManager.game_over_triggered.connect(_on_over)
	GameManager.medicine_collected.connect(_on_med)
	GameManager.puzzle_solved.connect(_on_puzzle)
	# 设置聚光灯（视野）
	_setup_spot_light()
	# 刷新灯光状态
	_refresh_light()

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

# 物理处理函数 - 每帧执行，处理移动和物理
func _physics_process(delta: float) -> void:
	# 游戏结束时停止处理
	if GameManager.is_game_over:
		return
	# 应用重力
	if not is_on_floor():
		velocity.y -= gravity * delta
	# 获取移动输入
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	# 转换输入到世界坐标
	var dir = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	# 根据输入设置速度
	if dir != Vector3.ZERO:
		velocity.x = dir.x * move_speed
		velocity.z = dir.z * move_speed
	else:
		# 没有输入时逐渐减速
		velocity.x = move_toward(velocity.x, 0.0, move_speed)
		velocity.z = move_toward(velocity.z, 0.0, move_speed)
	# 执行移动
	move_and_slide()
	# 更新心理值
	GameManager.update_mental_health(delta)

# 心理值变化处理函数
func _on_health(value: float) -> void:
	# 更新UI显示
	health_bar.value = value
	health_label.text = "心理值: " + str(int(value)) + "%"
	# 刷新灯光状态（视野）
	_refresh_light()

# 聚光灯设置函数 - 创建和配置视野灯光
func _setup_spot_light() -> void:
	# 创建聚光灯
	spot_light = SpotLight3D.new()
	# 设置灯光属性
	spot_light.light_color = Color(0.1, 0.1, 0.15)  # 墨黑色灯光
	spot_light.light_energy = 2.0  # 增加亮度以确保能看到周围
	spot_light.spot_range = 0.7  # 减小视野范围
	spot_light.spot_angle = 10.0  # 减小视野角度
	spot_light.spot_attenuation = 0.5  # 增加衰减，使光线更集中
	spot_light.shadow_enabled = true  # 启用阴影
	# 将灯光添加到相机上
	camera.add_child(spot_light)
	
	# 为瞎子玩家的相机创建独立环境，禁用环境光
	var camera_env = Environment.new()
	camera_env.background_mode = Environment.BG_COLOR
	camera_env.background_color = Color(0, 0, 0)  # 纯黑背景
	camera_env.ambient_light_source = 2  # 禁用环境光 (0=sky, 1=color, 2=disabled)
	camera_env.fog_enabled = false
	camera.environment = camera_env

# 灯光刷新函数 - 根据心理值更新灯光
func _refresh_light() -> void:
	# 计算心理值比例
	var ratio = GameManager.mental_health / GameManager.mental_health_max
	if spot_light != null:
		# 根据心理值调整亮度
		spot_light.light_energy = 1.0 + ratio * 1.5  # 保持较高亮度
		# 固定视野范围为0.8
		spot_light.spot_range = 0.5
		# 保持墨黑色灯光颜色
		spot_light.light_color = Color(0.1, 0.1, 0.15)
	
	# 确保相机环境设置正确
	if camera and not camera.environment:
		var camera_env = Environment.new()
		camera_env.background_mode = Environment.BG_COLOR
		camera_env.background_color = Color(0, 0, 0)  # 纯黑背景
		camera_env.ambient_light_source = 1  # 禁用环境光 (0=sky, 1=color, 2=disabled)
		camera_env.fog_enabled = false
		camera.environment = camera_env

# 交互尝试函数 - 检测和处理与物体的交互
func _try_interact() -> void:
	# 获取物理空间
	var space = get_world_3d().direct_space_state
	# 射线检测起点和终点
	var from = camera.global_position
	var to = from - camera.global_transform.basis.z * 3.0
	# 创建射线检测参数
	var params = PhysicsRayQueryParameters3D.create(from, to, 8)
	# 执行射线检测
	var hit = space.intersect_ray(params)
	# 处理检测结果
	if hit.size() > 0:
		var obj = hit["collider"]
		# 如果物体有interact方法，则调用它
		if obj.has_method("interact"):
			obj.interact(GameManager.ROLE_BLIND)

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
	# 只有当药物是给瞎子角色时才显示消息
	if role == GameManager.ROLE_BLIND:
		_show_msg("服药成功! 心理值恢复!")

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
	return GameManager.ROLE_BLIND
