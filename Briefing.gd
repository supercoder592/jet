extends Node3D
#══════════════════════════════════════════════════════════════════════════════
#  Briefing.gd ─ 開戰前的長官簡報畫面
#
#  一間 3D 簡報室：長官站在戰術地圖板前，用指示棒指著地圖講解攻防戰背景
#  與任務目標；講到哪個目標，地圖上那個圖示就會發亮並被指到。
#
#  講稿依陣營不同。可用 [Enter/滑鼠左鍵] 推進、[ESC] 跳過。
#  簡報室蓋在戰場正上方遠處，不會跟地形打架。
#
#  註：刻意不宣告 class_name，由 GameWorld 以 load() 動態載入。
#══════════════════════════════════════════════════════════════════════════════

const ROOM_ORIGIN := Vector3(0.0, 2800.0, 2600.0)   # 遠離戰場的獨立空間
const BOARD_W := 23.0
const BOARD_H := 12.6
const LINE_HOLD := 1.9          # 一句話講完之後停多久自動下一句
const TYPE_SPEED := 42.0        # 每秒顯示幾個字（九句要在簡報時間內講完）

var world: Node3D
var team: int = 0
var cam: Camera3D
var done: bool = false

var _lines: Array = []
var _idx: int = 0
var _reveal: float = 0.0
var _hold: float = 0.0
var _t: float = 0.0
var _icons: Dictionary = {}      # key -> { node, mat, base }
var _focus: String = ""
var _pointer_pivot: Node3D
var _mouth: MeshInstance3D
var _speaking: float = 0.0

# UI
var _ui: CanvasLayer
var _text: Label
var _name_lbl: Label
var _mood_bar: ColorRect
var _dots: Label
var _title: Label
var _fade: ColorRect


#══════════════════════════════════════════════════════════════════════════════
#  建構
#══════════════════════════════════════════════════════════════════════════════
func build(my_team: int) -> void:
	team = my_team
	position = ROOM_ORIGIN
	_lines = _script_for(team)
	_build_room()
	_build_board()
	_build_officer()
	_build_camera()
	_build_ui()
	_start_line(0)


func _build_room() -> void:
	var floor_m := _mat(Color(0.055, 0.062, 0.078), 0.0, 0.9)
	var wall := _mat(Color(0.075, 0.085, 0.105), 0.0, 0.85)
	var trim := _mat(MainGame.C_DEF, 1.1)
	var wood := _mat(Color(0.14, 0.10, 0.08), 0.0, 0.7)

	_box(self, Vector3(40, 0.6, 34), Vector3(0, -0.3, 0), floor_m)
	_box(self, Vector3(40, 13.0, 0.6), Vector3(0, 6.5, -16.0), wall)      # 後牆（掛地圖板）
	for s in [-1.0, 1.0]:
		_box(self, Vector3(0.6, 13.0, 34), Vector3(s * 20.0, 6.5, 0), wall)
	_box(self, Vector3(40, 0.6, 34), Vector3(0, 13.0, 0), wall)           # 天花板
	# 牆腳燈帶：讓房間有輪廓
	_box(self, Vector3(38, 0.14, 0.2), Vector3(0, 0.3, -15.6), trim)
	for s2 in [-1.0, 1.0]:
		_box(self, Vector3(0.2, 0.14, 32), Vector3(s2 * 19.6, 0.3, 0), trim)

	# 天花板投射燈
	for i in 3:
		var lx := -9.0 + i * 9.0
		_box(self, Vector3(3.4, 0.25, 1.0), Vector3(lx, 12.4, -4.0), _mat(Color(0.95, 0.97, 1.0), 2.6))
		var om := OmniLight3D.new()
		om.position = Vector3(lx, 11.0, -4.0)
		om.light_color = Color(0.85, 0.92, 1.0)
		om.light_energy = 2.2
		om.omni_range = 30.0
		add_child(om)

	# 打在地圖板上的聚光燈：簡報室的重點光
	var sp := SpotLight3D.new()
	sp.position = Vector3(0, 11.5, 2.0)
	sp.rotation_degrees = Vector3(-62, 0, 0)
	sp.light_color = Color(0.90, 0.95, 1.0)
	sp.light_energy = 6.0
	sp.spot_range = 40.0
	sp.spot_angle = 38.0
	add_child(sp)

	# 前排座椅（椅背朝鏡頭，做出「你也坐在裡面」的感覺）
	for r in 2:
		for c in 5:
			var seat := Node3D.new()
			seat.position = Vector3(-8.0 + c * 4.0, 0, 7.0 + r * 5.0)
			add_child(seat)
			_box(seat, Vector3(2.0, 0.25, 1.8), Vector3(0, 1.0, 0), wood)
			_box(seat, Vector3(2.0, 1.9, 0.25), Vector3(0, 1.9, 0.9), wood)
			for lx2 in [-0.8, 0.8]:
				for lz in [-0.7, 0.7]:
					_cyl(seat, 0.09, 0.09, 1.0, Vector3(lx2, 0.5, lz), _mat(Color(0.1, 0.1, 0.12)))

	# 講桌
	var desk := Node3D.new()
	desk.position = Vector3(-7.5, 0, -6.0)
	add_child(desk)
	_box(desk, Vector3(4.6, 0.24, 2.2), Vector3(0, 2.0, 0), wood)
	_box(desk, Vector3(4.2, 1.8, 0.2), Vector3(0, 1.1, -0.9), wood)
	# 桌上的文件與馬克杯
	for i2 in 3:
		_box(desk, Vector3(1.0, 0.03, 1.4), Vector3(-1.2 + i2 * 0.9, 2.14, 0.1),
			_mat(Color(0.82, 0.84, 0.80), 0.35))
	_cyl(desk, 0.22, 0.22, 0.42, Vector3(1.7, 2.32, 0.4), _mat(Color(0.15, 0.35, 0.45), 0.4))


