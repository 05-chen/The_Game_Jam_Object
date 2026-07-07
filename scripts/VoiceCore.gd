extends Node

## --- 基础配置 ---
const DEFAULT_SAMPLE_RATE: int = 16000
## 每帧从 Steam 麦克风队列最多读多少包
const LOCAL_PACKET_READ_LIMIT: int = 16
## 每帧最多解压多少包远端语音，避免单帧阻塞 Steam 网络线程
const REMOTE_PACKET_DECODE_LIMIT: int = 8
## AudioStreamGenerator 内部缓冲（秒）：公网 P2P 抖动需更大，过小会欠载发糊
const REMOTE_PLAYBACK_BUFFER_SEC: float = 0.25
## 开始播放前预缓冲（字节）：16kHz mono s16 ≈ 32000 B/s，6400≈200ms
const REMOTE_PREBUFFER_BYTES: int = 6400
## 欠载时最多补多少静音帧，避免 generator 断粮后反复触发预缓冲
const REMOTE_UNDERRUN_PAD_MS: float = 12.0
## PCM 队列上限，超出丢弃最旧数据防止延迟无限堆积
const REMOTE_PCM_MAX_BYTES: int = 32768

## --- 状态变量 ---
var _sample_rate: int = DEFAULT_SAMPLE_RATE
var _is_recording: bool = false
var always_on_voice: bool = true

# 预留：由主机/规则显式禁麦时可写；日常疼痛阶梯请只用 GameManager + set_voice_transmit_enabled
var is_disabled_by_pain: bool = false

## --- 远程音频组件 ---
var _remote_player: AudioStreamPlayer = null
var _remote_generator: AudioStreamGenerator = null
var _remote_playback: AudioStreamGeneratorPlayback = null
var _remote_pcm_buffer: PackedByteArray = PackedByteArray()
var _remote_read_idx: int = 0
var _remote_playback_primed: bool = false
var _remote_target_db: float = 0.0
var _remote_smoothed_db: float = 0.0
const REMOTE_DB_LERP_SPEED: float = 12.0
var _voice_transmit_enabled: bool = true
var _runtime_enabled: bool = true
## 疼痛阶梯离散化后，仅在 Tier 变化时改麦克/远端增益，避免 pain_value_changed 每帧触发带来的音量微抖
var _voice_tier_lame_local: int = -999
var _voice_tier_blind_remote: int = -999
var _voice_soft_paused: bool = false

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
	if _voice_soft_paused:
		if _is_recording:
			_set_recording(false)
		return
	if not NetworkManager.is_voice_link_ready():
		if _is_recording:
			_set_recording(false)
		if not NetworkManager.is_multiplayer_game:
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

	_poll_receive_voice_p2p()
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
	_remote_generator.buffer_length = REMOTE_PLAYBACK_BUFFER_SEC
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
	if _is_recording == enable:
		return
	_is_recording = enable
	if enable:
		Steam.startVoiceRecording()
		if NetworkManager.steam_id != 0:
			Steam.setInGameVoiceSpeaking(NetworkManager.steam_id, true)
	else:
		Steam.stopVoiceRecording()
		if NetworkManager.steam_id != 0:
			Steam.setInGameVoiceSpeaking(NetworkManager.steam_id, false)

func stop_voice_capture(reason: String = "") -> void:
	shutdown_voice(reason if reason != "" else "stop_voice_capture")

func shutdown_voice(_reason: String = "") -> void:
	if not _runtime_enabled and not _is_recording and not _voice_soft_paused:
		return
	_voice_soft_paused = false
	_runtime_enabled = false
	if _is_recording:
		_set_recording(false)
	_remote_pcm_buffer.clear()
	_remote_read_idx = 0
	_remote_playback_primed = false
	_remote_target_db = -80.0
	_remote_smoothed_db = -80.0
	if _remote_player:
		_remote_player.volume_db = -80.0
	is_disabled_by_pain = false
	# 不 stop() 播放器，避免 Windows WASAPI 设备反复开关导致 GetBufferSize 错误

func pause_voice(_reason: String = "") -> void:
	if _voice_soft_paused:
		return
	_voice_soft_paused = true
	if _is_recording:
		_set_recording(false)
	_remote_pcm_buffer.clear()
	_remote_read_idx = 0
	_remote_playback_primed = false
	if _remote_player:
		_remote_player.volume_db = -80.0

