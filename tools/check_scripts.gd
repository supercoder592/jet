extends SceneTree

## 逐一解析每一支 .gd，把語法／型別推導錯誤擋在跑起來之前。
##
##   godot --headless --path . --script res://tools/check_scripts.gd
##
## 為什麼需要這支：Godot 只有在真的 load() 到某支腳本時才會解析它，
## 而 NetSmoke.gd / AutoPlay.gd 都是「有設對應開關才掛上」的 ─
## 正常啟動根本不會碰到，錯字要等到跑測試那一刻才會現形。
## 網頁版更慘：匯出完全不解析腳本，錯誤要等到瀏覽器裡才爆。
##
## 最常中的是型別推導：`var x := main.foo()` 在 main 宣告成 Node 時
## 回傳的是 Variant，`:=` 推導不出來就是編譯失敗（README 的第 1 條 bug）。

func _init() -> void:
	var files: Array[String] = []
	_scan("res://", files)
	files.sort()

	var bad: Array[String] = []
	for f in files:
		# 這支自己是 SceneTree，load() 它會再跑一次 _init
		if f.ends_with("tools/check_scripts.gd"):
			continue
		var res: Variant = ResourceLoader.load(f, "GDScript", ResourceLoader.CACHE_MODE_IGNORE)
		if res == null or not (res is GDScript):
			bad.append(f)
			print("[SCRIPTS] FAIL  %s ─ 載不進來" % f)
			continue
		# 光看 load() 回傳值是不夠的：解析失敗它照樣給你一個 GDScript 物件，
		# 只是裡面是空的。reload() 才會把 ERR_PARSE_ERROR 交回來。
		var err: int = (res as GDScript).reload()
		if err != OK:
			bad.append(f)
			print("[SCRIPTS] FAIL  %s ─ 解析錯誤（%d）" % [f, err])

	print("[SCRIPTS] 檢查了 %d 支腳本" % files.size())
	if bad.is_empty():
		print("[SCRIPTS] RESULT OK ─ 全部解析通過")
		quit(0)
	else:
		print("[SCRIPTS] RESULT FAILED ─ %s" % ", ".join(bad))
		quit(1)


func _scan(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var full := dir_path.path_join(name)
		if d.current_is_dir():
			_scan(full, out)
		elif name.ends_with(".gd"):
			out.append(full)
		name = d.get_next()
	d.list_dir_end()
