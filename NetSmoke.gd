extends Node

#══════════════════════════════════════════════════════════════════════════════
#  連線煙霧測試（headless 自動化）
#
#  由 MainGame._ready() 在環境變數 NETSMOKE 有值時才掛上，正式遊玩完全不會執行。
#  兩個 headless 實例各自扮演房主與客戶端，跑完就以 exit code 0 / 1 回報。
#
#  網頁版沒有環境變數，改用同名的小寫網址參數，例如
#    https://…/?netsmoke=host&netsmoke_scenario=link&netsmoke_room=4242
#  這是驗證 WebRTC 唯一的辦法 ─ 桌面版沒裝 webrtc GDExtension 根本走不到那條路。
#
#    NETSMOKE          host | client        本實例的角色
#    NETSMOKE_SCENARIO happy | link | badpass | latejoin
#    NETSMOKE_ROOM     4 位數房號（房主固定用它開房，客戶端拿它連）
#    NETSMOKE_PASS     房主設定的房間密碼（空字串＝不設密碼）
#    NETSMOKE_JOINPASS 客戶端輸入的密碼（badpass 情境故意填錯）
#    NETSMOKE_DELAY    客戶端加入前先等幾秒，讓房主先把伺服器開起來
#    NETSMOKE_TIMEOUT  單一等待步驟的逾時秒數（預設 25）
#
#  log 裡以 [SMOKE] 開頭的行就是判讀結果，`SETTINGS` 那行給驅動腳本比對兩端一致性。
#══════════════════════════════════════════════════════════════════════════════

var main: Node = null

var role: String = "host"
var scenario: String = "happy"
var room: String = "4242"
var pass_word: String = ""
var join_pass: String = ""
var delay: float = 0.0
var timeout: float = 25.0

var _fails: Array[String] = []
var _checks: int = 0
var _saw_link: bool = false      # 曾經真的連上過（用來排除「根本沒連到」的假通過）
var _peak_players: int = 0       # 名單人數的歷史最高，見 _client_migrate()


func _ready() -> void:
	main = get_parent()
	role      = _env("NETSMOKE", "host").to_lower()
	scenario  = _env("NETSMOKE_SCENARIO", "happy").to_lower()
	room      = _env("NETSMOKE_ROOM", "4242")
	pass_word = _env("NETSMOKE_PASS", "")
	join_pass = _env("NETSMOKE_JOINPASS", pass_word)
	delay     = float(_env("NETSMOKE_DELAY", "0"))
	timeout   = float(_env("NETSMOKE_TIMEOUT", "25"))

	say("scenario=%s room=%s pass='%s' joinpass='%s'" % [scenario, room, pass_word, join_pass])
	_run.call_deferred()


## 一路盯著有沒有真的連上過；badpass / latejoin 要靠這個確認「有連上才被踢」，
## 而不是壓根沒連到主機。
func _process(_d: float) -> void:
	if main == null:
		return
	if not _saw_link and main.has_net():
		_saw_link = true
	_peak_players = maxi(_peak_players, main.players.size())


## 桌面版讀環境變數、網頁版讀網址參數 ─ 交給 MainGame.test_flag() 統一處理
func _env(key: String, fallback: String) -> String:
	var v := ""
	if main != null and main.has_method("test_flag"):
		v = String(main.test_flag(key)).strip_edges()
	else:
		v = OS.get_environment(key).strip_edges()
	return v if v != "" else fallback


func say(msg: String) -> void:
	print("[SMOKE][%s] %s" % [role.to_upper(), msg])


func check(ok: bool, label: String) -> bool:
	_checks += 1
	if ok:
		say("PASS  " + label)
	else:
		_fails.append(label)
		say("FAIL  " + label)
	return ok


## 等到 cond 回傳 true；逾時回 false。用實際時鐘計時，headless 不受 fps 影響。
func until(cond: Callable, secs: float = -1.0) -> bool:
	var limit_ms := int((timeout if secs < 0.0 else secs) * 1000.0)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < limit_ms:
		if bool(cond.call()):
			return true
		await get_tree().process_frame
	return false


func wait(secs: float) -> void:
	await get_tree().create_timer(secs).timeout


## 某一隊的真人數量
func humans(team: int) -> int:
	var n := 0
	for id in main.players:
		if int(main.players[id]["team"]) == team and not bool(main.players[id]["bot"]):
			n += 1
	return n


