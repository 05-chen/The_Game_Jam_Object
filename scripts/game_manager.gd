 # 游戏管理器脚本 - 管理游戏状态、角色属性和游戏事件

# 角色常量定义
extends Node

const ROLE_BLIND = 0  # 瞎子角色
const ROLE_LAME = 1   # 瘸子角色

# 当前角色
var current_role: int = ROLE_BLIND

# 瞎子角色属性
var mental_health: float = 100.0  # 当前心理值
var mental_health_max: float = 100.0  # 心理值上限
var mental_health_decay_rate: float = 2.0  # 心理值衰减速率

# 瘸子角色属性
var pain_value: float = 0.0  # 当前疼痛值
var pain_max: float = 100.0  # 疼痛值上限
var pain_increase_rate: float = 1.5  # 疼痛值增加速率

# 游戏状态
var is_game_over: bool = false  # 游戏是否结束
var is_game_won: bool = false  # 游戏是否胜利
var puzzles_solved: int = 0  # 已解决的谜题数量
var puzzles_required: int = 3  # 获胜所需的谜题数量
var blind_medicines: int = 0  # 瞎子收集的药物数量
var lame_painkillers: int = 0  # 瘸子收集的止痛药数量

# 游戏事件信号
signal mental_health_changed(value: float)  # 心理值变化信号
signal pain_value_changed(value: float)  # 疼痛值变化信号
signal game_over_triggered(won: bool)  # 游戏结束信号
signal puzzle_solved(total: int)  # 谜题解决信号
signal medicine_collected(role: int)  # 药物收集信号

# 初始化函数 - 游戏开始时执行
func _ready() -> void:
	# 设置为始终处理模式，确保即使在非活动场景中也能运行
	process_mode = Node.PROCESS_MODE_ALWAYS

# 重置游戏函数 - 开始新游戏时调用
func reset_game() -> void:
	# 重置所有游戏状态
	mental_health = mental_health_max
	pain_value = 0.0
	is_game_over = false
	is_game_won = false
	puzzles_solved = 0
	blind_medicines = 0
	lame_painkillers = 0

# 更新心理值函数 - 每帧调用
func update_mental_health(delta: float) -> void:
	# 游戏结束时停止更新
	if is_game_over:
		return
	# 减少心理值
	mental_health = clampf(mental_health - mental_health_decay_rate * delta, 0.0, mental_health_max)
	# 发送心理值变化信号
	mental_health_changed.emit(mental_health)
	# 心理值为0时游戏结束
	if mental_health <= 0.0:
		trigger_game_over(false)

# 更新疼痛值函数 - 每帧调用
func update_pain(delta: float) -> void:
	# 游戏结束时停止更新
	if is_game_over:
		return
	# 增加疼痛值
	pain_value = clampf(pain_value + pain_increase_rate * delta, 0.0, pain_max)
	# 发送疼痛值变化信号
	pain_value_changed.emit(pain_value)
	# 疼痛值达到上限时游戏结束
	if pain_value >= pain_max:
		trigger_game_over(false)

# 增加心理值函数 - 收集药物时调用
func add_mental_health(amount: float) -> void:
	# 增加心理值，限制在范围内
	mental_health = clampf(mental_health + amount, 0.0, mental_health_max)
	# 发送心理值变化信号
	mental_health_changed.emit(mental_health)

# 减少疼痛值函数 - 服用止痛药时调用
func reduce_pain(amount: float) -> void:
	# 减少疼痛值，限制在范围内
	pain_value = clampf(pain_value - amount, 0.0, pain_max)
	# 发送疼痛值变化信号
	pain_value_changed.emit(pain_value)

# 收集药物函数 - 角色收集药物时调用
func collect_medicine(role: int) -> void:
	# 根据角色类型处理药物效果
	if role == ROLE_BLIND:
		# 瞎子角色：增加药物计数，恢复心理值
		blind_medicines += 1
		add_mental_health(30.0)
	else:
		# 瘸子角色：增加止痛药计数，减少疼痛值
		lame_painkillers += 1
		reduce_pain(30.0)
	# 发送药物收集信号
	medicine_collected.emit(role)

# 解决谜题函数 - 角色解决谜题时调用
func solve_puzzle() -> void:
	# 增加已解决谜题数量
	puzzles_solved += 1
	# 发送谜题解决信号
	puzzle_solved.emit(puzzles_solved)
	# 检查是否达到获胜条件
	if puzzles_solved >= puzzles_required:
		trigger_game_over(true)

# 触发游戏结束函数
func trigger_game_over(won: bool) -> void:
	# 设置游戏结束状态
	is_game_over = true
	is_game_won = won
	# 发送游戏结束信号
	game_over_triggered.emit(won)

# 获取语音音量乘数函数 - 用于瘸子角色的语音效果
func get_voice_multiplier() -> float:
	# 疼痛值越高，语音音量越低
	return 1.0 - (pain_value / pain_max)
