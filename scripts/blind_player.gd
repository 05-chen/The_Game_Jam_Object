extends CharacterBody3D

@export var move_speed: float = 4.0
@export var mouse_sensitivity: float = 0.003
@export var visual_smooth: float = 18.0
## 联机：位移“够大才算动”的宽松阈值（米），与旋转阈值分离，避免小碎步抢带宽
@export var sync_move_pos_epsilon_m: float = 0.05
## 发送 / 广播时 yaw、pitch 的最小变化（度），取极小值保证转头连贯
@export var sync_rot_send_epsilon_deg: float = 0.1
## 摇杆式移动意图：输入向量变化低于此视为未变（与位移阈值概念分离，取较松）
@export var sync_input_vector_epsilon: float = 0.05
## 动作中（移动/转头/本帧鼠标）客户端发输入、主机播快照的间隔（毫秒）
@export var sync_host_broadcast_interval_ms: int = 33
## 完全静止时的慢心跳（毫秒）
@export var sync_move_rpc_heartbeat_still_ms: int = 80
## 表现层：水平角略快于位置，减轻 40~50ms 快照间隔下的视角滞涩（仍用 lerp_angle 最短弧）
@export var visual_smooth_rot_scale: float = 1.22

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var is_local: bool = false

var _remote_move_input: Vector2 = Vector2.ZERO
var _remote_rot_y: float = 0.0
var _remote_cam_x: float = 0.0
var _net_pos: Vector3 = Vector3.ZERO
var _net_rot_y: float = 0.0
var _net_cam_x: float = 0.0

## 联机：减少「每物理帧一包」；动作优先时收紧到 sync_host_broadcast_interval_ms
var _last_move_rpc_ms: int = -1_000_000
var _last_sent_input: Vector2 = Vector2(INF, INF)
var _last_sent_rot_y: float = INF
var _last_sent_cam_x: float = INF
var _mouse_look_this_frame: bool = false
var _prev_phys_rot_y: float = 0.0
var _prev_phys_cam_x: float = 0.0
var _prev_phys_initialized: bool = false

var _last_sync_broadcast_ms: int = -1_000_000
var _last_bcast_pos: Vector3 = Vector3(INF, INF, INF)
var _last_bcast_rot_y: float = INF
var _last_bcast_cam_x: float = INF
var _has_ever_bcast: bool = false

@onready var camera: Camera3D = $Camera3D
@onready var ui_root: CanvasLayer = $UI
@onready var health_bar: ProgressBar = $UI/Stats/HealthBar
@onready var health_label: Label = $UI/Stats/HealthLabel
@onready var msg_label: Label = $UI/MsgLabel
@onready var vision_mask: ColorRect = $UI/VisionMask

var spot_light: SpotLight3D = null
var _audio_listener: AudioListener3D = null


func _ready() -> void:
	add_to_group("player")
	_net_pos = global_position
	_net_rot_y = rotation.y
	_net_cam_x = camera.rotation.x
	_prev_phys_rot_y = rotation.y
	_prev_phys_cam_x = camera.rotation.x
	_prev_phys_initialized = true
	if not is_local:
		camera.current = false
		if ui_root:
			ui_root.visible = false
		return
	if GameManager.current_role != GameManager.ROLE_BLIND:
		camera.current = false
		if ui_root:
			ui_root.visible = false
		return
	camera.current = true
	camera.make_current()
	if ui_root:
		ui_root.visible = true
	_audio_listener = AudioListener3D.new()
	camera.add_child(_audio_listener)
	_audio_listener.make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# 瞎子路径：显式不连接 pain_value_changed；UI 仅心理值（场景无疼痛条）。瘸子疼痛由 GameManager 同步，供 VoiceChatManager 调节对方语音音量。
	GameManager.mental_health_changed.connect(_on_health)
	GameManager.game_over_triggered.connect(_on_over)
	GameManager.medicine_collected.connect(_on_med)
	GameManager.puzzle_solved.connect(_on_puzzle)
	_disable_scene_lights_for_blind_view()
	_setup_spot_light()
	_refresh_light()
	var vp := get_viewport()
	if vp and not vp.size_changed.is_connected(_on_viewport_size_changed):
		vp.size_changed.connect(_on_viewport_size_changed)


func _exit_tree() -> void:
	var vp := get_viewport()
	if vp and vp.size_changed.is_connected(_on_viewport_size_changed):
		vp.size_changed.disconnect(_on_viewport_size_changed)


func _on_viewport_size_changed() -> void:
	_refresh_light()


func _disable_scene_lights_for_blind_view() -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	_disable_lights_recursive(scene_root)


func _disable_lights_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is Light3D:
			(child as Light3D).visible = false
		_disable_lights_recursive(child)


