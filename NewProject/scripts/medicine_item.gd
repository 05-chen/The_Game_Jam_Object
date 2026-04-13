# 药物物品脚本 - 处理游戏中的可交互物品
# [已修改] 增加 RPC 同步拾取状态，确保两端一致

extends StaticBody3D

# 物品类型常量
const TYPE_MENTAL = 0  # 心理药物（镇定剂）
const TYPE_PAIN = 1    # 止痛药
const TYPE_KEY = 2     # 钥匙碎片

# 可导出属性
@export var medicine_type: int = 0
@export var float_speed: float = 2.0
@export var float_height: float = 0.3

# 内部变量
var initial_y: float = 0.0
var collected: bool = false

# 场景节点引用
@onready var mesh: MeshInstance3D = $Mesh
@onready var col: CollisionShape3D = $Col
@onready var lbl: Label3D = $Lbl

# 初始化函数
func _ready() -> void:
	initial_y = position.y
	collision_layer = 8
	_setup_look()

# 设置物品外观函数
func _setup_look() -> void:
	var mat = StandardMaterial3D.new()
	mat.emission_enabled = true
	if medicine_type == TYPE_MENTAL:
		mat.albedo_color = Color(0.2, 0.6, 1.0)
		mat.emission = Color(0.2, 0.6, 1.0)
		lbl.text = "镇定剂"
	elif medicine_type == TYPE_PAIN:
		mat.albedo_color = Color(0.2, 1.0, 0.3)
		mat.emission = Color(0.2, 1.0, 0.3)
		lbl.text = "止疼药"
	elif medicine_type == TYPE_KEY:
		mat.albedo_color = Color(1.0, 0.8, 0.0)
		mat.emission = Color(1.0, 0.8, 0.0)
		lbl.text = "钥匙碎片"
	mesh.material_override = mat

# 处理函数 - 浮动和旋转效果
func _process(delta: float) -> void:
	if collected:
		return
	position.y = initial_y + sin(Time.get_ticks_msec() * 0.001 * float_speed) * float_height
	rotate_y(delta * 1.5)

# [已修改] 交互函数 - 增加网络同步
func interact(_role: int) -> void:
	if collected:
		return
	# 本地执行收集
	_do_collect()
	# [新增] 同步到远程
	if NetworkManager.peer != null:
		_remote_collect.rpc()

# [新增] 远程收集 RPC
@rpc("any_peer", "reliable", "call_remote")
func _remote_collect() -> void:
	_do_collect()

# [新增] 实际收集逻辑（本地和远程共用）
func _do_collect() -> void:
	if collected:
		return
	# 应用游戏效果
	if medicine_type == TYPE_MENTAL:
		GameManager.collect_medicine(GameManager.ROLE_BLIND)
	elif medicine_type == TYPE_PAIN:
		GameManager.collect_medicine(GameManager.ROLE_LAME)
	elif medicine_type == TYPE_KEY:
		GameManager.solve_puzzle()
	# 标记为已收集
	collected = true
	visible = false
	col.set_deferred("disabled", true)
