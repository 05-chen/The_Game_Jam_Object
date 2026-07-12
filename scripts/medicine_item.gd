# 药物物品脚本 - 联机拾取：本地 mask8 + 主机距离/地形两步校验 + 拾取 Tween

extends NetworkedAuthorityInteractable

const TYPE_MENTAL := 0
const TYPE_PAIN := 1
const TYPE_KEY := 2
const ITEM_RENDER_LAYER := 8

@export var medicine_type: int = 0
@export var float_speed: float = 2.0
@export var float_height: float = 0.3
@export var max_collect_distance: float = 5.0
@export_flags_3d_physics var environment_mask: int = 1
@export var client_probe_slack_m: float = 2.5
@export var pickup_fx_duration: float = 0.15

var initial_y: float = 0.0
var is_collected: bool = false
var _pickup_animating: bool = false
var _gameplay_committed: bool = false
var _idle_phase: float = 0.0
var _spawn_position: Vector3 = Vector3.ZERO
var _initial_mesh_scale: Vector3 = Vector3.ONE
var _pickup_tween: Tween = null

@onready var mesh: MeshInstance3D = $Mesh
@onready var col: CollisionShape3D = $Col
@onready var lbl: Label3D = $Lbl


func is_interact_exhausted() -> bool:
	return is_collected or _pickup_animating


func interact(role: int, interact_from: Vector3 = Vector3.ZERO, has_interact_from: bool = false) -> void:
	if is_interact_exhausted():
		return
	if not _can_role_collect(role):
		return
	super.interact(role, interact_from, has_interact_from)


func _ready() -> void:
	_spawn_position = position
	initial_y = position.y
	if mesh:
		_initial_mesh_scale = mesh.scale
	collision_layer = 8
	_setup_look()


func is_fully_collected() -> bool:
	return is_collected and not _pickup_animating


func is_respawnable_medicine() -> bool:
	return medicine_type == TYPE_MENTAL or medicine_type == TYPE_PAIN


func reset_for_respawn() -> void:
	if _pickup_tween != null and is_instance_valid(_pickup_tween):
		_pickup_tween.kill()
		_pickup_tween = null
	is_collected = false
	_pickup_animating = false
	_gameplay_committed = false
	visible = true
	collision_layer = 8
	if col:
		col.disabled = false
	if mesh:
		mesh.scale = _initial_mesh_scale
	position = _spawn_position
	initial_y = _spawn_position.y
	if lbl:
		lbl.visible = true
	_setup_look()
	_idle_phase = rotation.y


func _setup_look() -> void:
	var mat := StandardMaterial3D.new()
	mat.emission_enabled = true
	mat.emission_energy_multiplier = 2.5
	if medicine_type == TYPE_MENTAL:
		mat.albedo_color = Color(0.2, 0.6, 1.0)
		mat.emission = Color(0.2, 0.6, 1.0)
		lbl.text = "镇定剂"
	elif medicine_type == TYPE_PAIN:
		mat.albedo_color = Color(0.2, 1.0, 0.3)
		mat.emission = Color(0.2, 1.0, 0.3)
		lbl.text = "止疼药"
	elif medicine_type == TYPE_KEY:
		mat.albedo_color = Color(1.0, 0.8, 0.0)
		mat.emission = Color(1.0, 0.8, 0.0)
		lbl.text = "钥匙碎片"
	mesh.material_override = mat
	mesh.layers = ITEM_RENDER_LAYER
	_idle_phase = rotation.y


func _process(delta: float) -> void:
	if is_collected or _pickup_animating:
		return
	_idle_phase += delta * (TAU / 4.0)
	position.y = initial_y + sin(_idle_phase * float_speed) * float_height
	rotation.y = _idle_phase


func _can_role_collect(role: int) -> bool:
	match medicine_type:
		TYPE_MENTAL:
			return role == GameManager.ROLE_BLIND
		TYPE_PAIN:
			return role == GameManager.ROLE_LAME
		TYPE_KEY:
			return true
	return false


