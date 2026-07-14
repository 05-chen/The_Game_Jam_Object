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
## true 时：集齐钥匙触发 stage_cleared（测试关→大场景），而非整局胜利
var advance_to_main_on_puzzle_clear: bool = false
## 是否启用 Type=2 钥匙碎片通关线索（开发验收第一关时保持 false）
var puzzle_clues_enabled: bool = false
var blind_medicines: int = 0
var lame_painkillers: int = 0
var checkpoint_data: Dictionary = {}

## ESC 暂停菜单状态（联机 Host 权威同步）
var is_paused: bool = false

## 本地 UI / 信号节流：避免每物理帧 emit 拖垮语音与 HUD
var _mental_last_emitted: float = 100.0
var _pain_last_emitted: float = 0.0
const STAT_EMIT_EPSILON: float = 0.4
## 网络对齐目标（表现层 lerp 向此靠拢，公式不变）
var target_mental_health: float = 100.0
var target_pain_value: float = 0.0
## 瘸子语音阶梯（0=禁麦/听不见，4=满音量）；与 pain_to_voice_tier 同步
var lame_voice_tier: int = 4

## 局内运行时玩家节点引用（切关/回大厅前由 GameWorld 注册与清空，作 Null 哨兵）
var blind_player: Node3D = null
var lame_player: Node3D = null

# 游戏事件信号
signal mental_health_changed(value: float)
signal pain_value_changed(value: float)
signal lame_voice_tier_changed(tier: int, pain: float)
signal game_over_triggered(won: bool)
signal puzzle_solved(total: int)
signal stage_cleared()
signal medicine_collected(role: int)
signal checkpoint_saved()
signal pause_changed(paused: bool)

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
	is_paused = false
	checkpoint_data = {}
	advance_to_main_on_puzzle_clear = false
	puzzle_clues_enabled = false
	_mental_last_emitted = mental_health_max
	_pain_last_emitted = 0.0
	target_mental_health = mental_health_max
	target_pain_value = 0.0
	lame_voice_tier = 4
	clear_player_refs()
	# 通知监听者，避免上一局数值残留在新一局 UI / 语音阶梯
	mental_health_changed.emit(mental_health)
	pain_value_changed.emit(pain_value)
	lame_voice_tier_changed.emit(lame_voice_tier, pain_value)
	pause_changed.emit(false)
	if LevelManager != null and LevelManager.has_method("reset_session"):
		LevelManager.reset_session()


func register_players(blind: Node3D, lame: Node3D) -> void:
	blind_player = blind
	lame_player = lame


func clear_player_refs() -> void:
	blind_player = null
	lame_player = null


## 切关 / 结算 / 回大厅时防止访问已释放玩家节点
func are_session_players_valid() -> bool:
	return is_instance_valid(blind_player) and is_instance_valid(lame_player)


# 更新心理值函数 - 仅由本地瞎子玩家调用
func update_mental_health(delta: float) -> void:
	if is_game_over or is_paused:
		return
	var prev := mental_health
	mental_health = clampf(mental_health - mental_health_decay_rate * delta, 0.0, mental_health_max)
	target_mental_health = mental_health
	if absf(mental_health - _mental_last_emitted) >= STAT_EMIT_EPSILON or (prev > 0.0 and mental_health <= 0.0):
		_mental_last_emitted = mental_health
		mental_health_changed.emit(mental_health)

# 更新疼痛值函数 - 仅由本地瘸子玩家调用
func update_pain(delta: float) -> void:
	if is_game_over or is_paused:
		return
	var prev := pain_value
	pain_value = clampf(pain_value + pain_increase_rate * delta, 0.0, pain_max)
	target_pain_value = pain_value
	var tier_prev := pain_to_voice_tier(prev)
	var tier_now := pain_to_voice_tier(pain_value)
	_refresh_lame_voice_tier(pain_value)
	if absf(pain_value - _pain_last_emitted) >= STAT_EMIT_EPSILON or tier_prev != tier_now or pain_value >= pain_max:
		_pain_last_emitted = pain_value
		pain_value_changed.emit(pain_value)

# 增加心理值函数
func add_mental_health(amount: float) -> void:
	mental_health = clampf(mental_health + amount, 0.0, mental_health_max)
	target_mental_health = mental_health
	_mental_last_emitted = mental_health
	mental_health_changed.emit(mental_health)

# 减少疼痛值函数
func reduce_pain(amount: float) -> void:
	var prev_tier := lame_voice_tier
	pain_value = clampf(pain_value - amount, 0.0, pain_max)
	target_pain_value = pain_value
	_pain_last_emitted = pain_value
	_refresh_lame_voice_tier(pain_value)
	pain_value_changed.emit(pain_value)
	# Tier0→恢复：即使 Discrete tier 同帧已刷新，也强制再推一次信号，确保 VoiceCore 唤醒麦
	if prev_tier == 0 and lame_voice_tier > 0:
		lame_voice_tier_changed.emit(lame_voice_tier, pain_value)


## 联机：接收端镜像权威数值 + target；本地模拟端仍每帧 update_*，RPC 仅节流对齐对端
func sync_mental_target_from_network(value: float) -> void:
	var clamped := clampf(value, 0.0, mental_health_max)
	mental_health = clamped
	target_mental_health = clamped
	if absf(clamped - _mental_last_emitted) >= STAT_EMIT_EPSILON:
		_mental_last_emitted = clamped
		mental_health_changed.emit(clamped)


