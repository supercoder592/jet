extends RefCounted
#══════════════════════════════════════════════════════════════════════════════
#  Account.gd ─ 帳號系統（訪客登入 / 自訂名稱 + 4 位數 PIN）
#
#  存檔位置：user://accounts.cfg
#  每個帳號一個 ConfigFile section（acc_0, acc_1 …），訪客固定用 "guest"。
#  PIN 不存明碼，只存 sha256(name:pin:salt)。
#
#  註：本檔刻意不宣告 class_name，由 MainGame 以 load() 動態載入，
#      與 GameWorld.gd 採同一策略，避免任何循環相依。
#══════════════════════════════════════════════════════════════════════════════

const PATH      := "user://accounts.cfg"
const SALT      := "asymmetric-air-combat-2026"
const GUEST_SEC := "guest"
const NAME_MIN  := 2
const NAME_MAX  := 14

## 預設就擁有的機種（VType.FIGHTER / VType.INTERCEPTOR），
## 其餘機種要在商店購買，避免新帳號連飛機都沒有。
const FREE_PLANES := [0, 3]

var _cf := ConfigFile.new()


func _init() -> void:
	_cf.load(PATH)          # 檔案不存在就是空資料庫，不視為錯誤


#──────────────────────────── 驗證 ────────────────────────────
func name_error(uname: String) -> String:
	var n := uname.strip_edges()
	if n.length() < NAME_MIN:
		return "呼號至少 %d 個字。" % NAME_MIN
	if n.length() > NAME_MAX:
		return "呼號最多 %d 個字。" % NAME_MAX
	# 這些字元會影響聊天室的 BBCode 與存檔鍵值
	for bad in ["[", "]", "\n", "\t", "="]:
		if n.contains(bad):
			return "呼號不能包含 %s 。" % bad
	return ""


func pin_error(pin: String) -> String:
	if pin.length() != 4:
		return "PIN 碼必須是 4 位數字。"
	for i in 4:
		if pin[i] < "0" or pin[i] > "9":
			return "PIN 碼只能是數字。"
	return ""


func _hash(uname: String, pin: String) -> String:
	return ("%s:%s:%s" % [uname.strip_edges(), pin, SALT]).sha256_text()


#──────────────────────────── 查詢 ────────────────────────────
func _find(uname: String) -> String:
	var target := uname.strip_edges()
	for sec in _cf.get_sections():
		if sec == GUEST_SEC:
			continue
		if String(_cf.get_value(sec, "name", "")) == target:
			return sec
	return ""


func exists(uname: String) -> bool:
	return _find(uname) != ""


## 已註冊的帳號名稱（給登入畫面列出來讓玩家直接點）
func account_names() -> Array:
	var out: Array = []
	for sec in _cf.get_sections():
		if sec == GUEST_SEC:
			continue
		var n := String(_cf.get_value(sec, "name", ""))
		if n != "":
			out.append(n)
	out.sort()
	return out


func has_guest() -> bool:
	return _cf.has_section(GUEST_SEC)


#──────────────────────────── 建立 / 登入 ────────────────────────────
## 回傳 { ok: bool, msg: String, data: Dictionary }
func register(uname: String, pin: String) -> Dictionary:
	var ne := name_error(uname)
	if ne != "":
		return { "ok": false, "msg": ne, "data": {} }
	var pe := pin_error(pin)
	if pe != "":
		return { "ok": false, "msg": pe, "data": {} }
	if exists(uname):
		return { "ok": false, "msg": "這個呼號已經註冊過了，請直接登入。", "data": {} }

	var sec := "acc_%d" % _next_index()
	var data := _blank(uname.strip_edges(), false)
	_write(sec, data, _hash(uname, pin))
	_cf.save(PATH)
	return { "ok": true, "msg": "帳號 %s 建立完成。" % data["name"], "data": data }


func login(uname: String, pin: String) -> Dictionary:
	var sec := _find(uname)
	if sec == "":
		return { "ok": false, "msg": "查不到這個呼號，請先註冊。", "data": {} }
	if String(_cf.get_value(sec, "pin", "")) != _hash(uname, pin):
		return { "ok": false, "msg": "PIN 碼不正確。", "data": {} }
	return { "ok": true, "msg": "歡迎回來，%s。" % uname.strip_edges(), "data": _read(sec) }