func _unhandled_input(event: InputEvent) -> void:
	if not is_local or not GameManager.is_game_active:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_mouse_look_this_frame = true
		rotate_y(-event.relative.x * mouse_sensitivity)
		camera.rotate_x(-event.relative.y * mouse_sensitivity)
		camera.rotation.x = clampf(camera.rotation.x, -1.5, 1.5)
	if event.is_action_pressed("interact"):
		_try_interact()


func _process(delta: float) -> void:
	if not NetworkManager.is_multiplayer_game or multiplayer.is_server():
		return
	var k_pos := clampf(visual_smooth * delta, 0.0, 1.0)
	global_position = global_position.lerp(_net_pos, k_pos)
	var local_blind := is_local and GameManager.current_role == GameManager.ROLE_BLIND
	if not local_blind:
		# lerp_angle 走最短弧；角速度用略大的 k，快照间隔抖动时仍平滑趋近目标
		var k_rot := clampf(visual_smooth * visual_smooth_rot_scale * delta, 0.0, 1.0)
		rotation.y = lerp_angle(rotation.y, _net_rot_y, k_rot)
		if camera:
			camera.rotation.x = lerpf(camera.rotation.x, _net_cam_x, k_rot)


func _physics_process(delta: float) -> void:
	if not GameManager.is_game_active or GameManager.is_game_over:
		return
	if not NetworkManager.is_multiplayer_game:
		if not is_local:
			return
		_simulate_blind_movement(delta)
		GameManager.update_mental_health(delta)
		return
	if multiplayer.is_server():
		_simulate_blind_movement_server(delta)
		return
	if not is_local or not GameManager.is_game_active:
		return
	if GameManager.current_role != GameManager.ROLE_BLIND:
		return
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var cam_x := camera.rotation.x
	var now_ms := Time.get_ticks_msec()
	var rot_eps_rad := deg_to_rad(sync_rot_send_epsilon_deg)
	## 与「发送阈值 0.1°」分离：仅检测物理帧之间是否在转头（略大于浮点噪声即可）
	var turn_step_rad := deg_to_rad(0.02)

	var moving := input_dir.length_squared() > 1e-6
	var turning_step := false
	if _prev_phys_initialized:
		turning_step = absf(angle_difference(_prev_phys_rot_y, rotation.y)) >= turn_step_rad or absf(_prev_phys_cam_x - cam_x) >= turn_step_rad
	_prev_phys_rot_y = rotation.y
	_prev_phys_cam_x = cam_x
	_prev_phys_initialized = true

	var action_priority := moving or turning_step or _mouse_look_this_frame
	var interval_ms := sync_host_broadcast_interval_ms if action_priority else sync_move_rpc_heartbeat_still_ms
	var heartbeat := now_ms - _last_move_rpc_ms >= interval_ms

	var input_changed := input_dir.distance_to(_last_sent_input) >= sync_input_vector_epsilon
	var rot_changed := absf(angle_difference(_last_sent_rot_y, rotation.y)) >= rot_eps_rad
	var cam_changed := absf(_last_sent_cam_x - cam_x) >= rot_eps_rad

	if not (heartbeat or input_changed or rot_changed or cam_changed):
		return
	_last_sent_input = input_dir
	_last_sent_rot_y = rotation.y
	_last_sent_cam_x = cam_x
	_last_move_rpc_ms = now_ms
	_mouse_look_this_frame = false
	s_request_move.rpc_id(1, input_dir, rotation.y, cam_x)


func _simulate_blind_movement(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var dir := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if dir != Vector3.ZERO:
		velocity.x = dir.x * move_speed
		velocity.z = dir.z * move_speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed)
		velocity.z = move_toward(velocity.z, 0.0, move_speed)
	move_and_slide()


