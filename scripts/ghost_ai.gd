# 幽灵 AI（Stage2）：PATROL → CHASE → RETURN 状态机
# - Host：Path 巡逻 / NavigationAgent 追逐与回归 / HitZone 致命判定
# - Client：PATROL 同步 progress_ratio；CHASE/RETURN 同步 global_position 并 Lerp
extends CharacterBody3D

enum State { PATROL, CHASE, RETURN }

## 编辑器可绑；若为空则在 _ready 自动取父节点 PathFollow3D
@export var path_follow: PathFollow3D = null
## PATROL：每秒沿轨道推进的 progress_ratio（0~1 为一圈）
@export var loop_progress_per_sec: float = 0.012
## 进入 CHASE 的检测距离（需无墙遮挡）
@export var detect_range: float = 12.0
## 超出此距离（或失去视线）则放弃追击
@export var lose_distance: float = 18.0
## CHASE / RETURN 移动速度（与瞎子 move_speed≈4.0 同量级）
@export var chase_speed: float = 4.5
## RETURN 抵达脱离点后重新挂回轨道的距离阈值
@export var return_arrive_distance: float = 0.5
@export var attack_range: float = 1.0
## 客机 CHASE/RETURN 位置插值速度
@export var client_lerp_speed: float = 22.0
@export_group("外观")
## 整体视觉/碰撞放大（预制体约人高；大医院建议 2~3）
@export_range(0.5, 6.0, 0.1) var body_scale: float = 2.5
## 壳体颜色（含透明度）
@export var ghost_color: Color = Color(0.75, 0.05, 0.05, 0.85)
## 自发光颜色（黑暗里更易看见）
@export var ghost_emission: Color = Color(1.0, 0.12, 0.08)
@export_range(0.0, 8.0, 0.1) var ghost_emission_energy: float = 2.2

const ATTACK_HIT_SCALE: float = 1.08

## 兼容 LevelFlow：Host 生成时设为 true
var is_host_controlled: bool = true
## Stage2 激活前保持静默（切断 physics / HitZone / 导航推进）
var _ai_active: bool = false

var state: State = State.PATROL
var _last_patrol_ratio: float = 0.0
var _detach_global_pos: Vector3 = Vector3.ZERO

var _hit_zone: Area3D = null
var _hit_latched: bool = false
var _nav: NavigationAgent3D = null
var _sync_target_pos: Vector3 = Vector3.ZERO
var _mesh_base_scale: Vector3 = Vector3.ONE

@onready var ghost_mesh: MeshInstance3D = $GhostMesh


func _ready() -> void:
	add_to_group("ghost_ai")
	_resolve_path_follow()
	_apply_body_scale()
	_apply_ghost_material()

	if NetworkManager.is_multiplayer_game:
		set_multiplayer_authority(1)

	var net_client := NetworkManager.is_multiplayer_game and not is_multiplayer_authority()

	# 默认关闭 AI，等 activate_stage2_ai() 再开，防止未正式登场就寻路/打脸
	_ai_active = false
	set_physics_process(false)

	if net_client:
		set_process(true)
		collision_layer = 0
		collision_mask = 0
		if has_node("Col"):
			$Col.set_deferred("disabled", true)
	elif _runs_authority_ai():
		_setup_navigation_agent()
		_setup_server_hit_zone()
		collision_mask = 1
		set_process(false)
	else:
		set_process(false)

	_sync_target_pos = global_position
	_setup_breath_animation_player()


## LevelFlow 在 Stage2 黑屏转场中调用：对齐巡逻起点 → 再打开物理与 HitZone
func activate_stage2_ai() -> void:
	_resolve_path_follow()
	_hit_latched = false
	state = State.PATROL
	velocity = Vector3.ZERO
	if path_follow != null and is_instance_valid(path_follow):
		path_follow.progress_ratio = 0.0
		top_level = false
		position = Vector3.ZERO
		_last_patrol_ratio = 0.0
		_detach_global_pos = global_position
	_sync_target_pos = global_position
	if _nav != null and is_instance_valid(_nav):
		_nav.target_position = global_position
	_ai_active = true
	if _runs_authority_ai():
		set_physics_process(true)
		if _hit_zone != null and is_instance_valid(_hit_zone):
			_hit_zone.monitoring = true
			_hit_zone.monitorable = false
	elif NetworkManager.is_multiplayer_game and not is_multiplayer_authority():
		set_process(true)
	print("[GhostAI] Stage2 AI 已激活 @ %s" % str(global_position))


