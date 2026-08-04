extends Node3D
#══════════════════════════════════════════════════════════════════════════════
#  Hangar3D.gd ─ 3D 停機棚
#
#  兩種用法（同一份場景建構程式）：
#    mode = "hangar" ─ 主選單背景：整座停機棚，中央轉盤上放玩家目前選用的戰機
#    mode = "stand"  ─ 商店 3D 預覽：放進 SubViewport 的小型展示台
#
#  註：刻意不宣告 class_name，由 MainGame 以 load() 動態載入。
#══════════════════════════════════════════════════════════════════════════════

const TURN_Y := 0.9        # 轉盤頂面高度：飛機停在這個平面上

var mode: String = "hangar"
var spin_speed: float = 0.22
var orbit_speed: float = 0.09

var cam: Camera3D
var turntable: Node3D
var plane_root: Node3D
var _mesher
var _spin: float = 0.0
var _orbit: float = 0.55
var _vtype: int = -1
var _rotor: Node3D = null
var _rng := RandomNumberGenerator.new()


#══════════════════════════════════════════════════════════════════════════════
#  建構
#══════════════════════════════════════════════════════════════════════════════
func build(m: String = "hangar") -> void:
	mode = m
	_rng.seed = 90210
	_mesher = load("res://AircraftMesh.gd").new()

	_build_environment()
	_build_shell()
	_build_turntable()
	if mode == "hangar":
		_build_props()
	_build_camera()


func _build_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.020, 0.028, 0.042)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.36, 0.44, 0.58)
	env.ambient_light_energy = 0.55
	env.glow_enabled = true
	env.glow_strength = 1.0
	env.glow_bloom = 0.22
	env.glow_intensity = 0.75
	env.glow_hdr_threshold = 0.85
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.07, 0.11)
	env.fog_density = 0.0075
	we.environment = env
	add_child(we)

	# 由棚門斜射進來的主光，讓機身有明確的明暗面
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-32, 152, 0)
	sun.light_color = Color(0.72, 0.82, 1.00)
	sun.light_energy = 1.15
	sun.shadow_enabled = (mode == "hangar")
	add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-14, -38, 0)
	fill.light_color = Color(1.00, 0.72, 0.42)
	fill.light_energy = 0.45
	add_child(fill)


