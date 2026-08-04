extends RefCounted
#══════════════════════════════════════════════════════════════════════════════
#  MapTeton.gd ─ 大堤頓巨峰 + 大峽谷地形
#
#  參考 Grand Teton 的高聳鋸齒巨峰與 Grand Canyon 的階狀深谷：
#    ‧ build()        ：完整的「大堤頓峽谷」地圖
#    ‧ outer_ranges() ：所有地圖共用 ─ 把擴大後的外環填滿巨峰與側翼峽谷，
#                       讓每張圖都有低空穿線（Canyon Run）的戰術路線
#
#  峽谷牆用 MultiMesh 畫（一個 draw call 畫完整條峽谷的階地），
#  只有最內側那層加碰撞體與高度圖登記 ─ 網頁端才吃得下這種規模。
#
#  註：刻意不宣告 class_name，由 GameWorld 以 load() 動態載入。
#══════════════════════════════════════════════════════════════════════════════

var w                          # GameWorld
var land_y: float = 8.0
var map_limit: float = 2500.0
var coast_z: float = -330.0
var land_back: float = -2300.0
var runway_pos := Vector3(0, 0, -760)
var carrier_pos := Vector3(0, 0, 400)


#══════════════════════════════════════════════════════════════════════════════
#  地圖：大堤頓峽谷
#══════════════════════════════════════════════════════════════════════════════
func build(t: Node3D, m: Dictionary) -> void:
	# ── 西側堤頓主脈：地圖上最高的一道鋸齒稜線 ──
	teton_range(t, m, Vector3(-1150, 0, 120), Vector3(-1320, 0, -1900), 230.0, 380.0)
	# ── 東側次脈，把戰場夾成南北向的走廊 ──
	teton_range(t, m, Vector3(1180, 0, 60), Vector3(1300, 0, -1850), 210.0, 330.0)
	# ── 內側前山：高度較低，做出「層層退後」的縱深 ──
	w._ridge_chain(t, m, Vector3(-780, 0, -160), Vector3(-880, 0, -1600), 170.0, 210.0, true)
	w._ridge_chain(t, m, Vector3(820, 0, -220), Vector3(900, 0, -1560), 165.0, 200.0, true)

	# ── 主峽谷：從外海側一路蜿蜒切到跑道盆地，是進攻方的低空航道 ──
	canyon_run(t, m, [
		Vector3(300, 0, -180), Vector3(430, 0, -520), Vector3(300, 0, -820),
		Vector3(90, 0, -1080), Vector3(180, 0, -1380), Vector3(60, 0, -1680),
	], 300.0, 210.0, true)

	# ── 第二條峽谷（西側），提供另一條進場路線 ──
	canyon_run(t, m, [
		Vector3(-380, 0, -300), Vector3(-520, 0, -620), Vector3(-400, 0, -980),
		Vector3(-560, 0, -1320),
	], 260.0, 175.0, false)

	# ── 側支溝：短而窄，飛得進去但要有膽 ──
	slot_canyon(t, m, Vector3(430, 0, -520), Vector3(760, 0, -680), 130.0, 130.0)
	slot_canyon(t, m, Vector3(90, 0, -1080), Vector3(-260, 0, -1180), 120.0, 120.0)
	slot_canyon(t, m, Vector3(-520, 0, -620), Vector3(-760, 0, -460), 120.0, 115.0)

	# ── 高原台地：峽谷之間的平頂高地 ──
	for i in 16:
		var p: Vector3 = w._pick_spot(-1000.0, 1000.0, -1800.0, -400.0)
		if p == Vector3.INF:
			continue
		var h: float = w._rng.randf_range(90.0, 165.0)
		var bw: float = w._rng.randf_range(190.0, 330.0)
		w._rock(t, "mesa", Vector3(bw, h, bw), Vector3(p.x, h * 0.5, p.z), m["rock2"],
			true, w._rng.randf_range(0, TAU))
		# 層積岩：台地側面的水平色帶，是大峽谷最好認的特徵
		for k in 3:
			w.make_cyl(t, bw * 0.36 + k * 2.0, bw * 0.52 - k * 3.0, 4.0,
				Vector3(p.x, h * (0.30 + k * 0.22), p.z),
				m["shade"] if k % 2 == 0 else m["sand"])
		w.make_box(t, Vector3(bw * 0.6, 0.5, 1.0), Vector3(p.x, h + 0.4, p.z), m["vein"])

	# ── 谷底孤峰（Monument Valley 式石柱），穿線時的障礙 ──
	for i2 in 22:
		var p2: Vector3 = w._pick_spot(-1050.0, 1050.0, -1750.0, -260.0)
		if p2 == Vector3.INF:
			continue
		spire(t, m, p2, w._rng.randf_range(70.0, 170.0), w._rng.randf_range(26.0, 52.0))

	# ── 冰河湖（Jackson Lake 式），主脈腳下的鏡面 ──
	for lp in [Vector3(-860, 0, -520), Vector3(-940, 0, -1120), Vector3(980, 0, -900)]:
		lake(t, m, lp, w._rng.randf_range(150.0, 240.0))

	# ── 橫跨峽谷的天然岩拱：可以從下面鑽過去 ──
	arch(t, m, Vector3(430, 0, -520), 300.0, 150.0)
	arch(t, m, Vector3(-400, 0, -980), 260.0, 130.0)

	w._build_forest(t, m, 420, -1050.0, 1050.0, -1800.0, -420.0)
	w._build_forest(t, m, 180, -1350.0, -900.0, -1700.0, -600.0)


