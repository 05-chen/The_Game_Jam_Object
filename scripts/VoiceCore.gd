extends Node

## --- 基础配置 ---
const DEFAULT_SAMPLE_RATE: int = 16000
const LOCAL_PACKET_READ_LIMIT: int = 6

## --- 状态变量 ---
var _sample_rate: int = DEFAULT_SAMPLE_RATE
var _is_recording: bool = false
var always_on_voice: bool = true

# 核心：由外部逻辑脚本（如 PainVoiceLogic）修改此变量
var is_disabled_by_pain: bool = false 

## --- 远程音频组件 ---
var _remote_player: AudioStreamPlayer = null
var _remote_generator: AudioStreamGenerator = null
var _remote_playback: AudioStreamGeneratorPlayback = null
var _remote_pcm_buffer: PackedByteArray = PackedByteArray()
var _remote_read_idx: int = 0
var _remote_target_db: float = 0.0
var _remote_smoothed_db: float = 0.0
const REMOTE_DB_LERP_SPEED: float = 12.0
var _voice_transmit_enabled: bool = true
var _runtime_enabled: bool = true
## 疼痛阶梯离散化后，仅在 Tier 变化时改麦克/远端增益，避免 pain_value_changed 每帧触发带来的音量微抖
var _voice_tier_lame_local: int = -999
var _voice_tier_blind_remote: int = -999

func _ready() -> void:
	# 只允许 Autoload 单例实例运行语音主循环，避免场景内重复 VoiceCore 造成双录音/双播放
	if self != VoiceChatManager:
		process_mode = Node.PROCESS_MODE_DISABLED
		set_process(false)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameManager.pain_value_changed.connect(_on_global_pain_for_voice)
	# 确保 Steam 初始化后再设置语音
	call_deferred("_setup_voice")

func _setup_voice() -> void:
	_setup_sample_rate()
	_setup_remote_audio_player()
	_on_global_pain_for_voice(GameManager.pain_value)


## 本地/远端语音阶梯均以 GameManager.pain_value 为准（瘸子端控麦，瞎子端控收听音量）；Tier 未变则不改 Steam/音量目标，减轻抖动
func _on_global_pain_for_voice(pain: float) -> void:
	if not _runtime_enabled:
		return
	var tier := GameManager.pain_to_voice_tier(pain)
	if NetworkManager.is_multiplayer_game:
		match GameManager.current_role:
			GameManager.ROLE_LAME:
				if tier == _voice_tier_lame_local:
					return
				_voice_tier_lame_local = tier
				set_local_pain_voice_policy(pain)
				set_voice_transmit_enabled(tier != 0)
			GameManager.ROLE_BLIND:
				if tier == _voice_tier_blind_remote:
					return
				_voice_tier_blind_remote = tier
				set_remote_voice_tier(tier)
	else:
		if GameManager.current_role == GameManager.ROLE_LAME:
			if tier == _voice_tier_lame_local:
				return
			_voice_tier_lame_local = tier
			set_local_pain_voice_policy(pain)
			set_voice_transmit_enabled(tier != 0)

func _process(delta: float) -> void:
	if not _runtime_enabled:
		if _is_recording:
			_set_recording(false)
		return
	if not NetworkManager.is_multiplayer_game:
		if _is_recording:
			_set_recording(false)
		is_disabled_by_pain = false
		_voice_transmit_enabled = true
		_remote_target_db = 0.0
		_remote_smoothed_db = 0.0
		if _remote_player:
			_remote_player.volume_db = 0.0
		return

	_smooth_remote_voice_db(delta)
	_update_recording_state()

	if _is_recording:
		_poll_and_send_local_voice()

	_consume_remote_audio_frames()


func _smooth_remote_voice_db(delta: float) -> void:
	if _remote_player == null:
		return
	var k := clampf(REMOTE_DB_LERP_SPEED * delta, 0.0, 1.0)
	_remote_smoothed_db = lerpf(_remote_smoothed_db, _remote_target_db, k)
	_remote_player.volume_db = _remote_smoothed_db

func _setup_sample_rate() -> void:
	if not Steam.isSteamRunning():
		print("语音组件：Steam 未运行")
		return
	_sample_rate = DEFAULT_SAMPLE_RATE

func _setup_remote_audio_player() -> void:
	_remote_player = AudioStreamPlayer.new()
	_remote_player.name = "RemoteVoicePlayer"
	add_child(_remote_player)

	_remote_generator = AudioStreamGenerator.new()
	_remote_generator.mix_rate = _sample_rate
	# 约 45ms 抖动缓冲，在稳定性与 40~50ms 级延迟目标之间折中
	_remote_generator.buffer_length = 0.045
	_remote_player.stream = _remote_generator
	_remote_player.volume_db = 0.0
	_remote_player.play()
	_remote_playback = _remote_player.get_stream_playback()

