extends Node3D
#══════════════════════════════════════════════════════════════════════════════
#  GroundForces.gd ─ 陸軍
#
#  設計原則：陸軍是「空戰的地景與壓力來源」，不是可玩兵種。
#  三種角色：
#    ‧ 高射砲陣地 AAA   ─ 固定，短距離高射速，逼你不敢貼著基地低飛
#    ‧ 機動防空車 SAM   ─ 沿路線移動，中距離追蹤彈，打完會換位置
#    ‧ 補給車隊 CONVOY  ─ 從內陸開往跑道，抵達就補滿防守方彈藥；
#                          被打光則進攻方得點、防空塔射速下降
#  另外還有純視覺的地勤載具（拖車、油罐車、地勤人員）。
#
#  移動一律用 match_time 推算，所有客戶端算出來的位置完全一致，不需要同步封包。
#  受損與摧毀走現成的 structures 裁決（房主權威）。
#
#  註：刻意不宣告 class_name，由 GameWorld 以 load() 動態載入。
#══════════════════════════════════════════════════════════════════════════════

## 陸軍的火力刻意偏弱：它們的價值是「逼你改變航線」，不是「把你打下來」。
## 高射砲只守低空（260 m 以下），拉高就完全打不到你。
const AAA_RANGE   := 380.0
const AAA_ROF     := 2.20
const AAA_DMG     := 4.0
const AAA_CEILING := 200.0        # 高射砲打不到這個高度以上（拉高就安全）

const SAM_RANGE   := 640.0
const SAM_ROF     := 9.0
const SAM_DMG     := 18.0

const TRUCK_SPEED := 13.0
const WAVE_GAP    := 150.0        # 每隔多久出一波車隊
const WAVE_START  := 30.0         # 第一波在開戰後幾秒出發

var w                             # GameWorld
var land_y: float = 8.0
var runway_pos := Vector3(0, 0, -760)
var nuke_pos := Vector3(140, 0, -900)

var units: Array = []             # [{ key, node, kind, turret, cd }]
var convoy: Array = []            # [{ key, node, offset }]
var convoy_path: Array = []
var convoy_len: float = 0.0
var wave: int = -1
var wave_reported: bool = false


#══════════════════════════════════════════════════════════════════════════════
#  建構
#══════════════════════════════════════════════════════════════════════════════
func build(t: Node3D, m: Dictionary) -> void:
	t.add_child(self)

	# ── 高射砲陣地：跑道與核設施周圍 ──
	var aaa_spots := [
		runway_pos + Vector3(-120, 0, 150),
		runway_pos + Vector3(130, 0, -170),
		nuke_pos + Vector3(-150, 0, 90),
		nuke_pos + Vector3(160, 0, -60),
	]
	for i in aaa_spots.size():
		_make_aaa(i, aaa_spots[i])

	# ── 機動防空車：兩條巡邏路線 ──
	_make_sam(0, [
		runway_pos + Vector3(-420, 0, -120), runway_pos + Vector3(-260, 0, 260),
		runway_pos + Vector3(180, 0, 300), runway_pos + Vector3(320, 0, -80),
	])
	_make_sam(1, [
		nuke_pos + Vector3(320, 0, 180), nuke_pos + Vector3(120, 0, -260),
		nuke_pos + Vector3(-280, 0, -180), nuke_pos + Vector3(-160, 0, 220),
	])

	# ── 補給車隊路線：內陸 → 跑道 ──
	convoy_path = [
		Vector3(760, 0, -1560), Vector3(520, 0, -1280), Vector3(300, 0, -1050),
		Vector3(120, 0, -900), runway_pos + Vector3(70, 0, -30),
	]
	convoy_len = 0.0
	for i2 in convoy_path.size() - 1:
		convoy_len += convoy_path[i2].distance_to(convoy_path[i2 + 1])

	# ── 地勤：跑道旁與航艦甲板上的雜物，純視覺 ──
	_ground_crew(m)