func deactivate_ai() -> void:
	_ai_active = false
	set_physics_process(false)
	velocity = Vector3.ZERO
	if _hit_zone != null and is_instance_valid(_hit_zone):
		_hit_zone.monitoring = false


func bind_path_follow(follow: PathFollow3D) -> void:
	path_follow = follow


func _resolve_path_follow() -> void:
	if path_follow != null and is_instance_valid(path_follow):
		return
	var parent_node := get_parent()
	if parent_node is PathFollow3D:
		path_follow = parent_node as PathFollow3D


func _runs_authority_ai() -> bool:
	if not NetworkManager.is_multiplayer_game or multiplayer.multiplayer_peer == null:
		return false
	return is_multiplayer_authority() and is_host_controlled


func _get_level_flow() -> GameLevelFlow:
	return get_tree().get_first_node_in_group("game_level_flow") as GameLevelFlow


## 放大网格 + 根节点碰撞；导航半径按同比例加宽
func _apply_body_scale() -> void:
	var s := maxf(body_scale, 0.1)
	scale = Vector3(s, s, s)
	if ghost_mesh != null:
		_mesh_base_scale = ghost_mesh.scale
	print("[GhostAI] 外观 body_scale=%.2f color=%s" % [s, str(ghost_color)])


func _apply_ghost_material() -> void:
	if ghost_mesh == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ghost_color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = ghost_emission
	mat.emission_energy_multiplier = ghost_emission_energy
	mat.roughness = 0.35
	ghost_mesh.material_override = mat


func _setup_navigation_agent() -> void:
	if _nav != null:
		return
	var s := maxf(body_scale, 0.1)
	_nav = NavigationAgent3D.new()
	_nav.name = "NavAgent"
	_nav.path_desired_distance = 0.6 * s
	_nav.target_desired_distance = 0.5 * s
	_nav.radius = 0.35 * s
	_nav.height = 1.6 * s
	_nav.avoidance_enabled = false
	add_child(_nav)
	await get_tree().physics_frame
	_nav.target_position = global_position


func _setup_server_hit_zone() -> void:
	if _hit_zone != null:
		return
	_hit_zone = Area3D.new()
	_hit_zone.name = "HitZone"
	_hit_zone.collision_layer = 0
	_hit_zone.collision_mask = 1 << 1
	_hit_zone.monitoring = false
	_hit_zone.monitorable = false
	var hs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = attack_range * ATTACK_HIT_SCALE
	hs.shape = sph
	_hit_zone.add_child(hs)
	add_child(_hit_zone)
	_hit_zone.body_entered.connect(_on_hit_body_entered)


func _on_hit_body_entered(body: Node3D) -> void:
	if not _ai_active or not _runs_authority_ai():
		return
	if state != State.CHASE:
		return
	if _hit_latched or GameManager.is_game_over:
		return
	if not is_instance_valid(body):
		return
	if not (body is CharacterBody3D):
		return
	if not body.has_method("get_role"):
		return
	if body.get_role() != GameManager.ROLE_BLIND:
		return
	if not _has_clear_hit_line(body):
		return
	_hit_latched = true
	print("[GhostAI] 追击命中瞎子，触发游戏结束")
	GameManager.trigger_game_over(false)