## 戰術地圖板：把整張戰場俯視圖畫在後牆上
func _build_board() -> void:
	var board := Node3D.new()
	board.position = Vector3(3.0, 7.2, -15.4)
	add_child(board)

	var frame := _mat(Color(0.11, 0.12, 0.15), 0.0, 0.6)
	var sea := _mat(Color(0.035, 0.10, 0.16), 0.55)
	var land := _mat(Color(0.10, 0.13, 0.08), 0.35)
	var grid := _mat(MainGame.C_DEF, 0.7)

	_box(board, Vector3(BOARD_W + 1.2, BOARD_H + 1.2, 0.3), Vector3(0, 0, -0.2), frame)
	# 海（下半）與陸（上半）：分界對應真正的海岸線 z = COAST_Z
	var coast_y := _board_y(-330.0)
	var sea_h := coast_y + BOARD_H * 0.5
	_box(board, Vector3(BOARD_W, sea_h, 0.12), Vector3(0, -BOARD_H * 0.5 + sea_h * 0.5, 0), sea)
	var land_h := BOARD_H - sea_h
	_box(board, Vector3(BOARD_W, land_h, 0.12), Vector3(0, coast_y + land_h * 0.5, 0), land)
	_box(board, Vector3(BOARD_W, 0.10, 0.16), Vector3(0, coast_y, 0.02),
		_mat(Color(0.55, 0.95, 1.0), 2.0))

	# 網格
	for i in 9:
		_box(board, Vector3(0.03, BOARD_H, 0.14),
			Vector3(-BOARD_W * 0.5 + (i + 1) * BOARD_W / 10.0, 0, 0.01), grid)
	for j in 5:
		_box(board, Vector3(BOARD_W, 0.03, 0.14),
			Vector3(0, -BOARD_H * 0.5 + (j + 1) * BOARD_H / 6.0, 0.01), grid)

	# 峽谷航道：一條蜿蜒虛線，簡報講到「貼著谷底飛」時會發亮
	var canyon := Node3D.new()
	canyon.position = Vector3(0, 0, 0.04)
	board.add_child(canyon)
	var cm := _mat(Color(1.0, 0.62, 0.25), 1.4)
	for k in 16:
		var f := float(k) / 15.0
		var wz := lerpf(-200.0, -1500.0, f)
		var wx := sin(f * 4.2) * 620.0 - 120.0
		var seg := _box(canyon, Vector3(0.16, 0.62, 0.1),
			Vector3(_board_x(wx), _board_y(wz), 0), cm)
		seg.rotation.z = sin(f * 4.2 + 1.57) * 0.5
	_icons["canyon"] = { "node": canyon, "mat": cm, "base": 1.4 }

	# 目標圖示
	_add_icon(board, "carrier", Vector3(0, 0, 400), MainGame.C_ATK, "航艦戰鬥群", true)
	_add_icon(board, "runway", Vector3(0, 0, -760), MainGame.C_DEF, "跑道", false)
	_add_icon(board, "nuke", Vector3(140, 0, -900), Color(0.42, 1.00, 0.45), "核設施", false)

	# 攻擊軸線：航艦 → 跑道的虛線箭頭
	var axis := Node3D.new()
	axis.position = Vector3(0, 0, 0.05)
	board.add_child(axis)
	var am := _mat(Color(1.0, 0.35, 0.30), 1.2)
	var from := Vector2(_board_x(0.0), _board_y(400.0))
	var to := Vector2(_board_x(0.0), _board_y(-700.0))
	for k2 in 12:
		var f2 := float(k2) / 11.0
		var p := from.lerp(to, f2)
		_box(axis, Vector3(0.14, 0.5, 0.1), Vector3(p.x, p.y, 0), am)
	for s3 in [-1.0, 1.0]:
		var head := _box(axis, Vector3(0.14, 0.9, 0.1), Vector3(to.x + s3 * 0.3, to.y + 0.45, 0), am)
		head.rotation.z = s3 * 0.6

	var t := Label3D.new()
	t.text = "作 戰 區 域 ─ OPERATION AREA"
	t.font_size = 56
	t.pixel_size = 0.012
	t.modulate = MainGame.C_TEXT
	t.outline_size = 12
	t.position = Vector3(0, BOARD_H * 0.5 + 1.0, 0.2)
	board.add_child(t)


