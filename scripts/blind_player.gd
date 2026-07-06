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
## 动作中（移动/转头/本帧鼠标）客户端发「移动意图」的最短间隔（毫秒）
@export var sync_host_broadcast_interval_ms: int = 33
## 主机向客户端广播**位移**的最短间隔（毫秒）；旋转单独更密
@export var sync_host_position_broadcast_ms: int = 80
## 主机广播**水平角/俯仰**的最短间隔（毫秒），与 sync_rot_send_epsilon_deg 配合
@export var sync_host_rotation_broadcast_min_ms: int = 33
## 客户端向主机上报视角时的最短间隔（毫秒），与位移心跳分离
@export var sync_client_rotation_send_min_ms: int = 33
## 完全静止时的慢心跳（毫秒）
@export var sync_move_rpc_heartbeat_still_ms: int = 80
## 表现层：水平角略快于位置，减轻 40~50ms 快照间隔下的视角滞涩（仍用 lerp_angle 最短弧）
@export var visual_smooth_rot_scale: float = 1.22

const JUMP_VELOCITY: float = 4.5
const INTERACT_RAY_MASK: int = 8
const INTERACT_RANGE: float = 5.0
const VISION_LERP_SPEED: float = 10.0

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var is_local: bool = false
var is_spawning: bool = true
var _display_mh: float = 100.0

var _remote_move_input: Vector2 = Vector2.ZERO
var _remote_want_jump: bool = false
var _remote_rot_y: float = 0.0
var _remote_cam_x: float = 0.0
var _net_rot_y: float = 0.0
var _net_cam_x: float = 0.0

var _last_sent_input: Vector2 = Vector2(INF, INF)
var _last_sent_rot_y: float = INF
var _last_sent_cam_x: float = INF
var _mouse_look_this_frame: bool = false
var _prev_phys_rot_y: float = 0.0
var _prev_phys_cam_x: float = 0.0
var _prev_phys_initialized: bool = false

var _last_sync_broadcast_ms: int = -1_000_000
var _last_pos_broadcast_ms: int = -1_000_000
var _last_rot_broadcast_ms: int = -1_000_000
var _last_bcast_pos: Vector3 = Vector3(INF, INF, INF)
var _last_bcast_rot_y: float = INF
var _last_bcast_cam_x: float = INF
var _has_ever_bcast: bool = false
## 客户端：移动意图上次发送时间 / 视角上次发送时间（分离节流）
var _last_client_move_send_ms: int = -1_000_000
var _last_client_rot_send_ms: int = -1_000_000
var _client_move_bootstrapped: bool = false
var _last_synced_mh: float = -1.0
const MH_NET_SYNC_EPSILON: float = 0.5

@onready var camera: Camera3D = $Camera3D
@onready var ui_root: CanvasLayer = $UI
@onready var health_bar: ProgressBar = $UI/Stats/HealthBar
@onready var health_label: Label = $UI/Stats/HealthLabel
@onready var msg_label: Label = $UI/MsgLabel
@onready var vision_mask: ColorRect = $UI/VisionMask

var spot_light: SpotLight3D = null
var _audio_listener: AudioListener3D = null
## 视野遮罩 ShaderMaterial 缓存；fragment 已用 SCREEN_PIXEL_SIZE，无需随分辨率每帧 set 尺寸类 uniform
var _vision_mask_mat: ShaderMaterial = null


func _ready() -> void:
	add_to_group("player")
	_configure_vision_mask()
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
	# 瞎子路径：显式不连接 pain_value_changed；UI 仅心理值（场景无疼痛条）。瘸子疼痛由 GameManager 同步，供 VoiceChatManager 调节对方语音音量。
	GameManager.mental_health_changed.connect(_on_health)
	GameManager.game_over_triggered.connect(_on_over)
	GameManager.medicine_collected.connect(_on_med)
	GameManager.puzzle_solved.connect(_on_puzzle)
	_disable_scene_lights_for_blind_view()
	_setup_spot_light()
	_display_mh = GameManager.mental_health
	_refresh_light()
	if _can_control_local_camera():
		InputMouseGuard.capture_for_local_player()


