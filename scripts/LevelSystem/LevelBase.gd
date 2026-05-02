extends Node3D
class_name LevelBase


# 根节点脚本若重写 _ready，须先 super._ready()
func _ready() -> void:
	LevelManager.hide_mask()
	if _scene_has_navigation_region():
		_init_navigation_ai()


func _scene_has_navigation_region() -> bool:
	return not find_children("*", "NavigationRegion3D", true, false).is_empty()


func _init_navigation_ai() -> void:
	pass


func _on_goal_reached() -> void:
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	LevelManager.advance()
