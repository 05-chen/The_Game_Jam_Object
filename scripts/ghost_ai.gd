# 幽灵AI脚本 - 控制敌人的巡逻和追逐行为
# [已修改] 增加 is_host_controlled 标记，Client 端仅显示同步位置
# [已修改] Host 端每帧广播 Ghost 位置到 Client
# [已修复] body_entered 信号在 CharacterBody3D 上不存在，改用距离检测

extends CharacterBody3D

@export var patrol_speed: float = 0.9
@export var chase_speed: float = 1.7
@export var detection_range: float = 12.0
@export var attack_range: float = 1.0  # [调整] 攻击距离阈值（缩小）
@export var patrol_wait_time: float = 3.0

# 状态常量
const ST_PATROL = 0
const ST_CHASE = 1

# 状态变量
var state: int = ST_PATROL
var target_pos: Vector3 = Vector3.ZERO
var patrol_pts: Array = []
var patrol_idx: int = 0
var wait_timer: float = 0.0
# 当前锁定的瞎子目标（瘸子与瞎子同坐标，不单独作为追踪目标）
var blind_target: Node3D = null
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# [新增] 多人标记 - 由 game_world.gd 设置
# true = 本机运行 AI 逻辑（Host 或单人）
# false = 本机仅显示同步位置（Client）
var is_host_controlled: bool = true

@onready var ghost_mesh: MeshInstance3D = $GhostMesh

# 初始化函数
func _ready() -> void:
	add_to_group("ghost_ai")
	patrol_pts = [
		Vector3(-6, 1, -6), Vector3(6, 1, -6),
		Vector3(6, 1, 6), Vector3(-6, 1, 6),
		Vector3(0, 1, 0), Vector3(-3, 1, 3), Vector3(3, 1, -3),
	]
	_next_patrol()
	# 设置幽灵材质
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0, 0, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.8, 0, 0)
	ghost_mesh.material_override = mat
	# [已修复] 移除了原来的 connect("body_entered", ...)
	# CharacterBody3D 没有 body_entered 信号，改用 _check_attack_range()

# 物理处理函数
func _physics_process(delta: float) -> void:
	if GameManager.is_game_over:
		return

	# 幽灵呼吸效果（所有端都运行）
	var pulse = (sin(Time.get_ticks_msec() * 0.005) + 1.0) * 0.5
	ghost_mesh.scale = Vector3.ONE * (1.0 + pulse * 0.2)

	# [新增] Client 端：不运行 AI，仅显示同步位置
	if not is_host_controlled:
		return

	# ── 以下仅 Host 端执行 ──
	# 重力
	if not is_on_floor():
		velocity.y -= gravity * delta
	# 状态机
	if state == ST_PATROL:
		_do_patrol(delta)
	elif state == ST_CHASE:
		_do_chase()
	move_and_slide()

	# [已修复] 使用距离检测替代不存在的 body_entered 信号
	_check_attack_range()

	# [新增] 同步位置到 Client
	# [修复] 使用 is_multiplayer_game 标记
	if NetworkManager.is_multiplayer_game:
		_sync_ghost.rpc(global_position)

# [新增] Ghost 位置同步 RPC
@rpc("authority", "unreliable_ordered", "call_remote")
func _sync_ghost(pos: Vector3) -> void:
	global_position = pos

# [新增/修复] 攻击范围检测 - 替代原来的 body_entered
func _check_attack_range() -> void:
	var players = get_tree().get_nodes_in_group("player")
	for p in players:
		if p.has_method("get_role") and p.get_role() == GameManager.ROLE_BLIND:
			if global_position.distance_to(p.global_position) < attack_range and _has_clear_hit_line(p):
				GameManager.trigger_game_over(false)
				return

func _has_clear_hit_line(target: Node3D) -> bool:
	var from := global_position + Vector3(0, 0.9, 0)
	var to := target.global_position + Vector3(0, 0.9, 0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1  # 仅检测环境墙体/家具
	query.exclude = [self.get_rid(), target.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	# 命中环境层物体说明被墙体阻挡，不可攻击
	return hit.is_empty()

# 巡逻行为函数
func _do_patrol(delta: float) -> void:
	var diff = target_pos - global_position
	diff.y = 0.0
	var dist = diff.length()
	if dist < 1.5:
		velocity.x = 0.0
		velocity.z = 0.0
		wait_timer += delta
		if wait_timer >= patrol_wait_time:
			wait_timer = 0.0
			_next_patrol()
	else:
		var dir = diff.normalized()
		velocity.x = dir.x * patrol_speed
		velocity.z = dir.z * patrol_speed
	_check_detect()

# 追逐行为函数
func _do_chase() -> void:
	if blind_target == null or not is_instance_valid(blind_target):
		state = ST_PATROL
		return
	var diff = blind_target.global_position - global_position
	diff.y = 0.0
	var dist = diff.length()
	if dist > detection_range * 1.5:
		state = ST_PATROL
		_next_patrol()
		return
	var mental_health_ratio = GameManager.mental_health / GameManager.mental_health_max
	var speed_multiplier = 1.0 + (1.0 - mental_health_ratio) * 0.5
	var adjusted_speed = chase_speed * speed_multiplier
	var dir = diff.normalized()
	velocity.x = dir.x * adjusted_speed
	velocity.z = dir.z * adjusted_speed

# 检测玩家函数
func _check_detect() -> void:
	var players = get_tree().get_nodes_in_group("player")
	for p in players:
		# 规则：瞎子背着瘸子，幽灵只追瞎子（与攻击判定保持一致）
		if not (p.has_method("get_role") and p.get_role() == GameManager.ROLE_BLIND):
			continue
		if global_position.distance_to(p.global_position) < detection_range:
			blind_target = p
			state = ST_CHASE
			return

# 设置下一个巡逻点函数
func _next_patrol() -> void:
	patrol_idx = (patrol_idx + 1) % patrol_pts.size()
	target_pos = patrol_pts[patrol_idx]

func reset_ai_state(reset_pos: Vector3) -> void:
	global_position = reset_pos
	velocity = Vector3.ZERO
	state = ST_PATROL
	wait_timer = 0.0
	blind_target = null
	_next_patrol()

func reset_to_initial_state(reset_pos: Vector3) -> void:
	reset_ai_state(reset_pos)
