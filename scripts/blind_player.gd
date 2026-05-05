extends CharacterBody3D

@export var move_speed: float = 4.0
@export var mouse_sensitivity: float = 0.003
@export var visual_smooth: float = 18.0

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var is_local: bool = false

var _remote_move_input: Vector2 = Vector2.ZERO
var _remote_rot_y: float = 0.0
var _remote_cam_x: float = 0.0
var _net_pos: Vector3 = Vector3.ZERO
var _net_rot_y: float = 0.0
var _net_cam_x: float = 0.0

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
	GameManager.mental_health_changed.connect(_on_health)
	GameManager.game_over_triggered.connect(_on_over)
	GameManager.medicine_collected.connect(_on_med)
	GameManager.puzzle_solved.connect(_on_puzzle)
	_disable_scene_lights_for_blind_view()
	_setup_spot_light()
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
		rotate_y(-event.relative.x * mouse_sensitivity)
		camera.rotate_x(-event.relative.y * mouse_sensitivity)
		camera.rotation.x = clampf(camera.rotation.x, -1.5, 1.5)
	if event.is_action_pressed("interact"):
		_try_interact()


func _process(delta: float) -> void:
	if not NetworkManager.is_multiplayer_game or multiplayer.is_server():
		return
	var k := clampf(visual_smooth * delta, 0.0, 1.0)
	global_position = global_position.lerp(_net_pos, k)
	var local_blind := is_local and GameManager.current_role == GameManager.ROLE_BLIND
	if not local_blind:
		rotation.y = lerp_angle(rotation.y, _net_rot_y, k)
		if camera:
			camera.rotation.x = lerpf(camera.rotation.x, _net_cam_x, k)


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
	s_request_move.rpc_id(1, Input.get_vector("move_left", "move_right", "move_forward", "move_backward"), rotation.y, camera.rotation.x)


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
		mat.set_shader_parameter("screen_size", get_viewport().get_visible_rect().size)
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