## 訪客登入：不需要密碼。進度存在本機的 guest 欄位，
## 換帳號登入時不會互相影響，但也不會跟著帳號走。
func guest_login() -> Dictionary:
	if _cf.has_section(GUEST_SEC):
		return { "ok": true, "msg": "以訪客身分登入（本機進度）。", "data": _read(GUEST_SEC) }
	var data := _blank("GUEST-%03d" % (randi() % 1000), true)
	_write(GUEST_SEC, data, "")
	_cf.save(PATH)
	return { "ok": true, "msg": "以訪客身分登入（進度只留在這台機器）。", "data": data }


## 改 PIN（登入後才呼叫）
func change_pin(uname: String, old_pin: String, new_pin: String) -> Dictionary:
	var sec := _find(uname)
	if sec == "":
		return { "ok": false, "msg": "找不到帳號。", "data": {} }
	if String(_cf.get_value(sec, "pin", "")) != _hash(uname, old_pin):
		return { "ok": false, "msg": "原 PIN 碼不正確。", "data": {} }
	var pe := pin_error(new_pin)
	if pe != "":
		return { "ok": false, "msg": pe, "data": {} }
	_cf.set_value(sec, "pin", _hash(uname, new_pin))
	_cf.save(PATH)
	return { "ok": true, "msg": "PIN 碼已更新。", "data": _read(sec) }


func delete_account(uname: String) -> void:
	var sec := _find(uname)
	if sec != "":
		_cf.erase_section(sec)
		_cf.save(PATH)


#──────────────────────────── 存檔 ────────────────────────────
## MainGame 每次賺點數 / 購買後都會呼叫，把整份 profile 寫回去
func save_profile(data: Dictionary) -> void:
	if data.is_empty():
		return
	var uname := String(data.get("name", ""))
	var sec := GUEST_SEC if bool(data.get("guest", false)) else _find(uname)
	if sec == "":
		return
	var pin := String(_cf.get_value(sec, "pin", ""))
	_write(sec, data, pin)
	_cf.save(PATH)


#──────────────────────────── 內部 ────────────────────────────
func _next_index() -> int:
	var n := 0
	while _cf.has_section("acc_%d" % n):
		n += 1
	return n


func _blank(uname: String, guest: bool) -> Dictionary:
	return {
		"name": uname,
		"guest": guest,
		"credits": 0,
		"upgrades": {},
		"skin": "default",
		"owned_skins": ["default"],
		"owned_planes": FREE_PLANES.duplicate(),
		"kills": 0,
		"deaths": 0,
		"wins": 0,
		"matches": 0,
	}


func _write(sec: String, data: Dictionary, pin_hash: String) -> void:
	_cf.set_value(sec, "name", String(data.get("name", "")))
	_cf.set_value(sec, "guest", bool(data.get("guest", false)))
	_cf.set_value(sec, "pin", pin_hash)
	_cf.set_value(sec, "credits", int(data.get("credits", 0)))
	_cf.set_value(sec, "upgrades", data.get("upgrades", {}))
	_cf.set_value(sec, "skin", String(data.get("skin", "default")))
	_cf.set_value(sec, "owned_skins", data.get("owned_skins", ["default"]))
	_cf.set_value(sec, "owned_planes", data.get("owned_planes", FREE_PLANES.duplicate()))
	_cf.set_value(sec, "kills", int(data.get("kills", 0)))
	_cf.set_value(sec, "deaths", int(data.get("deaths", 0)))
	_cf.set_value(sec, "wins", int(data.get("wins", 0)))
	_cf.set_value(sec, "matches", int(data.get("matches", 0)))


func _read(sec: String) -> Dictionary:
	# owned_planes 舊存檔可能沒有這個欄位，補上免費機種
	var planes: Array = _cf.get_value(sec, "owned_planes", FREE_PLANES.duplicate())
	var clean: Array = []
	for p in planes:
		clean.append(int(p))
	for f in FREE_PLANES:
		if not clean.has(f):
			clean.append(f)
	return {
		"name": String(_cf.get_value(sec, "name", "PILOT")),
		"guest": bool(_cf.get_value(sec, "guest", sec == GUEST_SEC)),
		"credits": int(_cf.get_value(sec, "credits", 0)),
		"upgrades": _cf.get_value(sec, "upgrades", {}),
		"skin": String(_cf.get_value(sec, "skin", "default")),
		"owned_skins": _cf.get_value(sec, "owned_skins", ["default"]),
		"owned_planes": clean,
		"kills": int(_cf.get_value(sec, "kills", 0)),
		"deaths": int(_cf.get_value(sec, "deaths", 0)),
		"wins": int(_cf.get_value(sec, "wins", 0)),
		"matches": int(_cf.get_value(sec, "matches", 0)),
	}
