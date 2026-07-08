extends Node

## --- 基础配置（对齐 GodotSteam Voice 教程）---
## Windows 音频设备原生率多为 48000；16kHz 会导致播放发糊、断续
const DEFAULT_SAMPLE_RATE: int = 48000
## getVoice 压缩缓冲（0 = 由 GodotSteam 按 getAvailableVoice 自动扩容）
const GET_VOICE_BUFFER_SIZE: int = 0
## decompressVoice 初始缓冲；过小会 VOICE_RESULT_BUFFER_TOO_SMALL 并丢包
const DECOMPRESS_BUFFER_SIZE: int = 65536
## 每帧从 Steam 麦克风队列最多读多少包
const LOCAL_PACKET_READ_LIMIT: int = 4
## 每帧最多解压多少包远端语音
const REMOTE_PACKET_DECODE_LIMIT: int = 32
## AudioStreamGenerator 内部缓冲（秒）
const REMOTE_PLAYBACK_BUFFER_SEC: float = 0.5
## 开始播放前预缓冲（字节）：48kHz mono s16 ≈ 96000 B/s，9600≈100ms
const REMOTE_PREBUFFER_BYTES: int = 9600
## 欠载时补静音上限（毫秒）
const REMOTE_UNDERRUN_PAD_MS: float = 20.0
## PCM 队列上限（约 1.5s @ 48kHz mono s16），超出丢弃最旧数据
const REMOTE_PCM_MAX_BYTES: int = 144000

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
var _decompress_fail_count: int = 0

func _ready() -> void:
	# 只允许 Autoload 单例实例运行语音主循环，避免场景内重复 VoiceCore 造成双录音/双播放
	if self != VoiceChatManager:
		process_mode = Node.PROCESS_MODE_DISABLED
		set_process(false)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameManager.pain_value_changed.connect(_on_global_pain_for_voice)
	call_deferred("_setup_voice")

func _setup_voice() -> void:
	_setup_sample_rate()
	_setup_remote_audio_player()
	_on_global_pain_for_voice(GameManager.pain_value)


## 双向语音：双方均可发麦；疼痛阶梯仍只约束「瘸子发麦 + 瞎子听瘸子音量」
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
				# 瘸子听瞎子：不受疼痛阶梯影响，保持清晰
				_remote_target_db = 0.0
			GameManager.ROLE_BLIND:
				if tier == _voice_tier_blind_remote:
					return
				_voice_tier_blind_remote = tier
				set_remote_voice_tier(tier)
				is_disabled_by_pain = false
				set_voice_transmit_enabled(true)
	else:
		if GameManager.current_role == GameManager.ROLE_LAME:
			if tier == _voice_tier_lame_local:
				return
			_voice_tier_lame_local = tier
			set_local_pain_voice_policy(pain)
			set_voice_transmit_enabled(tier != 0)
		elif GameManager.current_role == GameManager.ROLE_BLIND:
			is_disabled_by_pain = false
			set_voice_transmit_enabled(true)

func _process(_delta: float) -> void:
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

	_smooth_remote_voice_db(_delta)
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
		push_warning("语音组件：Steam 未运行")
		return
	_sample_rate = DEFAULT_SAMPLE_RATE

func _setup_remote_audio_player() -> void:
	if _remote_player == null:
		_remote_player = AudioStreamPlayer.new()
		_remote_player.name = "RemoteVoicePlayer"
		_remote_player.bus = &"Master"
		add_child(_remote_player)

	_remote_generator = AudioStreamGenerator.new()
	_remote_generator.mix_rate = float(_sample_rate)
	_remote_generator.buffer_length = REMOTE_PLAYBACK_BUFFER_SEC
	_remote_player.stream = _remote_generator
	_remote_player.volume_db = 0.0
	if not _remote_player.playing:
		_remote_player.play()
	_remote_playback = _remote_player.get_stream_playback()

func _update_recording_state() -> void:
	var can_work := not is_disabled_by_pain
	var should_record := (always_on_voice or Input.is_action_pressed("push_to_talk")) \
		and can_work and _voice_transmit_enabled

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
	_decompress_fail_count = 0
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
	is_disabled_by_pain = GameManager.pain_to_voice_tier(pain) == 0

func set_voice_transmit_enabled(enabled: bool) -> void:
	_voice_transmit_enabled = enabled

func set_remote_voice_tier(tier: int) -> void:
	_remote_target_db = GameManager.voice_tier_to_volume_db(tier)

func set_remote_pain_voice_policy(pain: float) -> void:
	set_remote_voice_tier(GameManager.pain_to_voice_tier(pain))