func _simulate_blind_movement_server(delta: float) -> void:
	var input_dir: Vector2
	if GameManager.current_role == GameManager.ROLE_BLIND:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	else:
		input_dir = _remote_move_input
		rotation.y = _remote_rot_y
		if camera:
			camera.rotation.x = _remote_cam_x
	if not is_on_floor():
		velocity.y -= gravity * delta
	var dir := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if dir != Vector3.ZERO:
		velocity.x = dir.x * move_speed
		velocity.z = dir.z * move_speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed)
		velocity.z = move_toward(velocity.z, 0.0, move_speed)
	move_and_slide()
	GameManager.update_mental_health(delta)
	var now_ms := Time.get_ticks_msec()
	var rot_eps_rad := deg_to_rad(sync_rot_send_epsilon_deg)

	var moving := input_dir.length_squared() > 1e-6
	var physically_active := moving or velocity.length_squared() > 0.02
	var interval_ms := sync_host_broadcast_interval_ms if physically_active else sync_move_rpc_heartbeat_still_ms
	var heartbeat := now_ms - _last_sync_broadcast_ms >= interval_ms

	var pos_delta := 0.0 if not _has_ever_bcast else global_position.distance_to(_last_bcast_pos)
	var pos_push := not _has_ever_bcast or pos_delta >= sync_move_pos_epsilon_m
	var rot_push := not _has_ever_bcast or absf(angle_difference(_last_bcast_rot_y, rotation.y)) >= rot_eps_rad
	var cam_push := not _has_ever_bcast or absf(_last_bcast_cam_x - camera.rotation.x) >= rot_eps_rad

	if heartbeat or pos_push or rot_push or cam_push:
		_last_sync_broadcast_ms = now_ms
		_last_bcast_pos = global_position
		_last_bcast_rot_y = rotation.y
		_last_bcast_cam_x = camera.rotation.x
		_has_ever_bcast = true
		c_sync_transform.rpc(global_position, rotation.y, camera.rotation.x, GameManager.mental_health)


@rpc("any_peer", "unreliable_ordered")
func s_request_move(input_dir: Vector2, rot_y: float, cam_x: float) -> void:
	if not NetworkManager.is_multiplayer_game or not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not NetworkManager.is_trusted_sender(sender_id):
		return
	if GameManager.current_role == GameManager.ROLE_BLIND:
		return
	if sender_id != NetworkManager.remote_peer_id:
		return
	_remote_move_input = input_dir
	_remote_rot_y = rot_y
	_remote_cam_x = cam_x


@rpc("authority", "unreliable_ordered", "call_remote")
func c_sync_transform(target_pos: Vector3, target_rot_y: float, target_cam_x: float, mh: float) -> void:
	if not NetworkManager.is_multiplayer_game:
		return
	_net_pos = target_pos
	_net_rot_y = target_rot_y
	_net_cam_x = target_cam_x
	GameManager.mental_health = mh
	GameManager.mental_health_changed.emit(mh)


func _on_health(value: float) -> void:
	health_bar.value = value
	health_label.text = "心理值: " + str(int(value)) + "%"
	_refresh_light()


func _setup_spot_light() -> void:
	spot_light = SpotLight3D.new()
	spot_light.light_color = Color(0.1, 0.1, 0.15)
	spot_light.light_energy = 2.0
	spot_light.spot_range = 0.7
	spot_light.spot_angle = 10.0
	spot_light.spot_attenuation = 0.5
	spot_light.shadow_enabled = true
	camera.add_child(spot_light)
	var camera_env := Environment.new()
	camera_env.background_mode = Environment.BG_COLOR
	camera_env.background_color = Color(0, 0, 0)
	camera_env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	camera_env.ambient_light_energy = 0.0
	camera_env.fog_enabled = false
	camera.environment = camera_env


func _refresh_light() -> void:
	if not is_local:
		return
	var mh := GameManager.mental_health
	var ratio := clampf(mh / 100.0, 0.0, 1.0)
	if spot_light != null:
		spot_light.light_energy = 1.0 + ratio * 1.5
	if vision_mask and vision_mask.material is ShaderMaterial:
		var mat := vision_mask.material as ShaderMaterial
		var target_radius := ratio * 0.18
		if mh < 8.0:
			target_radius = 0.0
		var current_r = mat.get_shader_parameter("vision_radius")
		mat.set_shader_parameter("vision_radius", lerp(current_r, target_radius, 0.1))


func _try_interact() -> void:
	var space := get_world_3d().direct_space_state
	var from := camera.global_position
	var to := from - camera.global_transform.basis.z * 3.0
	var params := PhysicsRayQueryParameters3D.create(from, to, 8)
	var hit := space.intersect_ray(params)
	if hit.size() > 0:
		var obj = hit["collider"]
		if obj.has_method("interact"):
			obj.interact(GameManager.ROLE_BLIND)


func _on_over(won: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if won:
		msg_label.text = "逃离成功!"
	else:
		msg_label.text = "游戏结束..."
	msg_label.visible = true


func _on_med(role: int) -> void:
	if role == GameManager.ROLE_BLIND:
		_show_msg("服药成功! 心理值恢复!")


func _on_puzzle(total: int) -> void:
	_show_msg("谜题已解开! (" + str(total) + "/" + str(GameManager.puzzles_required) + ")")


func _show_msg(text: String) -> void:
	msg_label.text = text
	msg_label.visible = true
	var tw := create_tween()
	tw.tween_interval(2.0)
	tw.tween_callback(func() -> void: msg_label.visible = false)


func get_role() -> int:
	return GameManager.ROLE_BLIND
