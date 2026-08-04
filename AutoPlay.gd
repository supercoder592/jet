extends Node

#══════════════════════════════════════════════════════════════════════════════
#  自動打一局（單人作戰）
#
#  由 MainGame._ready() 在環境變數 AUTOPLAY 有值時才掛上，正式遊玩完全不會執行。
#  流程：訪客登入 → 單人作戰 → 簡報 → 部署 → 登機 → 開自動駕駛 → 打到分出勝負。
#  飛行完全交給遊戲自己的 AI FSM（就是聊天密碼 120514 那個自動駕駛），
#  這支腳本只負責登機、重生後再登機、記錄戰況與截圖。
#
#    AUTOPLAY          1                  啟用
#    AUTOPLAY_TEAM     atk | def          選邊（預設 atk）
#    AUTOPLAY_SHOTS    截圖輸出資料夾（空＝不截圖）
#    AUTOPLAY_MAXSEC   總時間上限秒數（預設 900）
#    AUTOPLAY_MAP      鎖定地圖 id（0 峽谷 1 平原 2 高原 3 橫斷 4 高山 5 丘陵 6 大堤頓 7 都會）
#                      不設就照遊戲原本的隨機邏輯
#    AUTOPLAY_CHECK    lane ─ 不打了，只掃描航母進場航道上有沒有地形，掃完就結束
#══════════════════════════════════════════════════════════════════════════════

var main: Node = null
var world = null

var want_def: bool = false
var shots_dir: String = ""
var max_sec: float = 900.0

var _t0: int = 0
var _shot_n: int = 0
var _boards: int = 0
var _last_log: int = 0
var _env_deaths: int = 0           # 自己摔掉的次數（撞山／墜海…）
var _shot_down: int = 0            # 被敵人打下來的次數
var _cause: Dictionary = {}        # 死因 -> 次數


func _ready() -> void:
	main = get_parent()
	want_def  = OS.get_environment("AUTOPLAY_TEAM").strip_edges().to_lower() == "def"
	shots_dir = OS.get_environment("AUTOPLAY_SHOTS").strip_edges()
	var ms := OS.get_environment("AUTOPLAY_MAXSEC").strip_edges()
	if ms != "":
		max_sec = float(ms)
	_t0 = Time.get_ticks_msec()
	if shots_dir != "":
		DirAccess.make_dir_recursive_absolute(shots_dir)
	_run.call_deferred()


func say(msg: String) -> void:
	print("[PLAY] %6.1fs  %s" % [_elapsed(), msg])


func _elapsed() -> float:
	return float(Time.get_ticks_msec() - _t0) / 1000.0


func until(cond: Callable, secs: float) -> bool:
	var limit := Time.get_ticks_msec() + int(secs * 1000.0)
	while Time.get_ticks_msec() < limit:
		if bool(cond.call()):
			return true
		await get_tree().process_frame
	return false


func shoot(tag: String) -> void:
	if shots_dir == "":
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	_shot_n += 1
	var p := "%s/%02d-%s.png" % [shots_dir, _shot_n, tag]
	img.save_png(p)
	say("截圖 → " + p)


func me_id() -> int:
	return main.my_id()


func my_plane():
	if world == null:
		return null
	return world.aircraft.get(me_id())


func stat(key: String) -> int:
	var p: Dictionary = main.players.get(me_id(), {})
	return int(p.get(key, 0))


## 把 cli_kill 的 attacker id 翻成看得懂的來源，才知道到底是誰在殺我
func _killer_name(id: int) -> String:
	if world.KILLER_NAME.has(id):
		return String(world.KILLER_NAME[id])
	if main.players.has(id):
		return "敵機 %s" % main.players[id]["name"]
	return "不明(%d)" % id


func nuke_hp() -> float:
	if world == null or not world.structures.has("NUKE"):
		return -1.0
	return float(world.structures["NUKE"]["hp"])


func runway_hp() -> float:
	if world == null or not world.structures.has("RUNWAY"):
		return -1.0
	return float(world.structures["RUNWAY"]["hp"])


#══════════════════════════════════════════════════════════════════════════════
func _run() -> void:
	var r: Dictionary = main._accounts.guest_login()
	main._finish_login(r)
	main._name_edit.text = "AUTO"
	main._request_team(main.TEAM_DEFENDER if want_def else main.TEAM_ATTACKER)
	say("訪客登入完成，陣營＝%s" % ("防守方" if want_def else "進攻方"))

	# 地形問題要在同一張地圖上比才有意義，隨機地圖沒辦法做前後對照
	var mp := OS.get_environment("AUTOPLAY_MAP").strip_edges()
	if mp != "" and mp.is_valid_int():
		main.map_choice = int(mp)
		say("鎖定地圖：%s" % main.MAP_INFO[int(mp)]["name"])

	main.start_solo_game()
	if not await until(func(): return main.world != null, 20.0):
		say("開局失敗：world 沒有生成")
		await _bail(1)
		return
	world = main.world
	say("單人作戰已開局：地圖 %s / 天氣 %d / 時段 %d"
		% [main.MAP_INFO[main.map_id]["name"], main.weather, main.time_of_day])

	if OS.get_environment("AUTOPLAY_CHECK").strip_edges().to_lower() == "lane":
		await get_tree().process_frame
		await _check_carrier_lane()
		return

	await shoot("brief")

	# ── 簡報 → 部署 → 戰鬥 ──
	if not await until(func(): return world.phase == world.PHASE_DEPLOY, 90.0):
		say("卡在簡報階段")
		await _bail(1)
		return
	say("簡報結束，進入部署")
	await shoot("deploy")

	if not await until(func(): return world.phase == world.PHASE_COMBAT, 90.0):
		say("卡在部署階段")
		await _bail(1)
		return
	say("部署結束，戰鬥開始")

	# ── 登機 ＋ 打開自動駕駛 ──
	await _board_and_autopilot()
	await shoot("takeoff")

	# ── 打完整局 ──
	await _fight()

	await shoot("end")
	_report()
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0)