func _add_icon(board: Node3D, key: String, world_pos: Vector3, col: Color,
		label: String, is_ship: bool) -> void:
	var n := Node3D.new()
	n.position = Vector3(_board_x(world_pos.x), _board_y(world_pos.z), 0.08)
	board.add_child(n)
	var m := _mat(col, 1.8)
	if is_ship:
		_box(n, Vector3(1.5, 0.5, 0.12), Vector3.ZERO, m)
		_box(n, Vector3(0.4, 0.85, 0.12), Vector3(0.2, 0.3, 0), m)
	else:
		_box(n, Vector3(1.0, 1.0, 0.12), Vector3.ZERO, m)
		_box(n, Vector3(1.6, 0.08, 0.12), Vector3(0, 0.7, 0), m)
	var tag := Label3D.new()
	tag.text = label
	tag.font_size = 44
	tag.pixel_size = 0.010
	tag.modulate = col
	tag.outline_size = 10
	# 跑道與核設施在圖上很近，標籤往不同方向錯開才不會疊在一起
	tag.position = Vector3(1.5, 0.55 if key == "nuke" else -0.55, 0.1)
	n.add_child(tag)
	_icons[key] = { "node": n, "mat": m, "base": 1.8 }


## 世界座標 → 地圖板座標
func _board_x(wx: float) -> float:
	return clampf(wx / 2600.0, -1.0, 1.0) * BOARD_W * 0.46


func _board_y(wz: float) -> float:
	# z=+700（外海）在最下面，z=-2300（內陸最深）在最上面
	var f := clampf((700.0 - wz) / 3000.0, 0.0, 1.0)
	return lerpf(-BOARD_H * 0.46, BOARD_H * 0.46, f)


