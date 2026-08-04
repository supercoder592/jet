extends SceneTree

#══════════════════════════════════════════════════════════════════════════════
#  字型覆蓋檢查
#
#    godot --headless --path . --script res://tools/check_font.gd
#
#  掃過所有 .gd 原始碼裡出現的非 ASCII 字元，逐一問專案預設字型有沒有這個字。
#  網頁版沒有系統字型可以 fallback，缺字就是直接變空白／豆腐，而且在桌面上
#  完全看不出來 ─ 所以這件事一定要用程式檢查，不能靠眼睛看。
#
#  離開碼 0 = 全部有涵蓋，1 = 有缺字（會列出缺哪些）。
#
#  註：連註解也一起掃。寧可誤報也不要漏報 ─ 所以註解裡要提到沒涵蓋的符號時，
#  請寫成 U+XXXX 而不要直接放那個字，否則這裡會一直亮紅燈。
#══════════════════════════════════════════════════════════════════════════════

func _init() -> void:
	var path := String(ProjectSettings.get_setting("gui/theme/custom_font", ""))
	if path == "":
		print("[FONT] 專案沒有設定 gui/theme/custom_font ─ 網頁版的中文一定會壞")
		quit(1)
		return

	var font: Font = load(path)
	if font == null:
		print("[FONT] 載入不到字型：%s" % path)
		quit(1)
		return
	print("[FONT] 檢查字型：%s" % path)

	var chars := _collect_chars()
	print("[FONT] 原始碼裡出現的非 ASCII 字元共 %d 種" % chars.size())

	var missing: Array[String] = []
	for c in chars:
		if not _covered(font, c.unicode_at(0)):
			missing.append(c)

	if missing.is_empty():
		print("[FONT] RESULT OK ─ 全部涵蓋")
		quit(0)
		return

	# 缺字照 Unicode 分段列出來，比較看得出是整段缺還是零星缺
	var lines: Array[String] = []
	for c in missing:
		lines.append("%s(U+%04X)" % [c, c.unicode_at(0)])
	print("[FONT] 缺 %d 個字元：%s" % [missing.size(), ", ".join(lines)])
	print("[FONT] RESULT MISSING")
	quit(1)


## 字型本身或它的 fallback 有沒有這個字。
## 不直接信任 Font.has_char() 會不會自己走 fallback ─ 自己遞迴走一遍最保險。
func _covered(font: Font, code: int) -> bool:
	if font.has_char(code):
		return true
	for fb in font.fallbacks:
		if fb != null and _covered(fb, code):
			return true
	return false


## 掃 res:// 底下所有 .gd，收集出現過的非 ASCII 字元
func _collect_chars() -> Array[String]:
	var seen := {}
	for f in _gd_files("res://"):
		var text := FileAccess.get_file_as_string(f)
		for i in text.length():
			var code := text.unicode_at(i)
			if code > 127:
				seen[text[i]] = true
	var out: Array[String] = []
	for k in seen:
		out.append(String(k))
	out.sort()
	return out


func _gd_files(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var full := dir_path.path_join(name)
		if d.current_is_dir():
			if not name.begins_with("."):
				out.append_array(_gd_files(full))
		elif name.ends_with(".gd"):
			out.append(full)
		name = d.get_next()
	d.list_dir_end()
	return out