func _update_recording_state() -> void:
	# 核心逻辑：只有在没被疼痛禁用时，按键或常开才有效
	var can_work = not is_disabled_by_pain
	var should_record: bool = (always_on_voice or Input.is_action_pressed("push_to_talk")) and can_work and _voice_transmit_enabled
	
	if should_record != _is_recording:
		_set_recording(should_record)

func _set_recording(enable: bool) -> void:
	_is_recording = enable
	if enable:
		Steam.startVoiceRecording()
	else:
		Steam.stopVoiceRecording()

func stop_voice_capture(reason: String = "") -> void:
	shutdown_voice(reason if reason != "" else "stop_voice_capture")

func shutdown_voice(reason: String = "") -> void:
	if not _runtime_enabled and not _is_recording:
		return
	print("[Voice] shutdown_voice reason=", reason)
	_runtime_enabled = false
	if _is_recording:
		_set_recording(false)
	_remote_pcm_buffer.clear()
	_remote_read_idx = 0
	_remote_target_db = -80.0
	_remote_smoothed_db = -80.0
	if _remote_player:
		_remote_player.volume_db = -80.0
	is_disabled_by_pain = false
	if _remote_player and _remote_player.playing:
		_remote_player.stop()

func startup_voice(reason: String = "") -> void:
	if _runtime_enabled:
		return
	print("[Voice] startup_voice reason=", reason)
	_runtime_enabled = true
	_voice_transmit_enabled = true
	_remote_target_db = 0.0
	_remote_smoothed_db = 0.0
	_voice_tier_lame_local = -999
	_voice_tier_blind_remote = -999
	if _remote_player:
		_remote_player.volume_db = 0.0
		if not _remote_player.playing:
			_remote_player.play()
	_on_global_pain_for_voice(GameManager.pain_value)

func set_local_pain_voice_policy(pain: float) -> void:
	# 与 GameManager.pain_to_voice_tier 一致：仅 Tier0（疼痛>=100 濒死）彻底禁麦
	is_disabled_by_pain = GameManager.pain_to_voice_tier(pain) == 0

func set_voice_transmit_enabled(enabled: bool) -> void:
	_voice_transmit_enabled = enabled


func set_remote_voice_tier(tier: int) -> void:
	_remote_target_db = GameManager.voice_tier_to_volume_db(tier)  # 使用 GameManager.VOICE_TIER_DB


func set_remote_pain_voice_policy(pain: float) -> void:
	# 兼容旧调用：按疼痛映射为阶梯目标 dB，实际平滑在 _smooth_remote_voice_db
	set_remote_voice_tier(GameManager.pain_to_voice_tier(pain))

func _poll_and_send_local_voice() -> void:
	if not _voice_transmit_enabled:
		return
	for _i in range(LOCAL_PACKET_READ_LIMIT):
		var voice_data: Dictionary = Steam.getVoice()
		
		if voice_data.get("result", -1) != Steam.VOICE_RESULT_OK:
			break

		var packet: PackedByteArray = voice_data.get("buffer", PackedByteArray())
		if packet.is_empty():
			break
			
		NetworkManager.send_voice_packet(packet)

func push_remote_voice_packet(compressed_voice: PackedByteArray) -> void:
	if compressed_voice.is_empty(): return
	
	var decompressed: Dictionary = Steam.decompressVoice(compressed_voice, _sample_rate)
	if decompressed.get("result", -1) != Steam.VOICE_RESULT_OK: return

	var pcm: PackedByteArray = decompressed.get("uncompressed", PackedByteArray())
	if pcm.is_empty(): return
	
	_remote_pcm_buffer.append_array(pcm)

func _consume_remote_audio_frames() -> void:
	if _remote_playback == null or _remote_pcm_buffer.is_empty():
		return

	var frames_available: int = _remote_playback.get_frames_available()

	while frames_available > 0 and _remote_read_idx + 1 < _remote_pcm_buffer.size():
		var lo: int = _remote_pcm_buffer[_remote_read_idx]
		var hi: int = _remote_pcm_buffer[_remote_read_idx + 1]
		
		var raw_value: int = lo | (hi << 8)
		if raw_value >= 32768: raw_value -= 65536
		
		var amplitude: float = clampf(float(raw_value) / 32768.0, -1.0, 1.0)
		_remote_playback.push_frame(Vector2(amplitude, amplitude))
		
		_remote_read_idx += 2
		frames_available -= 1

	if _remote_read_idx >= _remote_pcm_buffer.size():
		_remote_pcm_buffer.clear()
		_remote_read_idx = 0
	elif _remote_pcm_buffer.size() > 8192: 
		_remote_pcm_buffer = _remote_pcm_buffer.slice(_remote_read_idx)
		_remote_read_idx = 0
