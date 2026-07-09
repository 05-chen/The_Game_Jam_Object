# 幽灵 AI：仅 Authority（主机）运行物理与命中判定；客机插值显示；低频不可靠同步
extends CharacterBody3D

@export var patrol_speed: float = 0.9
@export var chase_speed: float = 1.7
@export var detection_range: float = 12.0
@export var attack_range: float = 1.0
@export var patrol_wait_time: float = 3.0

const ST_PATROL: int = 0
const ST_CHASE: int = 1

# 约 18Hz 同步间隔；位移不足 0.05 则跳过发包（定期仍强制同步避免漂移）
const GHOST_SYNC_INTERVAL_SEC: float = 1.0 / 18.0
const GHOST_POS_SYNC_EPS: float = 0.05
const GHOST_FORCE_RESYNC_SEC: float = 0.35
const ATTACK_HIT_SCALE: float = 1.08

var state: int = ST_PATROL
var target_pos: Vector3 = Vector3.ZERO
var patrol_pts: Array = []
var patrol_idx: int = 0
var wait_timer: float = 0.0
var blind_target: Node3D = null
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

## 兼容 game_world：单机或非权威时仍可由该标记控制（权威以 is_multiplayer_authority 为准）
var is_host_controlled: bool = true

var _sync_target_pos: Vector3 = Vector3.ZERO
var _last_sent_pos: Vector3 = Vector3.ZERO
var _sync_accum_sec: float = 0.0
var _since_last_send_sec: float = 0.0
var _hit_zone: Area3D = null

@onready var ghost_mesh: MeshInstance3D = $GhostMesh


func _ready() -> void:
	add_to_group("ghost_ai")
	patrol_pts = [
		Vector3(-6, 1, -6), Vector3(6, 1, -6),
		Vector3(6, 1, 6), Vector3(-6, 1, 6),
		Vector3(0, 1, 0), Vector3(-3, 1, 3), Vector3(3, 1, -3),
	]
	_next_patrol()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0, 0, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.8, 0, 0)
	ghost_mesh.material_override = mat

	_sync_target_pos = global_position
	_last_sent_pos = global_position

	if NetworkManager.is_multiplayer_game:
		set_multiplayer_authority(1)

	var runs_ai: bool = _runs_authority_ai()
	var net_client: bool = NetworkManager.is_multiplayer_game and not is_multiplayer_authority()

	if net_client:
		set_physics_process(false)
		set_process(true)
		collision_layer = 0
		collision_mask = 0
		if has_node("Col"):
			$Col.set_deferred("disabled", true)
	else:
		set_process(false)
		if runs_ai:
			_setup_server_hit_zone()

	_setup_breath_animation_player()


func _runs_authority_ai() -> bool:
	if not NetworkManager.is_multiplayer_game or multiplayer.multiplayer_peer == null:
		return false
	return is_multiplayer_authority() and is_host_controlled


func _setup_server_hit_zone() -> void:
	if _hit_zone != null:
		return
	_hit_zone = Area3D.new()
	_hit_zone.name = "HitZone"
	_hit_zone.collision_layer = 0
	_hit_zone.collision_mask = 1 << 1
	_hit_zone.monitoring = true
	_hit_zone.monitorable = false
	var hs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = attack_range * ATTACK_HIT_SCALE
	hs.shape = sph
	_hit_zone.add_child(hs)
	add_child(_hit_zone)
	_hit_zone.body_entered.connect(_on_hit_body_entered)


func _on_hit_body_entered(body: Node3D) -> void:
	if not _runs_authority_ai():
		return
	if not (body is CharacterBody3D):
		return
	if body.has_method("get_role") and body.get_role() == GameManager.ROLE_BLIND:
		if _has_clear_hit_line(body):
			GameManager.trigger_game_over(false)


