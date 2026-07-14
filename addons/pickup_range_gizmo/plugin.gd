@tool
extends EditorPlugin

## 在编辑器中为 BlindPlayer / LamePlayer 绘制拾取范围（类似灯光范围 gizmo）。
## 游戏运行时不会显示。

var _gizmo_plugin: EditorNode3DGizmoPlugin


func _enter_tree() -> void:
	_gizmo_plugin = preload("res://addons/pickup_range_gizmo/pickup_range_gizmo.gd").new()
	add_node_3d_gizmo_plugin(_gizmo_plugin)
	var inspector := EditorInterface.get_inspector()
	if not inspector.property_edited.is_connected(_on_inspector_property_edited):
		inspector.property_edited.connect(_on_inspector_property_edited)


func _exit_tree() -> void:
	var inspector := EditorInterface.get_inspector()
	if inspector.property_edited.is_connected(_on_inspector_property_edited):
		inspector.property_edited.disconnect(_on_inspector_property_edited)
	if _gizmo_plugin != null:
		remove_node_3d_gizmo_plugin(_gizmo_plugin)
		_gizmo_plugin = null


func _on_inspector_property_edited(property: String) -> void:
	if not property.begins_with("pickup_"):
		return
	var obj := EditorInterface.get_inspector().get_edited_object()
	if obj is Node3D and (obj as Node3D).has_method("get_pickup_probe_config"):
		(obj as Node3D).update_gizmos()