func _on_spawning_finished() -> void:
	velocity = Vector3.ZERO
	if _can_control_local_camera():
		InputMouseGuard.capture_for_local_player()


func _configure_vision_mask() -> void:
	if vision_mask == null:
		return
	vision_mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vision_mask.color = Color(1, 1, 1, 1)
	if vision_mask.material is ShaderMaterial:
		var mat := (vision_mask.material as ShaderMaterial).duplicate()
		vision_mask.material = mat
		_vision_mask_mat = mat
		# 半圆孔：平直边在中下方，弧向上
		mat.set_shader_parameter("vision_radius", 0.18)
		mat.set_shader_parameter("feather", 0.08)
		mat.set_shader_parameter("vision_center", Vector2(0.5, 0.68))


func _exit_tree() -> void:
	if GameManager.mental_health_changed.is_connected(_on_health):
		GameManager.mental_health_changed.disconnect(_on_health)
	if GameManager.game_over_triggered.is_connected(_on_over):
		GameManager.game_over_triggered.disconnect(_on_over)
	if GameManager.medicine_collected.is_connected(_on_med):
		GameManager.medicine_collected.disconnect(_on_med)
	if GameManager.puzzle_solved.is_connected(_on_puzzle):
		GameManager.puzzle_solved.disconnect(_on_puzzle)


func _disable_scene_lights_for_blind_view() -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	_disable_lights_recursive(scene_root)


func _disable_lights_recursive(node: Node) -> void:
	for child in node.get_children():
		# 保留瞎子相机上的 SpotLight（玩法核心照明），只关场景环境灯
		if child is SpotLight3D and child.name == "BlindSpotLight":
			continue
		if child is Light3D:
			(child as Light3D).visible = false
		_disable_lights_recursive(child)


func _unhandled_input(event: InputEvent) -> void:
	if not _can_control_local_camera():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_apply_look(event.relative)
	if event.is_action_pressed("interact"):
		_try_interact()


func _can_control_local_camera() -> bool:
	return is_local \
		and not is_spawning \
		and GameManager.is_game_active \
		and not GameManager.is_game_over \
		and GameManager.current_role == GameManager.ROLE_BLIND \
		and not GameManager.dev_paused


func _apply_look(relative: Vector2) -> void:
	_mouse_look_this_frame = true
	rotate_y(-relative.x * mouse_sensitivity)
	camera.rotate_x(-relative.y * mouse_sensitivity)
	camera.rotation.x = clampf(camera.rotation.x, -1.5, 1.5)


func _process(delta: float) -> void:
	if is_local and GameManager.current_role == GameManager.ROLE_BLIND:
		var target_mh := GameManager.target_mental_health if NetworkManager.is_multiplayer_game and not multiplayer.is_server() else GameManager.mental_health
		_display_mh = lerpf(_display_mh, target_mh, clampf(VISION_LERP_SPEED * delta, 0.0, 1.0))
		# [测试] 暂停心理值驱动圆孔，使用 tscn 默认 vision_radius=0.15
		# _apply_vision_radius_from_display()
	if not NetworkManager.is_multiplayer_game or multiplayer.is_server():
		return
	# 位移与 velocity 由 MultiplayerSynchronizer 从权威端同步；此处仅平滑远程视角
	var local_blind := is_local and GameManager.current_role == GameManager.ROLE_BLIND
	if not local_blind:
		# lerp_angle 走最短弧；角速度用略大的 k，快照间隔抖动时仍平滑趋近目标
		var k_rot := clampf(visual_smooth * visual_smooth_rot_scale * delta, 0.0, 1.0)
		rotation.y = lerp_angle(rotation.y, _net_rot_y, k_rot)
		if camera:
			camera.rotation.x = lerpf(camera.rotation.x, _net_cam_x, k_rot)