## 場上實際存在的機體數量。真人開賽時是走在甲板上的飛行員、還不是機體，
## 所以 5v5 兩個真人的情況下應該剛好是 8 架 AI。
func world_aircraft_count() -> int:
	if main.world == null:
		return -1
	return int(main.world.aircraft.size())


func _is_combat() -> bool:
	if main.world == null:
		return false
	return int(main.world.phase) == int(main.world.PHASE_COMBAT)


## 某一隊的總人數（真人 + AI）
func team_size(team: int) -> int:
	var n := 0
	for id in main.players:
		if int(main.players[id]["team"]) == team:
			n += 1
	return n


func roster_text() -> String:
	var out: Array[String] = []
	var ids: Array = main.players.keys()
	ids.sort()
	for id in ids:
		var p: Dictionary = main.players[id]
		out.append("%s(%d,team=%d%s)" % [p["name"], id, int(p["team"]),
			",bot" if bool(p["bot"]) else ""])
	return "[" + ", ".join(out) + "]"


#══════════════════════════════════════════════════════════════════════════════
#  主流程
#══════════════════════════════════════════════════════════════════════════════
func _run() -> void:
	# 訪客登入 → 進得了主選單才有 host / join 可按
	var r: Dictionary = main._accounts.guest_login()
	main._finish_login(r)
	check(not main.account.is_empty(), "訪客登入成功")
	main._name_edit.text = role.to_upper()

	match [role, scenario]:
		["host", "happy"]:      await _host_happy()
		["client", "happy"]:    await _client_happy()
		["host", "link"]:       await _host_link()
		["client", "link"]:     await _client_link()
		["host", "powers"]:     await _host_powers()
		["client", "powers"]:   await _client_powers()
		["host", "kick"]:       await _host_kick()
		["client", "kick"]:     await _client_kicked()
		["host", "migrate"]:    await _host_migrate()
		["client", "migrate"]:  await _client_migrate()
		["host", "badpass"]:    await _host_reject("密碼錯誤")
		["client", "badpass"]:  await _client_rejected()
		["host", "latejoin"]:   await _host_latejoin()
		["client", "latejoin"]: await _client_rejected()
		_:
			check(false, "未知的角色／情境組合 %s/%s" % [role, scenario])

	_finish()


func _finish() -> void:
	if _fails.is_empty():
		say("RESULT  ALL PASS（%d 項）" % _checks)
	else:
		say("RESULT  FAILED %d/%d ─ %s" % [_fails.size(), _checks, ", ".join(_fails)])
	# 讓 print 有機會 flush 再離開
	await wait(0.2)
	get_tree().quit(0 if _fails.is_empty() else 1)


#══════════════════════════════════════════════════════════════════════════════
#  情境一：正常連線 → 換陣營 → 開賽
#══════════════════════════════════════════════════════════════════════════════
func _host_happy() -> void:
	main._pass_edit.text = pass_word
	main.host_game()
	check(main.has_net(), "ENet 伺服器已啟動")
	check(main.room_code == room, "房號固定為 %s（實際 %s）" % [room, main.room_code])
	check(main.is_host, "本機是房主")

	var joined := await until(func(): return humans(main.TEAM_ATTACKER) + humans(main.TEAM_DEFENDER) >= 2)
	check(joined, "客戶端已註冊進名單")
	say("roster after join = " + roster_text())

	# 客戶端會把自己換到防守方，等同步過來
	var switched := await until(func(): return humans(main.TEAM_DEFENDER) >= 1, 10.0)
	check(switched, "客戶端換陣營已同步到房主")

	main.start_match()
	check(main.in_match, "房主 in_match=true")
	check(main.world != null, "房主已生成 GameWorld")
	say("SETTINGS map=%d seed=%d wx=%d tod=%d diff=%d"
		% [main.map_id, main.map_seed, main.weather, main.time_of_day, main.difficulty])
	say("roster at start = " + roster_text())
	check(humans(main.TEAM_ATTACKER) >= 1 and humans(main.TEAM_DEFENDER) >= 1,
		"開賽時兩隊各有真人")
	# 兩個真人 + AI 補齊 = 連線對戰也要湊滿 5v5
	check(team_size(main.TEAM_ATTACKER) == main.MIN_PER_TEAM
		and team_size(main.TEAM_DEFENDER) == main.MIN_PER_TEAM,
		"房主端兩隊各 %d 人（實際 %d / %d）" % [main.MIN_PER_TEAM,
			team_size(main.TEAM_ATTACKER), team_size(main.TEAM_DEFENDER)])

	# 名單湊滿只是第一步：AI 機體要到戰鬥階段才生成，
	# 5v5 的重點是「10 個席次真的都變成場上的機體」，而且兩端都要看得到。
	var in_combat := await until(_is_combat, 150.0)
	check(in_combat, "已進入戰鬥階段（簡報 → 部署 → 戰鬥）")
	check(world_aircraft_count() == main.MIN_PER_TEAM * 2 - 2,
		"房主端生成 %d 架 AI 機體（真人要自己走去登機，實際 %d）"
			% [main.MIN_PER_TEAM * 2 - 2, world_aircraft_count()])

	# 讓每秒 20 次的世界狀態 RPC 實際跑一段，錯誤才會現形
	await wait(12.0)
	check(main.in_match and main.world != null, "持續 12 秒後房主仍在戰鬥中")
	check(main.has_net(), "12 秒後連線仍在")


