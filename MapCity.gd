extends RefCounted
#══════════════════════════════════════════════════════════════════════════════
#  MapCity.gd ─ 都市地形（高樓林立）
#
#  ‧ district() ：一座城區 ─ 街廓網格、由市中心往外遞減的樓高、
#                 發光窗帶、屋頂航障燈、高架道路、公園。
#                 每張地圖都會放一座，讓城市成為隨處可見的低空掩體。
#  ‧ build()    ：完整的「濱海都會」地圖 ─ 雙市中心 + 郊區 + 跨海大橋。
#
#  窗戶與街燈全部塞進 MultiMesh（一個 draw call 畫完整座城），
#  只有夠高的大樓才加碰撞體，網頁端才跑得動。
#
#  註：刻意不宣告 class_name，由 GameWorld 以 load() 動態載入。
#══════════════════════════════════════════════════════════════════════════════

var w                              # GameWorld
var land_y: float = 8.0
var map_limit: float = 2500.0

const BLOCK := 74.0                # 街廓大小（含馬路）
const ROAD  := 24.0                # 馬路寬度


#══════════════════════════════════════════════════════════════════════════════
#  一座城區
#══════════════════════════════════════════════════════════════════════════════
## center 市中心、radius 城區半徑、tall 市中心的最高樓高
func district(t: Node3D, m: Dictionary, center: Vector3, radius: float,
		tall: float = 210.0) -> void:
	var root := Node3D.new()
	root.name = "City"
	t.add_child(root)

	var conc: StandardMaterial3D = w.make_terrain_material(Color(0.135, 0.140, 0.155))
	var conc2: StandardMaterial3D = w.make_terrain_material(Color(0.100, 0.105, 0.120))
	var glass: StandardMaterial3D = w.make_terrain_material(Color(0.075, 0.105, 0.130))
	var road_mat: StandardMaterial3D = w.make_terrain_material(Color(0.055, 0.058, 0.065))

	# ── 窗戶用的 MultiMesh：整座城市共用一個 draw call ──
	var win_mmi := MultiMeshInstance3D.new()
	var win_mm := MultiMesh.new()
	win_mm.transform_format = MultiMesh.TRANSFORM_3D
	win_mm.use_colors = true
	var wbox := BoxMesh.new()
	wbox.size = Vector3.ONE
	win_mm.mesh = wbox
	var win_mat := StandardMaterial3D.new()
	win_mat.albedo_color = Color.WHITE
	win_mat.vertex_color_use_as_albedo = true
	win_mat.emission_enabled = true
	win_mat.emission = Color(1, 1, 1)
	# 發光強度刻意壓低：窗帶面積大，開太亮會被 Glow 糊成一整片白方塊，
	# 整座城市就看不出樓的形狀了。
	win_mat.emission_energy_multiplier = 0.42
	win_mat.vertex_color_is_srgb = false
	win_mmi.material_override = win_mat

	var xf: Array = []
	var cols: Array = []

	var n := int(radius / BLOCK)
	for gx in range(-n, n + 1):
		for gz in range(-n, n + 1):
			var pos := Vector3(center.x + gx * BLOCK, 0.0, center.z + gz * BLOCK)
			var d := Vector2(pos.x - center.x, pos.z - center.z).length()
			if d > radius:
				continue
			if not w.is_land(pos) or w._in_corridor(pos, 70.0):
				continue

			# 市中心最高，往外遞減；再加上噪聲讓天際線起伏
			var falloff: float = pow(1.0 - clampf(d / radius, 0.0, 1.0), 1.35)
			var noise: float = absf(w._noise.get_noise_2d(pos.x * 2.2, pos.z * 2.2))
			var h: float = tall * (0.16 + 0.84 * falloff) * (0.55 + 0.95 * noise)
			h = clampf(h, 22.0, tall)
			# 偶爾留一個空地（公園 / 停車場），城市才不會像實心方塊
			if w._rng.randf() < 0.12:
				w.make_box(root, Vector3(BLOCK - ROAD, 0.4, BLOCK - ROAD),
					Vector3(pos.x, land_y + 0.3, pos.z), m["grass"])
				continue

			var sx: float = (BLOCK - ROAD) * w._rng.randf_range(0.55, 0.95)
			var sz: float = (BLOCK - ROAD) * w._rng.randf_range(0.55, 0.95)
			var body: StandardMaterial3D = glass if h > tall * 0.5 else (conc if gx % 2 == 0 else conc2)
			w.make_box(root, Vector3(sx, h, sz), Vector3(pos.x, land_y + h * 0.5, pos.z), body)
			# 高樓才加碰撞與高度圖：矮房子撞不到也不影響 AI 航路
			if h > 34.0:
				w.add_static_box(root, Vector3(sx, h, sz), Vector3(pos.x, land_y + h * 0.5, pos.z))
			w._stamp_height(pos, maxf(sx, sz) * 0.62, land_y + h)

			# 退縮的頂層（越高的樓越明顯），做出層次
			if h > tall * 0.45:
				var th: float = h * w._rng.randf_range(0.06, 0.16)
				w.make_box(root, Vector3(sx * 0.6, th, sz * 0.6),
					Vector3(pos.x, land_y + h + th * 0.5, pos.z), body)
				# 屋頂航障燈
				w.make_box(root, Vector3(1.6, 1.6, 1.6),
					Vector3(pos.x, land_y + h + th + 1.2, pos.z),
					w.make_material(Color(1.0, 0.25, 0.20), 5.0))

			# ── 四面窗帶 ──
			var lit: bool = w._rng.randf() < 0.78
			var wc: Color = Color(1.0, 0.84, 0.52) if w._rng.randf() < 0.6 \
				else Color(0.50, 0.80, 1.0)
			if not lit:
				wc = Color(0.08, 0.10, 0.14)
			wc = wc.darkened(w._rng.randf_range(0.25, 0.6))
			# 窗帶只占外牆中段，四周留出混凝土框，遠看才有樓的輪廓
			var wy: float = land_y + h * 0.52
			var wh: float = h * 0.62
			xf.append(_scaled(Vector3(sx * 0.58, wh, 0.5), Vector3(pos.x, wy, pos.z - sz * 0.5)))
			cols.append(wc)
			xf.append(_scaled(Vector3(sx * 0.58, wh, 0.5), Vector3(pos.x, wy, pos.z + sz * 0.5)))
			cols.append(wc)
			xf.append(_scaled(Vector3(0.5, wh, sz * 0.58), Vector3(pos.x - sx * 0.5, wy, pos.z)))
			cols.append(wc)
			xf.append(_scaled(Vector3(0.5, wh, sz * 0.58), Vector3(pos.x + sx * 0.5, wy, pos.z)))
			cols.append(wc)

	# ── 馬路網格與街燈帶 ──
	var lanes := int(radius / BLOCK)
	for i in range(-lanes, lanes + 1):
		var off := float(i) * BLOCK + BLOCK * 0.5
		var len_ax: float = sqrt(maxf(0.0, radius * radius - off * off)) * 2.0
		if len_ax < BLOCK:
			continue
		var px := Vector3(center.x, land_y + 0.25, center.z + off)
		if w.is_land(px):
			w.make_box(root, Vector3(len_ax, 0.4, ROAD * 0.8), px, road_mat)
			w.make_box(root, Vector3(len_ax, 0.4, 0.7),
				px + Vector3(0, 0.2, 0), w.make_material(Color(1.0, 0.78, 0.35), 0.55))
		var pz := Vector3(center.x + off, land_y + 0.25, center.z)
		if w.is_land(pz):
			w.make_box(root, Vector3(ROAD * 0.8, 0.4, len_ax), pz, road_mat)
			w.make_box(root, Vector3(0.7, 0.4, len_ax),
				pz + Vector3(0, 0.2, 0), w.make_material(Color(0.55, 0.85, 1.0), 0.55))

	# ── 地標塔：比周圍再高一截，附尖塔與頻閃燈 ──
	_landmark(root, m, center + Vector3(BLOCK * 0.5, 0, -BLOCK * 0.5), tall * 1.35)

	win_mm.instance_count = xf.size()
	for i in xf.size():
		win_mm.set_instance_transform(i, xf[i])
		win_mm.set_instance_color(i, cols[i])
	win_mmi.multimesh = win_mm
	root.add_child(win_mmi)