#══════════════════════════════════════════════════════════════════════════════
#  所有地圖共用：把擴大後的外環填滿
#══════════════════════════════════════════════════════════════════════════════
## 舊版地圖的物件都擠在 ±1100 以內，地圖放大後外圈會空掉。
## 這裡在外環鋪一圈堤頓式巨峰，並在兩側各切一條峽谷航道，
## 讓「地形分布廣大 + 到處都能低空穿線」在每張圖都成立。
func outer_ranges(t: Node3D, m: Dictionary) -> void:
	var inner := 1250.0
	var outer := map_limit - 120.0

	# 外環巨峰：越外圈越高，形成天然的戰區邊界
	var count := 30
	for i in count:
		var a := TAU * float(i) / float(count) + 0.21
		var r: float = w._rng.randf_range(inner + 120.0, outer)
		var pos := Vector3(cos(a) * r, 0.0, sin(a) * r * 0.86 - 700.0)
		if absf(pos.x) > map_limit - 60.0 or absf(pos.z) > map_limit - 60.0:
			continue
		# 海上那半圈改成較低的岩島，不要在航艦前面長出高牆
		var at_sea: bool = not w.is_land(pos)
		var h: float = w._rng.randf_range(150.0, 260.0) if at_sea \
			else w._rng.randf_range(300.0, 460.0)
		var bw: float = w._rng.randf_range(200.0, 330.0)
		if w._in_corridor(pos, 220.0):
			continue
		w._rock(t, "cone", Vector3(bw, h, bw), Vector3(pos.x, h * 0.5, pos.z),
			m["cliff"] if not at_sea else m["rock"], true, w._rng.randf_range(0, TAU))
		if not at_sea:
			w.make_cyl(t, bw * 0.06, bw * 0.20, h * 0.26, Vector3(pos.x, h * 0.86, pos.z), m["snow"])
			w.make_sphere(t, 4.0, Vector3(pos.x, h + 4.0, pos.z),
				w.make_material(Color(0.72, 0.90, 1.0), 4.0))

	# 側翼的兩條峽谷航道（東、西各一），繞過中央主戰場
	canyon_run(t, m, [
		Vector3(-1500, 0, -300), Vector3(-1620, 0, -700), Vector3(-1480, 0, -1100),
		Vector3(-1600, 0, -1500),
	], 280.0, 170.0, false)
	canyon_run(t, m, [
		Vector3(1520, 0, -260), Vector3(1660, 0, -660), Vector3(1500, 0, -1060),
		Vector3(1640, 0, -1460),
	], 280.0, 170.0, false)