func _physics_process(delta: float) -> void:
	if is_spawning:
		velocity = Vector3.ZERO
		return
	if not GameManager.is_game_active or GameManager.is_game_over:
		return
	# [增量] 联机跳跃：仅在权威端改 velocity，由 MultiplayerSynchronizer 同步给远端
	if is_multiplayer_authority():
		_apply_authority_jump()
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
	var move_interval_ms := sync_host_broadcast_interval_ms if action_priority else sync_move_rpc_heartbeat_still_ms
	var move_hb := now_ms - _last_client_move_send_ms >= move_interval_ms

	var input_changed := input_dir.distance_to(_last_sent_input) >= sync_input_vector_epsilon
	var rot_changed := absf(angle_difference(_last_sent_rot_y, rotation.y)) >= rot_eps_rad
	var cam_changed := absf(_last_sent_cam_x - cam_x) >= rot_eps_rad
	var rot_due := (rot_changed or cam_changed) and (now_ms - _last_client_rot_send_ms >= sync_client_rotation_send_min_ms)

	var move_due := input_changed or move_hb
	if not (_client_move_bootstrapped or move_due or rot_due):
		return
	_client_move_bootstrapped = true
	_last_sent_input = input_dir
	_last_sent_rot_y = rotation.y
	_last_sent_cam_x = cam_x
	if move_due:
		_last_client_move_send_ms = now_ms
	if rot_due:
		_last_client_rot_send_ms = now_ms
	_mouse_look_this_frame = false
	var want_jump := Input.is_action_just_pressed("ui_accept")
	s_request_move.rpc_id(1, input_dir, rotation.y, cam_x, want_jump)


## 权威端起跳：主机当瞎子用本地输入；客机当瞎子经 s_request_move 上报 want_jump
func _apply_authority_jump() -> void:
	if not is_on_floor():
		return
	var want_jump := false
	if NetworkManager.is_multiplayer_game:
		if GameManager.current_role == GameManager.ROLE_BLIND:
			want_jump = Input.is_action_just_pressed("ui_accept")
		elif _remote_want_jump:
			want_jump = true
			_remote_want_jump = false
	else:
		want_jump = Input.is_action_just_pressed("ui_accept")
	if want_jump:
		velocity.y = JUMP_VELOCITY


