# 房间构建器脚本 - 生成游戏场景的布局和环境

# 基本设置
extends Node3D

# 初始化函数 - 节点加载时执行
func _ready() -> void:
	# 构建场景元素
	_build_floor()  # 构建地板
	_build_ceiling()  # 构建天花板
	_build_outer_walls()  # 构建外墙
	_build_inner_walls()  # 构建内墙
	_build_furniture()  # 构建家具
	_setup_lighting()  # 设置光照

# 创建立方体函数 - 通用函数，用于创建各种场景元素
func _make_box(bsize: Vector3, pos: Vector3, c: Color) -> void:
	# 创建静态刚体
	var body = StaticBody3D.new()
	body.position = pos  # 设置位置
	body.collision_layer = 1  # 设置碰撞层
	
	# 创建网格实例
	var mi = MeshInstance3D.new()
	var bm = BoxMesh.new()
	bm.size = bsize  # 设置立方体大小
	mi.mesh = bm
	
	# 创建材质
	var mat = StandardMaterial3D.new()
	mat.albedo_color = c  # 设置颜色
	mi.material_override = mat
	body.add_child(mi)
	
	# 创建碰撞形状
	var cs = CollisionShape3D.new()
	var bs = BoxShape3D.new()
	bs.size = bsize  # 设置碰撞形状大小
	cs.shape = bs
	body.add_child(cs)
	
	# 将立方体添加到场景
	add_child(body)

# 构建地板函数
func _build_floor() -> void:
	# 创建16x16的地板
	_make_box(Vector3(16, 0.2, 16), Vector3(0, 0, 0), Color(0.15, 0.12, 0.1))

# 构建天花板函数
func _build_ceiling() -> void:
	# 创建16x16的天花板，高度为4
	_make_box(Vector3(16, 0.2, 16), Vector3(0, 4, 0), Color(0.1, 0.08, 0.07))

# 构建外墙函数
func _build_outer_walls() -> void:
	# 设置外墙颜色
	var c = Color(0.2, 0.18, 0.15)
	# 创建四面外墙
	_make_box(Vector3(16, 4, 0.3), Vector3(0, 2, -8), c)  # 后墙
	_make_box(Vector3(16, 4, 0.3), Vector3(0, 2, 8), c)  # 前墙
	_make_box(Vector3(0.3, 4, 16), Vector3(8, 2, 0), c)  # 右墙
	_make_box(Vector3(0.3, 4, 16), Vector3(-8, 2, 0), c)  # 左墙

# 构建内墙函数
func _build_inner_walls() -> void:
	# 设置内墙颜色
	var c = Color(0.25, 0.2, 0.18)
	# 创建各种内墙
	_make_box(Vector3(5, 4, 0.3), Vector3(-3.5, 2, -2), c)
	_make_box(Vector3(4, 4, 0.3), Vector3(5, 2, -2), c)
	_make_box(Vector3(0.3, 4, 4), Vector3(2, 2, -5.5), c)
	_make_box(Vector3(0.3, 4, 4), Vector3(2, 2, 4.5), c)
	_make_box(Vector3(4, 4, 0.3), Vector3(-5.5, 2, 3), c)
	_make_box(Vector3(0.3, 4, 3.5), Vector3(-3.5, 2, 5), c)

# 构建家具函数
func _build_furniture() -> void:
	# 设置家具颜色
	var fc = Color(0.35, 0.25, 0.15)  # 浅色家具
	var dc = Color(0.12, 0.1, 0.08)  # 深色家具
	# 创建各种家具
	_make_box(Vector3(2, 0.8, 1), Vector3(-5, 0.4, -5), fc)  # 桌子
	_make_box(Vector3(1.5, 0.8, 1.5), Vector3(5, 0.4, 5), fc)  # 桌子
	_make_box(Vector3(1, 0.8, 2), Vector3(5, 0.4, -5), fc)  # 桌子
	_make_box(Vector3(0.5, 2.5, 1.5), Vector3(-7, 1.25, 0), dc)  # 柜子
	_make_box(Vector3(1.5, 2.5, 0.5), Vector3(0, 1.25, -7), dc)  # 柜子
	_make_box(Vector3(0.5, 2, 2), Vector3(7, 1, -2), dc)  # 柜子
	_make_box(Vector3(0.8, 0.8, 0.8), Vector3(-2, 0.4, 5), fc)  # 箱子
	_make_box(Vector3(0.6, 0.6, 0.6), Vector3(3, 0.3, 3), fc)  # 箱子
	_make_box(Vector3(1, 1, 1), Vector3(-5, 0.5, 3.5), dc)  # 箱子

# 设置光照函数
func _setup_lighting() -> void:
	# 创建世界环境
	var we = WorldEnvironment.new()
	var env = Environment.new()
	# 设置背景
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.8, 0.85, 0.9)  # 白天背景
	# 设置环境光
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.95, 0.95, 0.95)  # 更亮的白色环境光
	env.ambient_light_energy = 1.8  # 增强环境光强度
	# 禁用雾效
	env.fog_enabled = false
	we.environment = env
	add_child(we)
	
	# 创建方向光（上方光源）
	var sun = DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.95, 0.9)  # 暖白色光源
	sun.light_energy = 3.0  # 增强光源强度
	sun.rotation_degrees = Vector3(-90, 0, 0)  # 从正上方照射
	sun.shadow_enabled = true  # 启用阴影
	add_child(sun)
	
	# 添加点光源 - 从上方均匀分布
	_add_light(Vector3(0, 3.8, 0), Color(0.9, 0.7, 0.5), 1.8, 18)  # 中心暖光（更高位置）
	_add_light(Vector3(-6, 3.8, -6), Color(0.8, 0.8, 0.8), 1.5, 15)  # 左上白色光
	_add_light(Vector3(6, 3.8, 6), Color(0.8, 0.8, 0.8), 1.5, 15)  # 右下白色光
	_add_light(Vector3(-6, 3.8, 6), Color(0.8, 0.8, 0.8), 1.5, 15)  # 左下白色光
	_add_light(Vector3(6, 3.8, -6), Color(0.8, 0.8, 0.8), 1.5, 15)  # 右上白色光
	_add_light(Vector3(-3, 3.8, 0), Color(0.9, 0.9, 0.8), 1.2, 12)  # 左侧暖白色光
	_add_light(Vector3(3, 3.8, 0), Color(0.9, 0.9, 0.8), 1.2, 12)  # 右侧暖白色光
	_add_light(Vector3(0, 3.8, -3), Color(0.9, 0.9, 0.8), 1.2, 12)  # 前侧暖白色光
	_add_light(Vector3(0, 3.8, 3), Color(0.9, 0.9, 0.8), 1.2, 12)  # 后侧暖白色光

# 添加点光源函数
func _add_light(pos: Vector3, c: Color, e: float, r: float) -> void:
	# 创建点光源
	var l = OmniLight3D.new()
	l.position = pos  # 设置位置
	l.light_color = c  # 设置颜色
	l.light_energy = e  # 设置强度
	l.omni_range = r  # 设置范围
	l.shadow_enabled = true  # 启用阴影
	add_child(l)