## 高射砲：底座 + 可轉的雙管
func _make_aaa(idx: int, pos: Vector3) -> void:
	var key := "AAA_%d" % idx
	var root := Node3D.new()
	root.name = key
	root.position = Vector3(pos.x, _floor_at(pos), pos.z)
	add_child(root)

	var body: StandardMaterial3D = _mat(Color(0.16, 0.18, 0.15))
	var dark: StandardMaterial3D = _mat(Color(0.09, 0.10, 0.09))
	var glow: StandardMaterial3D = _mat(MainGame.C_DEF, 1.6)

	# 沙包工事
	for a in 8:
		var ang := TAU * float(a) / 8.0
		_box(root, Vector3(3.2, 1.5, 1.6), Vector3(cos(ang) * 5.4, 0.75, sin(ang) * 5.4), dark) \
			.rotation.y = -ang
	_cyl(root, 3.0, 3.4, 1.2, Vector3(0, 0.6, 0), body)

	var turret := Node3D.new()
	turret.position = Vector3(0, 1.6, 0)
	root.add_child(turret)
	_box(turret, Vector3(2.4, 1.4, 2.8), Vector3.ZERO, body)
	for s in [-0.5, 0.5]:
		var barrel := _cyl(turret, 0.16, 0.20, 5.0, Vector3(s, 0.5, -2.4), dark)
		barrel.rotation_degrees.x = 90
	_sphere(turret, 0.5, Vector3(0, 1.1, 0.4), glow)      # 射控雷達

	_static_box(root, Vector3(7.0, 3.2, 7.0), Vector3(0, 1.6, 0))
	if w != null:
		w._register_structure(key, root, MainGame.TEAM_DEFENDER, "aaa", 160.0)
		w._stamp_height(root.position, 8.0, root.position.y + 3.5)
	units.append({ "key": key, "node": root, "kind": "aaa", "turret": turret, "cd": 0.0,
		"path": [], "speed": 0.0 })


## 機動防空車：車體 + 可豎起的發射箱，沿巡邏路線移動
func _make_sam(idx: int, path: Array) -> void:
	var key := "SAM_%d" % idx
	var root := Node3D.new()
	root.name = key
	add_child(root)

	var body: StandardMaterial3D = _mat(Color(0.17, 0.19, 0.16))
	var dark: StandardMaterial3D = _mat(Color(0.08, 0.09, 0.08))
	var warn: StandardMaterial3D = _mat(Color(1.0, 0.55, 0.15), 1.4)

	_box(root, Vector3(3.4, 1.6, 8.4), Vector3(0, 1.6, 0), body)          # 底盤
	_box(root, Vector3(3.0, 1.8, 2.6), Vector3(0, 3.2, -2.4), body)       # 駕駛室
	_box(root, Vector3(2.8, 0.3, 2.2), Vector3(0, 4.2, -2.4), dark)
	for s in [-1.0, 1.0]:
		for k in 3:
			_cyl(root, 0.5, 0.5, 1.4, Vector3(s * 1.4, 0.8, -3.0 + k * 2.8), dark) \
				.rotation.z = PI * 0.5

	var turret := Node3D.new()
	turret.position = Vector3(0, 2.6, 1.4)
	root.add_child(turret)
	var rack := _box(turret, Vector3(2.6, 1.2, 4.4), Vector3(0, 0.6, 0), body)
	rack.rotation_degrees.x = -22.0                                      # 發射箱仰角
	for s2 in [-0.7, 0.7]:
		var tube := _box(turret, Vector3(0.7, 0.7, 4.6), Vector3(s2, 0.9, 0), dark)
		tube.rotation_degrees.x = -22.0
	_sphere(turret, 0.45, Vector3(0, 1.6, -1.6), warn)

	_static_box(root, Vector3(4.0, 4.0, 9.0), Vector3(0, 2.0, 0))
	if w != null:
		w._register_structure(key, root, MainGame.TEAM_DEFENDER, "sam", 200.0)
	units.append({ "key": key, "node": root, "kind": "sam", "turret": turret,
		"cd": float(idx) * 2.0, "path": path, "speed": 9.0 })


