extends RefCounted
#══════════════════════════════════════════════════════════════════════════════
#  AircraftMesh.gd ─ 機體外觀建構（唯一來源）
#
#  戰鬥中的 Aircraft、停機坪展示機、主選單 3D 停機棚、商店 3D 預覽
#  全部呼叫這裡，機體外觀因此只有一份實作。
#
#  build() 回傳：
#    rotor    : 旋翼節點（直升機／萊特飛行者才有，否則 null）
#    exhaust  : 尾噴口的區域座標陣列（後燃器火花粒子掛在這些點上）
#
#  註：刻意不宣告 class_name，由 GameWorld / Hangar3D 以 load() 動態載入。
#══════════════════════════════════════════════════════════════════════════════

## 外部 3D 模型（.glb）。載入失敗時回退到程式碼生成的機模，少了模型檔照樣能跑。
const MODEL_PATHS := {
	MainGame.VType.INTERCEPTOR: "res://models/interceptor.glb",
	MainGame.VType.FIGHTER:     "res://models/fighter.glb",
	MainGame.VType.BOMBER:      "res://models/bomber.glb",     # B-2 式飛翼
}
## 模型尺寸不一，要各自縮放到跟碰撞盒相稱；YAW 用來把機首轉到 -Z
const MODEL_SCALE := {
	MainGame.VType.INTERCEPTOR: 4.5,
	MainGame.VType.FIGHTER:     0.75,
	MainGame.VType.BOMBER:      7.0,
}
const MODEL_YAW := {
	MainGame.VType.INTERCEPTOR: 90.0,
	MainGame.VType.FIGHTER:     180.0,
	MainGame.VType.BOMBER:      180.0,
}
## 外部模型自帶的材質常常過白，用塗裝色蓋掉（保留明暗變化）
const MODEL_TINT := {
	MainGame.VType.BOMBER:      Color(0.055, 0.058, 0.065),   # 匿蹤黑
	MainGame.VType.INTERCEPTOR: Color(0.34, 0.36, 0.39),      # 軍用灰
}

var _model_cache := {}


#══════════════════════════════════════════════════════════════════════════════
#  材質與基本幾何（與 GameWorld 的工具函式行為一致，但不依賴它）
#══════════════════════════════════════════════════════════════════════════════
func make_material(col: Color, emit: float = 0.0, emit_col: Color = Color.BLACK) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = 0.25
	m.roughness = 0.55
	if emit > 0.0:
		m.emission_enabled = true
		m.emission = emit_col if emit_col != Color.BLACK else col
		m.emission_energy_multiplier = emit
	return m