func _physics_process(delta: float) -> void:
	# 切关 / 回大厅哨兵：防止访问已释放的玩家或自身子节点
	if not _ai_active:
		return
	if not is_instance_valid(self):
		return
	if not GameManager.are_session_players_valid():
		return
	if not is_instance_valid(GameManager.blind_player) or not is_instance_valid(GameManager.lame_player):
		return
	if not _runs_authority_ai():
		return
	if GameManager.is_game_over or GameManager.is_paused:
		return
	if path_follow == null or not is_instance_valid(path_follow):
		push_warning("[GhostAI] path_follow 未绑定")
		return

	match state:
		State.PATROL:
			_tick_patrol(delta)
		State.CHASE:
			_tick_chase(delta)
		State.RETURN:
			_tick_return(delta)


func _process(delta: float) -> void:
	if not _ai_active:
		return
	if GameManager.is_paused or GameManager.is_game_over:
		return
	if not is_instance_valid(self):
		return
	if _runs_authority_ai():
		return
	if state == State.PATROL:
		return
	global_position = global_position.lerp(_sync_target_pos, clampf(client_lerp_speed * delta, 0.0, 1.0))


func _tick_patrol(delta: float) -> void:
	path_follow.progress_ratio = fmod(
		path_follow.progress_ratio + loop_progress_per_sec * delta,
		1.0
	)
	velocity = Vector3.ZERO

	if NetworkManager.is_multiplayer_game:
		var flow := _get_level_flow()
		if flow:
			flow.broadcast_stage2_ghost_progress(path_follow.progress_ratio)

	var blind := _find_blind_player()
	if blind == null:
		return
	var dist := global_position.distance_to(blind.global_position)
	if dist > detect_range:
		return
	if not _has_clear_hit_line(blind):
		return

	_last_patrol_ratio = path_follow.progress_ratio
	_detach_global_pos = global_position
	_detach_from_path_follow()
	_set_state(State.CHASE)


func _tick_chase(delta: float) -> void:
	var blind := _find_blind_player()
	if blind == null:
		_begin_return()
		return

	var dist := global_position.distance_to(blind.global_position)
	if dist > lose_distance or not _has_clear_hit_line(blind):
		_begin_return()
		return

	_nav_move_toward(blind.global_position, chase_speed, delta)

	if NetworkManager.is_multiplayer_game:
		var flow := _get_level_flow()
		if flow:
			flow.broadcast_stage2_ghost_position(global_position)


func _tick_return(delta: float) -> void:
	var dist := global_position.distance_to(_detach_global_pos)
	if dist <= return_arrive_distance:
		_attach_to_path_follow(_last_patrol_ratio)
		_set_state(State.PATROL)
		if NetworkManager.is_multiplayer_game:
			var flow := _get_level_flow()
			if flow:
				flow.broadcast_stage2_ghost_progress(path_follow.progress_ratio)
		return

	_nav_move_toward(_detach_global_pos, chase_speed, delta)

	if NetworkManager.is_multiplayer_game:
		var flow := _get_level_flow()
		if flow:
			flow.broadcast_stage2_ghost_position(global_position)


func _begin_return() -> void:
	_set_state(State.RETURN)


func _set_state(new_state: State) -> void:
	if state == new_state:
		return
	state = new_state
	velocity = Vector3.ZERO
	if NetworkManager.is_multiplayer_game:
		var flow := _get_level_flow()
		if flow:
			flow.broadcast_stage2_ghost_state(state, _last_patrol_ratio, global_position)


func _detach_from_path_follow() -> void:
	if path_follow == null or top_level:
		return
	var world_pos := global_position
	top_level = true
	global_position = world_pos


func _attach_to_path_follow(ratio: float) -> void:
	if path_follow == null:
		return
	path_follow.progress_ratio = ratio
	top_level = false
	position = Vector3.ZERO
	velocity = Vector3.ZERO
	if _nav != null:
		_nav.target_position = global_position


func _nav_move_toward(target: Vector3, speed: float, _delta: float) -> void:
	if _nav == null:
		_move_direct_flat(target, speed)
		return
	_nav.target_position = target
	var next_pos := _nav.get_next_path_position()
	var diff := next_pos - global_position
	diff.y = 0.0
	if diff.length_squared() < 0.0004:
		_move_direct_flat(target, speed)
		return
	var dir := diff.normalized()
	velocity.x = dir.x * speed
	velocity.y = 0.0
	velocity.z = dir.z * speed
	move_and_slide()