#══════════════════════════════════════════════════════════════════════════════
#  堤頓式巨峰：鋸齒稜線 + 雪冠 + 冰斗
#══════════════════════════════════════════════════════════════════════════════
func teton_range(t: Node3D, m: Dictionary, from: Vector3, to: Vector3,
		base_w: float, base_h: float) -> void:
	# 先用現成的山脊鏈長出山體，再往上疊真正高聳的主峰
	w._ridge_chain(t, m, from, to, base_w, base_h * 0.72, true)

	var span := to - from
	var length := span.length()
	var dir := span / maxf(length, 0.001)
	var side := Vector3(-dir.z, 0, dir.x)
	var peaks := int(maxf(4.0, length / (base_w * 1.45)))

	for i in peaks:
		var f := (float(i) + 0.5) / float(peaks)
		var n: float = w._noise.get_noise_2d(from.x + span.x * f, from.z + span.z * f)
		var pos: Vector3 = from + span * f + side * n * base_w * 0.7
		if w._in_corridor(pos, 200.0):
			continue
		var h: float = base_h * (0.82 + 0.34 * absf(n))
		var pw: float = base_w * (0.62 + 0.26 * absf(n))
		# 主峰：細長的錐體，比周圍山體高一截，遠看就是那道鋸齒天際線
		w._rock(t, "cone", Vector3(pw, h, pw), Vector3(pos.x, h * 0.5, pos.z),
			m["cliff"], true, w._rng.randf_range(0, TAU))
		# 雪冠 + 峰頂標記燈（夜戰導航）
		w.make_cyl(t, pw * 0.05, pw * 0.19, h * 0.30, Vector3(pos.x, h * 0.84, pos.z), m["snow"])
		w.make_sphere(t, 3.6, Vector3(pos.x, h + 3.0, pos.z),
			w.make_material(Color(0.80, 0.92, 1.0), 4.5))
		# 冰斗與碎石坡：主峰兩側的小峰，讓稜線不對稱
		for k in 2:
			var off: Vector3 = side * (1.0 if k == 0 else -1.0) * pw * 0.62 \
				+ dir * w._rng.randf_range(-0.3, 0.3) * pw
			var sh: float = h * w._rng.randf_range(0.42, 0.66)
			var sw: float = pw * w._rng.randf_range(0.44, 0.66)
			w._rock(t, "cone", Vector3(sw, sh, sw),
				Vector3(pos.x + off.x, sh * 0.5, pos.z + off.z),
				m["rock"] if k == 0 else m["shade"], false, w._rng.randf_range(0, TAU))
			if sh > base_h * 0.5:
				w.make_cyl(t, sw * 0.06, sw * 0.18, sh * 0.22,
					Vector3(pos.x + off.x, sh * 0.84, pos.z + off.z), m["snow"])


#══════════════════════════════════════════════════════════════════════════════
#  大峽谷：階狀岩壁夾出的深谷航道
#══════════════════════════════════════════════════════════════════════════════
## pts 是峽谷中線的控制點；width 是谷寬；depth 是岩壁高度。
## river = 谷底要不要鋪一條河。
func canyon_run(t: Node3D, m: Dictionary, pts: Array, width: float, depth: float,
		river: bool) -> void:
	if pts.size() < 2:
		return

	# ── 岩壁：階狀退縮的箱體，全部塞進一個 MultiMesh ──
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	mm.mesh = box

	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color.WHITE
	wall_mat.vertex_color_use_as_albedo = true
	wall_mat.metallic = 0.0
	wall_mat.roughness = 0.96
	wall_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mmi.material_override = wall_mat

	var rock_col: Color = (m["rock"] as StandardMaterial3D).albedo_color
	var shade_col: Color = (m["shade"] as StandardMaterial3D).albedo_color
	var sand_col: Color = (m["sand"] as StandardMaterial3D).albedo_color

	var xforms: Array = []
	var cols: Array = []
	var seg := 78.0
	const LAYERS := 5

	# 沿著中線以固定步距前進（控制點之間線性內插）
	var path: Array = _resample(pts, seg)
	for i in path.size():
		var p: Vector3 = path[i]
		var dir: Vector3 = Vector3.FORWARD
		if i + 1 < path.size():
			dir = (path[i + 1] - p).normalized()
		else:
			dir = (p - path[i - 1]).normalized()
		var side := Vector3(-dir.z, 0.0, dir.x)
		var yaw := atan2(dir.x, dir.z)

		# 谷壁略微蜿蜒，不要像水泥渠道
		var wob: float = w._noise.get_noise_2d(p.x * 1.4, p.z * 1.4) * width * 0.16

		for s in [-1.0, 1.0]:
			for k in LAYERS:
				var offset: float = width * 0.5 + wob * s + float(k) * (width * 0.11)
				var top: float = depth * (0.30 + 0.175 * float(k))
				var wpos: Vector3 = p + side * s * offset
				if w._in_corridor(wpos, 30.0):
					continue
				var sx: float = seg * 1.5
				var sz: float = width * 0.16 + seg * 0.25
				# 用三個基底軸直接組出「先旋轉再各軸縮放」的 Basis，
				# Basis.scaled() 是對世界軸縮放，套在轉過的箱體上會歪掉。
				var rot := Basis(Vector3.UP, yaw)
				var xf := Transform3D(
					Basis(rot.x * sz, rot.y * top, rot.z * sx),
					Vector3(wpos.x, land_y + top * 0.5, wpos.z))
				xforms.append(xf)
				# 由下往上：陰影 → 岩色 → 砂色，做出層積岩的水平色帶
				var f := float(k) / float(LAYERS - 1)
				var c: Color = shade_col.lerp(rock_col, minf(1.0, f * 1.6))
				if k >= LAYERS - 2:
					c = c.lerp(sand_col, 0.35)
				cols.append(c)

				# 只有最內側那層需要碰撞與 AI 高度圖：撞得到的就是這面牆
				if k == 0:
					if i % 2 == 0:
						w.add_static_box(t, Vector3(sz * 0.9, top, sx * 0.8), wpos + Vector3(0, land_y + top * 0.5, 0))
					w._stamp_height(wpos, width * 0.22, land_y + top)
				elif k == LAYERS - 1:
					# 谷緣也登記高度，AI 才知道整片高原都不能低飛
					w._stamp_height(wpos, width * 0.20, land_y + top)

		# 谷緣導航燈：夜戰時看得出峽谷走向（貼在最外層階地的頂面）
		if i % 3 == 0:
			for s2 in [-1.0, 1.0]:
				var lp: Vector3 = p + side * s2 * (width * 0.5 + width * 0.44)
				w.make_box(t, Vector3(10.0, 0.6, 1.2),
					Vector3(lp.x, land_y + depth + 0.6, lp.z), m["vein"])

		# 河：谷底的暗色水帶
		if river:
			w.make_box(t, Vector3(width * 0.34, 0.4, seg + 4.0),
				Vector3(p.x, land_y + 0.35, p.z),
				w.make_material(Color(0.05, 0.14, 0.22), 0.55))

	mm.instance_count = xforms.size()
	for i2 in xforms.size():
		mm.set_instance_transform(i2, xforms[i2])
		mm.set_instance_color(i2, cols[i2])
	mmi.multimesh = mm
	t.add_child(mmi)