func _setup_breath_animation_player() -> void:
	var ap := AnimationPlayer.new()
	ap.name = "GhostBreathAnim"
	add_child(ap)
	ap.root_node = NodePath("..")
	var anim := Animation.new()
	anim.length = 2.0
	anim.loop_mode = Animation.LOOP_LINEAR
	var tr := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(tr, NodePath("GhostMesh:scale"))
	anim.value_track_set_update_mode(tr, Animation.UPDATE_CONTINUOUS)
	anim.track_insert_key(tr, 0.0, Vector3.ONE)
	anim.track_insert_key(tr, 1.0, Vector3(1.2, 1.2, 1.2))
	anim.track_insert_key(tr, 2.0, Vector3.ONE)
	var lib := AnimationLibrary.new()
	lib.add_animation("breath", anim)
	ap.add_animation_library("", lib)
	ap.play("breath")


func _process(delta: float) -> void:
	if not NetworkManager.is_multiplayer_game:
		return
	if is_multiplayer_authority():
		return
	global_position = global_position.move_toward(_sync_target_pos, delta * 22.0)


func _physics_process(delta: float) -> void:
	if GameManager.is_game_over:
		return
	if not _runs_authority_ai():
		return

	if not is_on_floor():
		velocity.y -= gravity * delta
	if state == ST_PATROL:
		_do_patrol(delta)
	elif state == ST_CHASE:
		_do_chase()
	move_and_slide()

	if NetworkManager.is_multiplayer_game:
		_since_last_send_sec += delta
		_sync_accum_sec += delta
		if _sync_accum_sec >= GHOST_SYNC_INTERVAL_SEC:
			_sync_accum_sec = 0.0
			var moved_enough := global_position.distance_to(_last_sent_pos) >= GHOST_POS_SYNC_EPS
			var force := _since_last_send_sec >= GHOST_FORCE_RESYNC_SEC
			if moved_enough or force:
				_sync_ghost_net.rpc(global_position)
				_last_sent_pos = global_position
				_since_last_send_sec = 0.0


@rpc("authority", "unreliable", "call_remote")
func _sync_ghost_net(pos: Vector3) -> void:
	_sync_target_pos = pos


func _has_clear_hit_line(target: Node3D) -> bool:
	var from := global_position + Vector3(0, 0.9, 0)
	var to := target.global_position + Vector3(0, 0.9, 0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	query.exclude = [self.get_rid(), target.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty()


func _do_patrol(delta: float) -> void:
	var diff := target_pos - global_position
	diff.y = 0.0
	var dist := diff.length()
	if dist < 1.5:
		velocity.x = 0.0
		velocity.z = 0.0
		wait_timer += delta
		if wait_timer >= patrol_wait_time:
			wait_timer = 0.0
			_next_patrol()
	else:
		var dir := diff.normalized()
		velocity.x = dir.x * patrol_speed
		velocity.z = dir.z * patrol_speed
	_check_detect()


func _do_chase() -> void:
	if blind_target == null or not is_instance_valid(blind_target):
		state = ST_PATROL
		return
	var diff := blind_target.global_position - global_position
	diff.y = 0.0
	var dist := diff.length()
	if dist > detection_range * 1.5:
		state = ST_PATROL
		_next_patrol()
		return
	var mental_health_ratio := GameManager.mental_health / GameManager.mental_health_max
	var speed_multiplier := 1.0 + (1.0 - mental_health_ratio) * 0.5
	var adjusted_speed := chase_speed * speed_multiplier
	var dir := diff.normalized()
	velocity.x = dir.x * adjusted_speed
	velocity.z = dir.z * adjusted_speed


func _check_detect() -> void:
	var players := get_tree().get_nodes_in_group("player")
	for p in players:
		if not (p.has_method("get_role") and p.get_role() == GameManager.ROLE_BLIND):
			continue
		if global_position.distance_to(p.global_position) < detection_range:
			blind_target = p
			state = ST_CHASE
			return


func _next_patrol() -> void:
	patrol_idx = (patrol_idx + 1) % patrol_pts.size()
	target_pos = patrol_pts[patrol_idx]


func reset_ai_state(reset_pos: Vector3) -> void:
	global_position = reset_pos
	velocity = Vector3.ZERO
	state = ST_PATROL
	wait_timer = 0.0
	blind_target = null
	_sync_target_pos = reset_pos
	_last_sent_pos = reset_pos
	_next_patrol()


func reset_to_initial_state(reset_pos: Vector3) -> void:
	reset_ai_state(reset_pos)
