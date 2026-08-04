extends Control
#══════════════════════════════════════════════════════════════════════════════
#  TacticalDialog.gd ─ 「加入房間」戰術彈出視窗
#
#  軍事 HUD 風格：四角括號、掃描線、訊號強度條、即時連線狀態機與訊息紀錄。
#  欄位：房號／IP、連線密碼、網路模式切換。
#
#  註：刻意不宣告 class_name，由 MainGame 以 load() 動態載入。
#══════════════════════════════════════════════════════════════════════════════

signal confirmed(code: String, passcode: String)
signal cancelled

const C_OK   := Color(0.35, 1.00, 0.55)
const C_WARN := Color(1.00, 0.82, 0.30)
const C_BAD  := Color(1.00, 0.38, 0.34)

var code_edit: LineEdit
var pass_edit: LineEdit

var _deco: Control
var _panel: Control
var _state_lbl: Label
var _detail_lbl: Label
var _log: RichTextLabel
var _mode_btn: Button
var _go_btn: Button
var _bars: Control
var _t: float = 0.0
var _state: String = "idle"
var _signal_strength: float = 0.0
var _mg: Node


#══════════════════════════════════════════════════════════════════════════════
#  建構
#══════════════════════════════════════════════════════════════════════════════
func build(mg: Node) -> void:
	_mg = mg
	# 這個 Control 直接掛在 CanvasLayer 底下，必須自己撐滿整個視窗：
	# 只設 anchors 有時候還沒重新排版，size 會是 0，
	# 底下用 PRESET_CENTER 的面板就會被推到畫面左上角只露出一半。
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = 0; offset_top = 0; offset_right = 0; offset_bottom = 0
	# 用 set_deferred：直接指定 size 會在 _ready 之後被 anchors 蓋掉，引擎也會警告
	set_deferred("size", get_viewport_rect().size)
	get_viewport().size_changed.connect(func(): set_deferred("size", get_viewport_rect().size))
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.02, 0.04, 0.78)
	add_child(dim)

	# 底層裝飾（括號、掃描線、格線）畫在面板之下
	_deco = Control.new()
	_deco.set_anchors_preset(Control.PRESET_CENTER)
	_deco.offset_left = -330; _deco.offset_right = 330
	_deco.offset_top = -260; _deco.offset_bottom = 260
	_deco.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_deco.draw.connect(_draw_deco)
	add_child(_deco)

	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -330; _panel.offset_right = 330
	_panel.offset_top = -260; _panel.offset_bottom = 260
	_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_panel)

	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 26; v.offset_right = -26
	v.offset_top = 22; v.offset_bottom = -22
	v.add_theme_constant_override("separation", 8)
	_panel.add_child(v)

	# ── 標題列 ──
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	v.add_child(head)
	head.add_child(_label("◤", 20, MainGame.C_DEF))
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 0)
	head.add_child(titles)
	titles.add_child(_label("加入戰術網路", 24, Color.WHITE))
	titles.add_child(_label("TACTICAL LINK ─ SECURE CHANNEL", 11, MainGame.C_DIM))

	_bars = Control.new()
	_bars.custom_minimum_size = Vector2(56, 34)
	_bars.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bars.draw.connect(_draw_bars)
	head.add_child(_bars)

	v.add_child(_rule())

	# ── 房號 / IP ──
	v.add_child(_label("房號 / 主機位址　ROOM CODE / HOST", 12, MainGame.C_DEF))
	code_edit = LineEdit.new()
	code_edit.placeholder_text = "4 位數房號，或 192.168.0.5:10042"
	code_edit.max_length = 42
	code_edit.custom_minimum_size = Vector2(0, 40)
	code_edit.add_theme_font_size_override("font_size", 18)
	code_edit.text_submitted.connect(func(_t2: String): _emit_confirm())
	v.add_child(code_edit)

	# ── 密碼 ──
	v.add_child(_label("連線密碼　PASSCODE（房主未設定就留空）", 12, MainGame.C_DEF))
	pass_edit = LineEdit.new()
	pass_edit.placeholder_text = "••••"
	pass_edit.secret = true
	pass_edit.max_length = 16
	pass_edit.custom_minimum_size = Vector2(0, 40)
	pass_edit.add_theme_font_size_override("font_size", 18)
	pass_edit.text_submitted.connect(func(_t3: String): _emit_confirm())
	v.add_child(pass_edit)

	# ── 網路模式 ──
	_mode_btn = _button("", MainGame.C_DIM)
	_mode_btn.pressed.connect(func():
		if _mg != null:
			_mg.toggle_net_mode()
			refresh_mode())
	v.add_child(_mode_btn)

	v.add_child(_rule())

	# ── 連線狀態 ──
	var sb := HBoxContainer.new()
	sb.add_theme_constant_override("separation", 8)
	v.add_child(sb)
	sb.add_child(_label("連線狀態", 12, MainGame.C_DIM))
	_state_lbl = _label("待機　STANDBY", 15, MainGame.C_TEXT)
	_state_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_state_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sb.add_child(_state_lbl)

	_detail_lbl = _label("", 11, MainGame.C_DIM)
	_detail_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_lbl.custom_minimum_size = Vector2(0, 30)
	v.add_child(_detail_lbl)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.custom_minimum_size = Vector2(0, 96)
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", 12)
	v.add_child(_log)

	# ── 按鈕 ──
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	v.add_child(row)
	var cancel := _button("✕  取消　ABORT", C_BAD)
	cancel.custom_minimum_size = Vector2(0, 46)
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(func():
		close()
		cancelled.emit())
	row.add_child(cancel)

	_go_btn = _button("▶  建立連線　CONNECT", C_OK)
	_go_btn.custom_minimum_size = Vector2(0, 46)
	_go_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_go_btn.pressed.connect(_emit_confirm)
	row.add_child(_go_btn)

	refresh_mode()
	set_process(true)


