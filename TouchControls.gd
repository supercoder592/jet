extends Control

#══════════════════════════════════════════════════════════════════════════════
#  TouchControls.gd ─ 手機／平板的觸控操控層
#
#  所有飛行操作都是透過 InputMap 動作讀取的（Input.get_action_strength / is_action_pressed），
#  所以這一層只要去按同一組動作就能完整接管，不需要改動任何飛行、武器或 AI 程式碼。
#
#  刻意用 _input() 自己做命中判定，而不是靠 Control 的 _gui_input：
#  Godot 只會把「第一根手指」轉成滑鼠事件餵給 UI，多點觸控（一邊轉向一邊開火）
#  非得自己處理 InputEventScreenTouch/Drag 的 index 不可。
#
#  註：本檔同樣不宣告 class_name，由 GameWorld 以 load() 動態載入。
#══════════════════════════════════════════════════════════════════════════════

## 搖桿：左手大拇指，垂直＝俯仰，水平＝偏航（跟鍵盤的 W/S、A/D 對應）
const STICK_HOME   := Vector2(250, 706)
const STICK_RADIUS := 115.0
const KNOB_RADIUS  := 46.0
const DEAD_ZONE    := 0.16

## 搖桿可以在這個範圍內「浮動」：手指按在哪就以哪裡為中心，
## 手機上比固定式搖桿好按太多（不用先找到那個圈）。
## 範圍刻意不含右側的滾轉鈕，免得想按滾轉卻把搖桿拉過去。
const STICK_AREA := Rect2(0, 520, 400, 380)

var world = null                      # GameWorld（由 setup() 帶進來）

var _font: Font
var _stick_touch: int = -99           # 目前控制搖桿的手指 index，-99 = 沒有
var _stick_home: Vector2 = STICK_HOME # 這次按下時的實際圓心（浮動搖桿）
var _stick_vec: Vector2 = Vector2.ZERO
var _btn_touch: Dictionary = {}       # 手指 index -> 按鈕 id
var _pressed: Dictionary = {}         # 按鈕 id -> true

## 按鈕表。id 就是要驅動的 InputMap 動作名稱，改版面只要動這張表。
##   hold = true  按住持續生效（機炮、後燃器）
##   hold = false 點一下觸發一次（切視角、換武裝）
## 版面是配合現有 HUD 的空隙排的：右下角是小地圖、正下方是血條與後燃器條、
## 左下角原本是聊天面板（觸控模式下由 GameWorld._apply_mobile_hud() 收起來讓給搖桿）、
## 右上角是長官對話框。改位置前先看一眼截圖，不然很容易疊到讀數上。
const BUTTONS := [
	{ "id": "ac_gun",         "pos": Vector2(1296, 706), "r": 64.0, "label": "機炮",   "col": Color(1.00, 0.62, 0.25), "hold": true },
	{ "id": "ac_missile",     "pos": Vector2(1462, 578), "r": 64.0, "label": "飛彈",   "col": Color(1.00, 0.40, 0.35), "hold": true },
	{ "id": "ac_boost",       "pos": Vector2(1286, 546), "r": 50.0, "label": "後燃",   "col": Color(1.00, 0.80, 0.30), "hold": true },
	{ "id": "ac_flare",       "pos": Vector2(1440, 424), "r": 46.0, "label": "干擾",   "col": Color(0.75, 0.85, 1.00), "hold": false },
	{ "id": "ac_view",        "pos": Vector2(1288, 408), "r": 40.0, "label": "視角",   "col": Color(0.62, 0.72, 0.88), "hold": false },
	# 這兩個往內縮：手機有圓角與瀏覽器邊界，貼著右緣的鈕按不到
	{ "id": "ac_swap_weapon", "pos": Vector2(1532, 474), "r": 40.0, "label": "換裝",   "col": Color(0.70, 0.80, 0.95), "hold": false },
	{ "id": "ac_deploy",      "pos": Vector2(1516, 334), "r": 40.0, "label": "防空",   "col": Color(0.45, 0.85, 1.00), "hold": false },
	{ "id": "ac_thr_up",      "pos": Vector2(86, 366),   "r": 46.0, "label": "油門＋", "col": Color(0.55, 0.95, 0.70), "hold": true },
	{ "id": "ac_thr_down",    "pos": Vector2(86, 470),   "r": 46.0, "label": "油門－", "col": Color(0.55, 0.95, 0.70), "hold": true },
	{ "id": "ac_roll_left",   "pos": Vector2(474, 596),  "r": 42.0, "label": "滾左",   "col": Color(0.62, 0.72, 0.88), "hold": true },
	{ "id": "ac_roll_right",  "pos": Vector2(474, 716),  "r": 42.0, "label": "滾右",   "col": Color(0.62, 0.72, 0.88), "hold": true },
	# 步行階段專用：走到停機坪的飛機旁按它登機
	{ "id": "ac_board",       "pos": Vector2(1400, 620), "r": 66.0, "label": "登機",   "col": Color(0.55, 1.00, 0.75), "hold": false },
]

