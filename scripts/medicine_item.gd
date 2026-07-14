# 药物/可拾取物脚本 - 联机拾取：本地 mask8 + 主机距离/地形两步校验 + 拾取 Tween
#
# medicine_type 含义（在 Inspector 里设置）：
#   0 = 镇定剂（仅瞎子）
#   1 = 止痛药（仅瘸子）
#   2 = 钥匙/线索（测试关钥匙；医院关卡线索请同时设置下方 hospital_stage）

extends NetworkedAuthorityInteractable

const TYPE_MENTAL := 0
const TYPE_PAIN := 1
const TYPE_KEY := 2
const ITEM_RENDER_LAYER := 8

## 医院大场景：该药品/线索属于哪一阶段（Inspector 下拉选择）
enum HospitalStage {
	STAGE_1 = 1,
	STAGE_2 = 2,
}

@export_group("关卡阶段")
## 第一阶段 / 第二阶段（药品与通关线索通用；与 GameLevelFlow 分组 stage1_only / stage2_only 联动）
@export var hospital_stage: HospitalStage = HospitalStage.STAGE_1

@export var medicine_type: int = 0
@export var float_speed: float = 2.0
@export var float_height: float = 0.3
@export_flags_3d_physics var environment_mask: int = 1
@export var client_probe_slack_m: float = 1.5
## 视线检测：射线打在台面/地面时，落点距道具中心在此范围内仍视为可拾取
@export var pickup_los_surface_slack_m: float = 3.5
@export var pickup_fx_duration: float = 0.15

var initial_y: float = 0.0
var is_collected: bool = false
var _pickup_animating: bool = false
var _gameplay_committed: bool = false
var _idle_phase: float = 0.0
var _spawn_position: Vector3 = Vector3.ZERO
var _initial_mesh_scale: Vector3 = Vector3.ONE
var _pickup_tween: Tween = null
var _stage_interaction_enabled: bool = true
var _saved_collision_layer: int = 8

@onready var mesh: MeshInstance3D = $Mesh
@onready var col: CollisionShape3D = $Col
@onready var lbl: Label3D = $Lbl


func is_interact_exhausted() -> bool:
	return not _stage_interaction_enabled or is_collected or _pickup_animating


func interact(role: int, interact_from: Vector3 = Vector3.ZERO, has_interact_from: bool = false) -> void:
	if is_interact_exhausted():
		return
	if not _can_role_collect(role):
		return
	super.interact(role, interact_from, has_interact_from)


func _ready() -> void:
	_register_hospital_stage_group()
	_spawn_position = position
	initial_y = position.y
	if mesh:
		_initial_mesh_scale = mesh.scale
	_saved_collision_layer = 8
	collision_layer = _saved_collision_layer
	_setup_look()
	add_to_group("interactable_pickup")
	# Stage2 药品默认先隐藏，等 GameLevelFlow.switch_to_stage(1) 统一刷新
	if hospital_stage == HospitalStage.STAGE_2:
		set_stage_interaction_active(false)


## 由 GameLevelFlow._set_group_interaction 调用：彻底开关显隐、帧更新与碰撞/拾取
func set_stage_interaction_active(active: bool) -> void:
	_stage_interaction_enabled = active
	visible = active
	set_process(active)
	set_physics_process(active)
	if active and not is_collected:
		if not is_in_group("interactable_pickup"):
			add_to_group("interactable_pickup")
		collision_layer = _saved_collision_layer
		collision_mask = 0
		_set_all_collision_shapes_enabled(true)
		_set_area3d_monitoring_recursive(self, true)
		_setup_look()
	else:
		if is_in_group("interactable_pickup"):
			remove_from_group("interactable_pickup")
		collision_layer = 0
		collision_mask = 0
		_set_all_collision_shapes_enabled(false)
		_set_area3d_monitoring_recursive(self, false)


func _set_area3d_monitoring_recursive(node: Node, active: bool) -> void:
	if node is Area3D:
		var area := node as Area3D
		area.monitoring = active
		area.monitorable = active
	for child in node.get_children():
		_set_area3d_monitoring_recursive(child, active)


func is_stage_interaction_enabled() -> bool:
	return _stage_interaction_enabled


func get_hospital_stage() -> int:
	return int(hospital_stage)


func _register_hospital_stage_group() -> void:
	match hospital_stage:
		HospitalStage.STAGE_1:
			if not is_in_group("stage1_only"):
				add_to_group("stage1_only")
		HospitalStage.STAGE_2:
			if not is_in_group("stage2_only"):
				add_to_group("stage2_only")


func _set_all_collision_shapes_enabled(enabled: bool) -> void:
	_apply_collision_shapes_recursive(self, enabled)


func _apply_collision_shapes_recursive(node: Node, enabled: bool) -> void:
	for child in node.get_children():
		if child is CollisionShape3D:
			(child as CollisionShape3D).set_deferred("disabled", not enabled)
		_apply_collision_shapes_recursive(child, enabled)


func is_fully_collected() -> bool:
	return is_collected and not _pickup_animating


func is_respawnable_medicine() -> bool:
	return medicine_type == TYPE_MENTAL or medicine_type == TYPE_PAIN