## 棚體：地板、後牆、側牆、屋頂桁架、天花板燈
func _build_shell() -> void:
	var floor_mat := _mat(Color(0.085, 0.092, 0.108), 0.0, 0.92)
	var wall := _mat(Color(0.105, 0.115, 0.135), 0.0, 0.85)
	var rib := _mat(Color(0.135, 0.148, 0.172), 0.0, 0.7)
	var line := _emit(Color(0.95, 0.78, 0.25), 1.6)
	var cool := _emit(MainGame.C_DEF, 2.2)

	var w := 46.0 if mode == "hangar" else 26.0
	var d := 54.0 if mode == "hangar" else 30.0
	var h := 17.0 if mode == "hangar" else 12.0

	# 地板 + 髒污色塊，避免大片純色看起來像塑膠
	_box(self, Vector3(w, 0.6, d), Vector3(0, -0.3, 0), floor_mat)
	for i in (14 if mode == "hangar" else 6):
		var sx := _rng.randf_range(-w * 0.45, w * 0.45)
		var sz := _rng.randf_range(-d * 0.45, d * 0.45)
		_box(self, Vector3(_rng.randf_range(3.0, 9.0), 0.02, _rng.randf_range(3.0, 9.0)),
			Vector3(sx, 0.02, sz), _mat(Color(0.065, 0.072, 0.086), 0.0, 0.95))

	# 地面導引標線（黃色）：中央線 + 停機十字
	_box(self, Vector3(0.4, 0.03, d * 0.9), Vector3(0, 0.04, 0), line)
	_box(self, Vector3(w * 0.5, 0.03, 0.4), Vector3(0, 0.04, -6.0), line)
	for sx2 in [-1.0, 1.0]:
		_box(self, Vector3(0.3, 0.03, 8.0), Vector3(sx2 * 9.0, 0.04, 4.0), line)

	# 後牆與側牆（用縱向肋條做出鐵皮感）
	_box(self, Vector3(w, h, 0.8), Vector3(0, h * 0.5, -d * 0.5), wall)
	for i in int(w / 3.0):
		var x := -w * 0.5 + 1.5 + i * 3.0
		_box(self, Vector3(0.35, h, 0.35), Vector3(x, h * 0.5, -d * 0.5 + 0.6), rib)
	for s in [-1.0, 1.0]:
		_box(self, Vector3(0.8, h, d), Vector3(s * w * 0.5, h * 0.5, 0), wall)
		for j in int(d / 4.0):
			var z := -d * 0.5 + 2.0 + j * 4.0
			_box(self, Vector3(0.35, h, 0.35), Vector3(s * (w * 0.5 - 0.6), h * 0.5, z), rib)

	# 屋頂：主樑 + 交錯桁架
	for j2 in int(d / 6.0) + 1:
		var z2 := -d * 0.5 + j2 * 6.0
		_box(self, Vector3(w, 0.5, 0.5), Vector3(0, h, z2), rib)
		for k in 4:
			var beam := _box(self, Vector3(0.28, 0.28, 7.0),
				Vector3(-w * 0.35 + k * (w * 0.23), h - 1.4, z2), rib)
			beam.rotation.x = deg_to_rad(38.0 if k % 2 == 0 else -38.0)
	_box(self, Vector3(w, 0.6, d), Vector3(0, h + 0.6, 0), wall)

	# 天花板燈：發光燈條 + 實際光源
	var lamps := 4 if mode == "hangar" else 2
	for i2 in lamps:
		var lz := -d * 0.34 + i2 * (d * 0.22)
		for s2 in [-1.0, 1.0]:
			_box(self, Vector3(6.0, 0.3, 1.2), Vector3(s2 * w * 0.22, h - 1.0, lz),
				_emit(Color(0.92, 0.96, 1.00), 3.2))
			var om := OmniLight3D.new()
			om.position = Vector3(s2 * w * 0.22, h - 2.0, lz)
			om.light_color = Color(0.86, 0.92, 1.0)
			om.light_energy = 2.4
			om.omni_range = 34.0
			add_child(om)

	# 棚門框：前緣的門柱與滑軌，暗示外面是夜間停機坪
	_box(self, Vector3(w, 1.2, 1.0), Vector3(0, h - 0.6, d * 0.5), rib)
	for s3 in [-1.0, 1.0]:
		_box(self, Vector3(1.6, h, 1.2), Vector3(s3 * (w * 0.5 - 1.0), h * 0.5, d * 0.5), rib)
		_box(self, Vector3(0.6, h * 0.9, 0.3), Vector3(s3 * (w * 0.5 - 2.2), h * 0.45, d * 0.5 - 0.8), cool)

	# 後牆隊徽：只用發光橫條，不放 Label3D。
	# （3D 文字會穿過半透明的 UI 底、跟選單文字疊在一起，變得兩邊都看不清楚。）
	if mode == "hangar":
		var badge := Node3D.new()
		badge.position = Vector3(0, h * 0.52, -d * 0.5 + 1.0)
		add_child(badge)
		_box(badge, Vector3(16.0, 0.30, 0.2), Vector3(0, -1.6, 0), cool)
		_box(badge, Vector3(10.0, 0.30, 0.2), Vector3(0, 1.6, 0), cool)
		for i in 5:
			_box(badge, Vector3(0.5, 2.6, 0.2), Vector3(-4.0 + i * 2.0, 0, 0),
				_emit(MainGame.C_ATK, 1.2))


## 中央轉盤：飛機站在上面慢慢轉
func _build_turntable() -> void:
	turntable = Node3D.new()
	add_child(turntable)

	var plate := _mat(Color(0.13, 0.14, 0.17), 0.0, 0.6)
	var r := 11.0 if mode == "hangar" else 9.0
	_cyl(self, r, r, 0.5, Vector3(0, 0.25, 0), plate)
	_cyl(self, r * 0.96, r * 0.96, 0.14, Vector3(0, TURN_Y - 0.35, 0),
		_emit(MainGame.C_DEF, 0.9))
	# 轉盤刻度：轉起來才看得出在動
	for i in 24:
		var a := TAU * float(i) / 24.0
		var tick := _box(turntable, Vector3(0.22, 0.06, 1.5),
			Vector3(cos(a) * (r - 1.2), TURN_Y - 0.28, sin(a) * (r - 1.2)),
			_emit(Color(0.95, 0.80, 0.30), 1.4))
		tick.rotation.y = -a

	plane_root = Node3D.new()
	plane_root.position = Vector3(0, TURN_Y + 0.1, 0)
	turntable.add_child(plane_root)

	# 機腹下方的補光，讓機體不會整台沉在陰影裡
	var up := OmniLight3D.new()
	up.position = Vector3(0, TURN_Y + 0.6, 0)
	up.light_color = MainGame.C_DEF
	up.light_energy = 1.6
	up.omni_range = 18.0
	add_child(up)
	# 機種名稱由 UI 顯示，這裡不放 Label3D ─ 3D 文字會跟前面的選單文字疊在一起