## 通訊：無線電與聊天在 MainGame 裡是走 _unhandled_input 的實體鍵碼判斷，
## 不是 InputMap 輪詢 ─ 所以這幾顆不能用 Input.action_press()，要直接呼叫
## send_radio() / _open_chat_input()。id 以 ui_ 開頭的都由 _ui_action() 處理。
## 左上角 y<214 是搬過來的聊天面板，所以通訊列排在它正下方的橫列。
const COMMS_TOGGLE := { "id": "ui_comms", "pos": Vector2(86, 262), "r": 40.0,
	"label": "通訊", "col": Color(0.45, 0.85, 1.00), "hold": false }

const COMMS_BUTTONS := [
	{ "id": "ui_radio_0", "pos": Vector2(196, 262), "r": 40.0, "label": "求救", "col": Color(1.00, 0.55, 0.45), "hold": false },
	{ "id": "ui_radio_1", "pos": Vector2(294, 262), "r": 40.0, "label": "總攻", "col": Color(1.00, 0.78, 0.35), "hold": false },
	{ "id": "ui_radio_2", "pos": Vector2(392, 262), "r": 40.0, "label": "空投", "col": Color(0.55, 0.95, 0.70), "hold": false },
	{ "id": "ui_radio_3", "pos": Vector2(490, 262), "r": 40.0, "label": "嗆聲", "col": Color(0.75, 0.80, 0.95), "hold": false },
	{ "id": "ui_chat",    "pos": Vector2(588, 262), "r": 40.0, "label": "打字", "col": Color(0.62, 0.78, 1.00), "hold": false },
]

## 預設就展開：手機上少一次點擊比較好用，而且這一排下方本來就是空的。
## 想把畫面清乾淨可以按「通訊」收起來。
var _comms_open: bool = true


## 這一幀實際存在的按鈕（含展開中的通訊列）
func _active_buttons() -> Array:
	var out: Array = [COMMS_TOGGLE]
	if _comms_open:
		out.append_array(COMMS_BUTTONS)
	for b in BUTTONS:
		if _btn_enabled(b):
			out.append(b)
	return out


## 要不要啟用觸控層。FORCE_TOUCH 是給桌面截圖與版面調整用的。
static func should_enable() -> bool:
	if OS.get_environment("FORCE_TOUCH").strip_edges() != "":
		return true
	return DisplayServer.is_touchscreen_available() or OS.has_feature("mobile")


func setup(w) -> void:
	world = w
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 不吃 GUI 事件：底下的聊天框、選單按鈕照常可以點
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = get_theme_default_font()
	set_process_input(true)


var _was_on_foot: bool = false


## 只在戰鬥階段出現。部署階段要用「點地面放防空炮」，簡報階段要點著推進對話 ─
## 那些都靠觸控轉滑鼠事件完成，這一層擋在上面只會把它們吃掉。
func _process(_delta: float) -> void:
	if world == null:
		return
	var want: bool = int(world.phase) == int(world.PHASE_COMBAT)
	if want != visible:
		visible = want
		if not want:
			release_all()
	if not want:
		return
	# 登機／下機時整組按鈕會換一批，狀態變了就重畫並放掉殘留的輸入
	var foot: bool = world.has_method("local_on_foot") and world.local_on_foot()
	if foot != _was_on_foot:
		_was_on_foot = foot
		release_all()


