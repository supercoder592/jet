extends Node3D
#══════════════════════════════════════════════════════════════════════════════
#  EscortFleet.gd ─ 航母護航艦隊（進攻方）
#
#  兩艘驅逐艦 + 兩艘巡防艦，掛在航母節點底下 → 部署階段會跟著航母
#  一起破浪駛進作戰海域。每艘船有：
#    ‧ CIWS 近迫防空砲：短距離高射速，射線判定
#    ‧ 艦對空飛彈 SAM  ：中距離追蹤彈
#  形成航母周圍的防空火網。四艘船都是可被摧毀的建築物（房主權威裁決）。
#
#  註：刻意不宣告 class_name，由 GameWorld 以 load() 動態載入。
#══════════════════════════════════════════════════════════════════════════════

## 相對航母中心的站位。刻意全部落在 |x| > 140（避開彈射航道）
## 且距離航母中心 < 320（地形生成的淨空半徑內，不會跟島礁重疊）。
const LAYOUT := [
	{ "off": Vector3(-235, 0, 40),   "kind": "destroyer", "yaw": 0.05 },
	{ "off": Vector3(245, 0, 70),    "kind": "destroyer", "yaw": -0.04 },
	{ "off": Vector3(-160, 0, -230), "kind": "frigate",   "yaw": 0.09 },
	{ "off": Vector3(185, 0, -215),  "kind": "frigate",   "yaw": -0.07 },
]

const CIWS_RANGE := 430.0
const CIWS_ROF   := 0.38
const CIWS_DMG   := 5.0
const SAM_RANGE  := 900.0
const SAM_ROF    := 5.5
const SAM_DMG    := 26.0

var world: Node3D
var team: int = 0
var ships: Array = []      # [{ key, node, turrets, mast, ciws_cd, sam_cd }]


#══════════════════════════════════════════════════════════════════════════════
#  建構
#══════════════════════════════════════════════════════════════════════════════
func build(carrier: Node3D, t: int) -> void:
	team = t
	carrier.add_child(self)
	for i in LAYOUT.size():
		var e: Dictionary = LAYOUT[i]
		_make_ship(i, e["off"], String(e["kind"]), float(e["yaw"]))