#══════════════════════════════════════════════════════════════════════════════
#  對外
#══════════════════════════════════════════════════════════════════════════════
func open(default_code: String = "") -> void:
	visible = true
	set_deferred("size", get_viewport_rect().size)   # 保險：解析度變了也要重新撐滿
	code_edit.text = default_code
	_log.clear()
	log_line("[通道] 戰術網路模組已載入。", MainGame.C_DIM)
	log_line("[通道] 輸入房號或主機位址後按 CONNECT。", MainGame.C_DIM)
	set_state("idle", "待機　STANDBY", "尚未建立連線。")
	refresh_mode()
	code_edit.grab_focus()


func close() -> void:
	visible = false


## kind: idle / working / ok / fail
func set_state(kind: String, text: String, detail: String = "") -> void:
	_state = kind
	var col := MainGame.C_TEXT
	match kind:
		"working": col = C_WARN
		"ok":      col = C_OK
		"fail":    col = C_BAD
		_:         col = MainGame.C_DIM
	_state_lbl.text = text
	_state_lbl.add_theme_color_override("font_color", col)
	if detail != "":
		_detail_lbl.text = detail
	_go_btn.disabled = (kind == "working")


func log_line(text: String, col: Color = MainGame.C_TEXT) -> void:
	if _log == null:
		return
	_log.append_text("[color=#%s]%s[/color]\n" % [col.to_html(false), text])


func refresh_mode() -> void:
	if _mode_btn == null or _mg == null:
		return
	var web: bool = (int(_mg.net_mode) == int(MainGame.NetMode.WEBRTC))
	_mode_btn.text = "傳輸層：%s　（點擊切換）" % ("WebRTC ─ 網頁對戰" if web else "ENet ─ 本機／區網測試")
	_mode_btn.add_theme_color_override("font_color", MainGame.C_DEF if web else MainGame.C_DIM)


func _emit_confirm() -> void:
	var code := code_edit.text.strip_edges()
	if code.is_empty():
		set_state("fail", "缺少目標　NO TARGET", "請輸入 4 位數房號，或 主機IP:埠號。")
		log_line("[錯誤] 未指定連線目標。", C_BAD)
		return
	set_state("working", "解析中　RESOLVING", "正在解析目標並準備交握…")
	log_line("[連線] 目標 %s" % code, C_WARN)
	confirmed.emit(code, pass_edit.text)


