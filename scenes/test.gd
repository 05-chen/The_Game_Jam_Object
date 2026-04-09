extends Node

var steam

func _ready():
	# GDExtension 方式获取 Steam 单例
	if Engine.has_singleton("Steam"):
		steam = Engine.get_singleton("Steam")
	else:
		print("Steam 单例未找到，请检查 GodotSteam 插件是否正确安装")
		return

	if steam.steamInitEx(480, true):  # 480 是 Spacewar 测试 AppID
		print("Steam 初始化成功！")
		print("玩家昵称：", steam.getPersonaName())
		print("Steam ID：", steam.getSteamID())
	else:
		print("Steam 初始化失败！")