## 補給卡車（每一波重新生成）
func _spawn_convoy(index: int) -> void:
	for e in convoy:
		if is_instance_valid(e["node"]):
			(e["node"] as Node3D).queue_free()
		if w != null:
			w.structures.erase(String(e["key"]))
	convoy.clear()

	var body: StandardMaterial3D = _mat(Color(0.19, 0.21, 0.16))
	var dark: StandardMaterial3D = _mat(Color(0.08, 0.09, 0.08))
	var canvas: StandardMaterial3D = _mat(Color(0.28, 0.28, 0.22))

	for i in 5:
		var key := "CONVOY_%d_%d" % [index, i]
		var root := Node3D.new()
		root.name = key
		add_child(root)
		_box(root, Vector3(2.6, 1.4, 3.0), Vector3(0, 1.9, -2.6), body)     # 駕駛室
		_box(root, Vector3(2.4, 0.4, 3.0), Vector3(0, 2.7, -2.6), dark)
		_box(root, Vector3(2.8, 2.2, 5.4), Vector3(0, 2.3, 1.4), canvas)    # 篷布貨廂
		_box(root, Vector3(3.0, 0.5, 5.6), Vector3(0, 1.2, 1.4), body)
		for s in [-1.3, 1.3]:
			for k in 3:
				_cyl(root, 0.6, 0.6, 0.5, Vector3(s, 0.6, -2.4 + k * 2.4), dark) \
					.rotation.z = PI * 0.5
		_static_box(root, Vector3(3.2, 3.4, 9.0), Vector3(0, 1.8, 0))
		if w != null:
			w._register_structure(key, root, MainGame.TEAM_DEFENDER, "convoy", 90.0)
		convoy.append({ "key": key, "node": root, "offset": float(i) * 26.0 })


## 地勤：跑道旁與甲板上的拖車、油罐車、人員（純視覺，不可摧毀）
func _ground_crew(m: Dictionary) -> void:
	var body: StandardMaterial3D = _mat(Color(0.20, 0.22, 0.24))
	var yellow: StandardMaterial3D = _mat(Color(0.85, 0.66, 0.12))
	var vest: StandardMaterial3D = _mat(Color(1.0, 0.55, 0.10), 0.8)
	var dark: StandardMaterial3D = _mat(Color(0.08, 0.09, 0.10))

	var spots := [
		runway_pos + Vector3(-70, 0, 60), runway_pos + Vector3(-88, 0, 96),
		runway_pos + Vector3(96, 0, -40), runway_pos + Vector3(64, 0, 120),
	]
	for i in spots.size():
		var p: Vector3 = spots[i]
		var n := Node3D.new()
		n.position = Vector3(p.x, _floor_at(p), p.z)
		n.rotation.y = float(i) * 1.1
		add_child(n)
		if i % 2 == 0:
			# 牽引車
			_box(n, Vector3(2.0, 1.0, 3.4), Vector3(0, 0.9, 0), yellow)
			_box(n, Vector3(1.8, 0.9, 1.4), Vector3(0, 1.8, -0.8), dark)
		else:
			# 油罐車
			_box(n, Vector3(2.2, 1.0, 2.4), Vector3(0, 1.0, -2.6), body)
			_cyl(n, 1.3, 1.3, 5.0, Vector3(0, 2.0, 0.8), yellow).rotation.x = PI * 0.5
		for s in [-0.9, 0.9]:
			_cyl(n, 0.5, 0.5, 0.4, Vector3(s, 0.5, -1.4), dark).rotation.z = PI * 0.5
			_cyl(n, 0.5, 0.5, 0.4, Vector3(s, 0.5, 1.4), dark).rotation.z = PI * 0.5
		# 旁邊站兩個地勤
		for k in 2:
			var g := Node3D.new()
			g.position = Vector3(3.0 + k * 1.6, 0, 1.2)
			n.add_child(g)
			_box(g, Vector3(0.5, 0.9, 0.35), Vector3(0, 1.35, 0), vest)
			_box(g, Vector3(0.35, 0.7, 0.3), Vector3(0, 0.45, 0), dark)
			_sphere(g, 0.22, Vector3(0, 1.95, 0), yellow)