## 停機棚裡的雜物：飛彈推車、油桶、梯子、工具箱、三角錐
func _build_props() -> void:
	var metal := _mat(Color(0.16, 0.17, 0.20), 0.0, 0.55)
	var rust := _mat(Color(0.30, 0.18, 0.11), 0.0, 0.8)
	var cone := _emit(Color(1.0, 0.42, 0.12), 1.2)
	var glassy := _emit(MainGame.C_ATK, 1.6)

	# 飛彈推車 ×2
	for s in [-1.0, 1.0]:
		var cart := Node3D.new()
		cart.position = Vector3(s * 17.0, 0, -6.0)
		add_child(cart)
		_box(cart, Vector3(2.4, 0.4, 6.0), Vector3(0, 1.0, 0), metal)
		for wz in [-2.2, 2.2]:
			for wx in [-1.0, 1.0]:
				var wheel := _cyl(cart, 0.4, 0.4, 0.3, Vector3(wx, 0.4, wz), metal)
				wheel.rotation.z = PI * 0.5
		for i in 3:
			var msl := _cyl(cart, 0.22, 0.22, 4.4, Vector3(-0.7 + i * 0.7, 1.5, 0), metal)
			msl.rotation.x = PI * 0.5
			_sphere(cart, 0.28, Vector3(-0.7 + i * 0.7, 1.5, -2.3), glassy)

	# 油桶群
	for i2 in 7:
		var bx := _rng.randf_range(-20.0, 20.0)
		var bz := _rng.randf_range(-22.0, 20.0)
		if absf(bx) < 13.0 and absf(bz) < 13.0:
			continue
		_cyl(self, 0.8, 0.8, 2.2, Vector3(bx, 1.1, bz), rust if i2 % 2 == 0 else metal)
		_cyl(self, 0.85, 0.85, 0.12, Vector3(bx, 2.25, bz), cone)

	# 工作梯
	var lad := Node3D.new()
	lad.position = Vector3(9.5, 0, 5.0)
	lad.rotation.y = -0.5
	add_child(lad)
	for s2 in [-0.6, 0.6]:
		var rail := _box(lad, Vector3(0.14, 5.4, 0.14), Vector3(s2, 2.7, 0), metal)
		rail.rotation.x = 0.16
	for i3 in 6:
		_box(lad, Vector3(1.3, 0.1, 0.4), Vector3(0, 0.7 + i3 * 0.8, -0.12 * i3), metal)
	_box(lad, Vector3(1.6, 0.12, 1.6), Vector3(0, 5.4, -0.75), metal)

	# 工具箱與三角錐
	for i4 in 4:
		var tx := -14.0 + i4 * 9.0
		_box(self, Vector3(1.6, 1.0, 0.9), Vector3(tx, 0.5, 18.0), metal)
		_box(self, Vector3(1.7, 0.12, 1.0), Vector3(tx, 1.06, 18.0), cone)
	for i5 in 6:
		var a2 := TAU * float(i5) / 6.0
		var pos := Vector3(cos(a2) * 14.5, 0.0, sin(a2) * 14.5)
		_cyl(self, 0.05, 0.45, 1.0, pos + Vector3(0, 0.5, 0), cone)
		_box(self, Vector3(1.0, 0.06, 1.0), pos + Vector3(0, 0.03, 0), cone)

	# 掛在牆上的隊旗
	for s3 in [-1.0, 1.0]:
		_box(self, Vector3(0.2, 5.0, 3.4), Vector3(s3 * 22.0, 9.0, -12.0),
			_emit(MainGame.C_ATK if s3 < 0.0 else MainGame.C_DEF, 0.8))


