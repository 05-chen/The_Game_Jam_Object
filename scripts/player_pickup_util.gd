extends RefCounted
class_name PlayerPickupUtil

## 拾取区：身前圆柱（直径≈身高/3，轴向长度≈身高），后背无效。

const DEFAULT_PLAYER_HEIGHT: float = 1.8
const PICKUP_LENGTH_SCALE: float = 1.0


static func get_body_height(player: CharacterBody3D) -> float:
	if player == null:
		return DEFAULT_PLAYER_HEIGHT
	var col_shape := player.get_node_or_null("Col") as CollisionShape3D
	if col_shape != null and col_shape.shape is CapsuleShape3D:
		return (col_shape.shape as CapsuleShape3D).height
	return DEFAULT_PLAYER_HEIGHT


static func build_probe(player: Node3D, use_flat_forward: bool) -> Dictionary:
	var body := player as CharacterBody3D
	var height := get_body_height(body)
	var pickup_radius := height / 6.0
	var max_forward := height * PICKUP_LENGTH_SCALE
	var cam := player.get_node_or_null("Camera3D") as Camera3D
	var origin: Vector3
	var forward: Vector3
	if cam != null:
		origin = cam.global_position
		forward = -cam.global_transform.basis.z
	else:
		origin = player.global_position + Vector3(0, height * 0.5, 0)
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
		"height": height,
	}


static func is_in_front_pickup_zone(probe: Dictionary, target_pos: Vector3) -> bool:
	if probe.is_empty():
		return false
	var origin: Vector3 = probe["origin"]
	var forward: Vector3 = probe["forward"]
	var max_forward: float = probe["max_forward"]
	var pickup_radius: float = probe["pickup_radius"]
	var to: Vector3 = target_pos - origin
	if to.dot(forward) <= 0.0:
		return false
	var along: float = to.dot(forward)
	if along > max_forward:
		return false
	var lateral: Vector3 = to - forward * along
	return lateral.length() <= pickup_radius


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
