# 游戏管理器脚本 - 管理游戏状态、角色属性和游戏事件
# [已修改] 增加 RPC 同步：game_over、collect_medicine、solve_puzzle

extends Node

# 角色常量定义
const ROLE_BLIND = 0  # 瞎子角色
const ROLE_LAME = 1   # 瘸子角色

# 当前角色
var current_role: int = ROLE_BLIND

# 瞎子角色属性
var mental_health: float = 100.0
var mental_health_max: float = 100.0
var mental_health_decay_rate: float = 2.0

# 瘸子角色属性
var pain_value: float = 0.0
var pain_max: float = 100.0
var pain_increase_rate: float = 1.5

# 游戏状态
var is_game_active: bool = true
var is_game_over: bool = false
var is_game_won: bool = false
var puzzles_solved: int = 0
var puzzles_required: int = 3
var blind_medicines: int = 0
var lame_painkillers: int = 0
var checkpoint_data: Dictionary = {}

# 开发者演示开关
var dev_invincible: bool = false
var dev_paused: bool = false

# 游戏事件信号
signal mental_health_changed(value: float)
signal pain_value_changed(value: float)
signal game_over_triggered(won: bool)
signal puzzle_solved(total: int)
signal medicine_collected(role: int)
signal checkpoint_saved()
signal dev_invincible_changed(enabled: bool)
signal dev_pause_changed(paused: bool)

# 初始化函数
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

# 重置游戏函数
func reset_game() -> void:
	mental_health = mental_health_max
	pain_value = 0.0
	is_game_active = true
	is_game_over = false
	is_game_won = false
	puzzles_solved = 0
	blind_medicines = 0
	lame_painkillers = 0
	dev_invincible = false
	dev_paused = false
	checkpoint_data = {}

# 更新心理值函数 - 仅由本地瞎子玩家调用
func update_mental_health(delta: float) -> void:
	if is_game_over:
		return
	if dev_invincible:
		return
	mental_health = clampf(mental_health - mental_health_decay_rate * delta, 0.0, mental_health_max)
	mental_health_changed.emit(mental_health)
	if mental_health <= 0.0:
		trigger_game_over(false)

# 更新疼痛值函数 - 仅由本地瘸子玩家调用
func update_pain(delta: float) -> void:
	if is_game_over:
		return
	pain_value = clampf(pain_value + pain_increase_rate * delta, 0.0, pain_max)
	pain_value_changed.emit(pain_value)
	if pain_value >= pain_max:
		trigger_game_over(false)

# 增加心理值函数
func add_mental_health(amount: float) -> void:
	mental_health = clampf(mental_health + amount, 0.0, mental_health_max)
	mental_health_changed.emit(mental_health)

# 减少疼痛值函数
func reduce_pain(amount: float) -> void:
	pain_value = clampf(pain_value - amount, 0.0, pain_max)
	pain_value_changed.emit(pain_value)

# 收集药物函数
func collect_medicine(role: int) -> void:
	if role == ROLE_BLIND:
		blind_medicines += 1
		add_mental_health(30.0)
	else:
		lame_painkillers += 1
		reduce_pain(30.0)
	medicine_collected.emit(role)

# 解决谜题函数
func solve_puzzle() -> void:
	puzzles_solved += 1
	puzzle_solved.emit(puzzles_solved)
	if puzzles_solved >= puzzles_required:
		trigger_game_over(true)

# [已修改] 触发游戏结束 - 增加网络同步
func trigger_game_over(won: bool) -> void:
	if is_game_over:
		return
	# 上帝模式下仅忽略失败，不影响胜利流程
	if dev_invincible and not won:
		return
	is_game_over = true
	is_game_won = won
	is_game_active = false
	game_over_triggered.emit(won)
	# 多人模式下由 Authority 统一裁决并广播
	if NetworkManager.is_multiplayer_game and multiplayer.is_server():
		_remote_game_over.rpc(won)
	elif NetworkManager.is_multiplayer_game:
		_request_game_over.rpc_id(1, won)

func save_checkpoint(blind_pos: Vector3, lame_pos: Vector3) -> void:
	checkpoint_data = {
		"blind_pos": blind_pos,
		"lame_pos": lame_pos,
		"mental_health": mental_health,
		"pain_value": pain_value
	}
	checkpoint_saved.emit()

func has_checkpoint() -> bool:
	return checkpoint_data.has("blind_pos") and checkpoint_data.has("lame_pos")

func apply_checkpoint_state() -> void:
	if not has_checkpoint():
		return
	mental_health = checkpoint_data.get("mental_health", mental_health_max)
	pain_value = checkpoint_data.get("pain_value", 0.0)
	is_game_active = true
	is_game_over = false
	is_game_won = false
	mental_health_changed.emit(mental_health)
	pain_value_changed.emit(pain_value)

func set_dev_invincible(enabled: bool) -> void:
	dev_invincible = enabled
	dev_invincible_changed.emit(enabled)

func set_dev_pause(paused: bool) -> void:
	dev_paused = paused
	dev_pause_changed.emit(paused)

# [新增] 远程游戏结束 RPC
@rpc("authority", "reliable", "call_remote")
func _remote_game_over(won: bool) -> void:
	if is_game_over:
		return
	is_game_over = true
	is_game_won = won
	is_game_active = false
	game_over_triggered.emit(won)

@rpc("any_peer", "reliable")
func _request_game_over(won: bool) -> void:
	if not multiplayer.is_server():
		return
	var sender_id = multiplayer.get_remote_sender_id()
	if not NetworkManager.is_trusted_sender(sender_id):
		return
	trigger_game_over(won)

# 获取语音音量乘数函数
func get_voice_multiplier() -> float:
	return 1.0 - (pain_value / pain_max)

# 根据指定疼痛值计算语音音量乘数（用于联机同步显示/播放）
func get_voice_multiplier_from_pain(pain: float) -> float:
	return clampf(1.0 - (pain / pain_max), 0.0, 1.0)