func _client_happy() -> void:
	await wait(delay)
	main.join_game(room, join_pass)

	var linked := await until(func(): return main.has_net())
	check(linked, "已連上房主")

	var got_roster := await until(func(): return main.players.size() >= 2, 10.0)
	check(got_roster, "已收到房主同步的名單")
	say("roster after join = " + roster_text())
	check(main.my_id() != 1, "取得非 1 的 peer id（實際 %d）" % main.my_id())

	# 換到防守方，房主是唯一權威，改完要能同步回來
	main._request_team(main.TEAM_DEFENDER)
	var mine := await until(func(): return main.my_team() == main.TEAM_DEFENDER, 10.0)
	check(mine, "換到防守方並由房主同步確認")

	var started := await until(func(): return main.in_match, 20.0)
	check(started, "收到房主開賽")
	check(main.world != null, "客戶端已生成 GameWorld")
	say("SETTINGS map=%d seed=%d wx=%d tod=%d diff=%d"
		% [main.map_id, main.map_seed, main.weather, main.time_of_day, main.difficulty])

	# AI 補齊是房主算完才廣播的，客戶端名單必須跟房主一致
	check(main.players.size() >= 2, "開賽名單含 AI 補齊後不為空")
	say("roster at start = " + roster_text())
	check(team_size(main.TEAM_ATTACKER) == main.MIN_PER_TEAM
		and team_size(main.TEAM_DEFENDER) == main.MIN_PER_TEAM,
		"客戶端端兩隊各 %d 人（實際 %d / %d）" % [main.MIN_PER_TEAM,
			team_size(main.TEAM_ATTACKER), team_size(main.TEAM_DEFENDER)])

	var in_combat := await until(_is_combat, 150.0)
	check(in_combat, "已進入戰鬥階段（簡報 → 部署 → 戰鬥）")
	check(world_aircraft_count() == main.MIN_PER_TEAM * 2 - 2,
		"客戶端生成 %d 架 AI 機體（真人要自己走去登機，實際 %d）"
			% [main.MIN_PER_TEAM * 2 - 2, world_aircraft_count()])

	await wait(12.0)
	check(main.in_match and main.world != null, "持續 12 秒後客戶端仍在戰鬥中")
	check(main.has_net(), "12 秒後連線仍在")


#══════════════════════════════════════════════════════════════════════════════
#  情境四：link ─ 只驗「連得起來、名單同步、開得了賽」，不等到戰鬥階段
#
#  happy 情境會一路等到戰鬥（簡報 42 秒 + 部署 30 秒），在瀏覽器裡跑一次要兩分多鐘，
#  而且整個 3D 世界都得算。要驗的是**傳輸層**通不通，所以 link 停在開賽的那一刻。
#  網頁版的 WebRTC 驗證跑的就是這個情境。
#══════════════════════════════════════════════════════════════════════════════
func _host_link() -> void:
	main._pass_edit.text = pass_word
	main.host_game()

	# WebRTC 要先連上信令伺服器才會有 peer；Render 冷啟動可能要一分鐘
	var opened := await until(func(): return main.has_net() and main.room_code == room, timeout)
	check(opened, "房間已開啟且房號為 %s（實際 %s）" % [room, main.room_code])
	check(main.is_host, "本機是房主")

	var joined := await until(func(): return humans(main.TEAM_ATTACKER) + humans(main.TEAM_DEFENDER) >= 2, timeout)
	check(joined, "客戶端已連上並註冊進名單")
	say("roster after join = " + roster_text())

	var switched := await until(func(): return humans(main.TEAM_DEFENDER) >= 1, 20.0)
	check(switched, "客戶端換陣營已同步到房主")

	main.start_match()
	check(main.in_match, "房主 in_match=true")
	check(main.world != null, "房主已生成 GameWorld")
	say("SETTINGS map=%d seed=%d wx=%d tod=%d diff=%d"
		% [main.map_id, main.map_seed, main.weather, main.time_of_day, main.difficulty])
	check(team_size(main.TEAM_ATTACKER) == main.MIN_PER_TEAM
		and team_size(main.TEAM_DEFENDER) == main.MIN_PER_TEAM,
		"兩隊各 %d 人（實際 %d / %d）" % [main.MIN_PER_TEAM,
			team_size(main.TEAM_ATTACKER), team_size(main.TEAM_DEFENDER)])

	await wait(10.0)
	check(main.has_net(), "10 秒後連線仍在")
	check(main.in_match and main.world != null, "10 秒後房主仍在對戰中")


