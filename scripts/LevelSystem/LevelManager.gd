extends Node

## Autoload：关卡切换总调度。
##
## 两种模式（勿混用同一阶段）：
## 1. **局内流程** [GameLevelFlow]：GameWorld 不卸载，子场景测试关 → 实例化大场景（house_f_1）、拆 AirWall。
##    触发：GameManager.stage_cleared（集齐钥匙）→ [method notify_tutorial_stage_cleared]。
## 2. **整场景切换** [method advance]：`change_scene_to_file`，按 `level_array` 换 .tscn（如 LevelBase 终点）。
##    触发：LevelBase._on_goal_reached() → [method advance]。
##
## 改「测试关进医院」→ scripts/LevelSystem/GameLevelFlow.gd
## 改「整关换场景 / level_array」→ 本文件

@export var level_array: Array[String] = []

var _level_index: int = 0
var _in_scene_flow: GameLevelFlow = null
var _mask_layer: CanvasLayer
var _mask_rect: ColorRect
var _tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_mask()
	if not GameManager.stage_cleared.is_connected(_on_tutorial_stage_cleared):
		GameManager.stage_cleared.connect(_on_tutorial_stage_cleared)


func register_in_scene_flow(flow: GameLevelFlow) -> void:
	_in_scene_flow = flow


func _on_tutorial_stage_cleared() -> void:
	notify_tutorial_stage_cleared()


## 测试关集齐钥匙 → 局内切到大场景（Host 权威 + RPC 在 GameLevelFlow）
func notify_tutorial_stage_cleared() -> void:
	if _in_scene_flow == null:
		push_warning("[LevelManager] 未注册 GameLevelFlow，无法进入大场景")
		return
	_in_scene_flow.request_enter_main_level()


func _build_mask() -> void:
	_mask_layer = CanvasLayer.new()
	_mask_layer.layer = 128
	_mask_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_mask_layer)
	_mask_rect = ColorRect.new()
	_mask_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_mask_rect.offset_left = 0.0
	_mask_rect.offset_top = 0.0
	_mask_rect.offset_right = 0.0
	_mask_rect.offset_bottom = 0.0
	_mask_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mask_rect.color = Color.BLACK
	_mask_rect.modulate.a = 0.0
	_mask_rect.visible = false
	_mask_layer.add_child(_mask_rect)


func _new_tween_pause_immune() -> Tween:
	if _tween != null and is_instance_valid(_tween):
		_tween.kill()
	_tween = create_tween()
	_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	return _tween


@rpc("authority", "call_local", "reliable")
func sync_transition(scene_path: String) -> void:
	await _run_transition(scene_path)


func _run_transition(scene_path: String) -> void:
	var tree := get_tree()
	tree.paused = true
	_mask_rect.visible = true
	_mask_rect.modulate.a = 0.0
	var tw := _new_tween_pause_immune()
	tw.tween_property(_mask_rect, "modulate:a", 1.0, 0.35)
	await tw.finished
	var err := tree.change_scene_to_file(scene_path)
	if err != OK:
		push_error("[LevelManager] change_scene failed: %s (%d)" % [scene_path, err])
		tree.paused = false
		_mask_rect.modulate.a = 0.0
		_mask_rect.visible = false


func hide_mask() -> void:
	var tw := _new_tween_pause_immune()
	_mask_rect.visible = true
	tw.tween_property(_mask_rect, "modulate:a", 0.0, 0.35)
	await tw.finished
	_mask_rect.visible = false
	get_tree().paused = false


func advance() -> void:
	if NetworkManager.is_multiplayer_game and not multiplayer.is_server():
		return
	if level_array.is_empty():
		return
	_level_index += 1
	if _level_index >= level_array.size():
		_level_index = level_array.size() - 1
		return
	var path: String = level_array[_level_index]
	if NetworkManager.is_multiplayer_game:
		sync_transition.rpc(path)
	else:
		await _run_transition(path)


func set_level_index(idx: int) -> void:
	_level_index = clampi(idx, 0, maxi(level_array.size() - 1, 0))
