extends RefCounted
class_name InputMouseGuard
## 联机 UI 鼠标状态机：菜单显示必释放，恢复游戏仅本地控制角色捕获。


static func release_for_ui() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


static func capture_for_local_player() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var world := tree.current_scene
	if world == null:
		return
	for node_name in ["BlindPlayer", "LamePlayer"]:
		var p := world.get_node_or_null(node_name)
		if p == null:
			continue
		if p.has_method("_can_control_local_camera") and p.call("_can_control_local_camera"):
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