## 網頁版：等驅動腳本把 window.__smoke_go 設起來才加入房間。
## 用固定秒數等房主是行不通的 ─ 兩個分頁搶同一顆 CPU 與同一條下載頻寬，
## 光是各自抓 51 MB 再編譯 wasm，開機時間就可能差到好幾分鐘。
func _await_go() -> void:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		await wait(delay)
		return
	var js := Engine.get_singleton("JavaScriptBridge")
	var ok := await until(func(): return bool(js.eval("window.__smoke_go === true", true)), timeout)
	check(ok, "收到驅動腳本的發車信號")


func _client_link() -> void:
	await _await_go()
	main.join_game(room, join_pass)

	# 要用 net_connected() 而不是 has_net()：後者在 WebRTC 還在交握時就是 true，
	# 用它判定會得到「已連上」然後下一步的 RPC 全部送不出去
	var linked := await until(func(): return main.net_connected(), timeout)
	check(linked, "已連上房主")

	var got_roster := await until(func(): return main.players.size() >= 2, 20.0)
	check(got_roster, "已收到房主同步的名單")
	say("roster after join = " + roster_text())
	check(main.my_id() != 1, "取得非 1 的 peer id（實際 %d）" % main.my_id())

	main._request_team(main.TEAM_DEFENDER)
	var mine := await until(func(): return main.my_team() == main.TEAM_DEFENDER, 20.0)
	check(mine, "換到防守方並由房主同步確認")

	var started := await until(func(): return main.in_match, 30.0)
	check(started, "收到房主開賽")
	check(main.world != null, "客戶端已生成 GameWorld")
	say("SETTINGS map=%d seed=%d wx=%d tod=%d diff=%d"
		% [main.map_id, main.map_seed, main.weather, main.time_of_day, main.difficulty])
	check(team_size(main.TEAM_ATTACKER) == main.MIN_PER_TEAM
		and team_size(main.TEAM_DEFENDER) == main.MIN_PER_TEAM,
		"兩隊各 %d 人（實際 %d / %d）" % [main.MIN_PER_TEAM,
			team_size(main.TEAM_ATTACKER), team_size(main.TEAM_DEFENDER)])

	await wait(10.0)
	check(main.has_net(), "10 秒後連線仍在")
	check(main.in_match and main.world != null, "10 秒後客戶端仍在對戰中")


#══════════════════════════════════════════════════════════════════════════════
#  情境五：powers ─ 房主的權限開放給所有人（改時段、按開始遊戲）
#══════════════════════════════════════════════════════════════════════════════
func _host_powers() -> void:
	main._pass_edit.text = pass_word
	main.host_game()
	check(main.has_net(), "伺服器已啟動")
	main.time_of_day = main.TOD_DAY

	var joined := await until(func(): return main.players.size() >= 2)
	check(joined, "客戶端已註冊進名單")

	# 客戶端改時段 → 房主這邊要跟著變（房主才是唯一說了算的那個）
	var tod_synced := await until(func(): return main.time_of_day == main.TOD_NIGHT, 20.0)
	check(tod_synced, "非房主改的時段有同步到房主（實際 %d）" % main.time_of_day)

	# 客戶端按開始遊戲 → 房主要真的開賽
	var started := await until(func(): return main.in_match, 20.0)
	check(started, "非房主按下開始遊戲，房主真的開賽了")
	check(main.world != null, "房主已生成 GameWorld")
	say("SETTINGS map=%d seed=%d wx=%d tod=%d diff=%d"
		% [main.map_id, main.map_seed, main.weather, main.time_of_day, main.difficulty])
	check(main.time_of_day == main.TOD_NIGHT, "開賽時沿用的是客戶端選的時段")