func _make_ship(idx: int, off: Vector3, kind: String, yaw: float) -> void:
	var big: bool = (kind == "destroyer")
	var key := "ESCORT_%d" % idx
	var root := Node3D.new()
	root.name = key
	root.position = off
	root.rotation.y = yaw
	add_child(root)

	var col: Color = MainGame.C_ATK if team == MainGame.TEAM_ATTACKER else MainGame.C_DEF
	var hull := _mat(Color(0.105, 0.115, 0.140), 0.0, 0.7)
	var dark := _mat(Color(0.070, 0.078, 0.095), 0.0, 0.7)
	var deck := _mat(Color(0.135, 0.145, 0.170), 0.0, 0.8)
	var glow := _mat(col, 2.4)
	var warn := _mat(Color(1.0, 0.72, 0.15), 2.2)

	var L := 116.0 if big else 88.0        # 船長
	var W := 15.0 if big else 12.0         # 船寬

	# ── 船體：主體 + 逐段收窄的艦艏 + 方艉 ──
	_box(root, Vector3(W, 9.0, L * 0.72), Vector3(0, 4.5, L * 0.06), hull)
	for i in 4:
		var f := float(i) / 4.0
		_box(root, Vector3(W - f * (W * 0.72), 9.0 - f * 2.6, L * 0.09),
			Vector3(0, 4.5 - f * 1.0, -L * 0.32 - i * (L * 0.075)), hull)
	_box(root, Vector3(W * 0.92, 8.0, L * 0.12), Vector3(0, 4.0, L * 0.40), hull)
	_box(root, Vector3(W + 0.4, 2.6, L * 0.86), Vector3(0, 1.3, L * 0.02), dark)   # 吃水線

	# ── 主甲板 ──
	_box(root, Vector3(W + 0.6, 0.6, L * 0.92), Vector3(0, 9.2, 0), deck)
	for s in [-1.0, 1.0]:
		_box(root, Vector3(0.4, 1.4, L * 0.92), Vector3(s * (W * 0.5 + 0.2), 9.9, 0), dark)

	# ── 艦橋與上部結構 ──
	var br := Node3D.new()
	br.position = Vector3(0, 9.5, -L * 0.06)
	root.add_child(br)
	_box(br, Vector3(W * 0.72, 6.0, 20.0), Vector3(0, 3.0, 0), hull)
	_box(br, Vector3(W * 0.56, 4.4, 13.0), Vector3(0, 8.2, -1.5), hull)
	_box(br, Vector3(W * 0.60, 0.9, 13.4), Vector3(0, 9.6, -1.5), glow)     # 艦橋窗帶
	_box(br, Vector3(1.1, 16.0, 1.1), Vector3(0, 18.0, 3.0), dark)          # 主桅
	_box(br, Vector3(7.0, 0.5, 0.5), Vector3(0, 24.0, 3.0), dark)
	# 相位陣列雷達面（四面）
	for a in 4:
		var face := _box(br, Vector3(4.6, 4.6, 0.4), Vector3(0, 5.4, 0), glow)
		face.rotation.y = TAU * float(a) / 4.0
		face.position = Vector3(sin(TAU * float(a) / 4.0) * (W * 0.36),
			5.4, cos(TAU * float(a) / 4.0) * (W * 0.36))
	_sphere(br, 1.3, Vector3(0, 25.2, 3.0), _mat(Color(1.0, 0.30, 0.20), 5.0))

	# ── 煙囪 ──
	_box(root, Vector3(W * 0.34, 7.0, 7.0), Vector3(0, 13.0, L * 0.12), dark)
	_box(root, Vector3(W * 0.30, 0.6, 6.0), Vector3(0, 16.6, L * 0.12), warn)

	# ── 垂直發射系統 VLS：艦艏一塊格狀甲板 ──
	var vls := Node3D.new()
	vls.position = Vector3(0, 9.6, -L * 0.30)
	root.add_child(vls)
	for gx in 3:
		for gz in 4:
			_box(vls, Vector3(2.0, 0.3, 2.0),
				Vector3(-2.6 + gx * 2.6, 0, -3.9 + gz * 2.6),
				warn if (gx + gz) % 3 == 0 else deck)

	# ── CIWS 近迫防空砲塔：艏、艉各一 ──
	var turrets: Array = []
	for tz in [-L * 0.20, L * 0.30]:
		var mount := Node3D.new()
		mount.position = Vector3(0, 9.8, tz)
		root.add_child(mount)
		_cyl(mount, 2.0, 2.4, 1.8, Vector3(0, 0.9, 0), hull)
		var turret := Node3D.new()
		turret.position = Vector3(0, 2.1, 0)
		mount.add_child(turret)
		_sphere(turret, 1.5, Vector3.ZERO, hull)
		for bx in [-0.5, 0.5]:
			var barrel := _cyl(turret, 0.16, 0.16, 5.0, Vector3(bx, 0.3, -2.5), dark)
			barrel.rotation.x = PI * 0.5
		_sphere(turret, 0.45, Vector3(0, 0.9, -0.6), glow)   # 追蹤雷達球
		turrets.append(turret)

	# ── 艉部直升機甲板 ──
	_box(root, Vector3(W * 0.86, 0.3, 16.0), Vector3(0, 9.7, L * 0.38), deck)
	for i2 in 4:
		var ang := TAU * float(i2) / 4.0
		_box(root, Vector3(4.0, 0.34, 0.5),
			Vector3(sin(ang) * 4.0, 9.9, L * 0.38 + cos(ang) * 4.0), glow)

	# ── 航行燈 ──
	for i3 in 8:
		var lz := -L * 0.4 + i3 * (L * 0.11)
		for s2 in [-1.0, 1.0]:
			_box(root, Vector3(0.4, 0.4, 0.9), Vector3(s2 * (W * 0.5 + 0.3), 10.4, lz), warn)

	_build_wake(root, L, W)

	# 碰撞體（讓機槍與飛彈打得到），並登記成可摧毀的建築
	_static_box(root, Vector3(W + 1.0, 11.0, L * 0.94), Vector3(0, 5.0, 0))
	# 船在海上而且會跟著航母移動，不登記進地形高度圖（那是給 AI 避「地形」用的）
	if world != null:
		world._register_structure(key, root, team, "escort", 900.0 if big else 700.0)

	ships.append({
		"key": key, "node": root, "turrets": turrets,
		"ciws_cd": 0.0, "sam_cd": float(idx) * 1.3, "big": big,
	})