## 長官：低多邊形立體角色，一手拿指示棒指地圖
func _build_officer() -> void:
	var o := Node3D.new()
	o.position = Vector3(-4.6, 0, -11.0)
	o.rotation.y = 0.55
	add_child(o)

	var coat := _mat(Color(0.13, 0.17, 0.22), 0.0, 0.7)
	var dark := _mat(Color(0.08, 0.09, 0.12), 0.0, 0.6)
	var skin := _mat(Color(0.62, 0.48, 0.38), 0.0, 0.8)
	var gold := _mat(Color(1.0, 0.82, 0.25), 1.6)
	var glass := _mat(Color(0.05, 0.07, 0.10), 0.0, 0.3)

	# 腿與軍靴
	for s in [-0.22, 0.22]:
		_box(o, Vector3(0.34, 1.65, 0.36), Vector3(s, 0.85, 0), dark)
		_box(o, Vector3(0.38, 0.22, 0.58), Vector3(s, 0.11, -0.08), dark)
	# 軍裝外套與腰帶
	_box(o, Vector3(1.08, 1.55, 0.62), Vector3(0, 2.45, 0), coat)
	_box(o, Vector3(1.16, 0.18, 0.68), Vector3(0, 1.82, 0), dark)
	_box(o, Vector3(1.14, 0.10, 0.66), Vector3(0, 2.95, 0), gold)     # 肩章連線
	for s2 in [-0.46, 0.46]:
		_box(o, Vector3(0.34, 0.12, 0.5), Vector3(s2, 3.14, 0), gold)  # 肩章
	# 勳表
	for i in 3:
		_box(o, Vector3(0.16, 0.1, 0.04), Vector3(-0.36 + i * 0.2, 2.68, -0.33), gold)

	# 左手垂在身側
	_box(o, Vector3(0.26, 1.25, 0.28), Vector3(-0.66, 2.35, 0.02), coat)

	# 右手抬起握指示棒
	var arm := Node3D.new()
	arm.position = Vector3(0.66, 2.95, 0.0)
	o.add_child(arm)
	var upper := _box(arm, Vector3(0.26, 1.15, 0.28), Vector3(0.18, -0.42, 0), coat)
	upper.rotation.z = 0.55
	_pointer_pivot = Node3D.new()
	_pointer_pivot.position = Vector3(0.55, -0.75, 0.0)
	arm.add_child(_pointer_pivot)
	var stick := _cyl(_pointer_pivot, 0.045, 0.06, 5.2, Vector3(0, 0, -2.6),
		_mat(Color(0.85, 0.86, 0.9), 0.4))
	stick.rotation.x = PI * 0.5
	_sphere(_pointer_pivot, 0.09, Vector3(0, 0, -5.2), _mat(Color(1.0, 0.35, 0.25), 3.0))

	# 頭、軍帽、墨鏡、鬍子、會動的嘴
	_cyl(o, 0.18, 0.20, 0.22, Vector3(0, 3.32, 0), skin)
	_box(o, Vector3(0.66, 0.72, 0.62), Vector3(0, 3.78, 0), skin)
	_box(o, Vector3(0.72, 0.26, 0.68), Vector3(0, 4.24, 0), dark)     # 帽體
	_box(o, Vector3(0.80, 0.08, 0.86), Vector3(0, 4.08, -0.10), dark) # 帽簷
	_box(o, Vector3(0.16, 0.16, 0.04), Vector3(0, 4.22, -0.34), gold) # 帽徽
	for ex in [-0.16, 0.16]:
		_box(o, Vector3(0.22, 0.12, 0.04), Vector3(ex, 3.88, -0.32), glass)
	_box(o, Vector3(0.30, 0.07, 0.05), Vector3(0, 3.66, -0.31),
		_mat(Color(0.20, 0.16, 0.13), 0.0, 0.8))
	_mouth = _box(o, Vector3(0.20, 0.05, 0.05), Vector3(0, 3.56, -0.31),
		_mat(Color(0.22, 0.10, 0.10), 0.0, 0.8))


func _build_camera() -> void:
	cam = Camera3D.new()
	cam.fov = 52.0
	cam.far = 400.0
	cam.position = Vector3(1.5, 5.4, 12.5)
	cam.current = true
	add_child(cam)
	cam.look_at(global_position + Vector3(-1.0, 5.2, -8.0), Vector3.UP)