#══════════════════════════════════════════════════════════════════════════════
#  每幀更新
#══════════════════════════════════════════════════════════════════════════════
func update(delta: float, match_time: float, is_host: bool) -> void:
	if w == null:
		return
	_update_convoy(match_time, is_host)
	_update_vehicles(match_time)
	_update_fire(delta, is_host)


## 車隊沿路線前進；位置直接由 match_time 推算，所有客戶端一致
func _update_convoy(match_time: float, is_host: bool) -> void:
	var idx := int(floor((match_time - WAVE_START) / WAVE_GAP))
	if idx < 0:
		return
	if idx != wave:
		wave = idx
		wave_reported = false
		_spawn_convoy(idx)
		if w._mg().my_team() == MainGame.TEAM_DEFENDER:
			w.officer_say("補給車隊已經出發，護送它到跑道。", "order", 3)
		else:
			w.officer_say("敵方補給車隊在內陸公路上 ─ 有餘力就順手拆了。", "calm", 2)

	var travelled: float = (match_time - WAVE_START - float(idx) * WAVE_GAP) * TRUCK_SPEED
	var alive := 0
	var arrived := 0
	for e in convoy:
		var node: Node3D = e["node"]
		if not is_instance_valid(node):
			continue
		var st: Dictionary = w.structures.get(String(e["key"]), {})
		if st.is_empty() or float(st["hp"]) <= 0.0:
			continue
		alive += 1
		var d: float = travelled - float(e["offset"])
		if d < 0.0:
			node.visible = false
			continue
		node.visible = true
		if d >= convoy_len:
			arrived += 1
			node.visible = false
			continue
		var p := _sample_path(convoy_path, d)
		var p2 := _sample_path(convoy_path, minf(d + 6.0, convoy_len))
		node.position = Vector3(p.x, _floor_at(p), p.z)
		if p2.distance_to(p) > 0.5:
			node.rotation.y = atan2(p2.x - p.x, p2.z - p.z)

	# 結算：全部抵達 → 防守方補給；全部被打掉 → 進攻方得利
	if not wave_reported and is_host and travelled > convoy_len + 20.0:
		wave_reported = true
		if arrived > 0:
			w._broadcast("cli_convoy_result", [true, arrived])
		else:
			w._broadcast("cli_convoy_result", [false, 0])


## 防空車沿巡邏路線繞圈
func _update_vehicles(match_time: float) -> void:
	for u in units:
		if String(u["kind"]) != "sam":
			continue
		var st: Dictionary = w.structures.get(String(u["key"]), {})
		if st.is_empty() or float(st["hp"]) <= 0.0:
			continue
		var path: Array = u["path"]
		if path.size() < 2:
			continue
		var total := 0.0
		for i in path.size():
			total += path[i].distance_to(path[(i + 1) % path.size()])
		var d: float = fmod(match_time * float(u["speed"]), total)
		var p := _sample_loop(path, d)
		var p2 := _sample_loop(path, fmod(d + 8.0, total))
		var node: Node3D = u["node"]
		node.position = Vector3(p.x, _floor_at(p), p.z)
		if p2.distance_to(p) > 0.5:
			node.rotation.y = atan2(p2.x - p.x, p2.z - p.z)