func _client_powers() -> void:
	await wait(delay)
	main.join_game(room, join_pass)
	var linked := await until(func(): return main.net_connected())
	check(linked, "已連上房主")
	var got_roster := await until(func(): return main.players.size() >= 2, 10.0)
	check(got_roster, "已收到房主同步的名單")

	# 非房主改時段：本機不能自己改掉，要等房主廣播回來才算數
	main._request_tod(main.TOD_NIGHT)
	var echoed := await until(func(): return main.time_of_day == main.TOD_NIGHT, 20.0)
	check(echoed, "改時段有被房主接受並廣播回來")

	# 非房主按開始遊戲
	check(not main.is_host, "本機不是房主")
	main.request_start_match()
	var started := await until(func(): return main.in_match, 20.0)
	check(started, "自己按開始遊戲後真的進了比賽")
	check(main.world != null, "客戶端已生成 GameWorld")
	say("SETTINGS map=%d seed=%d wx=%d tod=%d diff=%d"
		% [main.map_id, main.map_seed, main.weather, main.time_of_day, main.difficulty])


#══════════════════════════════════════════════════════════════════════════════
#  情境六：kick ─ 房主把人請出房間
#══════════════════════════════════════════════════════════════════════════════
func _host_kick() -> void:
	main._pass_edit.text = pass_word
	main.host_game()
	check(main.has_net(), "伺服器已啟動")

	var joined := await until(func(): return main.players.size() >= 2)
	check(joined, "客戶端已註冊進名單")
	say("roster before kick = " + roster_text())

	# 找出那個客戶端（不是自己、不是 AI）
	var target := 0
	for id in main.players:
		if int(id) != main.my_id() and not bool(main.players[id]["bot"]):
			target = int(id)
	check(target != 0, "找得到要踢的對象")

	# 踢不動自己、踢不動 AI ─ 這兩條在 kick_player() 裡把關
	main.kick_player(main.my_id())
	check(main.players.has(main.my_id()), "房主踢不掉自己")

	main.kick_player(target)
	var gone := await until(func(): return not main.players.has(target), 15.0)
	check(gone, "被踢的人已從名單移除")
	say("roster after kick = " + roster_text())
	check(main.has_net(), "踢完之後房主自己還活著")
	check(main.is_host, "踢完之後房主還是房主")

	# 踢完還要能正常開賽，不能留下半死的連線狀態
	main.start_match()
	check(main.in_match and main.world != null, "踢完之後仍然開得了賽")


## 客戶端：連上 → 被踢 → 乾淨地退回去，而且知道理由
func _client_kicked() -> void:
	await wait(delay)
	main.join_game(room, join_pass)

	var linked := await until(func(): return main.net_connected(), 20.0)
	check(linked or _saw_link, "有真的連上房主（不是連不到）")

	var dropped := await until(func(): return not main.has_net(), 25.0)
	check(dropped, "被踢之後連線已中斷")
	check(main.room_code == "", "房號已清空（cli_reject 有跑到）")
	check(not main.in_match, "被踢的人沒有進入戰鬥")
	check(main.world == null, "被踢的人沒有生成 GameWorld")


#══════════════════════════════════════════════════════════════════════════════
#  情境七：migrate ─ 房主離線，剩下的人自動推一個出來接手
#
#  只有 WebRTC 跑得動（ENet 沒有信令伺服器可以居中重新牽線），所以這個情境是
#  給 tools/web_net_smoke.js 開三個分頁用的。房主不需要做任何事 ─
#  「離線」是由驅動腳本直接把那個分頁關掉來模擬的，那才是真實的斷線。
#══════════════════════════════════════════════════════════════════════════════
func _host_migrate() -> void:
	main._pass_edit.text = pass_word
	main.host_game()
	var opened := await until(func(): return main.has_net() and main.room_code == room, timeout)
	check(opened, "房間已開啟（房號 %s）" % room)

	# 等兩個客戶端都連進來，驅動腳本會盯這一行才動手關分頁
	var both := await until(func(): return main.players.size() >= 3, timeout)
	check(both, "兩個客戶端都已連上（名單 %d 人）" % main.players.size())
	say("MIGRATE-READY roster=" + roster_text())
	# 之後就等著被關掉。不能自己 quit ─ 那會送出正常的離線流程，
	# 測不到「真的斷線」這件事。
	await wait(timeout)