func sync_pain_target_from_network(value: float) -> void:
	var clamped := clampf(value, 0.0, pain_max)
	pain_value = clamped
	target_pain_value = clamped
	_refresh_lame_voice_tier(clamped)
	var tier_now := pain_to_voice_tier(clamped)
	var tier_prev := pain_to_voice_tier(_pain_last_emitted)
	if absf(clamped - _pain_last_emitted) >= STAT_EMIT_EPSILON or tier_now != tier_prev:
		_pain_last_emitted = clamped
		pain_value_changed.emit(clamped)


## 联机：VoiceCore 专用轻量 RPC 入口，优先刷新语音 Tier（瞎子听瘸子音量）
func apply_lame_voice_tier_from_network(tier: int, pain: float) -> void:
	var t := clampi(tier, 0, 4)
	if pain >= 0.0:
		var clamped := clampf(pain, 0.0, pain_max)
		pain_value = clamped
		target_pain_value = clamped
	var tier_changed := t != lame_voice_tier
	if tier_changed:
		lame_voice_tier = t
		lame_voice_tier_changed.emit(t, pain_value)
	if pain >= 0.0:
		var tier_now := pain_to_voice_tier(pain_value)
		var tier_prev := pain_to_voice_tier(_pain_last_emitted)
		if absf(pain_value - _pain_last_emitted) >= STAT_EMIT_EPSILON or tier_now != tier_prev:
			_pain_last_emitted = pain_value
			if not tier_changed:
				pain_value_changed.emit(pain_value)


func _refresh_lame_voice_tier(pain: float) -> void:
	var tier := pain_to_voice_tier(pain)
	if tier == lame_voice_tier:
		return
	lame_voice_tier = tier
	lame_voice_tier_changed.emit(tier, pain)

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
	if not puzzle_clues_enabled:
		return
	puzzles_solved += 1
	puzzle_solved.emit(puzzles_solved)
	if puzzles_solved >= puzzles_required:
		# 测试关通关 → 由 GameWorld 切到美术大场景，不算整局胜利
		if advance_to_main_on_puzzle_clear:
			advance_to_main_on_puzzle_clear = false
			if not NetworkManager.is_multiplayer_game or multiplayer.is_server():
				stage_cleared.emit()
			return
		trigger_game_over(true)

# [已修改] 触发游戏结束 - 联机仅主机裁决后 call_local 广播；客户端只发请求
func trigger_game_over(won: bool) -> void:
	if is_game_over:
		return
	if NetworkManager.is_multiplayer_game:
		if not multiplayer.is_server():
			_request_game_over.rpc_id(1, won)
			return
		_remote_game_over.rpc(won)
		return
	_apply_game_over_state(won)


func _apply_game_over_state(won: bool) -> void:
	if is_game_over:
		return
	is_game_over = true
	is_game_won = won
	is_game_active = false
	game_over_triggered.emit(won)


# [新增] 远程游戏结束 RPC：authority + call_local，主机裁决后两端同步生效
@rpc("authority", "reliable", "call_local")
func _remote_game_over(won: bool) -> void:
	_apply_game_over_state(won)


@rpc("any_peer", "reliable")
func _request_game_over(won: bool) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not NetworkManager.is_trusted_sender(sender_id):
		return
	trigger_game_over(won)

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
	target_mental_health = mental_health
	target_pain_value = pain_value
	is_game_active = true
	is_game_over = false
	is_game_won = false
	mental_health_changed.emit(mental_health)
	pain_value_changed.emit(pain_value)
	_refresh_lame_voice_tier(pain_value)

func set_paused(paused: bool) -> void:
	is_paused = paused
	pause_changed.emit(paused)

# 获取语音音量乘数函数
func get_voice_multiplier() -> float:
	return 1.0 - (pain_value / pain_max)


## Tier → 远端播放音量（dB），与 pain_to_voice_tier 配套；VoiceChatManager 通过 voice_tier_to_volume_db 读取
const VOICE_TIER_DB: Dictionary = {
	0: -80.0,
	1: -20.0,
	2: -12.0,
	3: -6.0,
	4: 0.0,
}


## 疼痛越高 → Tier 越低 → 音量越小。Tier4=健康大声，Tier0=达到疼痛上限（濒死）静音/禁发
func pain_to_voice_tier(pain: float) -> int:
	if pain >= pain_max:
		return 0
	if pain >= 80.0:
		return 1
	if pain >= 50.0:
		return 2
	if pain >= 20.0:
		return 3
	return 4


func voice_tier_to_volume_db(tier: int) -> float:
	var t := clampi(tier, 0, 4)
	return float(VOICE_TIER_DB.get(t, 0.0))


func voice_tier_to_linear_gain(tier: int) -> float:
	match clampi(tier, 0, 4):
		0:
			return 0.0
		1:
			return 0.1
		2:
			return 0.25
		3:
			return 0.5
		_:
			return 1.0


# 根据疼痛值得到阶梯对应的线性增益（用于 UI 百分比等）
func get_voice_multiplier_from_pain(pain: float) -> float:
	return voice_tier_to_linear_gain(pain_to_voice_tier(pain))
