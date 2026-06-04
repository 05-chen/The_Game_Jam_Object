# 药物物品脚本 - 处理游戏中的可交互物品（联机走 NetworkedAuthorityInteractable 模板）

extends NetworkedAuthorityInteractable

# 物品类型常量
const TYPE_MENTAL = 0  # 心理药物（镇定剂）
const TYPE_PAIN = 1    # 止痛药
const TYPE_KEY = 2     # 钥匙碎片

# 可导出属性
@export var medicine_type: int = 0
@export var float_speed: float = 2.0
@export var float_height: float = 0.3
@export var max_collect_distance: float = 5.0
@export_flags_3d_physics var obstruction_mask: int = 1

# 内部变量
var initial_y: float = 0.0
var is_collected: bool = false

# 场景节点引用
@onready var mesh: MeshInstance3D = $Mesh
@onready var col: CollisionShape3D = $Col
@onready var lbl: Label3D = $Lbl


func is_interact_exhausted() -> bool:
	return is_collected


func interact(role: int) -> void:
	if is_interact_exhausted():
		return
	if not _can_role_collect(role):
		return
	super.interact(role)


func _ready() -> void:
	initial_y = position.y
	collision_layer = 8
	_setup_look()


func _setup_look() -> void:
	var mat = StandardMaterial3D.new()
	mat.emission_enabled = true
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
	_setup_idle_animation_player()


func _setup_idle_animation_player() -> void:
	var ap := AnimationPlayer.new()
	ap.name = "IdleAnim"
	add_child(ap)
	ap.root_node = NodePath("..")
	var anim := Animation.new()
	anim.length = 4.0
	anim.loop_mode = Animation.LOOP_LINEAR
	var tr_y := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(tr_y, NodePath("position:y"))
	anim.value_track_set_update_mode(tr_y, Animation.UPDATE_CONTINUOUS)
	anim.track_insert_key(tr_y, 0.0, initial_y)
	anim.track_insert_key(tr_y, 2.0, initial_y + float_height)
	anim.track_insert_key(tr_y, 4.0, initial_y)
	var tr_ry := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(tr_ry, NodePath("rotation:y"))
	anim.value_track_set_update_mode(tr_ry, Animation.UPDATE_CONTINUOUS)
	var ry0 := rotation.y
	anim.track_insert_key(tr_ry, 0.0, ry0)
	anim.track_insert_key(tr_ry, 4.0, ry0 + TAU)
	var lib := AnimationLibrary.new()
	lib.add_animation("idle", anim)
	ap.add_animation_library("", lib)
	ap.play("idle")


func _can_role_collect(role: int) -> bool:
	match medicine_type:
		TYPE_MENTAL:
			return role == GameManager.ROLE_BLIND
		TYPE_PAIN:
			return role == GameManager.ROLE_LAME
		TYPE_KEY:
			return true
	return false


func _authority_validate_host(sender_id: int, role: int) -> bool:
	if not _can_role_collect(role):
		return false
	var request_player := _resolve_request_player(sender_id)
	if request_player == null:
		return false
	return _is_collect_request_legal(request_player)


func _authority_apply_local() -> void:
	if is_collected:
		return
	if medicine_type == TYPE_MENTAL:
		GameManager.collect_medicine(GameManager.ROLE_BLIND)
	elif medicine_type == TYPE_PAIN:
		GameManager.collect_medicine(GameManager.ROLE_LAME)
	elif medicine_type == TYPE_KEY:
		GameManager.solve_puzzle()
	is_collected = true
	visible = false
	col.set_deferred("disabled", true)
	var ap := get_node_or_null("IdleAnim") as AnimationPlayer
	if ap:
		ap.stop()


func _is_collect_request_legal(request_player: Node3D) -> bool:
	var probe := _get_interact_probe(request_player)
	var from: Vector3 = probe["from"]
	var dist: float = from.distance_to(global_position + Vector3(0, 0.5, 0))
	if dist > max_collect_distance:
		return false
	var space = get_world_3d().direct_space_state
	var to := global_position + Vector3(0, 0.5, 0)
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collision_mask = obstruction_mask
	params.exclude = [request_player.get_rid(), self.get_rid()]
	var hit := space.intersect_ray(params)
	return hit.is_empty()


func _get_interact_probe(request_player: Node3D) -> Dictionary:
	var cam := request_player.get_node_or_null("Camera3D") as Camera3D
	if cam:
		return {"from": cam.global_position}
	return {"from": request_player.global_position + Vector3(0, 1.2, 0)}


func _resolve_request_player(sender_id: int) -> Node3D:
	if not NetworkManager.is_multiplayer_game:
		return get_parent().get_node_or_null("BlindPlayer") as Node3D
	if sender_id == 1:
		return get_parent().get_node_or_null("BlindPlayer") as Node3D if GameManager.current_role == GameManager.ROLE_BLIND else get_parent().get_node_or_null("LamePlayer") as Node3D
	if sender_id == NetworkManager.remote_peer_id:
		return get_parent().get_node_or_null("LamePlayer") as Node3D if GameManager.current_role == GameManager.ROLE_BLIND else get_parent().get_node_or_null("BlindPlayer") as Node3D
	return null