func _client_migrate() -> void:
	await _await_go()
	main.join_game(room, join_pass)

	var linked := await until(func(): return main.net_connected(), timeout)
	check(linked, "已連上原房主")
	var full := await until(func(): return main.players.size() >= 3, timeout)
	check(full, "名單裡有三個人（原房主 + 兩個客戶端）")
	check(not main.is_host, "一開始不是房主")
	# 不能用 := ：main 宣告成 Node，透過它呼叫的東西回傳 Variant，推導不出型別
	var old_id: int = main.my_id()
	say("MIGRATE-READY id=%d" % old_id)

	# 這裡開始驅動腳本會把原房主的分頁關掉。
	#
	# 刻意**不**斷言「有察覺斷線」：交接常常比 WebRTC 自己的 ICE 逾時判定還快，
	# 接手的那個人根本不會經過斷線狀態 ─ 那是最好的情況，不是失敗。
	# 改成看結果：所有人都會被重新編號（接手的變 1，其餘往下排）。
	var took := await until(func(): return main.is_host or main.my_id() != old_id, timeout)
	check(took, "交接完成 ─ 已重新編號（%d → %d）" % [old_id, main.my_id()])
	# 重新編號是收到 host_changed 的當下就完成的，但 P2P 還要再握一次手 ─
	# 這裡要用等的，當場判定會抓到中間那個還沒接上的瞬間
	var relinked := await until(func(): return main.is_host or main.net_connected(), timeout)
	check(relinked, "交接後回到連線狀態")
	check(main.room_code == room, "房號沒變（還是 %s，實際 %s）" % [room, main.room_code])
	check(not main.in_match, "交接後回到大廳")

	# 兩個人重新湊在同一份名單裡。
	# 看的是**歷史最高**而不是當下 ─ 兩個分頁跑完的時間差很大，
	# 先跑完的那個會 quit 離線，後跑完的當下再數就只剩自己了。
	var rejoined := await until(func(): return _peak_players >= 2, 45.0)
	check(rejoined, "名單重新湊回兩個人（最多看到 %d 人）" % _peak_players)
	say("MIGRATED is_host=%s my_id=%d players=%d"
		% [str(main.is_host), main.my_id(), _peak_players])

	await wait(6.0)
	check(main.is_host or main.net_connected(), "6 秒後連線仍然穩定")


#══════════════════════════════════════════════════════════════════════════════
#  情境二／三：房主應該拒絕連線
#══════════════════════════════════════════════════════════════════════════════
func _host_reject(why: String) -> void:
	main._pass_edit.text = pass_word
	main.host_game()
	check(main.has_net(), "ENet 伺服器已啟動")

	# 給客戶端足夠時間連上、被踢
	await wait(delay + 18.0)
	say("roster after attempt = " + roster_text())
	check(main.players.size() == 1, "%s 的客戶端沒有進入名單" % why)
	check(main.has_net(), "踢掉客戶端後房主自己還活著")


func _host_latejoin() -> void:
	main._pass_edit.text = pass_word
	main.host_game()
	check(main.has_net(), "ENet 伺服器已啟動")

	# 先開賽，客戶端才會撞上「比賽已開始」這條規則
	await wait(2.0)
	main.start_match()
	check(main.in_match, "房主已先行開賽")
	var before: int = main.players.size()

	await wait(delay + 18.0)
	say("roster after attempt = " + roster_text())
	check(main.players.size() == before, "中途加入的客戶端沒有被塞進名單")
	check(main.in_match and main.world != null, "被拒絕後房主的戰鬥不受影響")
	check(main.has_net(), "被拒絕後房主連線仍正常")


## 客戶端：預期先連上、再被房主踢掉，並且乾淨地退回主選單
func _client_rejected() -> void:
	await wait(delay)
	main.join_game(room, join_pass)

	var linked := await until(func(): return main.has_net(), 15.0)
	check(linked or _saw_link, "ENet 層有真的連上房主（不是連不到）")

	var dropped := await until(func(): return not main.has_net(), 15.0)
	check(dropped, "被房主拒絕後連線已中斷")
	check(main.room_code == "", "房號已清空（cli_reject 有跑到）")
	check(not main.in_match, "被拒絕的客戶端沒有進入戰鬥")
	check(main.world == null, "被拒絕的客戶端沒有生成 GameWorld")
