# 数据库建议 - 瘸子和瞎子 游戏数据持久化方案

## ══════════════════════════════════════════════
##  方案一：轻量级本地存储（推荐起步方案）
## ══════════════════════════════════════════════

### 使用 Godot 内置的 JSON 文件存储
### 适合：单机存档、玩家设置、统计数据

# --- save_manager.gd ---
# 添加为 Autoload 单例

extends Node

const SAVE_PATH = "user://save_data.json"

# 需要保存的数据结构
var player_data: Dictionary = {
	"steam_id": 0,
	"display_name": "",
	"settings": {
		"mouse_sensitivity": 0.003,
		"master_volume": 1.0,
		"sfx_volume": 1.0,
	},
	"statistics": {
		"games_played": 0,
		"games_won": 0,
		"games_lost": 0,
		"times_as_blind": 0,
		"times_as_lame": 0,
		"total_medicines_collected": 0,
		"total_puzzles_solved": 0,
		"total_play_time_seconds": 0,
	},
	"achievements": [],      # 成就列表
	"last_played": "",       # 最后游玩时间
}

func _ready() -> void:
	load_data()

func save_data() -> void:
	var file = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(player_data, "\t"))
		file.close()

func load_data() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		save_data()  # 首次运行创建默认存档
		return
	var file = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file:
		var json = JSON.new()
		var err = json.parse(file.get_as_text())
		file.close()
		if err == OK:
			# 合并加载的数据（保留新增字段的默认值）
			_merge_dict(player_data, json.data)

# 递归合并字典，保留默认值中的新键
func _merge_dict(target: Dictionary, source: Dictionary) -> void:
	for key in source:
		if key in target and target[key] is Dictionary and source[key] is Dictionary:
			_merge_dict(target[key], source[key])
		else:
			target[key] = source[key]

# ── 便捷方法 ──
func record_game_result(won: bool, role: int) -> void:
	player_data["statistics"]["games_played"] += 1
	if won:
		player_data["statistics"]["games_won"] += 1
	else:
		player_data["statistics"]["games_lost"] += 1
	if role == GameManager.ROLE_BLIND:
		player_data["statistics"]["times_as_blind"] += 1
	else:
		player_data["statistics"]["times_as_lame"] += 1
	player_data["last_played"] = Time.get_datetime_string_from_system()
	save_data()


## ══════════════════════════════════════════════
##  方案二：云端数据库（多设备同步 / 排行榜 / 反作弊）
## ══════════════════════════════════════════════

### 推荐方案：Firebase Realtime Database 或 Supabase
### 适合：排行榜、玩家档案云同步、好友系统

### ── Firebase 方案 ──
### 优点：免费额度大、实时同步、Google 托管
### 使用方式：通过 HTTPRequest 节点调用 Firebase REST API
###
### 数据结构示例 (JSON):
### /players/{steam_id}/
###   ├── display_name: "玩家名"
###   ├── statistics: { games_played, wins, losses, ... }
###   ├── achievements: [...]
###   └── last_online: "2026-04-09T12:00:00"
###
### /leaderboard/
###   ├── {steam_id}: { name, wins, win_rate, total_games }
###   └── ...
###
### /match_history/{match_id}/
###   ├── timestamp: "2026-04-09T12:00:00"
###   ├── players: { host_steam_id, guest_steam_id }
###   ├── roles: { host_role, guest_role }
###   ├── result: "win" | "lose"
###   ├── duration_seconds: 180
###   └── puzzles_solved: 3

### ── Supabase 方案（推荐）──
### 优点：开源、PostgreSQL、REST + Realtime、自带认证
### 比 Firebase 更适合关系型数据查询（如复杂排行榜）
###
### SQL 表结构：

# CREATE TABLE players (
#     steam_id BIGINT PRIMARY KEY,
#     display_name TEXT NOT NULL,
#     mouse_sensitivity FLOAT DEFAULT 0.003,
#     master_volume FLOAT DEFAULT 1.0,
#     games_played INTEGER DEFAULT 0,
#     games_won INTEGER DEFAULT 0,
#     games_lost INTEGER DEFAULT 0,
#     times_as_blind INTEGER DEFAULT 0,
#     times_as_lame INTEGER DEFAULT 0,
#     total_medicines INTEGER DEFAULT 0,
#     total_puzzles INTEGER DEFAULT 0,
#     total_play_time INTEGER DEFAULT 0,
#     created_at TIMESTAMPTZ DEFAULT NOW(),
#     last_played TIMESTAMPTZ
# );
#
# CREATE TABLE match_history (
#     id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
#     host_steam_id BIGINT REFERENCES players(steam_id),
#     guest_steam_id BIGINT REFERENCES players(steam_id),
#     host_role INTEGER NOT NULL,       -- 0=blind, 1=lame
#     result TEXT NOT NULL,             -- 'win', 'lose', 'disconnect'
#     puzzles_solved INTEGER DEFAULT 0,
#     duration_seconds INTEGER DEFAULT 0,
#     created_at TIMESTAMPTZ DEFAULT NOW()
# );
#
# CREATE TABLE achievements (
#     id SERIAL PRIMARY KEY,
#     steam_id BIGINT REFERENCES players(steam_id),
#     achievement_key TEXT NOT NULL,    -- 如 'first_win', 'speed_run_60s'
#     unlocked_at TIMESTAMPTZ DEFAULT NOW(),
#     UNIQUE(steam_id, achievement_key)
# );
#
# -- 排行榜视图
# CREATE VIEW leaderboard AS
# SELECT
#     steam_id,
#     display_name,
#     games_won,
#     games_played,
#     CASE WHEN games_played > 0
#         THEN ROUND(games_won::NUMERIC / games_played * 100, 1)
#         ELSE 0
#     END AS win_rate
# FROM players
# WHERE games_played >= 5
# ORDER BY games_won DESC, win_rate DESC
# LIMIT 100;


## ══════════════════════════════════════════════
##  方案三：Steam Cloud（最简单的云存储）
## ══════════════════════════════════════════════

### 如果你有正式的 Steam App ID，可以使用 Steam Cloud 存储
### 优点：无需自建服务器、自动多设备同步、与 Steam 深度集成

# --- steam_cloud_save.gd ---
# func save_to_steam_cloud() -> void:
#     var data = JSON.stringify(player_data)
#     var bytes = data.to_utf8_buffer()
#     Steam.fileWrite("save_data.json", bytes)
#
# func load_from_steam_cloud() -> void:
#     if Steam.fileExists("save_data.json"):
#         var size = Steam.getFileSize("save_data.json")
#         var bytes = Steam.fileRead("save_data.json", size)
#         var data = bytes.get_string_from_utf8()
#         var json = JSON.new()
#         if json.parse(data) == OK:
#             _merge_dict(player_data, json.data)


## ══════════════════════════════════════════════
##  推荐实施路径
## ══════════════════════════════════════════════

### 第一阶段（现在）：
###   → 使用方案一 (本地 JSON) 保存设置和统计
###   → 添加 save_manager.gd 作为 Autoload
###   → 在 game_manager.gd 的 trigger_game_over() 中调用存档

### 第二阶段（联机稳定后）：
###   → 添加方案三 (Steam Cloud) 实现云同步
###   → 需要正式 Steam App ID

### 第三阶段（需要排行榜/社交功能时）：
###   → 部署 Supabase 实例（免费 tier 足够）
###   → 添加 HTTP 层上报对局数据
###   → 实现排行榜和对局历史查询