func _simulate_blind_movement(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var dir := _camera_flat_move_dir(input_dir)
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
	var dir := _camera_flat_move_dir(input_dir)
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
	var still_interval_ms := sync_host_broadcast_interval_ms if physically_active else sync_move_rpc_heartbeat_still_ms
	var due_still := _has_ever_bcast and (now_ms - _last_sync_broadcast_ms >= still_interval_ms)

	var pos_delta := 0.0 if not _has_ever_bcast else global_position.distance_to(_last_bcast_pos)
	var pos_push := not _has_ever_bcast or pos_delta >= sync_move_pos_epsilon_m
	var rot_push := not _has_ever_bcast or absf(angle_difference(_last_bcast_rot_y, rotation.y)) >= rot_eps_rad
	var cam_push := not _has_ever_bcast or absf(_last_bcast_cam_x - camera.rotation.x) >= rot_eps_rad

	var due_pos := pos_push and (not _has_ever_bcast or now_ms - _last_pos_broadcast_ms >= sync_host_position_broadcast_ms)
	var due_rot := (rot_push or cam_push) and (not _has_ever_bcast or now_ms - _last_rot_broadcast_ms >= sync_host_rotation_broadcast_min_ms)

	var pos_authoritative := not _has_ever_bcast or due_pos or due_still
	if not (due_pos or due_rot or due_still):
		return
	_last_sync_broadcast_ms = now_ms
	if pos_authoritative:
		_last_pos_broadcast_ms = now_ms
	if due_rot or not _has_ever_bcast or due_still:
		_last_rot_broadcast_ms = now_ms
	_last_bcast_pos = global_position
	_last_bcast_rot_y = rotation.y
	_last_bcast_cam_x = camera.rotation.x
	var mh := GameManager.mental_health
	var mh_push := _last_synced_mh < 0.0 or absf(mh - _last_synced_mh) >= MH_NET_SYNC_EPSILON
	if mh_push:
		_last_synced_mh = mh
	_has_ever_bcast = true
	c_sync_transform.rpc(global_position, rotation.y, camera.rotation.x, mh, pos_authoritative, mh_push)


@rpc("any_peer", "unreliable_ordered")
func s_request_move(input_dir: Vector2, rot_y: float, cam_x: float, want_jump: bool = false) -> void:
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
	if want_jump:
		_remote_want_jump = true


@rpc("authority", "unreliable_ordered", "call_remote")
func c_sync_transform(_target_pos: Vector3, target_rot_y: float, target_cam_x: float, mh: float, _pos_authoritative: bool = true, apply_mh: bool = true) -> void:
	if not NetworkManager.is_multiplayer_game:
		return
	_net_rot_y = target_rot_y
	_net_cam_x = target_cam_x
	if apply_mh:
		GameManager.sync_mental_target_from_network(mh)


func _camera_flat_move_dir(input_dir: Vector2) -> Vector3:
	if camera == null:
		return Vector3.ZERO
	var basis := camera.global_transform.basis
	var forward := -basis.z
	forward.y = 0.0
	var right := basis.x
	right.y = 0.0
	if forward.length_squared() < 1e-8 or right.length_squared() < 1e-8:
		return Vector3.ZERO
	forward = forward.normalized()
	right = right.normalized()
	# get_vector：W(forward) → y 为负，需取反才沿相机朝向前进
	return (forward * -input_dir.y + right * input_dir.x).normalized()


func _on_health(value: float) -> void:
	health_bar.value = value
	health_label.text = "心理值: " + str(int(value)) + "%"
	if not NetworkManager.is_multiplayer_game or multiplayer.is_server():
		_display_mh = value
	# [测试] 暂停心理值驱动圆孔
	# _apply_vision_radius_from_display()
	if spot_light != null:
		var ratio := clampf(_display_mh / GameManager.mental_health_max, 0.0, 1.0)
		spot_light.light_energy = 1.0 + ratio * 1.5


func _setup_spot_light() -> void:
	spot_light = SpotLight3D.new()
	spot_light.name = "BlindSpotLight"
	spot_light.light_color = Color(0.85, 0.82, 0.75)
	spot_light.light_energy = 2.0
	spot_light.spot_range = 12.0
	spot_light.spot_angle = 45.0
	spot_light.spot_attenuation = 0.6
	spot_light.shadow_enabled = true
	camera.add_child(spot_light)
	var camera_env := Environment.new()
	camera_env.background_mode = Environment.BG_COLOR
	camera_env.background_color = Color(0, 0, 0)
	# 保留极低环境光，避免圆孔内除 Spot 外一片死黑
	camera_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	camera_env.ambient_light_color = Color(0.04, 0.04, 0.05)
	camera_env.ambient_light_energy = 0.15
	camera_env.fog_enabled = false
	camera.environment = camera_env


func _refresh_light() -> void:
	if not is_local:
		return
	var mh := _display_mh
	var ratio := clampf(mh / 100.0, 0.0, 1.0)
	if spot_light != null:
		spot_light.light_energy = 1.0 + ratio * 1.5


## [测试] 原逻辑已注释：动态 vision_radius 会把圆孔压到 0 导致全黑，现改用 blind_player.tscn 默认 0.15
func _apply_vision_radius_from_display() -> void:
	pass
#	if not is_local or GameManager.current_role != GameManager.ROLE_BLIND:
#		return
#	var mh := _display_mh
#	var ratio := clampf(mh / GameManager.mental_health_max, 0.0, 1.0)
#	var mat := _vision_mask_mat
#	if mat == null and vision_mask and vision_mask.material is ShaderMaterial:
#		mat = vision_mask.material as ShaderMaterial
#		_vision_mask_mat = mat
#	if mat == null:
#		return
#	var target_radius := ratio * 0.18
#	if mh < 8.0:
#		target_radius = 0.0
#	var current_r: float = float(mat.get_shader_parameter("vision_radius"))
#	var new_r := lerpf(current_r, target_radius, 0.22)
#	if not is_equal_approx(new_r, current_r):
#		mat.set_shader_parameter("vision_radius", new_r)


func _try_interact() -> void:
	var space := get_world_3d().direct_space_state
	var from := camera.global_position
	var to := from - camera.global_transform.basis.z * INTERACT_RANGE
	var params := PhysicsRayQueryParameters3D.create(from, to, INTERACT_RAY_MASK)
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		return
	var collider = hit["collider"]
	if collider != null and collider.has_method("interact"):
		collider.interact(GameManager.ROLE_BLIND, from, true)


func _on_over(won: bool) -> void:
	InputMouseGuard.release_for_ui()
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
