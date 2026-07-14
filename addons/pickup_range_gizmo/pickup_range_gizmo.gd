@tool
extends EditorNode3DGizmoPlugin

## 编辑器专用：按玩家「拾取范围」参数画线框，效果接近 SpotLight 范围示意。
## 仅在编辑器可见；游戏运行时不会绘制。

const RING_SIDES := 16
const DASH_COUNT := 10


func _get_gizmo_name() -> String:
	return "PickupRange"


func _has_gizmo(node: Node3D) -> bool:
	# 勿依赖 has_method：编辑器 placeholder 上 call 会报错；用 export 判定
	return node != null and node.get("pickup_show_debug") != null and node.get("pickup_radius_scale") != null


func _init() -> void:
	create_material("pickup_range", Color(1.0, 0.85, 0.15, 1.0), false, true, true)


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d()
	if node == null:
		return
	if not bool(node.get("pickup_show_debug")):
		return

	var use_flat := _use_flat_forward(node)
	var probe: Dictionary = PlayerPickupUtil.build_probe(node, use_flat)
	if probe.is_empty():
		return

	var origin: Vector3 = probe["origin"]
	var forward: Vector3 = probe["forward"]
	var radius: float = probe["pickup_radius"]
	var length: float = probe["max_forward"]
	var vertical_half: float = probe["vertical_half_m"]

	var up := Vector3.UP
	if absf(forward.dot(up)) > 0.95:
		up = Vector3.RIGHT
	var side := forward.cross(up).normalized()
	up = side.cross(forward).normalized()

	var to_local := node.global_transform.affine_inverse()
	var lines := PackedVector3Array()
	_append_wire_lines(lines, to_local, origin, forward, side, up, radius, vertical_half, length)

	var mat := get_material("pickup_range", gizmo)
	gizmo.add_lines(lines, mat, false)


func _use_flat_forward(node: Node3D) -> bool:
	# 拾取朝向压平到水平：高度由胶囊中心 + 竖直半高覆盖
	return true


func _ellipse_point(side: Vector3, up: Vector3, radius: float, vertical_half: float, angle: float) -> Vector3:
	return side * (cos(angle) * radius) + up * (sin(angle) * vertical_half)


func _append_wire_lines(
	lines: PackedVector3Array,
	to_local: Transform3D,
	origin: Vector3,
	forward: Vector3,
	side: Vector3,
	up: Vector3,
	radius: float,
	vertical_half: float,
	length: float
) -> void:
	for i in RING_SIDES:
		var a0 := TAU * float(i) / float(RING_SIDES)
		var a1 := TAU * float(i + 1) / float(RING_SIDES)
		var p0 := origin + _ellipse_point(side, up, radius, vertical_half, a0)
		var p1 := origin + _ellipse_point(side, up, radius, vertical_half, a1)
		lines.append(to_local * p0)
		lines.append(to_local * p1)
		lines.append(to_local * (p0 + forward * length))
		lines.append(to_local * (p1 + forward * length))

	for i in 4:
		var a := TAU * float(i) / 4.0 + PI * 0.25
		var p := origin + _ellipse_point(side, up, radius, vertical_half, a)
		lines.append(to_local * p)
		lines.append(to_local * (p + forward * length))

	for i in DASH_COUNT:
		if i % 2 == 1:
			continue
		var t0 := float(i) / float(DASH_COUNT)
		var t1 := float(i + 1) / float(DASH_COUNT)
		lines.append(to_local * (origin + forward * (length * t0)))
		lines.append(to_local * (origin + forward * (length * t1)))

	var cross := mini(radius, vertical_half) * 0.35
	lines.append(to_local * (origin - side * cross))
	lines.append(to_local * (origin + side * cross))
	lines.append(to_local * (origin - up * cross))
	lines.append(to_local * (origin + up * cross))