func _build_camera() -> void:
	cam = Camera3D.new()
	cam.fov = 46.0 if mode == "hangar" else 40.0
	cam.far = 400.0
	cam.current = true
	add_child(cam)
	_place_camera(0.0)


#══════════════════════════════════════════════════════════════════════════════
#  展示機
#══════════════════════════════════════════════════════════════════════════════
## 換機種或換塗裝時呼叫；重建 plane_root 底下的模型
func set_aircraft(vtype: int, base_col: Color, team_col: Color, label: String = "") -> void:
	_vtype = vtype
	_rotor = null
	for c in plane_root.get_children():
		c.queue_free()
	# 外層負責縮放與置中，內層才是機體本身
	var holder := Node3D.new()
	plane_root.add_child(holder)
	var pivot := Node3D.new()
	holder.add_child(pivot)
	# 機首朝棚門（+Z 是鏡頭那側，機首朝 -Z 會背對玩家）→ 轉半圈
	pivot.rotation.y = PI
	# skin_col：外部 .glb 也要吃塗裝色，否則商店換色在預覽上看不出來
	var r: Dictionary = _mesher.build(pivot, vtype, base_col, team_col,
		{ "emul": 0.55, "skin_col": base_col })
	_rotor = r.get("rotor")

	# 起落架：讓飛機看起來是停著而不是浮著
	if r.get("rotor") == null:
		var gear := _mat(Color(0.09, 0.10, 0.12), 0.0, 0.6)
		for off in [Vector3(-1.6, -1.4, 1.2), Vector3(1.6, -1.4, 1.2), Vector3(0, -1.4, -2.2)]:
			_cyl(pivot, 0.12, 0.12, 1.4, off, gear)
			var tyre := _cyl(pivot, 0.34, 0.34, 0.22, off + Vector3(0, -0.75, 0), gear)
			tyre.rotation.z = PI * 0.5

	# 自動縮放置中：轟炸機翼展 15 公尺、戰鬥機才 9 公尺，
	# 不正規化的話大機種會整台衝出展示台外。
	_fit(holder, 13.0 if mode == "hangar" else 11.5)


## 把節點底下的所有網格等比縮到指定尺寸，並把幾何中心對到節點原點
func _fit(node: Node3D, target: float) -> void:
	var ab: AABB = _mesher.local_aabb(node)
	var m: float = maxf(ab.size.x, maxf(ab.size.y, ab.size.z))
	if m < 0.01:
		return
	var s: float = target / m
	node.scale = Vector3.ONE * s
	# 水平置中，垂直則讓「機體最低點（含起落架）」剛好落在轉盤面上
	var c := ab.get_center()
	node.position = Vector3(-c.x * s, -ab.position.y * s + 0.08, -c.z * s)


func _process(delta: float) -> void:
	_spin += delta * spin_speed
	if turntable:
		turntable.rotation.y = _spin
	if _rotor:
		_rotor.rotation.y += delta * 1.6
	_orbit += delta * orbit_speed
	_place_camera(delta)


## 鏡頭繞著展示機緩慢環繞，並帶一點上下浮動
func _place_camera(_delta: float) -> void:
	if cam == null:
		return
	var dist := 23.0 if mode == "hangar" else 15.0
	var height := 6.0 if mode == "hangar" else 4.2
	var ang := 0.9 + sin(_orbit) * 0.55
	cam.position = Vector3(cos(ang) * dist, height + sin(_orbit * 1.7) * 0.9, sin(ang) * dist)
	cam.look_at(Vector3(0, TURN_Y + 1.9, 0), Vector3.UP)
	# 主選單模式：把展示機推到畫面右側，中央留給選單按鈕
	# （yaw 取正值＝鏡頭往左轉，畫面裡的飛機就往右移）
	if mode == "hangar":
		cam.rotate_object_local(Vector3.UP, 0.36)
		cam.rotate_object_local(Vector3.RIGHT, 0.04)


#══════════════════════════════════════════════════════════════════════════════
#  小工具
#══════════════════════════════════════════════════════════════════════════════
func _mat(col: Color, emit: float = 0.0, rough: float = 0.7) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = 0.2
	m.roughness = rough
	if emit > 0.0:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = emit
	return m


func _emit(col: Color, energy: float) -> StandardMaterial3D:
	return _mat(col, energy, 0.4)


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