#══════════════════════════════════════════════════════════════════════════════
#  輸入
#══════════════════════════════════════════════════════════════════════════════
func _input(event: InputEvent) -> void:
	if not visible:
		return

	# 桌面上用滑鼠模擬單一觸點，方便在電腦上調版面與驗證
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_touch(-1, event.position, event.pressed)
		return
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_drag(-1, event.position)
		return

	if event is InputEventScreenTouch:
		_touch(event.index, event.position, event.pressed)
	elif event is InputEventScreenDrag:
		_drag(event.index, event.position)


func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	if not pressed:
		_release(index)
		return

	# 先比對按鈕，再比對搖桿區 ─ 按鈕疊在搖桿活動範圍上時以按鈕優先
	for b in _active_buttons():
		if pos.distance_to(b["pos"]) <= float(b["r"]) + 8.0:
			_btn_touch[index] = b["id"]
			_press_action(String(b["id"]), bool(b["hold"]))
			_consume()
			queue_redraw()
			return

	if _stick_touch == -99 and STICK_AREA.has_point(pos):
		_stick_touch = index
		# 浮動搖桿：以按下的位置當圓心，但不要貼到畫面邊緣
		_stick_home = Vector2(
			clampf(pos.x, STICK_RADIUS + 10.0, STICK_AREA.end.x - STICK_RADIUS),
			clampf(pos.y, STICK_AREA.position.y + STICK_RADIUS, 900.0 - STICK_RADIUS - 10.0))
		_drag(index, pos)
		_consume()


func _drag(index: int, pos: Vector2) -> void:
	if index != _stick_touch:
		return
	var v := (pos - _stick_home) / STICK_RADIUS
	if v.length() > 1.0:
		v = v.normalized()
	_stick_vec = v
	_apply_stick()
	_consume()
	queue_redraw()


func _release(index: int) -> void:
	if _btn_touch.has(index):
		var id := String(_btn_touch[index])
		_btn_touch.erase(index)
		_release_action(id)
		queue_redraw()
	if index == _stick_touch:
		_stick_touch = -99
		_stick_vec = Vector2.ZERO
		_apply_stick()
		queue_redraw()


func _consume() -> void:
	get_viewport().set_input_as_handled()


#══════════════════════════════════════════════════════════════════════════════
#  驅動 InputMap
#══════════════════════════════════════════════════════════════════════════════
## 搖桿是類比的：action_press 的第二個參數就是 get_action_strength() 讀到的值，
## 所以輕推＝小舵量，跟鍵盤的全有全無不一樣（手機上反而比鍵盤好操縱）。
func _apply_stick() -> void:
	var x := _stick_vec.x
	var y := _stick_vec.y
	if absf(x) < DEAD_ZONE:
		x = 0.0
	if absf(y) < DEAD_ZONE:
		y = 0.0
	# 螢幕 y 往下為正，往上推＝抬頭
	_axis("ac_pitch_up", "ac_pitch_down", -y)
	_axis("ac_yaw_right", "ac_yaw_left", x)


func _axis(pos_action: String, neg_action: String, v: float) -> void:
	if v > 0.0:
		Input.action_release(neg_action)
		Input.action_press(pos_action, minf(v, 1.0))
	elif v < 0.0:
		Input.action_release(pos_action)
		Input.action_press(neg_action, minf(-v, 1.0))
	else:
		Input.action_release(pos_action)
		Input.action_release(neg_action)


func _press_action(id: String, hold: bool) -> void:
	if id.begins_with("ui_"):
		_ui_action(id)
		return
	Input.action_press(id, 1.0)
	_pressed[id] = true
	if not hold:
		# 點按型：壓一幀就放掉，讓 is_action_just_pressed 只觸發一次
		_release_next_frame(id)


func _release_next_frame(id: String) -> void:
	await get_tree().process_frame
	Input.action_release(id)


