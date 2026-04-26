extends Node

# 修正：名字必须和左侧场景树里的 "VoiceSystem" 一模一样
@onready var voice_core = get_node("../VoiceSystem") 

func _process(_delta):
	# 检查父节点是否有 pain_value 变量，防止报错
	if "pain_value" in get_parent():
		var pain = get_parent().pain_value 
		
		if pain >= 90:
			voice_core.is_disabled_by_pain = true # 彻底禁言
		elif pain >= 50:
			# 这里的 randf() 会造成每帧随机开关，产生类似信号不良的“电音撕裂感”
			voice_core.is_disabled_by_pain = (randf() > 0.5) 
		else:
			voice_core.is_disabled_by_pain = false # 正常说话
	else:
		# 如果父节点没找到疼痛变量，默认不禁用，防止脚本卡死
		voice_core.is_disabled_by_pain = false