func make_box(parent: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func make_cyl(parent: Node3D, top_r: float, bot_r: float, h: float, pos: Vector3,
		mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = top_r
	cm.bottom_radius = bot_r
	cm.height = h
	mi.mesh = cm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func make_sphere(parent: Node3D, r: float, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	mi.mesh = sm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func make_prism(parent: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var pm := PrismMesh.new()
	pm.size = size
	mi.mesh = pm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


#══════════════════════════════════════════════════════════════════════════════
#  外部模型
#══════════════════════════════════════════════════════════════════════════════
## skin_col 有值時（自機／停機棚預覽）用塗裝色蓋掉模型自帶材質，
## 這樣商店買的塗裝才會真的套用到外部 3D 模型上。
func get_model(vtype: int, skin_col: Variant = null) -> Node3D:
	if not MODEL_PATHS.has(vtype):
		return null
	var path: String = MODEL_PATHS[vtype]
	if not _model_cache.has(path):
		_model_cache[path] = load(path) if ResourceLoader.exists(path) else null
	var ps = _model_cache[path]
	if ps == null or not (ps is PackedScene):
		return null
	var inst: Node3D = (ps as PackedScene).instantiate()
	var tint = skin_col if skin_col != null else MODEL_TINT.get(vtype)
	if tint != null:
		var mat := make_material(Color(tint))
		mat.roughness = 0.55
		mat.metallic = 0.15
		_tint_meshes(inst, mat)
	return inst


func _tint_meshes(n: Node, mat: StandardMaterial3D) -> void:
	if n is MeshInstance3D:
		(n as MeshInstance3D).material_override = mat
	for c in n.get_children():
		_tint_meshes(c, mat)


#══════════════════════════════════════════════════════════════════════════════
#  量測：外部模型的實際尺寸
#══════════════════════════════════════════════════════════════════════════════
## root 底下所有網格合起來的 AABB（以 root 的區域座標表示）。
## 識別燈與展示台縮放都要靠它，寫死座標會讓燈飄在機翼外面。
func local_aabb(root: Node3D) -> AABB:
	var boxes: Array = []
	_gather_aabb(root, Transform3D.IDENTITY, boxes)
	if boxes.is_empty():
		return AABB()
	var out: AABB = boxes[0]
	for i in range(1, boxes.size()):
		out = out.merge(boxes[i])
	return out


func _gather_aabb(n: Node, xf: Transform3D, boxes: Array) -> void:
	for c in n.get_children():
		if not (c is Node3D):
			continue
		var ct: Transform3D = xf * (c as Node3D).transform
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			boxes.append(ct * (c as MeshInstance3D).get_aabb())
		_gather_aabb(c, ct, boxes)


#══════════════════════════════════════════════════════════════════════════════
#  主入口
#══════════════════════════════════════════════════════════════════════════════
## opts:
##   emul       : 發光倍率（展示機壓低，避免近距離被 Glow 糊成一團白）
##   wright     : 萊特飛行者事件
##   use_model  : 是否允許使用外部 .glb（停機棚預覽刻意也用，才跟實機一致）
##   engine_col : 引擎噴口顏色（預設取 VSTATS 的機種色）
func build(pivot: Node3D, vtype: int, base_col: Color, team_col: Color,
		opts: Dictionary = {}) -> Dictionary:
	var emul: float = float(opts.get("emul", 1.0))
	var wright: bool = bool(opts.get("wright", false))
	var use_model: bool = bool(opts.get("use_model", true))
	var engine_col: Color = opts.get("engine_col", Color(MainGame.VSTATS[vtype]["color"]))

	var body := make_material(base_col)
	var accent := make_material(team_col, 2.6 * emul)
	var engine := make_material(engine_col, 5.0 * emul)
	var out := { "rotor": null, "exhaust": [] }

	# ── 萊特飛行者事件：戰鬥機位換成 1903 年的雙翼機 ──
	if wright:
		var wood := make_material(Color(0.42, 0.30, 0.16))
		var cloth := make_material(Color(0.82, 0.78, 0.66))
		make_box(pivot, Vector3(11.0, 0.16, 2.2), Vector3(0, 1.4, 0), cloth)   # 上翼
		make_box(pivot, Vector3(11.0, 0.16, 2.2), Vector3(0, -0.4, 0), cloth)  # 下翼
		for sx in [-3.4, -1.2, 1.2, 3.4]:                                      # 翼間支柱
			make_box(pivot, Vector3(0.14, 1.8, 0.14), Vector3(sx, 0.5, 0), wood)
		make_box(pivot, Vector3(0.5, 0.3, 6.0), Vector3(0, 0.4, 1.6), wood)    # 機身桁架
		make_box(pivot, Vector3(3.0, 0.12, 1.0), Vector3(0, 0.5, 4.4), cloth)  # 尾舵
		make_box(pivot, Vector3(3.2, 0.12, 1.0), Vector3(0, 0.5, -3.4), cloth) # 前升降舵
		make_box(pivot, Vector3(0.6, 0.5, 0.9), Vector3(0, 0.2, 0.4), wood)    # 引擎
		var wr := Node3D.new()                                                 # 木螺旋槳
		wr.position = Vector3(0, 0.5, 2.6)
		pivot.add_child(wr)
		for i in 2:
			var blade := make_box(wr, Vector3(0.3, 2.6, 0.1), Vector3.ZERO, wood)
			blade.rotation_degrees.z = i * 90.0
		out["rotor"] = wr
		out["aabb"] = local_aabb(pivot)
		return out

	# ── 有外部 3D 模型就優先用 ──
	if use_model:
		var mdl := get_model(vtype, opts.get("skin_col"))
		if mdl != null:
			pivot.add_child(mdl)
			mdl.scale = Vector3.ONE * float(MODEL_SCALE.get(vtype, 4.0))
			mdl.rotation_degrees = Vector3(0, float(MODEL_YAW.get(vtype, 0.0)), 0)
			# 隊色識別：外部模型自帶材質沒有隊伍色，遠距離會分不出敵我。
			# 位置一定要照模型「實際的」翼端算 ─ 寫死座標會讓識別燈飄在機體外面。
			# 量測對象必須是 pivot（含模型自己的縮放與 180° 轉向），
			# 量 mdl 會得到未縮放、機首還朝 +Z 的尺寸，前後左右全部反過來。
			var ab := local_aabb(pivot)
			var c := ab.get_center()
			var mark := make_material(team_col, 1.1 * emul)
			if ab.size.x > 0.01:
				for sx2 in [-1.0, 1.0]:
					make_box(pivot, Vector3(ab.size.x * 0.14, ab.size.y * 0.10 + 0.06,
						ab.size.z * 0.10),
						Vector3(c.x + sx2 * ab.size.x * 0.40, c.y, c.z + ab.size.z * 0.10), mark)
				# 尾噴口取模型最後端，加速特效才會從屁股噴出來
				var tail_z: float = ab.position.z + ab.size.z
				if vtype == MainGame.VType.BOMBER:
					out["exhaust"] = [
						Vector3(c.x - ab.size.x * 0.16, c.y, tail_z - ab.size.z * 0.06),
						Vector3(c.x + ab.size.x * 0.16, c.y, tail_z - ab.size.z * 0.06)]
				else:
					out["exhaust"] = [Vector3(c.x, c.y, tail_z - ab.size.z * 0.04)]
			out["aabb"] = ab
			return out

	# ── 程式碼生成的機模 ──
	if vtype == MainGame.VType.BOMBER:
		make_box(pivot, Vector3(2.6, 2.0, 11.0), Vector3(0, 0, 0), body)
		make_box(pivot, Vector3(16.0, 0.35, 2.4), Vector3(0, 0.3, 0.5), body)
		make_box(pivot, Vector3(16.2, 0.15, 0.5), Vector3(0, 0.55, 0.5), accent)
		make_box(pivot, Vector3(6.0, 0.3, 1.6), Vector3(0, 0.6, 5.0), body)
		make_prism(pivot, Vector3(0.4, 2.2, 2.0), Vector3(0, 1.6, 4.8), accent)
		for sx in [-4.5, 4.5]:
			make_cyl(pivot, 0.9, 0.9, 3.0, Vector3(sx, -0.2, 0.5), body)
			var e := make_cyl(pivot, 0.8, 0.8, 0.4, Vector3(sx, -0.2, 2.0), engine)
			e.rotation_degrees.x = 90
		make_sphere(pivot, 1.0, Vector3(0, 0.6, -5.2), accent)
		out["exhaust"] = [Vector3(-4.5, -0.2, 2.4), Vector3(4.5, -0.2, 2.4)]

	elif vtype == MainGame.VType.HELI:
		make_box(pivot, Vector3(2.4, 2.2, 6.0), Vector3(0, 0, 0), body)
		make_sphere(pivot, 1.3, Vector3(0, 0.3, -2.8), accent)
		make_box(pivot, Vector3(0.8, 0.8, 5.0), Vector3(0, 0.6, 4.2), body)
		make_prism(pivot, Vector3(0.3, 2.0, 1.6), Vector3(0, 1.8, 6.0), accent)
		make_box(pivot, Vector3(4.4, 0.25, 1.2), Vector3(0, -0.6, 0.2), body)   # 短翼掛架
		make_box(pivot, Vector3(0.6, 0.6, 2.0), Vector3(-2.2, -0.9, 0.2), engine)
		make_box(pivot, Vector3(0.6, 0.6, 2.0), Vector3(2.2, -0.9, 0.2), engine)
		var hr := Node3D.new()
		hr.position = Vector3(0, 1.5, 0)
		pivot.add_child(hr)
		for i in 2:
			var blade2 := make_box(hr, Vector3(9.0, 0.12, 0.7), Vector3.ZERO, accent)
			blade2.rotation_degrees.y = i * 90.0
		make_cyl(pivot, 0.3, 0.3, 0.8, Vector3(0, 1.5, 0), body)
		out["rotor"] = hr
		out["exhaust"] = [Vector3(-2.2, -0.9, 1.3), Vector3(2.2, -0.9, 1.3)]

	elif vtype == MainGame.VType.INTERCEPTOR:
		# 截擊機：細長機身 + 三角翼 + 雙垂尾 + 雙噴口，
		# 刻意跟戰鬥機做出明顯不同的剪影（以前兩者共用同一個機模，遠看分不出來）。
		make_box(pivot, Vector3(1.2, 1.0, 9.4), Vector3(0, 0, 0), body)
		make_prism(pivot, Vector3(1.2, 1.0, 4.2), Vector3(0, 0, -6.2), body)     # 尖長機鼻
		make_box(pivot, Vector3(0.5, 0.34, 3.0), Vector3(0, 0.05, -5.6), accent) # 空速管基座
		# 三角翼：由三段逐漸變窄的板子拼出後掠感
		for i in 3:
			var f := float(i)
			make_box(pivot, Vector3(8.4 - f * 2.2, 0.22, 1.8),
				Vector3(0, -0.05, 1.0 + f * 1.5), body)
		make_box(pivot, Vector3(8.6, 0.10, 0.34), Vector3(0, 0.10, 1.0), accent)
		# 雙垂尾（外傾）
		for sx3 in [-1.0, 1.0]:
			var fin := make_prism(pivot, Vector3(0.24, 2.0, 2.2), Vector3(sx3 * 1.1, 1.1, 3.6), body)
			fin.rotation_degrees.z = sx3 * 18.0
		# 水平尾翼
		make_box(pivot, Vector3(4.6, 0.20, 1.2), Vector3(0, 0.0, 4.3), body)
		make_sphere(pivot, 0.68, Vector3(0, 0.62, -3.0), accent)                 # 座艙罩
		# 雙噴口
		for sx4 in [-0.62, 0.62]:
			var ex2 := make_cyl(pivot, 0.55, 0.55, 0.4, Vector3(sx4, 0, 4.8), engine)
			ex2.rotation_degrees.x = 90
		out["exhaust"] = [Vector3(-0.62, 0, 5.1), Vector3(0.62, 0, 5.1)]

	else:  # FIGHTER
		make_box(pivot, Vector3(1.4, 1.1, 8.0), Vector3(0, 0, 0), body)
		make_prism(pivot, Vector3(1.4, 1.1, 3.0), Vector3(0, 0, -5.0), body)
		make_box(pivot, Vector3(9.0, 0.25, 2.2), Vector3(0, -0.1, 0.8), body)
		make_box(pivot, Vector3(9.2, 0.12, 0.4), Vector3(0, 0.1, 0.8), accent)
		make_box(pivot, Vector3(4.0, 0.22, 1.4), Vector3(0, 0.1, 3.6), body)
		make_prism(pivot, Vector3(0.3, 1.8, 1.8), Vector3(0, 1.2, 3.4), accent)
		make_sphere(pivot, 0.75, Vector3(0, 0.65, -2.4), accent)
		var ex := make_cyl(pivot, 0.65, 0.65, 0.4, Vector3(0, 0, 4.2), engine)
		ex.rotation_degrees.x = 90
		out["exhaust"] = [Vector3(0, 0, 4.5)]

	out["aabb"] = local_aabb(pivot)
	return out


#══════════════════════════════════════════════════════════════════════════════
#  後燃器：尾噴口火花 + 熱焰
#══════════════════════════════════════════════════════════════════════════════
## 在每個尾噴口掛一組粒子，回傳陣列供加速時開關 emitting。
## flame 是一小段拉長的發光錐，開加速時才顯示，近距離看得出「噴出去」。
func build_afterburners(pivot: Node3D, exhaust: Array, team_col: Color) -> Array:
	var out: Array = []
	var spark := StandardMaterial3D.new()
	spark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	spark.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	spark.albedo_color = Color(1.0, 0.78, 0.35, 0.9)
	spark.emission_enabled = true
	spark.emission = Color(1.0, 0.62, 0.22)
	spark.emission_energy_multiplier = 4.5

	var quad := QuadMesh.new()
	quad.size = Vector2(1.5, 1.5)

	for pos in exhaust:
		var holder := Node3D.new()
		holder.position = pos
		pivot.add_child(holder)

		var p := GPUParticles3D.new()
		p.amount = 46
		p.lifetime = 0.55
		p.emitting = false
		p.local_coords = true
		p.draw_pass_1 = quad
		p.material_override = spark
		var pm := ParticleProcessMaterial.new()
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = 0.30
		pm.direction = Vector3(0, 0, 1)          # 往機尾噴
		pm.spread = 9.0
		pm.initial_velocity_min = 22.0
		pm.initial_velocity_max = 40.0
		pm.gravity = Vector3.ZERO
		pm.scale_min = 0.5
		pm.scale_max = 1.5
		pm.scale_curve = _fade_curve()
		pm.color = Color(1.0, 0.85, 0.5, 0.95)
		p.process_material = pm
		holder.add_child(p)

		# 噴口熱焰：藍白內焰 + 橙色外焰
		var core := make_cyl(holder, 0.10, 0.42, 2.6, Vector3(0, 0, 1.4),
			make_material(Color(0.65, 0.85, 1.0), 7.0))
		core.rotation_degrees.x = -90
		var flame := make_cyl(holder, 0.16, 0.72, 4.6, Vector3(0, 0, 2.6),
			make_material(Color(1.0, 0.55, 0.18), 5.5))
		flame.rotation_degrees.x = -90
		core.visible = false
		flame.visible = false

		out.append({ "particles": p, "core": core, "flame": flame })
	return out


## 粒子由大縮到小的曲線（做出火花衰減）
func _fade_curve() -> CurveTexture:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 1.0))
	c.add_point(Vector2(1.0, 0.05))
	var ct := CurveTexture.new()
	ct.curve = c
	return ct