func reset_for_respawn() -> void:
	if not _stage_interaction_enabled:
		return
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
		if GameManager.puzzle_clues_enabled:
			mat.albedo_color = Color(1.0, 0.8, 0.0)
			mat.emission = Color(1.0, 0.8, 0.0)
			lbl.text = "钥匙碎片"
		elif _is_hospital_clue_item():
			mat.albedo_color = Color(0.95, 0.82, 0.25)
			mat.emission = Color(0.9, 0.7, 0.15)
			lbl.text = "线索·二" if hospital_stage == HospitalStage.STAGE_2 else "线索"
		else:
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
	# 浮动按「世界高度」算：节点 scale 5~10 时，本地 float_height 不能直接乘进 position
	var scale_y := maxf(absf(global_transform.basis.get_scale().y), 0.001)
	position.y = initial_y + sin(_idle_phase * float_speed) * (float_height / scale_y)
	rotation.y = _idle_phase


func can_role_pickup(role: int) -> bool:
	return _stage_interaction_enabled and _can_role_collect(role)


func get_pickup_focus_position() -> Vector3:
	# 世界空间固定抬高，避免 house_f_1 放大实例把焦点顶到数米外
	return global_position + Vector3(0.0, 0.35, 0.0)


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
	if not _stage_interaction_enabled:
		return false
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
	match medicine_type:
		TYPE_MENTAL:
			GameManager.collect_medicine(GameManager.ROLE_BLIND)
		TYPE_PAIN:
			GameManager.collect_medicine(GameManager.ROLE_LAME)
		TYPE_KEY:
			if GameManager.puzzle_clues_enabled:
				GameManager.solve_puzzle()
			elif _is_hospital_clue_item():
				_notify_hospital_clue_pickup()


func _is_collect_request_legal(request_player: Node3D, interact_from: Vector3, has_interact_from: bool) -> bool:
	var use_flat: bool = false
	if request_player.has_method("get_role"):
		use_flat = request_player.get_role() == GameManager.ROLE_BLIND
	var probe := PlayerPickupUtil.build_probe(request_player, use_flat)
	if probe.is_empty():
		return false
	if has_interact_from:
		var server_origin: Vector3 = probe["origin"]
		if interact_from.distance_to(server_origin) > client_probe_slack_m:
			return false
	var item_center: Vector3 = get_pickup_focus_position()
	if not PlayerPickupUtil.is_in_front_pickup_zone(probe, item_center):
		return false
	return _has_clear_environment_los(probe["origin"], item_center, request_player)


func _has_clear_environment_los(from: Vector3, to: Vector3, request_player: Node3D) -> bool:
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collision_mask = environment_mask
	params.exclude = [request_player.get_rid(), get_rid()]
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		return true
	# 道具常摆在桌子/台面上：射线先打到台面时，落点靠近道具仍算可见
	var hit_pos: Vector3 = hit.position
	return hit_pos.distance_to(to) <= pickup_los_surface_slack_m


func _get_interact_probe(request_player: Node3D) -> Dictionary:
	var use_flat: bool = false
	if request_player.has_method("get_role"):
		use_flat = request_player.get_role() == GameManager.ROLE_BLIND
	var probe := PlayerPickupUtil.build_probe(request_player, use_flat)
	if probe.is_empty():
		return {"from": request_player.global_position + Vector3(0, 0.9, 0)}
	return {"from": probe["origin"]}


func _resolve_request_player(sender_id: int) -> Node3D:
	var root := _get_players_root()
	if root == null:
		return null
	if sender_id == 1:
		if GameManager.current_role == GameManager.ROLE_BLIND:
			return root.get_node_or_null("BlindPlayer") as Node3D
		return root.get_node_or_null("LamePlayer") as Node3D
	if sender_id == NetworkManager.remote_peer_id:
		if GameManager.current_role == GameManager.ROLE_BLIND:
			return root.get_node_or_null("LamePlayer") as Node3D
		return root.get_node_or_null("BlindPlayer") as Node3D
	return null


## 测试关药品在 GameWorld 下；Stage1 药品在 GameWorld/Level 下，不能只用 get_parent()
func _get_players_root() -> Node:
	var scene := get_tree().current_scene
	if scene != null and scene.get_node_or_null("BlindPlayer") != null:
		return scene
	var node: Node = self
	while node != null:
		if node.get_node_or_null("BlindPlayer") != null:
			return node
		node = node.get_parent()
	return null


func _is_hospital_clue_item() -> bool:
	if medicine_type != TYPE_KEY:
		return false
	if GameManager.puzzle_clues_enabled:
		return false
	var flow := get_tree().get_first_node_in_group("game_level_flow") as GameLevelFlow
	return flow != null and flow.phase == GameLevelFlow.Phase.MAIN


func _notify_hospital_clue_pickup() -> void:
	var flow := get_tree().get_first_node_in_group("game_level_flow") as GameLevelFlow
	if flow == null:
		return
	match hospital_stage:
		HospitalStage.STAGE_1:
			flow.notify_stage1_clue_collected(String(name))
		HospitalStage.STAGE_2:
			flow.notify_stage2_clue_collected(String(name))