func _board_and_autopilot() -> void:
	var vt: int = int(main.players[me_id()]["vtype"])
	world._request_board(vt)
	_boards += 1
	var ok := await until(func(): return my_plane() != null, 15.0)
	if not ok:
		say("登機失敗")
		return
	say("已登上 %s（第 %d 次出擊）" % [main.VTYPE_NAME[vt], _boards])
	# 自動駕駛只要開一次就會一直有效，但重生後要重新給 AI 一組乾淨狀態
	if world.autopilot:
		world.toggle_autopilot()
	world.toggle_autopilot()
	say("自動駕駛接手")


func _fight() -> void:
	while main.in_match and _elapsed() < max_sec:
		await get_tree().process_frame

		# 掉了之後會變回步行的飛行員，等重生完成就再出擊一次。
		# 分辨是自己摔的還是被打下來的：只有前者會累加 world.local_env_deaths。
		if my_plane() == null and world.phase == world.PHASE_COMBAT and main.in_match:
			if world.pilots.has(me_id()):
				var env: int = int(world.local_env_deaths)
				if env > _env_deaths:
					_env_deaths = env
					_cause[world.last_death_cause] = int(_cause.get(world.last_death_cause, 0)) + 1
					say("陣亡（%s）" % world.last_death_cause)
				else:
					_shot_down += 1
					var who: String = _killer_name(int(world.last_killer))
					_cause[who] = int(_cause.get(who, 0)) + 1
					say("陣亡（%s）" % who)
				await _board_and_autopilot()

		# 每 60 秒記一次戰況＋截圖
		var t := int(world.match_time)
		if t / 60 > _last_log:
			_last_log = t / 60
			var a = my_plane()
			var hp := ("%.0f" % a.hp) if a != null else "─"
			var msl := ("%d" % a.msl_ammo) if a != null else "─"
			say("t=%d:%02d  自機HP=%s 飛彈存量=%s  擊墜=%d 陣亡=%d  累計射出飛彈=%d  核設施HP=%.0f  跑道HP=%.0f"
				% [t / 60, t % 60, hp, msl, stat("kills"), stat("deaths"),
					int(world.local_missiles_fired), nuke_hp(), runway_hp()])
			await shoot("t%02d" % (t / 60))


func _report() -> void:
	var won := nuke_hp() <= 0.0
	var mine := (not want_def) if won else want_def
	say("──────── 戰果 ────────")
	say("結束時比賽時間 %.0f 秒" % (world.match_time if world != null else 0.0))
	say("勝方：%s（%s）" % ["進攻方" if won else "防守方",
		"核設施被摧毀" if won else "核設施撐過 10 分鐘"])
	say("我方結果：%s" % ("勝利" if mine else "落敗"))
	say("擊墜 %d ／ 陣亡 %d（players 計數器）" % [stat("kills"), stat("deaths")])
	say("出擊 %d 次：自己摔 %d ／ 被擊落 %d" % [_boards, _env_deaths, _shot_down])
	say("整局射出副武裝 %d 發" % int(world.local_missiles_fired))
	var parts: Array[String] = []
	for k in _cause:
		parts.append("%s×%d" % [k, _cause[k]])
	say("我方死因：%s" % (", ".join(parts) if not parts.is_empty() else "無"))
	var all_parts: Array[String] = []
	for k in world.death_causes:
		all_parts.append("%s×%d" % [k, world.death_causes[k]])
	say("全場自摔統計（含 AI）：%s" % (", ".join(all_parts) if not all_parts.is_empty() else "無"))
	say("核設施 HP %.0f ／ 跑道 HP %.0f" % [nuke_hp(), runway_hp()])
	say("RESULT %s" % ("WIN" if mine else "LOSE"))


## 掃描航母進場航道：部署階段航母會從 CARRIER_APPROACH 外的海面駛進來，
## 護航艦橫向散到 ±285。這條航道上只要有被 stamp 進高度圖的地形，
## 航母與艦群就會直接穿過去。這裡直接掃高度圖，比用眼睛看截圖可靠。
func _check_carrier_lane() -> void:
	var cz: float = world.CARRIER_POS.z
	var z0: float = cz - 200.0
	var z1: float = cz + world.CARRIER_APPROACH + 200.0
	var worst := 0.0
	var worst_at := Vector3.ZERO
	var hits := 0
	var z := z0
	while z <= z1:
		var x := -300.0
		while x <= 300.0:
			var h: float = world.terrain_height(Vector3(x, 0.0, z))
			if h > 2.0:
				hits += 1
				if h > worst:
					worst = h
					worst_at = Vector3(x, h, z)
			x += 25.0
		z += 25.0
	say("航道掃描 x∈[-300,300] z∈[%.0f,%.0f]：%d 個取樣點有地形，最高 %.1f m @ (%.0f, %.0f)"
		% [z0, z1, hits, worst, worst_at.x, worst_at.z])
	say("RESULT %s" % ("LANE-CLEAR" if hits == 0 else "LANE-BLOCKED"))
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(0 if hits == 0 else 1)


func _bail(code: int) -> void:
	await shoot("bail")
	get_tree().quit(code)