#══════════════════════════════════════════════════════════════════════════════
#  動畫與繪製
#══════════════════════════════════════════════════════════════════════════════
func _process(delta: float) -> void:
	if not visible:
		return
	_t += delta
	# 訊號強度：交握中跳動、連上後滿格、失敗歸零
	var want := 0.15
	match _state:
		"working": want = 0.35 + 0.5 * absf(sin(_t * 4.0))
		"ok":      want = 1.0
		"fail":    want = 0.0
	_signal_strength = lerpf(_signal_strength, want, clampf(delta * 6.0, 0.0, 1.0))
	if _state == "working":
		var dots := ".".repeat(1 + int(_t * 3.0) % 3)
		_state_lbl.text = "交握中　HANDSHAKE" + dots
	if _deco:
		_deco.queue_redraw()
	if _bars:
		_bars.queue_redraw()


func _draw_deco() -> void:
	var s := _deco.size
	var accent: Color = MainGame.C_DEF
	# 面板底
	_deco.draw_rect(Rect2(Vector2.ZERO, s), Color(0.045, 0.062, 0.090, 0.97), true)
	# 內部細格線
	var grid := Color(accent.r, accent.g, accent.b, 0.055)
	var step := 26.0
	var gx := step
	while gx < s.x:
		_deco.draw_line(Vector2(gx, 0), Vector2(gx, s.y), grid, 1.0)
		gx += step
	var gy := step
	while gy < s.y:
		_deco.draw_line(Vector2(0, gy), Vector2(s.x, gy), grid, 1.0)
		gy += step
	# 外框
	_deco.draw_rect(Rect2(Vector2.ZERO, s), Color(accent.r, accent.g, accent.b, 0.55), false, 2.0)
	# 四角括號
	var arm := 34.0
	var col: Color = accent
	if _state == "ok":
		col = C_OK
	elif _state == "fail":
		col = C_BAD
	elif _state == "working":
		col = C_WARN
	for cx in [0.0, 1.0]:
		for cy in [0.0, 1.0]:
			var p := Vector2(cx * s.x, cy * s.y)
			var dx := arm if cx < 0.5 else -arm
			var dy := arm if cy < 0.5 else -arm
			_deco.draw_line(p, p + Vector2(dx, 0), col, 3.0)
			_deco.draw_line(p, p + Vector2(0, dy), col, 3.0)
	# 掃描線：上下來回掃
	var y := fmod(_t * 90.0, s.y)
	_deco.draw_line(Vector2(2, y), Vector2(s.x - 2, y), Color(col.r, col.g, col.b, 0.22), 2.0)
	_deco.draw_line(Vector2(2, y + 3), Vector2(s.x - 2, y + 3), Color(col.r, col.g, col.b, 0.10), 1.0)


func _draw_bars() -> void:
	var n := 5
	var col := C_OK if _state == "ok" else (C_BAD if _state == "fail" else MainGame.C_DEF)
	for i in n:
		var h := 8.0 + i * 6.0
		var r := Rect2(Vector2(i * 11.0, 34.0 - h), Vector2(8.0, h))
		var lit: bool = _signal_strength * float(n) > float(i)
		_bars.draw_rect(r, Color(col.r, col.g, col.b, 0.85 if lit else 0.16), true)


#══════════════════════════════════════════════════════════════════════════════
#  UI 小工具
#══════════════════════════════════════════════════════════════════════════════
func _label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _button(text: String, accent: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 38)
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", accent)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	for st in [["normal", 0.14], ["hover", 0.32], ["pressed", 0.48]]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(accent.r, accent.g, accent.b, float(st[1]))
		sb.border_color = accent
		sb.border_width_left = 1; sb.border_width_right = 1
		sb.border_width_top = 1; sb.border_width_bottom = 1
		sb.content_margin_left = 10; sb.content_margin_right = 10
		sb.content_margin_top = 6; sb.content_margin_bottom = 6
		b.add_theme_stylebox_override(String(st[0]), sb)
	var dis := StyleBoxFlat.new()
	dis.bg_color = Color(0.2, 0.2, 0.25, 0.25)
	b.add_theme_stylebox_override("disabled", dis)
	return b


func _rule() -> Control:
	var r := ColorRect.new()
	r.color = Color(1, 1, 1, 0.10)
	r.custom_minimum_size = Vector2(0, 1)
	return r
