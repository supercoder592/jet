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
	if not _saw_link and main != null and main.has_net():
		_saw_link = true


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