## 短側溝：窄、淺，但夠飛進去躲鎖定
func slot_canyon(t: Node3D, m: Dictionary, from: Vector3, to: Vector3,
		width: float, depth: float) -> void:
	canyon_run(t, m, [from, from.lerp(to, 0.5), to], width, depth, false)


#══════════════════════════════════════════════════════════════════════════════
#  單體地形
#══════════════════════════════════════════════════════════════════════════════
## 石柱：細高的方柱 + 頂帽，谷底的地標
func spire(t: Node3D, m: Dictionary, pos: Vector3, h: float, r: float) -> void:
	w._rock(t, "box", Vector3(r, h, r * 0.86), Vector3(pos.x, land_y + h * 0.5, pos.z),
		m["rock"], true, w._rng.randf_range(0, TAU))
	w.make_cyl(t, r * 0.62, r * 0.54, h * 0.10, Vector3(pos.x, land_y + h * 1.02, pos.z),
		m["cliff"])
	# 水平層理
	for k in 3:
		w.make_box(t, Vector3(r * 1.06, 2.0, r * 0.92),
			Vector3(pos.x, land_y + h * (0.24 + k * 0.24), pos.z), m["shade"])


## 冰河湖：反光的水面 + 灘岸
func lake(t: Node3D, m: Dictionary, pos: Vector3, r: float) -> void:
	# w 是無型別的 GameWorld 參考，回傳值是 Variant，型別要自己寫清楚
	var water: StandardMaterial3D = w.make_material(Color(0.06, 0.20, 0.30), 0.85)
	water.metallic = 0.6
	water.roughness = 0.12
	w.make_cyl(t, r, r * 0.94, 1.2, Vector3(pos.x, land_y + 0.4, pos.z), water)
	w.make_cyl(t, r * 1.12, r * 1.06, 0.8, Vector3(pos.x, land_y + 0.1, pos.z), m["sand"])


## 天然岩拱：兩根柱子架一道橫梁，中間可以鑽過去
func arch(t: Node3D, m: Dictionary, pos: Vector3, span: float, h: float) -> void:
	var half := span * 0.5
	w._rock(t, "box", Vector3(46, h, 60), Vector3(pos.x - half, land_y + h * 0.5, pos.z),
		m["cliff"])
	w._rock(t, "box", Vector3(46, h, 60), Vector3(pos.x + half, land_y + h * 0.5, pos.z),
		m["cliff"])
	w._rock(t, "box", Vector3(span + 40.0, 34, 58), Vector3(pos.x, land_y + h + 17.0, pos.z),
		m["cliff"])
	w.make_box(t, Vector3(span, 0.6, 1.2), Vector3(pos.x, land_y + h + 34.5, pos.z), m["vein"])


#══════════════════════════════════════════════════════════════════════════════
#  工具
#══════════════════════════════════════════════════════════════════════════════
## 把控制點串成固定步距的路徑
func _resample(pts: Array, step: float) -> Array:
	var out: Array = []
	for i in pts.size() - 1:
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[i + 1]
		var d: float = a.distance_to(b)
		var n := int(maxf(1.0, d / step))
		for k in n:
			out.append(a.lerp(b, float(k) / float(n)))
	out.append(pts[pts.size() - 1])
	return out