func _authority_validate_host(sender_id: int, role: int, interact_from: Vector3 = Vector3.ZERO, has_interact_from: bool = false) -> bool:
	if not _can_role_collect(role):
		return false
	var request_player := _resolve_request_player(sender_id)
	if request_player == null:
		return false
	return _is_collect_request_legal(request_player, interact_from, has_interact_from)


func _resolve_collector_pos(sender_id: int, interact_from: Vector3, has_interact_from: bool) -> Vector3:
	var request_player := _resolve_request_player(sender_id)
	if request_player == null:
		return global_position
	if has_interact_from:
		var server_from: Vector3 = _get_interact_probe(request_player)["from"]
		if interact_from.distance_to(server_from) <= client_probe_slack_m:
			return interact_from
	var cam := request_player.get_node_or_null("Camera3D") as Camera3D
	if cam:
		return cam.global_position
	return request_player.global_position


func _authority_apply_pickup_fx(collector_pos: Vector3) -> void:
	if is_collected or _pickup_animating:
		return
	_pickup_animating = true
	is_collected = true
	collision_layer = 0
	col.set_deferred("disabled", true)
	if lbl:
		lbl.visible = false
	if _pickup_tween != null and is_instance_valid(_pickup_tween):
		_pickup_tween.kill()
	_pickup_tween = create_tween()
	_pickup_tween.set_parallel(true)
	_pickup_tween.tween_property(self, "global_position", collector_pos, pickup_fx_duration)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_pickup_tween.tween_property(mesh, "scale", Vector3(0.01, 0.01, 0.01), pickup_fx_duration)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_pickup_tween.chain().tween_callback(_commit_gameplay_after_fx)


func _commit_gameplay_after_fx() -> void:
	if _gameplay_committed:
		return
	_gameplay_committed = true
	_pickup_animating = false
	_authority_apply_local()
	visible = false


func _authority_apply_local() -> void:
	if medicine_type == TYPE_MENTAL:
		GameManager.collect_medicine(GameManager.ROLE_BLIND)
	elif medicine_type == TYPE_PAIN:
		GameManager.collect_medicine(GameManager.ROLE_LAME)
	elif medicine_type == TYPE_KEY:
		if GameManager.puzzle_clues_enabled:
			GameManager.solve_puzzle()


func _is_collect_request_legal(request_player: Node3D, interact_from: Vector3, has_interact_from: bool) -> bool:
	var server_from: Vector3 = _get_interact_probe(request_player)["from"]
	var from := server_from
	if has_interact_from and interact_from.distance_to(server_from) <= client_probe_slack_m:
		from = interact_from
	var item_center := global_position + Vector3(0, 0.5, 0)
	if from.distance_to(item_center) > max_collect_distance:
		return false
	return _has_clear_environment_los(from, item_center, request_player)


func _has_clear_environment_los(from: Vector3, to: Vector3, request_player: Node3D) -> bool:
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collision_mask = environment_mask
	params.exclude = [request_player.get_rid(), get_rid()]
	var hit := space.intersect_ray(params)
	return hit.is_empty()


func _get_interact_probe(request_player: Node3D) -> Dictionary:
	var cam := request_player.get_node_or_null("Camera3D") as Camera3D
	if cam:
		return {"from": cam.global_position}
	return {"from": request_player.global_position + Vector3(0, 1.2, 0)}


func _resolve_request_player(sender_id: int) -> Node3D:
	var parent := get_parent()
	if parent == null:
		return null
	if sender_id == 1:
		if GameManager.current_role == GameManager.ROLE_BLIND:
			return parent.get_node_or_null("BlindPlayer") as Node3D
		return parent.get_node_or_null("LamePlayer") as Node3D
	if sender_id == NetworkManager.remote_peer_id:
		if GameManager.current_role == GameManager.ROLE_BLIND:
			return parent.get_node_or_null("LamePlayer") as Node3D
		return parent.get_node_or_null("BlindPlayer") as Node3D
	return null