## 地標摩天樓
func _landmark(root: Node3D, m: Dictionary, pos: Vector3, h: float) -> void:
	if not w.is_land(pos) or w._in_corridor(pos, 70.0):
		return
	var body: StandardMaterial3D = w.make_terrain_material(Color(0.085, 0.100, 0.125))
	var trim: StandardMaterial3D = w.make_material(MainGame.C_DEF, 0.9)
	var seg := h / 5.0
	for i in 5:
		var s: float = 34.0 - i * 5.0
		w.make_box(root, Vector3(s, seg, s), Vector3(pos.x, land_y + seg * (0.5 + i), pos.z), body)
		w.make_box(root, Vector3(s + 0.6, 1.2, s + 0.6),
			Vector3(pos.x, land_y + seg * (i + 1), pos.z), trim)
	w.make_cyl(root, 0.6, 3.0, h * 0.28, Vector3(pos.x, land_y + h + h * 0.14, pos.z), body)
	w.make_sphere(root, 2.2, Vector3(pos.x, land_y + h * 1.30, pos.z),
		w.make_material(Color(1.0, 0.30, 0.22), 6.0))
	w.add_static_box(root, Vector3(30, h, 30), Vector3(pos.x, land_y + h * 0.5, pos.z))
	w._stamp_height(pos, 40.0, land_y + h * 1.3)


