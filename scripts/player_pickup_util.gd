extends RefCounted
class_name PlayerPickupUtil

## 拾取区：以「胶囊中心」为原点向前延伸（默认横向半径≈身高/6，前向≈身高）。
## 瘸子可叠背负高度（瞎子身高 / CarryAnchor），从而捡到更高处物品。
## 勾选 pickup_show_debug 仅在编辑器显示范围线框（运行游戏不显示）。

const DEFAULT_PLAYER_HEIGHT: float = 1.8
## 统一最远拾取距离（米）；配置里可用 max_forward_m 覆盖
const DEFAULT_MAX_FORWARD_M: float = 3.5
## 物理层 4 = items（project.godot）；拾取几何判定不依赖环境射线
const ITEM_PHYSICS_LAYER_BIT: int = 8


static func get_body_height(player: CharacterBody3D) -> float:
	if player == null:
		return DEFAULT_PLAYER_HEIGHT
	var col_shape := player.get_node_or_null("Col") as CollisionShape3D
	if col_shape != null and col_shape.shape is CapsuleShape3D:
		return (col_shape.shape as CapsuleShape3D).height
	return DEFAULT_PLAYER_HEIGHT


## 碰撞胶囊中心（Col 节点世界坐标；无 Col 时取脚底 + 半身）
static func get_capsule_center(player: Node3D) -> Vector3:
	if player == null:
		return Vector3.ZERO
	var col := player.get_node_or_null("Col") as Node3D
	if col != null:
		return col.global_position
	var body := player as CharacterBody3D
	var height := get_body_height(body)
	return player.global_position + Vector3(0.0, height * 0.5, 0.0)


static func get_player_pickup_config(player: Node3D) -> Dictionary:
	if player == null:
		return {}
	# 编辑器中非 @tool 脚本是 placeholder：不能 call 自定义方法，只能读 export
	if Engine.is_editor_hint():
		return read_pickup_exports(player)
	if player.has_method("get_pickup_probe_config"):
		var result: Variant = player.call("get_pickup_probe_config")
		if result is Dictionary:
			return result as Dictionary
	return read_pickup_exports(player)


## 直接读 Inspector export（编辑器 gizmo / 运行时兜底均可用，不依赖脚本方法）
static func read_pickup_exports(player: Node3D) -> Dictionary:
	var is_lame := false
	var script := player.get_script() as Script
	if script != null:
		is_lame = String(script.resource_path).ends_with("lame_player.gd")
	var carrier_h := _export_float(player, "pickup_carrier_height_m", DEFAULT_PLAYER_HEIGHT)
	return {
		"radius_scale": _export_float(player, "pickup_radius_scale", 1.0),
		"forward_scale": _export_float(player, "pickup_forward_scale", 1.0),
		"max_forward_m": _export_float(player, "pickup_max_forward_m", DEFAULT_MAX_FORWARD_M),
		"origin_offset_y": _export_float(player, "pickup_origin_offset_y", 0.0),
		"vertical_half_m": _export_float(player, "pickup_vertical_half_m", -1.0),
		"use_carrier_height": is_lame,
		"carrier_height_m": carrier_h,
		"carrier_player_path": "../BlindPlayer",
	}


static func _export_float(player: Object, property: String, default_value: float) -> float:
	var value: Variant = player.get(property)
	if value == null:
		return default_value
	return float(value)


static func build_probe(player: Node3D, use_flat_forward: bool) -> Dictionary:
	var body := player as CharacterBody3D
	var height := get_body_height(body)
	var cfg := get_player_pickup_config(player)
	var radius_scale: float = float(cfg.get("radius_scale", 1.0))
	var forward_scale: float = float(cfg.get("forward_scale", 1.0))
	var origin_offset_y: float = float(cfg.get("origin_offset_y", cfg.get("origin_lower_m", 0.0)))
	var vertical_half_m: float = float(cfg.get("vertical_half_m", -1.0))
	var pickup_radius: float = (height / 6.0) * radius_scale
	var max_forward: float = float(cfg.get("max_forward_m", DEFAULT_MAX_FORWARD_M))
	if max_forward <= 0.0:
		max_forward = height * forward_scale
	if vertical_half_m < 0.0:
		vertical_half_m = maxf(height * 0.55, pickup_radius)

	var origin := _resolve_probe_origin(player, cfg, origin_offset_y)
	var forward := _resolve_probe_forward(player, use_flat_forward)
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


static func _resolve_probe_origin(player: Node3D, cfg: Dictionary, origin_offset_y: float) -> Vector3:
	# 优先：脚本直接给出世界原点
	if cfg.has("origin_world") and cfg["origin_world"] is Vector3:
		var override_origin: Vector3 = cfg["origin_world"]
		return override_origin + Vector3(0.0, origin_offset_y, 0.0)

	var origin := get_capsule_center(player)

	# 瘸子：判定中心抬到「瞎子胶囊中心 + 瞎子身高」，能覆盖肩上视角下的高处物品
	if bool(cfg.get("use_carrier_height", false)):
		var carrier_h := float(cfg.get("carrier_height_m", DEFAULT_PLAYER_HEIGHT))
		var carrier_path := String(cfg.get("carrier_player_path", "../BlindPlayer"))
		var carrier := player.get_node_or_null(carrier_path) as Node3D
		if carrier != null:
			var desired_y := get_capsule_center(carrier).y + carrier_h
			origin.y = desired_y
		else:
			# 单独打开瘸子场景时：在自身胶囊中心上再加瞎子身高
			origin.y += carrier_h

	return origin + Vector3(0.0, origin_offset_y, 0.0)


static func _resolve_probe_forward(player: Node3D, use_flat_forward: bool) -> Vector3:
	# 朝向仍可用相机（只决定前方），原点不再用相机位置
	var cam := player.get_node_or_null("Camera3D") as Camera3D
	var forward: Vector3
	if cam != null:
		forward = -cam.global_transform.basis.z
	else:
		forward = -player.global_transform.basis.z
	if use_flat_forward:
		forward.y = 0.0
	return forward


static func is_in_front_pickup_zone(probe: Dictionary, target_pos: Vector3) -> bool:
	if probe.is_empty():
		return false
	var origin: Vector3 = probe["origin"]
	var forward: Vector3 = probe["forward"]
	var max_forward: float = probe["max_forward"]
	var pickup_radius: float = probe["pickup_radius"]
	var vertical_half_m: float = probe["vertical_half_m"]
	var to: Vector3 = target_pos - origin
	# 贴身兜底：站在旁边即可
	var flat_to := Vector3(to.x, 0.0, to.z)
	var flat_dist := flat_to.length()
	if flat_dist <= pickup_radius * 1.35 and absf(to.y) <= vertical_half_m:
		return true
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