## 艦艏破浪 + 艦艉航跡
func _build_wake(root: Node3D, L: float, W: float) -> void:
	var foam := StandardMaterial3D.new()
	foam.albedo_color = Color(0.92, 0.97, 1.0, 0.30)
	foam.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	foam.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	foam.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	foam.emission_enabled = true
	foam.emission = Color(0.75, 0.90, 1.0)
	foam.emission_energy_multiplier = 1.4

	var quad := QuadMesh.new()
	quad.size = Vector2(3.0, 3.0)

	var bow := GPUParticles3D.new()
	bow.amount = 48
	bow.lifetime = 2.6
	bow.position = Vector3(0, 1.6, -L * 0.42)
	bow.draw_pass_1 = quad
	bow.material_override = foam
	var bm := ParticleProcessMaterial.new()
	bm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	bm.emission_box_extents = Vector3(W * 0.5, 0.6, 4.0)
	bm.direction = Vector3(0, 0.3, 1)
	bm.spread = 26.0
	bm.initial_velocity_min = 8.0
	bm.initial_velocity_max = 16.0
	bm.gravity = Vector3(0, -1.2, 0)
	bm.scale_min = 0.5
	bm.scale_max = 1.4
	bm.color = Color(1, 1, 1, 0.6)
	bow.process_material = bm
	root.add_child(bow)

	var stern := GPUParticles3D.new()
	stern.amount = 90
	stern.lifetime = 7.0
	stern.position = Vector3(0, 1.2, L * 0.46)
	stern.draw_pass_1 = quad
	stern.material_override = foam
	var sm := ParticleProcessMaterial.new()
	sm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	sm.emission_box_extents = Vector3(W * 0.45, 0.4, 2.0)
	sm.direction = Vector3(0, 0, 1)
	sm.spread = 10.0
	sm.initial_velocity_min = 5.0
	sm.initial_velocity_max = 11.0
	sm.gravity = Vector3.ZERO
	sm.scale_min = 0.8
	sm.scale_max = 2.4
	sm.color = Color(1, 1, 1, 0.42)
	stern.process_material = sm
	root.add_child(stern)


#══════════════════════════════════════════════════════════════════════════════
#  防空火網（只有房主跑，傷害與發射都由房主裁決後廣播）
#══════════════════════════════════════════════════════════════════════════════
func update_aa(delta: float) -> void:
	if world == null:
		return
	for sh in ships:
		var st: Dictionary = world.structures.get(String(sh["key"]), {})
		if st.is_empty() or float(st["hp"]) <= 0.0:
			continue

		var origin: Vector3 = (sh["node"] as Node3D).global_position + Vector3.UP * 12.0
		var target = _pick_target(origin, SAM_RANGE)
		sh["ciws_cd"] = float(sh["ciws_cd"]) - delta
		sh["sam_cd"] = float(sh["sam_cd"]) - delta
		if target == null:
			continue

		# 砲塔追瞄（視覺）
		for t in sh["turrets"]:
			var turret: Node3D = t
			var to: Vector3 = target.global_position - turret.global_position
			if to.length() > 1.0 and absf(to.normalized().dot(Vector3.UP)) < 0.97:
				turret.look_at(target.global_position, Vector3.UP)

		var d: float = origin.distance_to(target.global_position)

		# CIWS：近迫射線，連續壓制
		if d <= CIWS_RANGE and float(sh["ciws_cd"]) <= 0.0:
			sh["ciws_cd"] = CIWS_ROF
			var from: Vector3 = origin + Vector3.UP * 2.0
			world.request_damage(int(target.pilot_id), CIWS_DMG * world._dmg_mult(team), -9998)
			world._broadcast("cli_ship_ciws", [String(sh["key"]), from, target.global_position])

		# SAM：中距離追蹤彈。整支艦隊同時最多 4 發在空中 ─
		# 四艘船各自開火不設上限的話，玩家一進射程就會被飛彈牆蓋住。
		if d <= SAM_RANGE and d > 90.0 and float(sh["sam_cd"]) <= 0.0 \
				and int(world.active_sam_count(team)) < int(world.MAX_SAM_IN_FLIGHT):
			sh["sam_cd"] = SAM_ROF
			world._broadcast("cli_ship_sam", [String(sh["key"]), int(target.pilot_id)])


## 火網要打的目標：敵隊、活著、沒放干擾彈、不是貼地匿蹤的直升機
func _pick_target(origin: Vector3, max_d: float):
	var best = null
	var bd := max_d
	for pid in world.aircraft:
		var a = world.aircraft[pid]
		if not a.alive or int(a.team) == team:
			continue
		if a.flare_active > 0.0:
			continue
		if float(a.stats["radar"]) < 1.0 and a.global_position.y < 40.0:
			continue
		var d: float = origin.distance_to(a.global_position)
		if d < bd:
			best = a
			bd = d
	return best


## 被擊沉：船身傾斜下沉、防空停火
func sink(key: String) -> void:
	for sh in ships:
		if String(sh["key"]) != key:
			continue
		var n: Node3D = sh["node"]
		sh["ciws_cd"] = 1e9
		sh["sam_cd"] = 1e9
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(n, "position:y", -14.0, 6.0)
		tw.tween_property(n, "rotation:z", 0.5, 6.0)
		return


#══════════════════════════════════════════════════════════════════════════════
#  小工具
#══════════════════════════════════════════════════════════════════════════════
func _mat(col: Color, emit: float = 0.0, rough: float = 0.6) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = 0.25
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
