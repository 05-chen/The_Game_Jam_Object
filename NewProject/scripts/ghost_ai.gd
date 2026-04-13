# 幽灵AI脚本 - 控制敌人的巡逻和追逐行为

# 基本属性设置
extends CharacterBody3D

@export var patrol_speed: float = 1.0  # 巡逻速度
@export var chase_speed: float = 2.0  # 追逐速度
@export var detection_range: float = 12.0  # 检测范围
# 攻击范围已改为基于碰撞体接触检测
@export var patrol_wait_time: float = 3.0  # 巡逻等待时间

# 状态常量
const ST_PATROL = 0  # 巡逻状态
const ST_CHASE = 1   # 追逐状态

# 状态变量
var state: int = ST_PATROL  # 当前状态
var target_pos: Vector3 = Vector3.ZERO  # 目标位置
var patrol_pts: Array = []  # 巡逻点数组
var patrol_idx: int = 0  # 当前巡逻点索引
var wait_timer: float = 0.0  # 等待计时器
var player_ref: Node3D = null  # 玩家引用
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")  # 重力设置

# 场景节点引用
@onready var ghost_mesh: MeshInstance3D = $GhostMesh  # 幽灵模型

# 初始化函数 - 游戏开始时执行
func _ready() -> void:
	# 设置巡逻点
	patrol_pts = [
		Vector3(-6, 1, -6), Vector3(6, 1, -6),
		Vector3(6, 1, 6), Vector3(-6, 1, 6),
		Vector3(0, 1, 0), Vector3(-3, 1, 3), Vector3(3, 1, -3),
	]
	# 设置下一个巡逻点
	_next_patrol()
	# 创建并设置幽灵材质
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0, 0, 0.8)  # 半透明红色
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA  # 启用透明
	mat.emission_enabled = true  # 启用自发光
	mat.emission = Color(0.8, 0, 0)  # 红色发光
	ghost_mesh.material_override = mat
	# 连接碰撞信号
	connect("body_entered", _on_body_entered)

# 物理处理函数 - 每帧执行
func _physics_process(delta: float) -> void:
	# 游戏结束时停止处理
	if GameManager.is_game_over:
		return
	# 应用重力
	if not is_on_floor():
		velocity.y -= gravity * delta
	# 幽灵呼吸效果（缩放动画）
	var pulse = (sin(Time.get_ticks_msec() * 0.005) + 1.0) * 0.5
	ghost_mesh.scale = Vector3.ONE * (1.0 + pulse * 0.2)
	# 根据当前状态执行不同行为
	if state == ST_PATROL:
		_do_patrol(delta)  # 执行巡逻行为
	elif state == ST_CHASE:
		_do_chase()  # 执行追逐行为
	# 执行移动
	move_and_slide()

# 巡逻行为函数
func _do_patrol(delta: float) -> void:
	# 计算到目标点的向量
	var diff = target_pos - global_position
	diff.y = 0.0  # 忽略Y轴差异
	var dist = diff.length()  # 计算距离
	
	if dist < 1.5:  # 到达目标点
		# 停止移动
		velocity.x = 0.0
		velocity.z = 0.0
		# 增加等待时间
		wait_timer += delta
		# 等待时间到，移动到下一个巡逻点
		if wait_timer >= patrol_wait_time:
			wait_timer = 0.0
			_next_patrol()
	else:  # 向目标点移动
		# 计算移动方向
		var dir = diff.normalized()
		# 设置移动速度
		velocity.x = dir.x * patrol_speed
		velocity.z = dir.z * patrol_speed
	
	# 检查是否检测到玩家
	_check_detect()

# 追逐行为函数
func _do_chase() -> void:
	# 检查玩家是否有效
	if player_ref == null or not is_instance_valid(player_ref):
		# 玩家无效，回到巡逻状态
		state = ST_PATROL
		return
	
	# 计算到玩家的向量
	var diff = player_ref.global_position - global_position
	diff.y = 0.0  # 忽略Y轴差异
	var dist = diff.length()  # 计算距离
	
	if dist > detection_range * 1.5:  # 超出检测范围
		# 回到巡逻状态
		state = ST_PATROL
		_next_patrol()
		return
	
	# 根据瞎子玩家的心理值调整速度
	# 当心理值为35%时，使用设定的追逐速度
	var mental_health_ratio = GameManager.mental_health / GameManager.mental_health_max
	# 速度随心理值降低而增加，心理值35%时达到正常速度
	var speed_multiplier = 1.0 + (1.0 - mental_health_ratio) * 0.5
	var adjusted_speed = chase_speed * speed_multiplier
	
	# 向玩家移动
	var dir = diff.normalized()  # 计算移动方向
	velocity.x = dir.x * adjusted_speed  # 设置移动速度
	velocity.z = dir.z * adjusted_speed

# 检测玩家函数
func _check_detect() -> void:
	# 获取所有玩家节点
	var players = get_tree().get_nodes_in_group("player")
	# 检查每个玩家
	for p in players:
		# 检查距离是否在检测范围内
		if global_position.distance_to(p.global_position) < detection_range:
			# 检测到玩家，设置目标并切换到追逐状态
			player_ref = p
			state = ST_CHASE
			return

# 设置下一个巡逻点函数
func _next_patrol() -> void:
	# 循环切换到下一个巡逻点
	patrol_idx = (patrol_idx + 1) % patrol_pts.size()
	# 设置新的目标位置
	target_pos = patrol_pts[patrol_idx]

# 碰撞检测函数 - 当碰撞体与其他物体接触时触发
func _on_body_entered(body: Node3D) -> void:
	# 检查是否与瞎子玩家碰撞
	if body.is_in_group("player") and body.has_method("get_role"):
		var role = body.get_role()
		if role == GameManager.ROLE_BLIND:
			# 触发游戏结束（失败）
			GameManager.trigger_game_over(false)
