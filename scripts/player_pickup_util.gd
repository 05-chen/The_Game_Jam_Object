extends RefCounted
class_name PlayerPickupUtil

## 拾取区：身前圆柱（默认横向半径≈身高/6，前向≈身高），后背无效。
## 各玩家在 Inspector「拾取范围」分组里调节倍数与偏移。

const DEFAULT_PLAYER_HEIGHT: float = 1.8


static func get_body_height(player: CharacterBody3D) -> float:
	if player == null:
		return DEFAULT_PLAYER_HEIGHT
	var col_shape := player.get_node_or_null("Col") as CollisionShape3D
	if col_shape != null and col_shape.shape is CapsuleShape3D:
		return (col_shape.shape as CapsuleShape3D).height
	return DEFAULT_PLAYER_HEIGHT


static func get_player_pickup_config(player: Node3D) -> Dictionary:
	if player != null and player.has_method("get_pickup_probe_config"):
		return player.call("get_pickup_probe_config")
	return {}


static func build_probe(player: Node3D, use_flat_forward: bool) -> Dictionary:
	var body := player as CharacterBody3D
	var height := get_body_height(body)
	var cfg := get_player_pickup_config(player)
	var radius_scale: float = float(cfg.get("radius_scale", 1.0))
	var forward_scale: float = float(cfg.get("forward_scale", 1.0))
	var origin_lower_m: float = float(cfg.get("origin_lower_m", 0.0))
	var vertical_half_m: float = float(cfg.get("vertical_half_m", -1.0))
	var use_camera_origin: bool = bool(cfg.get("use_camera_origin", true))
	var pickup_radius: float = (height / 6.0) * radius_scale
	var max_forward: float = height * forward_scale
	if vertical_half_m < 0.0:
		vertical_half_m = pickup_radius
	var cam := player.get_node_or_null("Camera3D") as Camera3D
	var origin: Vector3
	var forward: Vector3
	if use_camera_origin and cam != null:
		origin = cam.global_position + Vector3(0.0, -origin_lower_m, 0.0)
		forward = -cam.global_transform.basis.z
	elif cam != null:
		origin = cam.global_position + Vector3(0.0, -origin_lower_m, 0.0)
		forward = -cam.global_transform.basis.z
	else:
		origin = player.global_position + Vector3(0.0, height * 0.5 - origin_lower_m, 0.0)
		forward = -player.global_transform.basis.z
	if use_flat_forward:
		forward.y = 0.0
	if forward.length_squared() < 1e-8:
		return {}
	forward = forward.normalized()
	return {
		"origin": origin,
		"forward": forward,
		"pickup_radius": pickup_radius,
		"max_forward": max_forward,
		"vertical_half_m": vertical_half_m,
		"height": height,
	}


static func is_in_front_pickup_zone(probe: Dictionary, target_pos: Vector3) -> bool:
	if probe.is_empty():
		return false
	var origin: Vector3 = probe["origin"]
	var forward: Vector3 = probe["forward"]
	var max_forward: float = probe["max_forward"]
	var pickup_radius: float = probe["pickup_radius"]
	var vertical_half_m: float = probe["vertical_half_m"]
	var to: Vector3 = target_pos - origin
	if to.dot(forward) <= 0.0:
		return false
	var along: float = to.dot(forward)
	if along > max_forward:
		return false
	var lateral: Vector3 = to - forward * along
	var lateral_xz := Vector3(lateral.x, 0.0, lateral.z)
	if lateral_xz.length() > pickup_radius:
		return false
	return absf(lateral.y) <= vertical_half_m


static func find_best_pickup_target(
	player: Node3D,
	role: int,
	use_flat_forward: bool
) -> Dictionary:
	var probe := build_probe(player, use_flat_forward)
	if probe.is_empty():
		return {}
	var probe_origin: Vector3 = probe["origin"]
	var best: Node = null
	var best_dist: float = INF
	for node in player.get_tree().get_nodes_in_group("interactable_pickup"):
		if node == null or not is_instance_valid(node):
			continue
		if not node.has_method("interact") or not node.has_method("can_role_pickup"):
			continue
		if not node.call("can_role_pickup", role):
			continue
		if node.has_method("is_interact_exhausted") and node.call("is_interact_exhausted"):
			continue
		if node.has_method("is_stage_interaction_enabled") and not node.call("is_stage_interaction_enabled"):
			continue
		var target_pos: Vector3 = node.global_position
		if node.has_method("get_pickup_focus_position"):
			target_pos = node.call("get_pickup_focus_position")
		if not is_in_front_pickup_zone(probe, target_pos):
			continue
		var dist: float = probe_origin.distance_to(target_pos)
		if dist < best_dist:
			best_dist = dist
			best = node
	if best == null:
		return {}
	return {"target": best, "origin": probe_origin}


## 运行时调试：在玩家下挂 PickupDebug 网格，随 Inspector 参数实时变化
static func sync_debug_visual(player: Node3D, debug_root: Node3D, use_flat_forward: bool) -> void:
	if debug_root == null:
		return
	var probe := build_probe(player, use_flat_forward)
	if probe.is_empty():
		debug_root.visible = false
		return
	debug_root.visible = true
	var forward: Vector3 = probe["forward"]
	var radius: float = probe["pickup_radius"]
	var length: float = probe["max_forward"]
	var vertical_half: float = probe["vertical_half_m"]
	var origin: Vector3 = probe["origin"]
	var center := origin + forward * (length * 0.5)
	debug_root.global_position = center
	var up := Vector3.UP if absf(forward.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var side := forward.cross(up).normalized()
	up = side.cross(forward).normalized()
	debug_root.global_transform.basis = Basis(side, up, forward)
	var cyl := debug_root.get_node_or_null("Cylinder") as MeshInstance3D
	var label := debug_root.get_node_or_null("Label") as Label3D
	if cyl != null:
		cyl.scale = Vector3(radius * 2.0, vertical_half * 2.0, length)
	if label != null:
		label.text = "R=%.2f F=%.2f V=%.2f" % [radius, length, vertical_half]


static func ensure_debug_root(player: Node3D) -> Node3D:
	var existing := player.get_node_or_null("PickupDebug") as Node3D
	if existing != null:
		return existing
	var root := Node3D.new()
	root.name = "PickupDebug"
	var cyl := MeshInstance3D.new()
	cyl.name = "Cylinder"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.5
	mesh.bottom_radius = 0.5
	mesh.height = 1.0
	cyl.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.85, 1.0, 0.25)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cyl.material_override = mat
	root.add_child(cyl)
	var label := Label3D.new()
	label.name = "Label"
	label.font_size = 48
	label.modulate = Color(0.3, 1.0, 0.5)
	label.position = Vector3(0, 0.6, 0)
	root.add_child(label)
	player.add_child(root)
	return root