## 高射砲與防空車開火（房主裁決）
func _update_fire(delta: float, is_host: bool) -> void:
	for u in units:
		var key := String(u["key"])
		var st: Dictionary = w.structures.get(key, {})
		if st.is_empty() or float(st["hp"]) <= 0.0:
			continue
		var node: Node3D = u["node"]
		var kind := String(u["kind"])
		var rng: float = AAA_RANGE if kind == "aaa" else SAM_RANGE
		var origin: Vector3 = node.global_position + Vector3.UP * 3.0
		var target = _pick_target(origin, rng, kind == "aaa")
		u["cd"] = float(u["cd"]) - delta
		if target == null:
			continue

		# 砲塔追瞄（純視覺，各端各自算）
		var turret: Node3D = u["turret"]
		var to: Vector3 = target.global_position - turret.global_position
		if to.length() > 1.0 and absf(to.normalized().dot(Vector3.UP)) < 0.97:
			turret.look_at(target.global_position, Vector3.UP)

		if not is_host or float(u["cd"]) > 0.0:
			continue

		# 地面防空集火上限：同一台飛機同時最多被 2 個地面系統打
		if not bool(w.aa_can_fire(int(target.pilot_id))):
			continue

		if kind == "aaa":
			u["cd"] = AAA_ROF
			w.request_damage(int(target.pilot_id), AAA_DMG, -9997)
			w._broadcast("cli_flak_burst", [target.global_position])
		else:
			# 防空飛彈同時最多 4 發在空中（跟護航艦、防空塔共用上限）
			if int(w.active_sam_count(MainGame.TEAM_DEFENDER)) >= int(w.MAX_SAM_IN_FLIGHT):
				continue
			u["cd"] = SAM_ROF
			w._broadcast("cli_ground_sam", [key, int(target.pilot_id)])


## 找一架進攻方的飛機當目標
func _pick_target(origin: Vector3, max_d: float, need_low: bool):
	var best = null
	var bd := max_d
	for pid in w.aircraft:
		var a = w.aircraft[pid]
		if not a.alive or int(a.team) != MainGame.TEAM_ATTACKER:
			continue
		if a.flare_active > 0.0:
			continue
		if need_low and a.global_position.y > AAA_CEILING:
			continue
		var d: float = origin.distance_to(a.global_position)
		if d < bd:
			best = a
			bd = d
	return best


#══════════════════════════════════════════════════════════════════════════════
#  工具
#══════════════════════════════════════════════════════════════════════════════
## 沿折線取樣（不循環）
func _sample_path(path: Array, dist: float) -> Vector3:
	var left := dist
	for i in path.size() - 1:
		var a: Vector3 = path[i]
		var b: Vector3 = path[i + 1]
		var seg := a.distance_to(b)
		if left <= seg:
			return a.lerp(b, left / maxf(seg, 0.001))
		left -= seg
	return path[path.size() - 1]


## 沿折線取樣（首尾相連的巡邏圈）
func _sample_loop(path: Array, dist: float) -> Vector3:
	var left := dist
	for i in path.size():
		var a: Vector3 = path[i]
		var b: Vector3 = path[(i + 1) % path.size()]
		var seg := a.distance_to(b)
		if left <= seg:
			return a.lerp(b, left / maxf(seg, 0.001))
		left -= seg
	return path[0]


## 車輛貼地高度。高度圖記的是「該格最高的障礙物」，直接拿來用的話
## 車子會爬上台地或大樓頂端浮在半空，所以只跟隨小起伏，超過就當作平地。
func _floor_at(p: Vector3) -> float:
	if w == null:
		return land_y
	var h := float(w.terrain_height(p))
	if h > land_y + 12.0:
		h = land_y
	return maxf(h, land_y) + 0.2


func _mat(col: Color, emit: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = 0.15
	m.roughness = 0.85
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


func _static_box(parent: Node3D, size: Vector3, pos: Vector3) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.position = pos
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	sb.add_child(cs)
	parent.add_child(sb)
	return sb