func _release_action(id: String) -> void:
	if not id.begins_with("ui_"):
		Input.action_release(id)
	_pressed.erase(id)


## ui_ 開頭的按鈕不是 InputMap 動作，直接呼叫 MainGame 的對應功能
func _ui_action(id: String) -> void:
	var mg = world._mg() if world != null else null
	if mg == null:
		return
	if id == "ui_comms":
		_comms_open = not _comms_open
		queue_redraw()
		return
	if id == "ui_chat":
		mg._open_chat_input()
		return
	if id.begins_with("ui_radio_"):
		mg.send_radio(int(id.substr("ui_radio_".length())))


## 離開戰鬥、切到選單或這一層被關掉時，一定要把所有動作放掉，
## 否則會留下「油門一直加著」這種卡住的輸入。
func release_all() -> void:
	_stick_touch = -99
	_stick_vec = Vector2.ZERO
	_btn_touch.clear()
	_apply_stick()
	for b in BUTTONS:
		Input.action_release(String(b["id"]))
	_pressed.clear()
	queue_redraw()


#══════════════════════════════════════════════════════════════════════════════
#  版面：依當下狀態決定哪些鈕要出現
#══════════════════════════════════════════════════════════════════════════════
func _btn_enabled(b: Dictionary) -> bool:
	if world == null:
		return true
	var id := String(b["id"])
	var on_foot: bool = world.has_method("local_on_foot") and world.local_on_foot()
	match id:
		"ac_board":
			return on_foot                      # 只有走在甲板上時才需要登機鈕
		"ac_deploy":
			return not on_foot and world.local_is_defender()
		_:
			return not on_foot                  # 飛行操控在步行時全部收起來


#══════════════════════════════════════════════════════════════════════════════
#  繪製
#══════════════════════════════════════════════════════════════════════════════
func _draw() -> void:
	# 搖桿在步行階段照樣要有：_update_on_foot() 讀的是同一組 ac_pitch_* / ac_yaw_*，
	# 推前進、左右轉身都靠它。
	_draw_stick()

	for b in _active_buttons():
		var id := String(b["id"])
		var held: bool = _pressed.has(id) or (id == "ui_comms" and _comms_open)
		_draw_button(b["pos"], float(b["r"]), String(b["label"]), b["col"], held)


func _draw_stick() -> void:
	var home := _stick_home if _stick_touch != -99 else STICK_HOME
	var col := Color(0.62, 0.78, 1.00)
	draw_circle(home, STICK_RADIUS, Color(col.r, col.g, col.b, 0.07))
	draw_arc(home, STICK_RADIUS, 0.0, TAU, 48, Color(col.r, col.g, col.b, 0.40), 2.5, true)
	# 中心十字：沒有它在深色地形上很難看出圓心在哪
	draw_line(home - Vector2(14, 0), home + Vector2(14, 0), Color(col.r, col.g, col.b, 0.30), 2.0)
	draw_line(home - Vector2(0, 14), home + Vector2(0, 14), Color(col.r, col.g, col.b, 0.30), 2.0)

	var knob := home + _stick_vec * STICK_RADIUS
	draw_circle(knob, KNOB_RADIUS, Color(col.r, col.g, col.b, 0.22))
	draw_arc(knob, KNOB_RADIUS, 0.0, TAU, 32, Color(col.r, col.g, col.b, 0.85), 3.0, true)


func _draw_button(pos: Vector2, r: float, label: String, col: Color, held: bool) -> void:
	var fill := Color(col.r, col.g, col.b, 0.30 if held else 0.10)
	draw_circle(pos, r, fill)
	draw_arc(pos, r, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.95 if held else 0.55), 3.0, true)
	if _font == null:
		return
	var size := 20 if r >= 46.0 else 17
	var w := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	# 外框加一圈深色描邊，白天地圖底下才看得清楚
	draw_string_outline(_font, pos + Vector2(-w * 0.5, size * 0.36), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, 5, Color(0, 0, 0, 0.85))
	draw_string(_font, pos + Vector2(-w * 0.5, size * 0.36), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0.95, 0.98, 1.0))