func resume_voice(reason: String = "") -> void:
	if not _runtime_enabled:
		startup_voice(reason if reason != "" else "resume_voice")
		return
	if not _voice_soft_paused:
		return
	_voice_soft_paused = false
	_remote_playback_primed = false
	_ensure_remote_playback_ready()
	if _remote_player:
		_remote_player.volume_db = _remote_smoothed_db
	_on_global_pain_for_voice(GameManager.pain_value)

func startup_voice(_reason: String = "") -> void:
	if _runtime_enabled and not _voice_soft_paused:
		return
	NetworkManager._ensure_voice_p2p_session()
	_runtime_enabled = true
	_voice_soft_paused = false
	_voice_transmit_enabled = true
	_remote_target_db = 0.0
	_remote_smoothed_db = 0.0
	_voice_tier_lame_local = -999
	_voice_tier_blind_remote = -999
	_remote_playback_primed = false
	_ensure_remote_playback_ready()
	if _remote_player:
		_remote_player.volume_db = 0.0
	_on_global_pain_for_voice(GameManager.pain_value)

func _ensure_remote_playback_ready() -> void:
	if _remote_player == null:
		_setup_remote_audio_player()
		return
	if not _remote_player.playing:
		_remote_player.play()
	_remote_playback = _remote_player.get_stream_playback()
	if _remote_playback == null:
		_remote_player.stop()
		_remote_player.play()
		_remote_playback = _remote_player.get_stream_playback()

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

func _poll_receive_voice_p2p() -> void:
	var decoded := 0
	for packet in NetworkManager.poll_voice_packets():
		push_remote_voice_packet(packet)
		decoded += 1
		if decoded >= REMOTE_PACKET_DECODE_LIMIT:
			break

func push_remote_voice_packet(compressed_voice: PackedByteArray) -> void:
	if compressed_voice.is_empty():
		return

	var decompressed: Dictionary = Steam.decompressVoice(compressed_voice, _sample_rate)
	if decompressed.get("result", -1) != Steam.VOICE_RESULT_OK:
		return

	var pcm: PackedByteArray = decompressed.get("uncompressed", PackedByteArray())
	if pcm.is_empty():
		return

	_remote_pcm_buffer.append_array(pcm)
	_trim_remote_pcm_buffer()


func _trim_remote_pcm_buffer() -> void:
	var unread := _remote_pcm_buffer.size() - _remote_read_idx
	if unread <= REMOTE_PCM_MAX_BYTES:
		return
	var drop := unread - REMOTE_PCM_MAX_BYTES
	_remote_read_idx += drop
	if _remote_read_idx >= _remote_pcm_buffer.size():
		_remote_pcm_buffer.clear()
		_remote_read_idx = 0
		_remote_playback_primed = false


func _remote_pcm_unread_bytes() -> int:
	return _remote_pcm_buffer.size() - _remote_read_idx


func _consume_remote_audio_frames() -> void:
	if _remote_playback == null:
		return

	var unread := _remote_pcm_unread_bytes()
	if not _remote_playback_primed:
		if unread < REMOTE_PREBUFFER_BYTES:
			return
		_remote_playback_primed = true

	var frames_available: int = _remote_playback.get_frames_available()
	if frames_available <= 0:
		return

	if unread >= 2:
		var samples_to_play := mini(unread >> 1, frames_available)
		var byte_len := samples_to_play * 2
		var chunk := _remote_pcm_buffer.slice(_remote_read_idx, _remote_read_idx + byte_len)
		var frames := PackedVector2Array()
		frames.resize(samples_to_play)
		for i in range(samples_to_play):
			var sample_int: int = chunk.decode_s16(i * 2)
			var amplitude: float = clampf(float(sample_int) / 32768.0, -1.0, 1.0)
			frames[i] = Vector2(amplitude, amplitude)
		_remote_read_idx += byte_len
		_remote_playback.push_buffer(frames)
	elif _remote_playback_primed:
		var pad := mini(
			frames_available,
			int(_sample_rate * REMOTE_UNDERRUN_PAD_MS / 1000.0)
		)
		if pad > 0:
			var silence := PackedVector2Array()
			silence.resize(pad)
			silence.fill(Vector2.ZERO)
			_remote_playback.push_buffer(silence)

	if _remote_read_idx >= _remote_pcm_buffer.size():
		_remote_pcm_buffer.clear()
		_remote_read_idx = 0
