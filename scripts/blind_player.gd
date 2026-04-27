# 瞎子玩家脚本 - 控制瞎子角色的移动、视野和交互
# [已修改] 增加 is_local 标记，区分本地/远程
# [已修改] 远程玩家禁用相机和UI，仅接收位置同步
# [已修改] 本地玩家每帧广播位置和心理值
# TODO (Network Optimization): 待优化 - 增加网络快照队列与插值/缓冲（lerp），降低网络抖动导致的远端视觉抽搐。
# TODO (Network Optimization): 待优化 - 将 interact 统一为“客户端请求 -> Authority 校验 -> 全局广播结果”的闭环链路。

extends CharacterBody3D

@export var move_speed: float = 4.0  # 移动速度
@export var mouse_sensitivity: float = 0.003  # 鼠标灵敏度

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")  # 重力设置

# [新增] 多人标记 - 由 game_world.gd 在 add_child 之前设置
var is_local: bool = false # 默认为 false，由生成函数来激活

# 场景节点引用
@onready var camera: Camera3D = $Camera3D
@onready var health_bar: ProgressBar = $UI/Stats/HealthBar
@onready var health_label: Label = $UI/Stats/HealthLabel
@onready var msg_label: Label = $UI/MsgLabel
@onready var vision_mask: ColorRect = $UI/VisionMask

var spot_light: SpotLight3D = null

# 初始化函数
func _ready() -> void:
	print("[BlindPlayer] _ready: is_local=", is_local)
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
	_disable_scene_lights_for_blind_view()
	_setup_spot_light()
	_refresh_light()

func _disable_scene_lights_for_blind_view() -> void:
	# 仅影响本机瞎子视角：关闭场景全局灯光，避免被环境光污染
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	_disable_lights_recursive(scene_root)

func _disable_lights_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is Light3D:
			var light := child as Light3D
			light.visible = false
		_disable_lights_recursive(child)

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

	# 单机：本地直接结算心理值
	if not NetworkManager.is_multiplayer_game:
		GameManager.update_mental_health(delta)
		return

	# 联机闭环：
	# 1) 客户端仅上报瞎子状态给 Authority
	# 2) Authority 统一结算心理值并广播最终状态
	if multiplayer.is_server():
		GameManager.update_mental_health(delta)
		_apply_authority_blind_state.rpc(global_position, rotation.y, camera.rotation.x, GameManager.mental_health)
	else:
		_request_blind_state.rpc_id(1, global_position, rotation.y, camera.rotation.x)

# 客户端上报瞎子状态给 Authority（不允许客户端直接写心理值）
@rpc("any_peer", "unreliable_ordered")
func _request_blind_state(pos: Vector3, rot_y: float, cam_x: float) -> void:
	if not NetworkManager.is_multiplayer_game:
		return
	if not multiplayer.is_server():
		return
	var sender_id = multiplayer.get_remote_sender_id()
	if not NetworkManager.is_trusted_sender(sender_id):
		return

	# Authority 侧做基础位移约束，防止异常瞬移包污染全局状态
	var max_step := move_speed * 0.2
	var requested_pos := pos
	var delta_len := global_position.distance_to(requested_pos)
	if delta_len > max_step:
		var dir := (requested_pos - global_position).normalized()
		requested_pos = global_position + dir * max_step

	global_position = requested_pos
	rotation.y = rot_y
	if camera:
		camera.rotation.x = cam_x

	GameManager.update_mental_health(get_physics_process_delta_time())
	_apply_authority_blind_state.rpc(global_position, rotation.y, camera.rotation.x, GameManager.mental_health)

# Authority 广播最终瞎子状态（位置/朝向/心理值）
@rpc("authority", "unreliable_ordered", "call_remote")
func _apply_authority_blind_state(pos: Vector3, rot_y: float, cam_x: float, mh: float) -> void:
	global_position = pos
	rotation.y = rot_y
	if camera:
		camera.rotation.x = cam_x
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
	camera_env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	camera_env.ambient_light_energy = 0.0
	camera_env.fog_enabled = false
	camera.environment = camera_env
	
	
func _refresh_light() -> void:
	# 1. 关键：如果不是本地玩家，直接跳过
	if not is_local: 
		return

	# 2. 计算比例
	var mh = GameManager.mental_health
	var ratio = clamp(mh / 100.0, 0.0, 1.0)
	
	# 3. 物理灯光逻辑
	if spot_light != null:
		spot_light.light_energy = 1.0 + ratio * 1.5
	
	# 4. Shader 遮罩逻辑
	if vision_mask and vision_mask.material is ShaderMaterial:
		var mat = vision_mask.material as ShaderMaterial
		
		# --- 修复报错的核心：直接赋值，不再使用 var 重复声明 ---
		var current_screen_size = get_viewport().get_visible_rect().size
		mat.set_shader_parameter("screen_size", current_screen_size)
		
		# 计算半径阈值
		var target_radius = ratio * 0.18
		if mh < 8.0:
			target_radius = 0.0
			
		# 获取 Shader 中当前的半径值
		var current_r = mat.get_shader_parameter("vision_radius")
		
		# 使用 lerp 平滑缩放
		var smooth_r = lerp(current_r, target_radius, 0.1)
		mat.set_shader_parameter("vision_radius", smooth_r)



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