func _build_ui() -> void:
	_ui = CanvasLayer.new()
	_ui.layer = 8
	add_child(_ui)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(root)

	# 開場淡入
	_fade = ColorRect.new()
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.color = Color(0, 0, 0, 1)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_fade)

	# 上方標題
	_title = _label("作 戰 簡 報　MISSION BRIEFING", 24, Color.WHITE)
	_title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_title.offset_left = -400; _title.offset_right = 400; _title.offset_top = 26
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_title)

	var sub := _label(MainGame.TEAM_NAME[team], 15,
		MainGame.C_ATK if team == MainGame.TEAM_ATTACKER else MainGame.C_DEF)
	sub.set_anchors_preset(Control.PRESET_CENTER_TOP)
	sub.offset_left = -400; sub.offset_right = 400; sub.offset_top = 58
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(sub)

	# 下方字幕框
	# 左下角是隊伍聊天框，字幕要讓開它，否則前半句會被蓋掉
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 520; panel.offset_right = -60
	panel.offset_top = -215; panel.offset_bottom = -40
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.055, 0.08, 0.94)
	sb.border_width_left = 4
	sb.border_color = MainGame.C_DEF
	sb.corner_radius_top_left = 4; sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4; sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 18; sb.content_margin_right = 18
	sb.content_margin_top = 12; sb.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	v.add_child(head)
	_mood_bar = ColorRect.new()
	_mood_bar.color = MainGame.C_DEF
	_mood_bar.custom_minimum_size = Vector2(4, 20)
	head.add_child(_mood_bar)
	_name_lbl = _label("戰術管制官 ─ 「老鷹」", 15, MainGame.C_DEF)
	_name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_name_lbl)
	_dots = _label("", 13, MainGame.C_DIM)
	head.add_child(_dots)

	_text = _label("", 20, Color.WHITE)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size = Vector2(0, 66)
	v.add_child(_text)

	var hint := _label("[Enter / 滑鼠左鍵] 下一句　　[ESC] 跳過簡報", 12, MainGame.C_DIM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(hint)


#══════════════════════════════════════════════════════════════════════════════
#  講稿
#══════════════════════════════════════════════════════════════════════════════
## 每張地圖的地形提示：長官會照今天實際抽到的地圖講解
const MAP_TIP := {
	MainGame.MAP_CANYON:
		"中央是一條深谷航道，兩側高壁夾出狹窄通道。貼著谷底飛，岩壁會擋掉雷達與飛彈鎖定；直線爬高的人今天不會回來。",
	MainGame.MAP_PLAINS:
		"開闊低地配大片林帶，掩體很少。這種地形是純纏鬥場，別在高空拉直線給人當靶。",
	MainGame.MAP_PLATEAU:
		"巨大台地被深切峽溝切開。你可以貼著溝底穿過去，也可以直接越頂 ─ 但越頂的那一刻你就在所有人的雷達上。",
	MainGame.MAP_RANGE:
		"橫向山嶺層層阻隔，每一道只有兩個隘口，位置逐道錯開，隘口上有標示燈。找不到隘口就得爬升，爬升就會被鎖。",
	MainGame.MAP_ALPINE:
		"高聳雪峰把飛行空間壓縮到峰間縫隙。撞山的機率比被打下來還高，飛慢一點。",
	MainGame.MAP_HILLS:
		"連綿的黃土丘陵與沖蝕溝壑，起伏比看起來大。低空掠地很好躲，但地形會突然抬起來。",
	MainGame.MAP_TETON:
		"高聳的鋸齒巨峰配上階狀大峽谷。谷底是最好的低空航道 ─ 岩壁會直接切斷飛彈鎖定，谷裡還有石柱與天然岩拱要閃。",
	MainGame.MAP_CITY:
		"這是一座高樓林立的都會區。摩天樓之間可以穿梭，建築物同樣能擋掉鎖定 ─ 代價是撞上去連殘骸都不會剩。",
}


func _script_for(t: int) -> Array:
	var mg := MainGame.instance
	var map_id: int = mg.map_id if mg != null else MainGame.MAP_CANYON
	var map: Dictionary = MainGame.MAP_INFO.get(map_id, MainGame.MAP_INFO[MainGame.MAP_CANYON])
	var wx: Dictionary = MainGame.WX_INFO.get(mg.weather if mg != null else 0,
		MainGame.WX_INFO[MainGame.WX_CLEAR])
	var tod: String = String(MainGame.TOD_NAME[mg.time_of_day if mg != null else 0]["name"])
	var tip: String = String(MAP_TIP.get(map_id, MAP_TIP[MainGame.MAP_CANYON]))

	# 地形與天候：兩句，所有陣營共用
	var terrain_lines: Array = [
		{ "t": "先講戰場。今天的作戰區域是「%s %s」─ %s" % [map["name"], map["en"], map["desc"]],
			"f": "canyon", "m": "calm" },
		{ "t": "%s　時段是%s，天候%s：%s" % [tip, tod, wx["name"], wx["desc"]],
			"f": "canyon", "m": "calm" },
	]

	if t == MainGame.TEAM_ATTACKER:
		var head: Array = [
			{ "t": "各位，坐下。這場簡報只講一次，三十秒後你們就在甲板上了。",
				"f": "", "m": "order" },
		]
		var body: Array = [
			{ "t": "敵方在這座半島上蓋了一座核設施 ─ 那是他們整條防線的心臟，也是我們今天唯一的勝利條件。",
				"f": "nuke", "m": "order" },
			{ "t": "我們的航艦戰鬥群已經進到外海就位，四艘護航艦會替你們壓制沿岸防空火網。從彈射器出去的那一刻，你們就在他們的雷達上了。",
				"f": "carrier", "m": "calm" },
			{ "t": "核設施從第一秒就可以打，不用先做什麼 ─ 但它很厚，靠機槍是拆不動的，炸彈與火箭才有效。",
				"f": "nuke", "m": "order" },
			{ "t": "順手的話先炸跑道：跑道一倒，他們六十秒內一架都升不了空，那是我們最好的突擊窗口。",
				"f": "runway", "m": "calm" },
			{ "t": "他們的防空飛彈同一時間最多只能有四發在空中 ─ 逼他們把飛彈打光，後面進場的人就輕鬆了。",
				"f": "runway", "m": "calm" },
			{ "t": "任務目標：摧毀核設施，時限十分鐘。時間到還沒拆掉就算我們輸。上機。",
				"f": "nuke", "m": "order" },
		]
		return head + terrain_lines + body

	var head2: Array = [
		{ "t": "全體注意，坐下。這不是演習。",
			"f": "", "m": "order" },
	]
	var body2: Array = [
		{ "t": "敵方航艦戰鬥群三十分鐘前進入我方外海，四艘護航艦已展開防空陣列，艦載機隨時會從彈射器上出來。",
			"f": "carrier", "m": "urgent" },
		{ "t": "他們要的是這裡 ─ 我們的核設施。它很厚，但沒有護盾，從第一秒就會被打。",
			"f": "nuke", "m": "calm" },
		{ "t": "另一個危險是跑道。跑道一倒，我們六十秒內沒有任何人能起飛 ─ 那六十秒他們會用光。",
			"f": "runway", "m": "urgent" },
		{ "t": "等一下你會看到全息立體地圖，有三十秒配置四座防空炮。把火網織在跑道與核設施之間 ─ 記住我們的防空飛彈同時最多四發在空中，堆在同一點只是浪費。",
			"f": "runway", "m": "order" },
		{ "t": "任務目標：跑道與核設施都要撐過十分鐘。時間到就是我們贏。",
			"f": "runway", "m": "order" },
		{ "t": "地形那條低空航道給我盯緊，他們一定會從那裡進來。各單位就位。",
			"f": "canyon", "m": "order" },
	]
	return head2 + terrain_lines + body2


#══════════════════════════════════════════════════════════════════════════════
#  推進
#══════════════════════════════════════════════════════════════════════════════
func _start_line(i: int) -> void:
	_idx = i
	if _idx >= _lines.size():
		finish()
		return
	var line: Dictionary = _lines[_idx]
	_reveal = 0.0
	_hold = 0.0
	_speaking = 1.0
	_focus = String(line["f"])
	_text.text = String(line["t"])
	_text.visible_ratio = 0.0
	var col: Color = MainGame.C_DEF
	match String(line["m"]):
		"order":  col = Color(1.00, 0.85, 0.35)
		"urgent": col = Color(1.00, 0.45, 0.35)
		"good":   col = Color(0.45, 1.00, 0.60)
	_name_lbl.add_theme_color_override("font_color", col)
	_mood_bar.color = col
	_dots.text = "%d / %d" % [_idx + 1, _lines.size()]


## 由 GameWorld 每個 physics frame 呼叫；回傳 true 表示還在簡報中
func update(delta: float) -> bool:
	if done:
		return false
	_t += delta

	# 淡入
	if _fade and _fade.color.a > 0.0:
		_fade.color.a = maxf(0.0, _fade.color.a - delta * 1.4)

	# 打字機
	var total := float(maxf(1.0, float(_text.text.length())))
	if _reveal < total:
		_reveal = minf(total, _reveal + delta * TYPE_SPEED)
		_text.visible_ratio = _reveal / total
		_speaking = 1.0
	else:
		_hold += delta
		_speaking = maxf(0.0, _speaking - delta * 3.0)
		if _hold >= LINE_HOLD:
			_start_line(_idx + 1)
			return not done

	# 嘴巴開合
	if _mouth:
		var h: float = 0.05 + (0.16 if _speaking > 0.0 else 0.0) * absf(sin(_t * 22.0))
		_mouth.scale.y = h / 0.05

	# 指示棒指向目前講到的目標，圖示同時脈動發亮
	_update_focus(delta)

	# 鏡頭極緩慢推近，畫面不會死板
	if cam:
		cam.position = Vector3(1.5 + sin(_t * 0.25) * 0.8, 5.4, 12.5 - minf(_t * 0.16, 2.4))
		cam.look_at(global_position + Vector3(-1.0, 5.2, -8.0), Vector3.UP)

	# 輸入
	if Input.is_action_just_pressed("ac_ui_skip"):
		finish()
		return false
	if Input.is_action_just_pressed("ac_ui_next"):
		if _reveal < total:
			_reveal = total          # 先把整句顯示完
			_text.visible_ratio = 1.0
		else:
			_start_line(_idx + 1)
	return not done


func _update_focus(delta: float) -> void:
	for key in _icons.keys():
		var e: Dictionary = _icons[key]
		var mat: StandardMaterial3D = e["mat"]
		var base: float = float(e["base"])
		var want := base
		if key == _focus:
			want = base * (2.6 + 1.4 * sin(_t * 7.0))
		mat.emission_energy_multiplier = lerpf(mat.emission_energy_multiplier, want,
			clampf(delta * 6.0, 0.0, 1.0))
		var n: Node3D = e["node"]
		var sc := 1.0 if key != _focus else 1.18
		n.scale = n.scale.lerp(Vector3.ONE * sc, clampf(delta * 6.0, 0.0, 1.0))

	if _pointer_pivot:
		var target: Vector3 = global_position + Vector3(3.0, 7.2, -15.0)
		if _focus != "" and _icons.has(_focus):
			target = (_icons[_focus]["node"] as Node3D).global_position
		var from := _pointer_pivot.global_position
		var dir := (target - from)
		# 方向與 UP 幾乎平行時 looking_at 會報錯，這種情況直接跳過
		if dir.length() > 0.5 and absf(dir.normalized().dot(Vector3.UP)) < 0.97:
			var want_basis := Transform3D().looking_at(dir.normalized(), Vector3.UP).basis
			var q := _pointer_pivot.global_transform.basis.get_rotation_quaternion().slerp(
				want_basis.get_rotation_quaternion(), clampf(delta * 3.0, 0.0, 1.0))
			_pointer_pivot.global_transform = Transform3D(Basis(q), from)


func finish() -> void:
	if done:
		return
	done = true
	if _ui:
		_ui.visible = false
	visible = false
	if cam:
		cam.current = false
	# 把鏡頭交還給世界
	if world != null and world._cam != null:
		world._cam.current = true


#══════════════════════════════════════════════════════════════════════════════
#  小工具
#══════════════════════════════════════════════════════════════════════════════
func _mat(col: Color, emit: float = 0.0, rough: float = 0.7) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = 0.18
	m.roughness = rough
	if emit > 0.0:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = emit
	return m


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _cyl(parent: Node3D, tr: float, br: float, h: float, pos: Vector3,
		mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = tr
	cm.bottom_radius = br
	cm.height = h
	mi.mesh = cm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _sphere(parent: Node3D, r: float, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	mi.mesh = sm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
