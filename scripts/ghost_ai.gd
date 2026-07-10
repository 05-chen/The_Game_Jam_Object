# 幽灵 AI（Stage2 MVP）
# - Host：驱动 PathFollow3D.progress_ratio 沿闭合轨道循环，并同步 ratio 给客机
# - Client：仅接收 ratio，本地 PathFollow 驱动表现（无物理、无命中判定）
# - 致命碰撞：仅 Host HitZone 检测瞎子（layer 2），带 _hit_latched 防重复
extends CharacterBody3D

## 编辑器可绑；若为空则在 _ready 自动取父节点 PathFollow3D
@export var path_follow: PathFollow3D = null
## 每秒沿轨道推进的 progress_ratio（0~1 为一圈）；大场景 Scale 0.08~0.1 时可微调
@export var loop_progress_per_sec: float = 0.012
@export var attack_range: float = 1.0

const ATTACK_HIT_SCALE: float = 1.08

## 兼容 game_world / LevelFlow：Host 生成时设为 true
var is_host_controlled: bool = true

var _hit_zone: Area3D = null
var _hit_latched: bool = false

@onready var ghost_mesh: MeshInstance3D = $GhostMesh


func _ready() -> void:
	add_to_group("ghost_ai")
	_resolve_path_follow()
	_apply_ghost_material()

	if NetworkManager.is_multiplayer_game:
		set_multiplayer_authority(1)

	var net_client := NetworkManager.is_multiplayer_game and not is_multiplayer_authority()

	if net_client:
		# 客机：不做物理/AI，位置完全由 PathFollow + RPC ratio 驱动
		set_physics_process(false)
		collision_layer = 0
		collision_mask = 0
		if has_node("Col"):
			$Col.set_deferred("disabled", true)
	elif _runs_authority_ai():
		# Host 权威：沿 Path 推进 + 致命 HitZone
		_setup_server_hit_zone()

	_setup_breath_animation_player()


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


func _apply_ghost_material() -> void:
	if ghost_mesh == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0, 0, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.8, 0, 0)
	ghost_mesh.material_override = mat


func _setup_server_hit_zone() -> void:
	if _hit_zone != null:
		return
	_hit_zone = Area3D.new()
	_hit_zone.name = "HitZone"
	_hit_zone.collision_layer = 0
	_hit_zone.collision_mask = 1 << 1  # player 层（瞎子 capsule）
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
	if _hit_latched or GameManager.is_game_over:
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
	GameManager.trigger_game_over(false)


func _physics_process(delta: float) -> void:
	if not _runs_authority_ai():
		return
	if GameManager.is_game_over:
		return
	if path_follow == null or not is_instance_valid(path_follow):
		push_warning("[GhostAI] path_follow 未绑定，无法巡逻")
		return

	# Host：恒定速度推进 progress_ratio，fmod 保证 0~1 闭合循环
	path_follow.progress_ratio = fmod(
		path_follow.progress_ratio + loop_progress_per_sec * delta,
		1.0
	)
	# 子节点自动跟随 PathFollow3D 变换，无需 move_and_slide
	velocity = Vector3.ZERO

	if NetworkManager.is_multiplayer_game:
		_sync_ghost_progress.rpc(path_follow.progress_ratio)


@rpc("authority", "unreliable", "call_remote")
func _sync_ghost_progress(ratio: float) -> void:
	if _runs_authority_ai():
		return
	_resolve_path_follow()
	if path_follow == null or not is_instance_valid(path_follow):
		return
	path_follow.progress_ratio = ratio


func _has_clear_hit_line(target: Node3D) -> bool:
	var from := global_position + Vector3(0, 0.9, 0)
	var to := target.global_position + Vector3(0, 0.9, 0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	query.exclude = [get_rid(), target.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty()


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


func reset_ai_state(_reset_pos: Vector3) -> void:
	_hit_latched = false
	velocity = Vector3.ZERO
	if path_follow != null and is_instance_valid(path_follow):
		path_follow.progress_ratio = 0.0
		if NetworkManager.is_multiplayer_game and _runs_authority_ai():
			_sync_ghost_progress.rpc(path_follow.progress_ratio)


func reset_to_initial_state(reset_pos: Vector3) -> void:
	reset_ai_state(reset_pos)