func _poll_and_send_local_voice() -> void:
	if not _voice_transmit_enabled:
		return
	for _i in range(LOCAL_PACKET_READ_LIMIT):
		if Steam.has_method("getAvailableVoice"):
			var available: Dictionary = Steam.getAvailableVoice()
			if available.get("result", -1) != Steam.VOICE_RESULT_OK:
				break
			if int(available.get("size", 0)) <= 0:
				break

		var voice_data: Dictionary = Steam.getVoice(GET_VOICE_BUFFER_SIZE)
		if voice_data.get("result", -1) != Steam.VOICE_RESULT_OK:
			break

		var written := int(voice_data.get("written", 0))
		if written <= 0:
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

	var pcm := _decompress_voice_to_pcm(compressed_voice)
	if pcm.is_empty():
		return

	_remote_pcm_buffer.append_array(pcm)
	_trim_remote_pcm_buffer()

func _decompress_voice_to_pcm(compressed_voice: PackedByteArray) -> PackedByteArray:
	var buf_size := DECOMPRESS_BUFFER_SIZE
	var last_result := -1
	for _attempt in range(4):
		var decompressed: Dictionary = Steam.decompressVoice(compressed_voice, _sample_rate, buf_size)
		last_result = int(decompressed.get("result", -1))
		if last_result == Steam.VOICE_RESULT_OK:
			var pcm_size := int(decompressed.get("size", 0))
			var pcm: PackedByteArray = decompressed.get("uncompressed", PackedByteArray())
			if pcm_size > 0 and pcm.size() >= pcm_size:
				return pcm.slice(0, pcm_size)
			if pcm.size() >= 2:
				return pcm
			return PackedByteArray()
		if last_result == Steam.VOICE_RESULT_BUFFER_TOO_SMALL:
			buf_size *= 2
			continue
		break

	_decompress_fail_count += 1
	if _decompress_fail_count <= 3 or _decompress_fail_count % 60 == 0:
		push_warning("语音解压失败 result=%d（累计 %d 次）" % [last_result, _decompress_fail_count])
	return PackedByteArray()

func _trim_remote_pcm_buffer() -> void:
	var unread := _remote_pcm_buffer.size() - _remote_read_idx
	if unread <= REMOTE_PCM_MAX_BYTES:
		return
	var drop := unread - REMOTE_PCM_MAX_BYTES
	_remote_read_idx += drop
	_compact_pcm_buffer_if_needed()

func _compact_pcm_buffer_if_needed() -> void:
	if _remote_read_idx <= 0:
		return
	if _remote_read_idx >= _remote_pcm_buffer.size():
		_remote_pcm_buffer.clear()
		_remote_read_idx = 0
		return
	if _remote_read_idx >= 8192:
		_remote_pcm_buffer = _remote_pcm_buffer.slice(_remote_read_idx)
		_remote_read_idx = 0

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

	# 每帧尽量填满 generator 可用空间，避免「攒一大包→播一小段→又断粮」
	while unread >= 2:
		var frames_available := _remote_playback.get_frames_available()
		if frames_available <= 0:
			break

		var samples_to_play := mini(unread >> 1, frames_available)
		var byte_len := samples_to_play * 2
		var chunk := _remote_pcm_buffer.slice(_remote_read_idx, _remote_read_idx + byte_len)
		var frames := _pcm_bytes_to_stereo_frames(chunk, samples_to_play)
		_remote_read_idx += byte_len
		_remote_playback.push_buffer(frames)
		unread = _remote_pcm_unread_bytes()

	if unread < 2 and _remote_playback_primed:
		var pad_frames := _remote_playback.get_frames_available()
		if pad_frames > 0:
			var pad := mini(pad_frames, int(_sample_rate * REMOTE_UNDERRUN_PAD_MS / 1000.0))
			if pad > 0:
				var silence := PackedVector2Array()
				silence.resize(pad)
				silence.fill(Vector2.ZERO)
				_remote_playback.push_buffer(silence)

	_compact_pcm_buffer_if_needed()

func _pcm_bytes_to_stereo_frames(chunk: PackedByteArray, sample_count: int) -> PackedVector2Array:
	var frames := PackedVector2Array()
	frames.resize(sample_count)
	for i in range(sample_count):
		var sample_int: int = chunk.decode_s16(i * 2)
		var amplitude: float = clampf(float(sample_int) / 32768.0, -1.0, 1.0)
		frames[i] = Vector2(amplitude, amplitude)
	return frames