func _move_direct_flat(target: Vector3, speed: float) -> void:
	var diff := target - global_position
	diff.y = 0.0
	if diff.length_squared() < 0.0004:
		velocity = Vector3.ZERO
		move_and_slide()
		return
	var dir := diff.normalized()
	velocity.x = dir.x * speed
	velocity.y = 0.0
	velocity.z = dir.z * speed
	move_and_slide()


func _find_blind_player() -> Node3D:
	if is_instance_valid(GameManager.blind_player):
		return GameManager.blind_player
	var tree := get_tree()
	if tree == null:
		return null
	for p in tree.get_nodes_in_group("player"):
		if not is_instance_valid(p):
			continue
		if p.has_method("get_role") and p.get_role() == GameManager.ROLE_BLIND:
			return p as Node3D
	return null


func _has_clear_hit_line(target: Node3D) -> bool:
	if not is_instance_valid(target) or get_world_3d() == null:
		return false
	var from := global_position + Vector3(0, 0.9, 0)
	var to := target.global_position + Vector3(0, 0.9, 0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	query.exclude = [get_rid(), target.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty()


func apply_state_sync(new_state: State, patrol_ratio: float, world_pos: Vector3) -> void:
	if _runs_authority_ai():
		return
	if not is_instance_valid(self):
		return
	_resolve_path_follow()
	state = new_state
	_last_patrol_ratio = patrol_ratio
	_sync_target_pos = world_pos
	match state:
		State.PATROL:
			_attach_to_path_follow(patrol_ratio)
		State.CHASE, State.RETURN:
			if not top_level:
				_detach_from_path_follow()
			global_position = world_pos


func apply_progress_sync(ratio: float) -> void:
	if _runs_authority_ai():
		return
	if not is_instance_valid(self):
		return
	if state != State.PATROL:
		return
	_resolve_path_follow()
	if path_follow == null or not is_instance_valid(path_follow):
		return
	path_follow.progress_ratio = ratio


func apply_position_sync(pos: Vector3) -> void:
	if _runs_authority_ai():
		return
	if not is_instance_valid(self):
		return
	_sync_target_pos = pos
	if global_position.distance_to(pos) > 4.0:
		global_position = pos


func _setup_breath_animation_player() -> void:
	var ap := AnimationPlayer.new()
	ap.name = "GhostBreathAnim"
	add_child(ap)
	ap.root_node = NodePath("..")
	var anim := Animation.new()
	anim.length = 2.0
	anim.loop_mode = Animation.LOOP_LINEAR
	var track_idx := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track_idx, NodePath("GhostMesh:scale"))
	anim.value_track_set_update_mode(track_idx, Animation.UPDATE_CONTINUOUS)
	# 呼吸动画基于网格本地缩放，不覆盖根节点 body_scale
	var base := _mesh_base_scale
	anim.track_insert_key(track_idx, 0.0, base)
	anim.track_insert_key(track_idx, 1.0, base * 1.15)
	anim.track_insert_key(track_idx, 2.0, base)
	var lib := AnimationLibrary.new()
	lib.add_animation("breath", anim)
	ap.add_animation_library("", lib)
	ap.play("breath")


func reset_ai_state(_reset_pos: Vector3) -> void:
	_hit_latched = false
	_last_patrol_ratio = 0.0
	_detach_global_pos = global_position
	if _runs_authority_ai() and path_follow != null:
		_attach_to_path_follow(0.0)
		_set_state(State.PATROL)
		if NetworkManager.is_multiplayer_game:
			var flow := _get_level_flow()
			if flow:
				flow.broadcast_stage2_ghost_progress(0.0)
	elif path_follow != null:
		state = State.PATROL
		_attach_to_path_follow(0.0)


func reset_to_initial_state(reset_pos: Vector3) -> void:
	reset_ai_state(reset_pos)
