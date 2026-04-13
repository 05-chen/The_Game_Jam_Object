# light_flicker.gd - 灯光闪烁效果脚本，为游戏营造恐怖氛围

# 基本设置
extends Node

# 变量定义
var base_energy: float  # 基础灯光能量（亮度）
var flicker_timer: float = 0.0  # 闪烁计时器
var flicker_interval: float = 0.1  # 闪烁间隔时间

# 初始化函数 - 节点加载时执行
func _ready() -> void:
	# 检查父节点是否为Light3D类型
	if get_parent() is Light3D:
		# 保存基础灯光能量
		base_energy = get_parent().light_energy
	# 随机设置初始闪烁间隔
	flicker_interval = randf_range(0.05, 0.2)

# 处理函数 - 每帧执行
func _process(delta: float) -> void:
	# 确保父节点是Light3D类型
	if not get_parent() is Light3D:
		return

	# 增加计时器
	flicker_timer += delta
	# 达到闪烁间隔时执行闪烁效果
	if flicker_timer >= flicker_interval:
		# 重置计时器
		flicker_timer = 0.0
		# 随机设置下一次闪烁间隔
		flicker_interval = randf_range(0.05, 0.3)
		# 获取父节点灯光
		var parent_light: Light3D = get_parent()
		# 随机调整灯光能量（70%-130%之间），产生闪烁效果
		parent_light.light_energy = base_energy * randf_range(0.7, 1.3)