#══════════════════════════════════════════════════════════════════════════════
#  地圖：濱海都會
#══════════════════════════════════════════════════════════════════════════════
func build(t: Node3D, m: Dictionary) -> void:
	# 兩個市中心：一個靠海、一個在內陸，中間用高架快速道路連起來
	district(t, m, Vector3(-560, 0, -640), 560.0, 250.0)
	district(t, m, Vector3(620, 0, -1120), 470.0, 200.0)
	# 外圍郊區：矮房子鋪開，讓城市有邊界感
	district(t, m, Vector3(-180, 0, -1500), 420.0, 90.0)
	district(t, m, Vector3(1180, 0, -520), 380.0, 110.0)

	highway(t, m, Vector3(-560, 0, -640), Vector3(620, 0, -1120))
	highway(t, m, Vector3(-560, 0, -640), Vector3(-180, 0, -1500))

	# 城市之間仍然要有地形起伏，不然整張圖都是平的
	w._ridge_chain(t, m, Vector3(-1500, 0, -300), Vector3(-1650, 0, -1500), 190.0, 210.0)
	w._ridge_chain(t, m, Vector3(1500, 0, -1500), Vector3(1700, 0, -300), 190.0, 190.0)

	# 港區：碼頭吊車與貨櫃堆
	harbour(t, m, Vector3(-820, 0, -300))

	w._build_forest(t, m, 200, -1400.0, -1000.0, -1700.0, -900.0)


## 高架快速道路：架在橋墩上的長帶，可以從下面鑽過去
func highway(t: Node3D, m: Dictionary, from: Vector3, to: Vector3) -> void:
	var span := to - from
	var length := span.length()
	var steps := int(length / 90.0)
	if steps < 2:
		return
	var deck: StandardMaterial3D = w.make_terrain_material(Color(0.115, 0.120, 0.135))
	var pier: StandardMaterial3D = w.make_terrain_material(Color(0.085, 0.090, 0.100))
	var lamp: StandardMaterial3D = w.make_material(Color(1.0, 0.82, 0.40), 2.0)
	var yaw := atan2(span.x, span.z)

	for i in steps + 1:
		var p: Vector3 = from + span * (float(i) / float(steps))
		if not w.is_land(p) or w._in_corridor(p, 60.0):
			continue
		var h := 34.0
		var mi: MeshInstance3D = w.make_box(t, Vector3(22.0, 2.2, 96.0),
			Vector3(p.x, land_y + h, p.z), deck)
		mi.rotation.y = yaw
		var col: MeshInstance3D = w.make_box(t, Vector3(6.0, h, 6.0),
			Vector3(p.x, land_y + h * 0.5, p.z), pier)
		col.rotation.y = yaw
		var lm: MeshInstance3D = w.make_box(t, Vector3(20.0, 0.5, 1.2),
			Vector3(p.x, land_y + h + 1.3, p.z), lamp)
		lm.rotation.y = yaw
		if i % 2 == 0:
			w.add_static_box(t, Vector3(20.0, 3.0, 90.0), Vector3(p.x, land_y + h, p.z))
		w._stamp_height(p, 40.0, land_y + h + 3.0)


## 港區：吊車與貨櫃
func harbour(t: Node3D, m: Dictionary, pos: Vector3) -> void:
	var metal: StandardMaterial3D = m["metal"]
	var warn: StandardMaterial3D = w.make_material(Color(1.0, 0.62, 0.15), 2.0)
	for i in 4:
		var base := pos + Vector3(i * 90.0 - 135.0, 0, 0)
		if not w.is_land(base):
			continue
		# 門式起重機
		for s in [-1.0, 1.0]:
			w.make_box(t, Vector3(4.0, 46.0, 4.0), base + Vector3(s * 16.0, land_y + 23.0, 0), metal)
		w.make_box(t, Vector3(40.0, 4.0, 6.0), base + Vector3(0, land_y + 46.0, 0), metal)
		w.make_box(t, Vector3(6.0, 4.0, 46.0), base + Vector3(-14.0, land_y + 44.0, -18.0), metal)
		w.make_box(t, Vector3(8.0, 1.0, 1.4), base + Vector3(0, land_y + 48.5, 0), warn)
		w._stamp_height(base, 26.0, land_y + 48.0)
		# 貨櫃堆
		for k in 10:
			var cpos := base + Vector3(w._rng.randf_range(-34, 34), 0, w._rng.randf_range(24, 70))
			var stack: int = w._rng.randi_range(1, 3)
			for s2 in stack:
				w.make_box(t, Vector3(12.0, 5.0, 5.4),
					cpos + Vector3(0, land_y + 2.6 + s2 * 5.2, 0),
					w.make_terrain_material(Color(w._rng.randf_range(0.10, 0.42),
						w._rng.randf_range(0.10, 0.30), w._rng.randf_range(0.10, 0.32))))


#══════════════════════════════════════════════════════════════════════════════
#  工具
#══════════════════════════════════════════════════════════════════════════════
## 只有縮放與位移的 Transform3D（窗帶不需要旋轉，四面各用不同的軸長）
func _scaled(size: Vector3, origin: Vector3) -> Transform3D:
	return Transform3D(Basis(Vector3(size.x, 0, 0), Vector3(0, size.y, 0), Vector3(0, 0, size.z)),
		origin)
