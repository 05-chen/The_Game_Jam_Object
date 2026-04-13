# 瞎子玩家脚本 - 控制瞎子角色的移动、视野和交互
# [已修改] 增加 is_local 标记，区分本地/远程
# [已修改] 远程玩家禁用相机和UI，仅接收位置同步
# [已修改] 本地玩家每帧广播位置和心理值

extends CharacterBody3D

@export var move_speed: float = 4.0  # 移动速度
@export var mouse_sensitivity: float = 0.003  # 鼠标灵敏度

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")  # 重力设置

# [新增] 多人标记 - 由 game_world.gd 在 add_child 之前设置
var is_local: bool = true

# 场景节点引用
@onready var camera: Camera3D = $Camera3D
@onready var health_bar: ProgressBar = $UI/Stats/HealthBar
@onready var health_label: Label = $UI/Stats/HealthLabel
@onready var msg_label: Label = $UI/MsgLabel

var spot_light: SpotLight3D = null

# 初始化函数
func _ready() -> void:
	# [新增] 远程玩家：禁用相机和UI，不处理任何逻辑
	if not is_local:
		camera.current = false
		# 隐藏 UI 的所有子元素
		for child in $UI.get_children():
			if child is CanvasItem:
				child.visible = false
		return

	# ── 以下仅本地玩家执行 ──
	camera.current = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	GameManager.mental_health_changed.connect(_on_health)
	GameManager.game_over_triggered.connect(_on_over)
	GameManager.medicine_collected.connect(_on_med)
	GameManager.puzzle_solved.connect(_on_puzzle)
	_setup_spot_light()
	_refresh_light()

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
	# [新增] 远程玩家不处理物理
	if not is_local:
		return
	if GameManager.is_game_over:
		return
	# 重力
	if not is_on_floor():
		velocity.y -= gravity * delta
	# 移动输入
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var dir = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if dir != Vector3.ZERO:
		velocity.x = dir.x * move_speed
		velocity.z = dir.z * move_speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed)
		velocity.z = move_toward(velocity.z, 0.0, move_speed)
	move_and_slide()
	# 更新心理值
	GameManager.update_mental_health(delta)
	# [新增] 多人同步：广播位置 + 旋转 + 心理值
	if NetworkManager.peer != null:
		_sync_state.rpc(global_position, rotation.y, camera.rotation.x, GameManager.mental_health)

# [新增] 位置和状态同步 RPC - 远程玩家接收
@rpc("any_peer", "unreliable_ordered", "call_remote")
func _sync_state(pos: Vector3, rot_y: float, cam_x: float, mh: float) -> void:
	global_position = pos
	rotation.y = rot_y
	if camera:
		camera.rotation.x = cam_x
	# 同步心理值到远程机器（供 Ghost AI 等使用）
	GameManager.mental_health = mh
	GameManager.mental_health_changed.emit(mh)

# 心理值变化处理函数
func _on_health(value: float) -> void:
	health_bar.value = value
	health_label.text = "心理值: " + str(int(value)) + "%"
	_refresh_light()

# 聚光灯设置函数
func _setup_spot_light() -> void:
	spot_light = SpotLight3D.new()
	spot_light.light_color = Color(0.1, 0.1, 0.15)
	spot_light.light_energy = 2.0
	spot_light.spot_range = 0.7
	spot_light.spot_angle = 10.0
	spot_light.spot_attenuation = 0.5
	spot_light.shadow_enabled = true
	camera.add_child(spot_light)
	var camera_env = Environment.new()
	camera_env.background_mode = Environment.BG_COLOR
	camera_env.background_color = Color(0, 0, 0)
	camera_env.ambient_light_source = 2
	camera_env.fog_enabled = false
	camera.environment = camera_env

# 灯光刷新函数
func _refresh_light() -> void:
	var ratio = GameManager.mental_health / GameManager.mental_health_max
	if spot_light != null:
		spot_light.light_energy = 1.0 + ratio * 1.5
		spot_light.spot_range = 0.5
		spot_light.light_color = Color(0.1, 0.1, 0.15)
	if camera and not camera.environment:
		var camera_env = Environment.new()
		camera_env.background_mode = Environment.BG_COLOR
		camera_env.background_color = Color(0, 0, 0)
		camera_env.ambient_light_source = 1
		camera_env.fog_enabled = false
		camera.environment = camera_env

# 交互尝试函数
func _try_interact() -> void:
	var space = get_world_3d().direct_space_state
	var from = camera.global_position
	var to = from - camera.global_transform.basis.z * 3.0
	var params = PhysicsRayQueryParameters3D.create(from, to, 8)
	var hit = space.intersect_ray(params)
	if hit.size() > 0:
		var obj = hit["collider"]
		if obj.has_method("interact"):
			obj.interact(GameManager.ROLE_BLIND)

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
	if role == GameManager.ROLE_BLIND:
		_show_msg("服药成功! 心理值恢复!")

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
	return GameManager.ROLE_BLIND
