# 药物物品脚本 - 处理游戏中的可交互物品

# 基本设置
extends StaticBody3D

# 物品类型常量
const TYPE_MENTAL = 0  # 心理药物（镇定剂）
const TYPE_PAIN = 1    # 止痛药
const TYPE_KEY = 2     # 钥匙碎片

# 可导出属性
@export var medicine_type: int = 0  # 物品类型
@export var float_speed: float = 2.0  # 浮动速度
@export var float_height: float = 0.3  # 浮动高度

# 内部变量
var initial_y: float = 0.0  # 初始Y坐标
var collected: bool = false  # 是否已被收集

# 场景节点引用
@onready var mesh: MeshInstance3D = $Mesh  # 物品模型
@onready var col: CollisionShape3D = $Col  # 碰撞形状
@onready var lbl: Label3D = $Lbl  # 3D标签

# 初始化函数 - 节点加载时执行
func _ready() -> void:
	# 保存初始Y坐标
	initial_y = position.y
	# 设置碰撞层
	collision_layer = 8
	# 设置物品外观
	_setup_look()

# 设置物品外观函数
func _setup_look() -> void:
	# 创建新的材质
	var mat = StandardMaterial3D.new()
	# 启用自发光
	mat.emission_enabled = true
	# 根据物品类型设置不同的颜色和标签
	if medicine_type == TYPE_MENTAL:
		# 心理药物：蓝色
		mat.albedo_color = Color(0.2, 0.6, 1.0)
		mat.emission = Color(0.2, 0.6, 1.0)
		lbl.text = "镇定剂"
	elif medicine_type == TYPE_PAIN:
		# 止痛药：绿色
		mat.albedo_color = Color(0.2, 1.0, 0.3)
		mat.emission = Color(0.2, 1.0, 0.3)
		lbl.text = "止疼药"
	elif medicine_type == TYPE_KEY:
		# 钥匙碎片：金色
		mat.albedo_color = Color(1.0, 0.8, 0.0)
		mat.emission = Color(1.0, 0.8, 0.0)
		lbl.text = "钥匙碎片"
	# 应用材质到模型
	mesh.material_override = mat

# 处理函数 - 每帧执行
func _process(delta: float) -> void:
	# 已收集的物品不再处理
	if collected:
		return
	# 实现物品浮动效果
	position.y = initial_y + sin(Time.get_ticks_msec() * 0.001 * float_speed) * float_height
	# 实现物品旋转效果
	rotate_y(delta * 1.5)

# 交互函数 - 玩家与物品交互时调用
func interact(_role: int) -> void:
	# 已收集的物品不再处理
	if collected:
		return
	# 根据物品类型执行不同的操作
	if medicine_type == TYPE_MENTAL:
		# 心理药物：为瞎子角色恢复心理值
		GameManager.collect_medicine(GameManager.ROLE_BLIND)
	elif medicine_type == TYPE_PAIN:
		# 止痛药：为瘸子角色减少疼痛值
		GameManager.collect_medicine(GameManager.ROLE_LAME)
	elif medicine_type == TYPE_KEY:
		# 钥匙碎片：解决一个谜题
		GameManager.solve_puzzle()
	# 标记物品为已收集
	collected = true
	# 隐藏物品	
	visible = false
	# 禁用碰撞器（延迟执行）
	col.set_deferred("disabled", true)
