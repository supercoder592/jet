extends Node3D
#══════════════════════════════════════════════════════════════════════════════
#  GameWorld.gd ─ 世界生成 / Arcade 飛行 / 武器 / 跑道懲罰 / 空投爭奪 / AI FSM
#  Godot 4.2+ ／ 100% 純程式碼，全部 Mesh 與 UI 都在執行期生成
#
#  註：本檔刻意不宣告 class_name，MainGame 以 load() 動態載入，
#      避免 MainGame <-> GameWorld 產生循環相依而無法編譯。
#══════════════════════════════════════════════════════════════════════════════

# ─────────────────────────── 地圖座標 ───────────────────────────
const CARRIER_POS  := Vector3(0, 0, 400)     # 進攻方：航空母艦（部署階段駛近到此處）
const RUNWAY_POS   := Vector3(0, 0, -760)    # 防守方：陸上跑道
const NUKE_POS     := Vector3(140, 0, -900)  # 防守方：核設施
const DROP_POS     := Vector3(0, 110, -180)  # 高空空投（取兩方基地中點）
const DROP_RADIUS  := 36.0
## 戰場尺度：地形分布大幅擴大（原本 1700），外環由 MapTeton.outer_ranges() 填滿
const MAP_LIMIT    := 2500.0
const CEILING      := 620.0

const COAST_Z      := -330.0                 # 海岸線基準（陸地在此以南）
const LAND_BACK    := -2400.0                # 陸地最深處
const LAND_Y       := 8.0                    # 陸地高度（海面 y=0）

# ─────────────────────────── 日夜 ───────────────────────────
#   elev/yaw : 太陽方向（elev 越負＝越高）   star : 星空可見度 0~1
const SKY_DAWN := {
	"elev": -7.0, "yaw": 100.0, "sun": Color(1.00, 0.60, 0.40), "energy": 0.62,
	"top": Color(0.10, 0.14, 0.32), "horiz": Color(0.86, 0.46, 0.30),
	"gnd": Color(0.06, 0.06, 0.09), "amb": 0.42, "fill": 0.20,
	"fog": Color(0.30, 0.20, 0.24), "fogd": 0.00085, "glow": 1.20, "star": 0.45,
}
const SKY_DAY := {
	"elev": -55.0, "yaw": 140.0, "sun": Color(1.00, 0.97, 0.90), "energy": 1.05,
	"top": Color(0.16, 0.36, 0.68), "horiz": Color(0.62, 0.78, 0.92),
	"gnd": Color(0.10, 0.12, 0.12), "amb": 0.55, "fill": 0.10,
	"fog": Color(0.45, 0.58, 0.74), "fogd": 0.00032, "glow": 0.55, "star": 0.0,
}
const SKY_DUSK := {
	"elev": -5.0, "yaw": 250.0, "sun": Color(1.00, 0.44, 0.20), "energy": 0.74,
	"top": Color(0.12, 0.10, 0.30), "horiz": Color(0.96, 0.36, 0.20),
	"gnd": Color(0.05, 0.05, 0.08), "amb": 0.44, "fill": 0.22,
	"fog": Color(0.34, 0.16, 0.20), "fogd": 0.00095, "glow": 1.30, "star": 0.35,
}
const SKY_NIGHT := {
	"elev": -42.0, "yaw": 300.0, "sun": Color(0.42, 0.58, 1.00), "energy": 0.30,
	"top": Color(0.010, 0.018, 0.045), "horiz": Color(0.04, 0.07, 0.15),
	"gnd": Color(0.005, 0.008, 0.015), "amb": 0.32, "fill": 0.48,
	"fog": Color(0.03, 0.05, 0.10), "fogd": 0.00085, "glow": 1.55, "star": 1.0,
}
## 循環模式的關鍵影格順序（一場比賽剛好跑完一圈）
const SKY_CYCLE := [SKY_DAY, SKY_DUSK, SKY_NIGHT, SKY_DAWN]

# 地形高度圖：給 AI 做避障用的粗略取樣網格（跟著擴大的戰場一起放大）
const GRID_N    := 160
const GRID_SPAN := 5600.0

const GUN_RANGE    := 620.0                  # 機槍射線最大距離
## 防空飛彈系統（護航艦 SAM 與地面防空塔）同時最多只能有這麼多枚在空中。
## 超過就必須等前面的命中或自毀，避免整片飛彈牆把玩家鎖死。
const MAX_SAM_IN_FLIGHT := 4
## 防空塔：舊版是 22 傷害 / 1.6 秒 / 380 m，三座疊起來就有 40 dps ─
## 玩家停在敵方基地上空四秒就死。這是「對手太強」最主要的來源。
const TOWER_DMG     := 9.0
const TOWER_ROF     := 3.2
const TOWER_CEILING := 420.0      # 拉高就打不到
const NET_TICK     := 0.05                   # 狀態同步 20Hz
const RESPAWN_TIME := 6.0
const BOOST_MULT   := 1.5                    # 空投獎勵傷害倍率
const BOOST_TIME   := 90.0

# ─────────────────────────── 執行期狀態 ───────────────────────────
var aircraft: Dictionary = {}       # pilot_id -> Aircraft
var pilots: Dictionary = {}         # pilot_id -> Pilot（步行中）
var _parked: Array = []             # 停機坪上的展示機
var _lbl_board: Label
var structures: Dictionary = {}     # String key -> { node, hp, max, team, kind }
var towers: Array = []              # 防空塔資料

# ── 階段：長官簡報 → 戰術部署 → 戰鬥 ──
const PHASE_DEPLOY    := 0
const PHASE_COMBAT    := 1
const PHASE_BRIEF     := 2          # 開戰前的長官簡報
const BRIEF_TIME      := 42.0       # 簡報最長時間（九句講完約 40 秒；提早看完就等其他人）
const DEPLOY_TIME     := 30.0       # 部署階段長度
const CARRIER_APPROACH := 900.0     # 航母在部署階段從多遠的海面駛來
const DEPLOY_TOWERS   := 4          # 防守方在部署階段可配置的防空炮數

var phase: int = PHASE_BRIEF
var brief_left: float = BRIEF_TIME
var deploy_left: float = DEPLOY_TIME
var deploy_towers_left: int = DEPLOY_TOWERS
var _carrier_node: Node3D
var _briefing = null                # Briefing.gd 實例
var _lbl_wait: Label                # 簡報看完後的等待提示
var _lbl_tutorial: Label            # 練習場的逐步提示
var _tut_step: int = 0
var _tut_done_t: float = 0.0
var _tut_flags := {}                # 各步驟的達成旗標
var _holo: Node3D                   # 防守方的全息立體地圖
var _deploy_root: Control
var _lbl_deploy_time: Label
var _lbl_deploy_hint: Label
var _lbl_deploy_count: Label
var _lbl_help: Label
var _terrain_node: Node3D

# HUD 強化
var _vignette: ColorRect
var _boxes: Control
var _lbl_warn: Label
var _warn_beep: float = 0.0

# 視角
var first_person: bool = false

# 自動駕駛（專屬外掛）：由 MainGame 的聊天密碼切換
var autopilot: bool = false

# ── 動態載入的模組（都刻意不宣告 class_name，避免循環相依）──
var _mesher = null                  # AircraftMesh.gd：機體外觀
var _teton = null                   # MapTeton.gd：巨峰與峽谷地形
var _city = null                    # MapCity.gd：都市（高樓林立）
var _ground = null                  # GroundForces.gd：陸軍（高射砲／防空車／補給車隊／地勤）
var _fleet = null                   # EscortFleet.gd：護航艦隊
var _mouse = null                   # FlightHud.gd：飛行視覺回饋（滾轉尺／速度線／鎖定環）
var _touch = null                   # TouchControls.gd：手機觸控操控層（沒有觸控螢幕就是 null）

# 萊特兄弟事件
var wright_left: float = 0.0
var _wright_cd: float = 70.0

# 小地圖與偵查機
var _minimap: Control
var _uav: Area3D
var _uav_team: int = 1
var _uav_hp: float = 140.0
var _uav_down: float = 0.0
var _uav_angle: float = 0.0

# 長官
var _officer: PanelContainer
var _officer_text: Label
var _officer_name: Label
var _officer_mouth: ColorRect
var _officer_hold: float = 0.0
var _officer_speak: float = 0.0
var _officer_idle: float = 14.0
var _officer_prio: int = 0

var match_time: float = 0.0
var match_running: bool = false
var runway_down: bool = false
var runway_lock_left: float = 0.0   # 防守方禁止復活剩餘秒數
var drop_spawned: bool = false
var drop_node: Node3D = null
var drop_progress := { 0: 0.0, 1: 0.0 }
var drop_done: bool = false
var team_boost := { 0: 0.0, 1: 0.0 }
var respawn_queue: Dictionary = {}  # pilot_id -> 剩餘秒數
var _respawn_slot := { 0: 0, 1: 0 } # 各隊輪替使用的起飛位

var _net_acc: float = 0.0
var _drop_sync_acc: float = 0.0
var _alert_timer: float = 0.0
var _cam: Camera3D
var _cam_pivot: Node3D
var _rng := RandomNumberGenerator.new()

# 環境 / 日夜
var _env: Environment
var _sun: DirectionalLight3D
var _fill: DirectionalLight3D
var _stars: MultiMeshInstance3D
var _star_mat: StandardMaterial3D
var _night_factor: float = 0.0     # 0=白天 1=深夜，供跑道燈等使用
var _tod_acc: float = 0.0

# 地形高度圖與地形噪聲（種子由房主同步，各端地形完全一致）
var _hgrid := PackedFloat32Array()
var _noise := FastNoiseLite.new()

# 曳光彈 / 飛彈尾煙共用材質（避免每發彈丸都配置新材質）
var _tracer_mat := {}
var _trail_mat: StandardMaterial3D
var _carrier_radar: MeshInstance3D    # 艦島上會轉的雷達

# 鏡頭震動與音效
var _shake_amt: float = 0.0
var _shake_left: float = 0.0
var _sfx := {}
var _sfx_players: Array = []

# 天氣
var _wx_particles: GPUParticles3D
var _lightning: DirectionalLight3D
var _wx_wind := Vector3.ZERO
var _wx_gust_t: float = 0.0
var _wx_dmg_acc: float = 0.0
var _bolt_timer: float = 0.0

# HUD
var _hud: CanvasLayer
var _lbl_timer: Label
var _lbl_obj: Label
var _lbl_vitals: Label
var _lbl_center: Label
var _lbl_alert: Label
var _bar_atk: ProgressBar
var _bar_def: ProgressBar
var _drop_box: VBoxContainer
var _crosshair: Control

# 血量條（自機 / 鎖定目標 / 兩座基地）與後燃器燃料條
var _bar_hp: ProgressBar
var _lbl_hp: Label
var _bar_boost: ProgressBar
var _lbl_boost: Label
var _bar_runway: ProgressBar
var _bar_nuke: ProgressBar
var _tgt_box: VBoxContainer
var _tgt_name: Label
var _bar_tgt: ProgressBar
var _hp_box: VBoxContainer


#══════════════════════════════════════════════════════════════════════════════
#  初始化
#══════════════════════════════════════════════════════════════════════════════
func _ready() -> void:
	_rng.seed = _mg().map_seed  # 種子由房主同步 → 所有客戶端地形完全一致
	_noise.seed = _mg().map_seed
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 0.0016
	_noise.fractal_octaves = 3
	_hgrid.resize(GRID_N * GRID_N)
	_hgrid.fill(0.0)
	_tracer_mat[MainGame.TEAM_ATTACKER] = make_material(Color(1.0, 0.78, 0.30), 7.0)
	_tracer_mat[MainGame.TEAM_DEFENDER] = make_material(Color(0.55, 0.95, 1.0), 7.0)
	_trail_mat = make_material(Color(0.75, 0.80, 0.90), 1.2)

	# 模組
	_mesher = load("res://AircraftMesh.gd").new()
	_teton = load("res://MapTeton.gd").new()
	_teton.w = self
	_teton.land_y = LAND_Y
	_teton.map_limit = MAP_LIMIT
	_teton.coast_z = COAST_Z
	_teton.land_back = LAND_BACK
	_teton.runway_pos = RUNWAY_POS
	_teton.carrier_pos = CARRIER_POS
	_city = load("res://MapCity.gd").new()
	_city.w = self
	_city.land_y = LAND_Y
	_city.map_limit = MAP_LIMIT

	_build_environment()
	_build_star_dome()
	_build_terrain()
	_build_carrier()
	_build_escort_fleet()
	_build_runway()
	_build_nuclear_facility()
	_build_initial_towers()
	_build_ground_forces()
	_build_camera()
	_build_audio()
	_build_weather()
	_build_hud()
	_build_deploy_ui()
	_build_holo_map()
	# 必須等星空建立完才套用天空，否則星星在白天不會被關掉
	_apply_sky(_tod_preset_now())
	# 開場先看長官簡報，接著才是戰術部署
	phase = PHASE_BRIEF
	brief_left = BRIEF_TIME
	deploy_left = DEPLOY_TIME
	_enter_brief()


func _mg() -> MainGame:
	return MainGame.instance


func _is_host() -> bool:
	var mg := _mg()
	return mg != null and mg.is_host


func _has_net() -> bool:
	return _mg().has_net()


func _local_id() -> int:
	return _mg().my_id()


## 本機玩家現在是「走在甲板／停機坪上」還是「在機上」。
## 觸控層要靠它決定該顯示登機鈕還是整組飛行操控。
func local_on_foot() -> bool:
	var id := _local_id()
	return pilots.has(id) and not aircraft.has(id)


func local_is_defender() -> bool:
	return _mg().my_team() == MainGame.TEAM_DEFENDER


#══════════════════════════════════════════════════════════════════════════════
#  環境 / 光影（Glow 輝光 + 高科技螢光風格）
#══════════════════════════════════════════════════════════════════════════════
func _build_environment() -> void:
	var we := WorldEnvironment.new()
	we.name = "Env"
	_env = Environment.new()

	_env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sun_angle_max = 18.0
	sm.energy_multiplier = 1.0
	sky.sky_material = sm
	_env.sky = sky

	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY

	# ── Glow / Bloom ──
	_env.glow_enabled = true
	_env.glow_strength = 1.1
	_env.glow_bloom = 0.30
	_env.glow_hdr_threshold = 0.80
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE

	_env.tonemap_mode = Environment.TONE_MAPPER_ACES
	_env.tonemap_exposure = 1.0

	_env.fog_enabled = true
	_env.fog_sky_affect = 0.35

	we.environment = _env
	add_child(we)

	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.shadow_enabled = true
	add_child(_sun)

	# 補光：讓夜戰不會全黑到看不見地形（強度由時段決定）
	_fill = DirectionalLight3D.new()
	_fill.rotation_degrees = Vector3(-18, -50, 0)
	_fill.light_color = Color(0.30, 0.55, 0.95)
	add_child(_fill)


## 星空穹頂：用一顆 MultiMesh 畫滿小發光球，白天淡出
func _build_star_dome() -> void:
	_stars = MultiMeshInstance3D.new()
	_stars.name = "Stars"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var s := SphereMesh.new()
	s.radius = 2.2
	s.height = 4.4
	s.radial_segments = 4
	s.rings = 3
	mm.mesh = s
	mm.instance_count = 420
	for i in mm.instance_count:
		# 只鋪在地平線以上的半球
		var yaw := _rng.randf_range(0.0, TAU)
		var pitch := _rng.randf_range(0.05, 1.45)
		var r := 1500.0
		var pos := Vector3(cos(pitch) * cos(yaw), sin(pitch), cos(pitch) * sin(yaw)) * r
		var sc := _rng.randf_range(0.5, 2.0)
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * sc), pos))
	_stars.multimesh = mm

	_star_mat = make_material(Color(0.85, 0.92, 1.0), 6.0)
	_star_mat.disable_fog = true
	_star_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_stars.material_override = _star_mat
	add_child(_stars)


# ── 日夜推進 ──
func _tod_preset_now() -> Dictionary:
	var mode := _mg().time_of_day if _mg() != null else MainGame.TOD_DAY
	match mode:
		MainGame.TOD_DUSK:
			return SKY_DUSK
		MainGame.TOD_NIGHT:
			return SKY_NIGHT
		MainGame.TOD_CYCLE:
			# 一場比賽跑完一圈：白天 → 黃昏 → 夜晚 → 黎明
			var f := fmod(match_time / MainGame.MATCH_TIME, 1.0) * float(SKY_CYCLE.size())
			var i := int(f)
			return _lerp_sky(SKY_CYCLE[i % SKY_CYCLE.size()],
				SKY_CYCLE[(i + 1) % SKY_CYCLE.size()], f - float(i))
		_:
			return SKY_DAY


func _lerp_sky(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var r := {}
	for k in a.keys():
		if a[k] is Color:
			r[k] = (a[k] as Color).lerp(b[k], t)
		else:
			r[k] = lerpf(float(a[k]), float(b[k]), t)
	return r


func _apply_sky(p: Dictionary) -> void:
	var sm: ProceduralSkyMaterial = _env.sky.sky_material
	sm.sky_top_color = p["top"]
	sm.sky_horizon_color = p["horiz"]
	sm.ground_horizon_color = p["horiz"]
	sm.ground_bottom_color = p["gnd"]

	# 天氣疊在時段之上：霧色被天氣染色、濃度倍增、陽光被遮蔽
	var w: Dictionary = WX_MOD.get(_mg().weather, WX_MOD[MainGame.WX_CLEAR])
	_env.ambient_light_energy = float(p["amb"]) * float(w["amb"])
	_env.glow_intensity = float(p["glow"]) * float(w["glow"])
	_env.fog_light_color = Color(p["fog"]).lerp(w["fog"], 0.0 if _mg().weather == MainGame.WX_CLEAR else 0.85)
	_env.fog_density = float(p["fogd"]) * float(w["fogd"])

	_sun.rotation_degrees = Vector3(p["elev"], p["yaw"], 0.0)
	_sun.light_color = p["sun"]
	_sun.light_energy = float(p["energy"]) * float(w["sun"])
	if _fill:
		_fill.light_energy = p["fill"]

	_night_factor = clampf(float(p["star"]), 0.0, 1.0)
	if _star_mat:
		_star_mat.emission_energy_multiplier = _night_factor * 7.0
		_stars.visible = _night_factor > 0.02


#══════════════════════════════════════════════════════════════════════════════
#  天氣：沙塵暴 / 冰雹 / 雷暴
#══════════════════════════════════════════════════════════════════════════════
## 天氣對天空的加成（在 _apply_sky 之後疊上去）
const WX_MOD := {
	MainGame.WX_CLEAR:     { "fog": Color(1, 1, 1), "fogd": 1.0,  "amb": 1.00, "sun": 1.00, "glow": 1.0 },
	# 沙塵暴刻意做成極低能見度：這是突發惡劣天況，壓迫感就是重點
	MainGame.WX_SANDSTORM: { "fog": Color(0.78, 0.52, 0.24), "fogd": 9.0, "amb": 0.85, "sun": 0.45, "glow": 0.8 },
	MainGame.WX_HAIL:      { "fog": Color(0.62, 0.66, 0.70), "fogd": 3.2, "amb": 0.75, "sun": 0.40, "glow": 0.9 },
	MainGame.WX_THUNDER:   { "fog": Color(0.24, 0.26, 0.32), "fogd": 3.6, "amb": 0.55, "sun": 0.25, "glow": 1.1 },
}


func _build_weather() -> void:
	var wx := _mg().weather
	if wx == MainGame.WX_CLEAR:
		return

	# 粒子跟著鏡頭走：只在玩家周圍一個盒子裡下，不必鋪滿整張地圖
	_wx_particles = GPUParticles3D.new()
	_wx_particles.amount = 900
	_wx_particles.lifetime = 2.4
	_wx_particles.local_coords = false
	_wx_particles.visibility_aabb = AABB(Vector3(-300, -300, -300), Vector3(600, 600, 600))

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES

	var quad := QuadMesh.new()
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(260, 160, 260)
	pm.gravity = Vector3.ZERO

	match wx:
		MainGame.WX_SANDSTORM:
			quad.size = Vector2(3.2, 1.0)              # 拉長的沙粒，強調橫向吹襲
			mat.albedo_color = Color(0.82, 0.62, 0.34, 0.40)
			pm.direction = Vector3(1, -0.12, 0.35)
			pm.spread = 12.0
			pm.initial_velocity_min = 110.0
			pm.initial_velocity_max = 170.0
			_wx_wind = Vector3(16.0, 0, 5.0)
		MainGame.WX_HAIL:
			quad.size = Vector2(0.7, 0.7)
			mat.albedo_color = Color(0.88, 0.94, 1.0, 0.75)
			pm.direction = Vector3(0.25, -1, 0)
			pm.spread = 6.0
			pm.initial_velocity_min = 150.0
			pm.initial_velocity_max = 210.0
			pm.gravity = Vector3(0, -40, 0)
			_wx_wind = Vector3(5.0, 0, 0)
		MainGame.WX_THUNDER:
			quad.size = Vector2(0.35, 4.0)             # 細長雨絲
			mat.albedo_color = Color(0.70, 0.80, 0.95, 0.45)
			pm.direction = Vector3(0.35, -1, 0.1)
			pm.spread = 8.0
			pm.initial_velocity_min = 190.0
			pm.initial_velocity_max = 260.0
			pm.gravity = Vector3(0, -60, 0)
			_wx_wind = Vector3(9.0, 0, 3.0)

	_wx_particles.draw_pass_1 = quad
	_wx_particles.material_override = mat
	_wx_particles.process_material = pm
	add_child(_wx_particles)
	_wx_particles.emitting = true

	if wx == MainGame.WX_THUNDER:
		_lightning = DirectionalLight3D.new()
		_lightning.rotation_degrees = Vector3(-60, 30, 0)
		_lightning.light_color = Color(0.85, 0.92, 1.0)
		_lightning.light_energy = 0.0
		add_child(_lightning)
		_bolt_timer = _rng.randf_range(4.0, 10.0)


## 天氣對玩法的實際影響（不只是視覺）
func weather_lock_scale() -> float:
	# 沙塵暴讓紅外／雷達鎖定距離大幅縮短
	match _mg().weather:
		MainGame.WX_SANDSTORM: return 0.45
		MainGame.WX_HAIL:      return 0.70
		MainGame.WX_THUNDER:   return 0.75
	return 1.0


func _update_weather(delta: float) -> void:
	var wx := _mg().weather
	if wx == MainGame.WX_CLEAR:
		return

	# 粒子盒跟著鏡頭移動
	if _wx_particles and _cam_pivot:
		_wx_particles.global_position = _cam_pivot.global_position + Vector3(0, 60, 0)

	# 陣風亂流：讓飛機被吹得晃動，雷暴最明顯
	var gust := 0.0
	if wx == MainGame.WX_THUNDER:
		gust = 1.0
	elif wx == MainGame.WX_SANDSTORM:
		gust = 0.55
	if gust > 0.0:
		_wx_gust_t += delta
		var g := Vector3(sin(_wx_gust_t * 1.7), sin(_wx_gust_t * 2.3) * 0.4, cos(_wx_gust_t * 1.1))
		for pid in aircraft:
			var a: Aircraft = aircraft[pid]
			if a.alive and (a.is_local or (_is_host() and a.is_bot)):
				a.global_position += (_wx_wind + g * 14.0) * gust * delta

	# 冰雹持續刮傷機體（房主裁決）
	if wx == MainGame.WX_HAIL and _is_host():
		_wx_dmg_acc += delta
		if _wx_dmg_acc >= 2.0:
			_wx_dmg_acc = 0.0
			for pid in aircraft:
				var a2: Aircraft = aircraft[pid]
				if a2.alive and a2.hp > 6.0:
					srv_damage(int(pid), 2.5, pid)

	# 閃電：先亮後雷，雷聲依距離延遲，符合真實體感
	if wx == MainGame.WX_THUNDER and _lightning:
		_bolt_timer -= delta
		if _lightning.light_energy > 0.0:
			_lightning.light_energy = maxf(0.0, _lightning.light_energy - delta * 14.0)
		if _bolt_timer <= 0.0:
			_bolt_timer = _rng.randf_range(5.0, 14.0)
			_strike_lightning()


func _strike_lightning() -> void:
	_lightning.rotation_degrees = Vector3(-_rng.randf_range(30.0, 75.0), _rng.randf_range(0.0, 360.0), 0.0)
	_lightning.light_energy = 5.5
	_set_alert("⚡ 雷擊！")
	# 雷聲延遲 0.6~2.6 秒，聽起來才像遠處打雷
	var d := _rng.randf_range(0.6, 2.6)
	get_tree().create_timer(d).timeout.connect(func(): play_sfx("thunder", -2.0))


func _update_time_of_day(delta: float) -> void:
	# 星空跟著攝影機平移，維持「無限遠」的感覺
	if _stars and _stars.visible and _cam_pivot:
		_stars.global_position = _cam_pivot.global_position

	_tod_acc += delta
	if _tod_acc < 0.1:                     # 10Hz 更新就夠，省效能
		return
	_tod_acc = 0.0
	if _mg().time_of_day == MainGame.TOD_CYCLE:
		_apply_sky(_tod_preset_now())


#══════════════════════════════════════════════════════════════════════════════
#  Mesh 工具
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


## 地表專用材質：完全不反射天空。
## 一般的 make_material 帶 metallic 0.25，套在地形上會把整片山反射成天空的淡藍白，
## 這是先前地形看起來慘白的主因。
func make_terrain_material(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = 0.0
	m.roughness = 0.96
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return m


## 機體外觀（含外部 .glb 模型載入與塗裝）全部搬到 AircraftMesh.gd，
## 停機棚與商店預覽才能跟戰鬥中的機體用同一份程式。

func make_box(parent: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func make_cyl(parent: Node3D, top_r: float, bot_r: float, h: float, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
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


func add_static_box(parent: Node3D, size: Vector3, pos: Vector3) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.position = pos
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	sb.add_child(cs)
	parent.add_child(sb)
	return sb


#══════════════════════════════════════════════════════════════════════════════
#  地形：深色海面 / 陸地 / 峽谷山塊
#══════════════════════════════════════════════════════════════════════════════
# ── 高度圖：記錄每個格子的最高障礙物，供 AI 避障 ──
func _stamp_height(pos: Vector3, radius: float, h: float) -> void:
	var cell := GRID_SPAN / float(GRID_N)
	var r := int(ceil(radius / cell))
	var cx := int((pos.x + GRID_SPAN * 0.5) / cell)
	var cz := int((pos.z + GRID_SPAN * 0.5) / cell)
	# 徑向衰減：山在高度場裡是圓丘而不是方柱。
	# 用方塊填最大值的話，等高線只會畫出方框，而且 AI 避障也會把山當成方形。
	for dz in range(-r - 1, r + 2):
		for dx in range(-r - 1, r + 2):
			var ix := cx + dx
			var iz := cz + dz
			if ix < 0 or iz < 0 or ix >= GRID_N or iz >= GRID_N:
				continue
			# 這個格點在世界座標上離山心多遠
			var wx := -GRID_SPAN * 0.5 + (float(ix) + 0.5) * cell
			var wz := -GRID_SPAN * 0.5 + (float(iz) + 0.5) * cell
			var d := Vector2(wx - pos.x, wz - pos.z).length()
			if d >= radius:
				continue
			# 1 - (d/r)^2 的圓頂剖面：中心最高、邊緣收斂到 0
			var f := 1.0 - pow(d / radius, 2.0)
			var hh := h * f
			var i := iz * GRID_N + ix
			if _hgrid[i] < hh:
				_hgrid[i] = hh


## 起降淨空區：只保護航艦與跑道「附近」，中段戰場刻意不保護，
## 否則像橫斷山脈這種地圖會被切出一條直通到底的免費航道。
func _in_corridor(pos: Vector3, pad: float = 0.0) -> bool:
	# 走廊範圍從基地座標推算，基地移動時不會失效（原本寫死會留下錯位的空洞）
	if absf(pos.x) < 140.0 + pad:
		if pos.z > CARRIER_POS.z - 240.0 - pad and pos.z < CARRIER_POS.z + 340.0 + pad:
			return true            # 航艦彈射區

	# 航母進場航道：部署階段航母從 CARRIER_APPROACH 外的海面駛入，護航艦掛在航母
	# 底下、橫向散開到 ±285。舊版只淨空了 CARRIER_POS 周圍半徑 320 的圓，進場那
	# 一整段完全沒保護 ─ 航母與艦群會直接從島礁與海上錐峰裡穿過去。
	# 半寬取 400 而不是剛好蓋住艦隊的 330：地形是先挑中心點再長出體積的，
	# 中心點落在走廊外、體積仍然會伸進來（峽谷圖實測在 x=-300 留下一顆 12 m 的岩礁）。
	if absf(pos.x) < 400.0 + pad \
		and pos.z > CARRIER_POS.z - 300.0 - pad \
		and pos.z < CARRIER_POS.z + CARRIER_APPROACH + 340.0 + pad:
		return true
		if pos.z > RUNWAY_POS.z - 420.0 - pad and pos.z < RUNWAY_POS.z + 220.0 + pad:
			return true            # 跑道與核設施區

	# 目標物本身也要淨空，否則會被山脊鏈掃到而整個埋進山裡
	var flat := Vector2(pos.x, pos.z)
	if flat.distance_to(Vector2(NUKE_POS.x, NUKE_POS.z)) < 240.0 + pad:
		return true
	if flat.distance_to(Vector2(RUNWAY_POS.x, RUNWAY_POS.z)) < 300.0 + pad:
		return true
	if flat.distance_to(Vector2(CARRIER_POS.x, CARRIER_POS.z)) < 320.0 + pad:
		return true
	if flat.distance_to(Vector2(DROP_POS.x, DROP_POS.z)) < 150.0 + pad:
		return true            # 中央空投空域
	return false


## 在指定範圍內隨機挑一個不落在走廊上的位置；找不到就回傳 Vector3.INF
func _pick_spot(x0: float, x1: float, z0: float, z1: float) -> Vector3:
	for i in 24:
		var p := Vector3(_rng.randf_range(x0, x1), 0.0, _rng.randf_range(z0, z1))
		if not _in_corridor(p, 60.0):
			return p
	return Vector3.INF


func terrain_height(pos: Vector3) -> float:
	var cell := GRID_SPAN / float(GRID_N)
	var ix := int((pos.x + GRID_SPAN * 0.5) / cell)
	var iz := int((pos.z + GRID_SPAN * 0.5) / cell)
	if ix < 0 or iz < 0 or ix >= GRID_N or iz >= GRID_N:
		return 0.0
	return _hgrid[iz * GRID_N + ix]


## 步行者腳下的地板高度。航母甲板不在高度圖裡，要另外判定。
func walk_floor(pos: Vector3) -> float:
	# 站在航母上
	var c := _carrier_node.global_position if _carrier_node else CARRIER_POS
	if absf(pos.x - c.x) < 34.0 and absf(pos.z - c.z) < 150.0:
		return c.y + DECK_Y
	if is_land(pos):
		return maxf(terrain_height(pos), LAND_Y)
	return terrain_height(pos)


## 這一點是不是陸地（用來決定山要不要長在海裡）
func is_land(pos: Vector3) -> bool:
	return pos.z < COAST_Z + _coast_bulge(pos.x)


## 海岸線的蜿蜒量：正值代表這一段陸地往海裡凸出
func _coast_bulge(x: float) -> float:
	return _noise.get_noise_2d(x * 0.9, 4000.0) * 150.0


## 建立地形物件：畫出來、加碰撞、並登記進高度圖
func _rock(parent: Node3D, kind: String, size: Vector3, pos: Vector3, mat: StandardMaterial3D,
		collide: bool = true, yaw: float = 0.0) -> void:
	var mi: MeshInstance3D
	if kind == "prism":
		mi = make_prism(parent, size, pos, mat)
	elif kind == "cone":
		mi = make_cyl(parent, size.x * 0.06, size.x * 0.5, size.y, pos, mat)
	elif kind == "mesa":
		mi = make_cyl(parent, size.x * 0.34, size.x * 0.5, size.y, pos, mat)
	elif kind == "dome":
		# 壓扁的半球 → 圓潤的黃土丘陵。球心壓在地面，只露出上半部。
		mi = make_sphere(parent, size.x * 0.5, Vector3(pos.x, LAND_Y, pos.z), mat)
		mi.scale = Vector3(1.0, size.y / maxf(size.x * 0.5, 0.01), 1.0)
	else:
		mi = make_box(parent, size, pos, mat)
	if yaw != 0.0:
		mi.rotation.y = yaw
	var top := pos.y + size.y * 0.5
	if collide:
		add_static_box(parent, Vector3(size.x * 0.6, size.y, size.z * 0.6), pos)
	_stamp_height(pos, maxf(size.x, size.z) * 0.6, top)


## 山脊鏈：沿著起訖點鋪一串互相重疊的錐體，高度與側偏都由噪聲驅動，
## 做出來的稜線是彎的、高低起伏的，不像一排方塊那樣死板。
func _ridge_chain(t: Node3D, m: Dictionary, from: Vector3, to: Vector3,
		base_w: float, base_h: float, snow: bool = false) -> void:
	var span := to - from
	var length := span.length()
	# 步距要遠小於錐體半徑，相鄰錐體才會融成連續稜線而不是一串孤立圓錐
	var steps := int(maxf(6.0, length / (base_w * 0.24)))
	var dir := span / maxf(length, 0.001)
	var side := Vector3(-dir.z, 0, dir.x)

	for i in steps + 1:
		var f := float(i) / float(steps)
		var along := from + span * f
		# 側向蜿蜒 + 高度起伏都取自同一組噪聲，稜線因此連續而不雜亂
		var n1 := _noise.get_noise_2d(along.x, along.z)
		var n2 := _noise.get_noise_2d(along.x + 1700.0, along.z - 1700.0)
		var pos := along + side * n1 * base_w * 1.4
		if _in_corridor(pos, 40.0):
			continue
		# 兩端收細，中段最高 → 自然的山脈剖面
		var taper := sin(f * PI)
		var h: float = base_h * (0.42 + 0.58 * taper) * (0.75 + 0.45 * absf(n2))
		var w: float = base_w * (0.7 + 0.5 * absf(n1))
		if h < 12.0:
			continue
		# 低矮處用圓潤丘陵、夠高才變成尖峰，一條稜線因此前緩後陡，像真實山系
		var tall := h > base_h * 0.80
		var kind := "cone" if tall else "dome"
		var body: StandardMaterial3D = m["cliff"] if tall else m["rock"]
		# 碰撞體每隔一顆才加，重疊的錐體已足以涵蓋，省掉一半物理物件
		_rock(t, kind, Vector3(w, h, w), Vector3(pos.x, h * 0.5, pos.z),
			body, i % 2 == 0, _rng.randf_range(0, TAU))

		if snow and tall:
			make_cyl(t, w * 0.07, w * 0.22, h * 0.24, Vector3(pos.x, h * 0.88, pos.z), m["snow"])
		elif tall and _rng.randf() < 0.3:
			make_box(t, Vector3(w * 0.34, 0.5, 0.9), Vector3(pos.x, h * 0.93, pos.z), m["vein"])

		# 側翼小丘：不同大小與明暗的丘陵互相疊出溝壑感，
		# 這是參考照片裡「一條條沖蝕紋」在低多邊形下最接近的表現方式
		for k in 2:
			if _rng.randf() > 0.72:
				continue
			var fo := side * _rng.randf_range(-1.3, 1.3) * w * 0.55 + dir * _rng.randf_range(-0.4, 0.4) * w
			var fh: float = h * _rng.randf_range(0.22, 0.55)
			var fw: float = w * _rng.randf_range(0.40, 0.70)
			_rock(t, "dome", Vector3(fw, fh, fw), Vector3(pos.x + fo.x, 0.0, pos.z + fo.z),
				m["shade"] if k == 0 else m["rock2"], false, _rng.randf_range(0, TAU))


## 每張地圖有自己的生態帶配色，讓五、六張圖不只是地形不同、連色調氣氛都不同。
## rock=主山體 rock2=台地 cliff=峭壁/背光 shade=溝壑陰影 grass=谷地 sand=灘岸
func _biome(map_id: int) -> Dictionary:
	var c := {}
	match map_id:
		MainGame.MAP_HILLS:      # 黃土丘陵：乾草金 → 曬黃 → 陰影褐
			c = { "rock": Color(0.46, 0.36, 0.17), "rock2": Color(0.38, 0.29, 0.14),
				"cliff": Color(0.26, 0.20, 0.12), "shade": Color(0.31, 0.24, 0.13),
				"grass": Color(0.18, 0.21, 0.09), "tree": Color(0.10, 0.14, 0.06),
				"sand": Color(0.54, 0.47, 0.31), "sea": Color(0.030, 0.070, 0.090) }
		MainGame.MAP_PLATEAU:    # 紅岩高原
			c = { "rock": Color(0.38, 0.19, 0.12), "rock2": Color(0.44, 0.23, 0.14),
				"cliff": Color(0.24, 0.12, 0.08), "shade": Color(0.29, 0.15, 0.10),
				"grass": Color(0.20, 0.16, 0.09), "tree": Color(0.12, 0.13, 0.07),
				"sand": Color(0.50, 0.38, 0.24), "sea": Color(0.028, 0.055, 0.080) }
		MainGame.MAP_PLAINS:     # 溫帶綠原
			c = { "rock": Color(0.20, 0.24, 0.13), "rock2": Color(0.26, 0.27, 0.15),
				"cliff": Color(0.13, 0.15, 0.10), "shade": Color(0.15, 0.19, 0.10),
				"grass": Color(0.13, 0.22, 0.10), "tree": Color(0.06, 0.13, 0.07),
				"sand": Color(0.46, 0.42, 0.29), "sea": Color(0.020, 0.055, 0.085) }
		MainGame.MAP_ALPINE:     # 冷白雪線
			c = { "rock": Color(0.17, 0.19, 0.24), "rock2": Color(0.21, 0.23, 0.28),
				"cliff": Color(0.10, 0.12, 0.17), "shade": Color(0.13, 0.15, 0.20),
				"grass": Color(0.12, 0.16, 0.14), "tree": Color(0.06, 0.11, 0.09),
				"sand": Color(0.40, 0.42, 0.44), "sea": Color(0.014, 0.038, 0.070) }
		MainGame.MAP_CITY:       # 濱海都會：冷灰水泥 + 都市綠地
			c = { "rock": Color(0.20, 0.21, 0.24), "rock2": Color(0.24, 0.25, 0.28),
				"cliff": Color(0.12, 0.13, 0.16), "shade": Color(0.16, 0.17, 0.20),
				"grass": Color(0.11, 0.19, 0.12), "tree": Color(0.06, 0.12, 0.07),
				"sand": Color(0.42, 0.40, 0.34), "sea": Color(0.020, 0.048, 0.078) }
		MainGame.MAP_TETON:      # 花崗岩巨峰 + 紅層大峽谷
			c = { "rock": Color(0.34, 0.22, 0.15), "rock2": Color(0.42, 0.27, 0.17),
				"cliff": Color(0.20, 0.20, 0.23), "shade": Color(0.22, 0.14, 0.10),
				"grass": Color(0.16, 0.20, 0.11), "tree": Color(0.07, 0.13, 0.07),
				"sand": Color(0.56, 0.44, 0.28), "sea": Color(0.022, 0.052, 0.082) }
		MainGame.MAP_RANGE:      # 灰岩山系
			c = { "rock": Color(0.24, 0.23, 0.21), "rock2": Color(0.29, 0.27, 0.24),
				"cliff": Color(0.14, 0.14, 0.14), "shade": Color(0.18, 0.17, 0.16),
				"grass": Color(0.14, 0.18, 0.10), "tree": Color(0.07, 0.12, 0.06),
				"sand": Color(0.44, 0.41, 0.33), "sea": Color(0.018, 0.045, 0.075) }
		_:                       # 峽谷：原本的冷色戰術風
			c = { "rock": Color(0.098, 0.106, 0.128), "rock2": Color(0.128, 0.120, 0.106),
				"cliff": Color(0.062, 0.070, 0.090), "shade": Color(0.080, 0.086, 0.104),
				"grass": Color(0.058, 0.092, 0.068), "tree": Color(0.040, 0.075, 0.052),
				"sand": Color(0.34, 0.31, 0.24), "sea": Color(0.018, 0.042, 0.072) }

	return {
		"rock":  make_terrain_material(c["rock"]),
		"rock2": make_terrain_material(c["rock2"]),
		"cliff": make_terrain_material(c["cliff"]),
		"shade": make_terrain_material(c["shade"]),
		"grass": make_terrain_material(c["grass"]),
		"tree":  make_terrain_material(c["tree"]),
		"sand":  make_terrain_material(c["sand"]),
		"snow":  make_terrain_material(Color(0.86, 0.89, 0.94)),
		"sea":   c["sea"],
		"vein":  make_material(Color(0.25, 0.55, 1.0), 2.4),
		"metal": make_material(Color(0.14, 0.15, 0.18)),
		"surf":  make_material(Color(0.60, 0.95, 1.00), 3.0),
	}


#══════════════════════════════════════════════════════════════════════════════
#  地形總入口
#══════════════════════════════════════════════════════════════════════════════
func _build_terrain() -> void:
	var terrain := Node3D.new()
	terrain.name = "Terrain"
	add_child(terrain)
	_terrain_node = terrain

	var m := _biome(_mg().map_id)

	_build_ocean(terrain, m)
	_build_coastline(terrain, m)

	match _mg().map_id:
		MainGame.MAP_PLAINS:
			_map_plains(terrain, m)
		MainGame.MAP_PLATEAU:
			_map_plateau(terrain, m)
		MainGame.MAP_RANGE:
			_map_transverse(terrain, m)
		MainGame.MAP_ALPINE:
			_map_alpine(terrain, m)
		MainGame.MAP_HILLS:
			_map_hills(terrain, m)
		MainGame.MAP_TETON:
			_teton.build(terrain, m)
		MainGame.MAP_CITY:
			_city.build(terrain, m)
		_:
			_map_canyon(terrain, m)

	# 戰場放大後，外環一律補上堤頓式巨峰與兩條側翼峽谷航道 ──
	# 不管抽到哪張地圖，地形都是廣泛分布的，而且到處都有低空穿線的路線。
	_teton.outer_ranges(terrain, m)

	# 每張地圖都放一座城區：高樓林立的市區同樣是低空掩體，
	# 建築會擋住視線，飛進大樓之間就能甩開飛彈鎖定。
	if _mg().map_id != MainGame.MAP_CITY:
		_city.district(terrain, m, Vector3(-980, 0, -760), 430.0, 190.0)
		_city.district(terrain, m, Vector3(760, 0, -1420), 320.0, 130.0)

	_build_base_props(terrain, m)
	_build_sea_features(terrain, m)


func _build_ocean(t: Node3D, m: Dictionary) -> void:
	var sea := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(MAP_LIMIT * 2.6, MAP_LIMIT * 2.6)
	sea.mesh = pm
	sea.material_override = make_terrain_material(m["sea"])
	t.add_child(sea)

	# 淺海帶：靠近陸地的水色變淺，讓海陸交界更明確
	var shallow := MeshInstance3D.new()
	var sp := PlaneMesh.new()
	sp.size = Vector2(MAP_LIMIT * 2.4, 420.0)
	shallow.mesh = sp
	shallow.material_override = make_terrain_material(Color(m["sea"]).lerp(Color(0.25, 0.55, 0.55), 0.35))
	shallow.position = Vector3(0, 0.4, COAST_Z + 150.0)
	t.add_child(shallow)


## 陸海分界：內陸台地 → 海崖 → 沙灘 → 碎浪線 → 淺海，一層一層做出來
func _build_coastline(t: Node3D, m: Dictionary) -> void:
	# 陸地主體（後緣，永遠不會露出海岸的鋸齒）
	var land_size := Vector3(MAP_LIMIT * 2.2, LAND_Y, absf(LAND_BACK - (COAST_Z - 180.0)))
	var land_pos := Vector3(0, LAND_Y * 0.5, (LAND_BACK + COAST_Z - 180.0) * 0.5)
	make_box(t, land_size, land_pos, m["grass"])
	# 陸地必須有實體碰撞：先前只建了網格，步行的飛行員會直接穿過地面掉出世界。
	# （進攻方沒事是因為航母船體本來就有 add_static_box。）
	add_static_box(t, land_size, land_pos)

	# 戰場放大後段數要跟著放大，否則海岸線的網格數會暴增
	var seg := 150.0
	var n := int(MAP_LIMIT * 2.2 / seg)
	for i in n:
		var x := -MAP_LIMIT * 1.1 + i * seg
		var bulge := _coast_bulge(x)
		var edge := COAST_Z + bulge                  # 這一段的海岸線位置
		var back := COAST_Z - 180.0

		# 這一段陸地的總深度；沙灘只佔靠海的一小條，其餘補草地，
		# 否則整片陸地會被沙色蓋掉、遠看變成一塊白板。
		var depth: float = edge - back
		if depth <= 4.0:
			continue
		var beach := minf(58.0, depth)
		make_box(t, Vector3(seg + 2.0, LAND_Y, beach),
			Vector3(x, LAND_Y * 0.5, edge - beach * 0.5), m["sand"])
		if depth > beach:
			make_box(t, Vector3(seg + 2.0, LAND_Y + 0.1, depth - beach),
				Vector3(x, (LAND_Y + 0.1) * 0.5, back + (depth - beach) * 0.5), m["grass"])

		# 海崖：讓陸地邊緣有落差而不是一片平的
		var ch: float = 6.0 + absf(_noise.get_noise_2d(x * 1.3, -2200.0)) * 26.0
		if ch > 12.0:
			_rock(t, "box", Vector3(seg + 2.0, ch, 26.0),
				Vector3(x, LAND_Y + ch * 0.5 - 2.0, back + 14.0), m["cliff"])

		# 碎浪線：貼在海岸線上的發光白帶，夜戰也看得出陸地在哪
		make_box(t, Vector3(seg + 2.0, 0.5, 7.0), Vector3(x, LAND_Y + 0.4, edge - 3.0), m["surf"])
		make_box(t, Vector3(seg + 2.0, 0.35, 3.0), Vector3(x, 1.2, edge + 9.0), m["surf"])

		# 灘外礁石
		if _rng.randf() < 0.30:
			var rh: float = _rng.randf_range(6.0, 18.0)
			_rock(t, "cone", Vector3(26, rh, 26),
				Vector3(x + _rng.randf_range(-40, 40), rh * 0.4, edge + _rng.randf_range(20, 70)),
				m["rock"], true, _rng.randf_range(0, TAU))

	# 陸地基準高度登記進高度圖，AI 才不會把陸地當海面
	for gi in GRID_N:
		for gj in GRID_N:
			var cell := GRID_SPAN / float(GRID_N)
			var wx := -GRID_SPAN * 0.5 + gi * cell
			var wz := -GRID_SPAN * 0.5 + gj * cell
			if wz < COAST_Z + _coast_bulge(wx):
				var idx := gj * GRID_N + gi
				if _hgrid[idx] < LAND_Y:
					_hgrid[idx] = LAND_Y


#══════════════════════════════════════════════════════════════════════════════
#  地圖 1：峽谷 CANYON ─ 兩道彎曲山脈夾出蜿蜒深谷，谷內有可穿越的岩拱
#══════════════════════════════════════════════════════════════════════════════
func _map_canyon(t: Node3D, m: Dictionary) -> void:
	# 主谷壁：兩條大致平行但各自蜿蜒的山脊鏈
	_ridge_chain(t, m, Vector3(-300, 0, 260), Vector3(-360, 0, -1300), 150.0, 190.0)
	_ridge_chain(t, m, Vector3(320, 0, 260), Vector3(280, 0, -1300), 150.0, 190.0)
	# 外圍第二層，讓谷看起來有縱深
	_ridge_chain(t, m, Vector3(-820, 0, 120), Vector3(-880, 0, -1200), 190.0, 240.0)
	_ridge_chain(t, m, Vector3(840, 0, 120), Vector3(800, 0, -1200), 190.0, 240.0)
	# 幾條橫向支脈伸進谷中，逼飛行員左右閃避
	for i in 4:
		var z: float = -180.0 - i * 260.0
		var side: float = 1.0 if i % 2 == 0 else -1.0
		_ridge_chain(t, m, Vector3(side * 300.0, 0, z),
			Vector3(side * 110.0, 0, z - 90.0), 110.0, 120.0)

	# 台地掩體
	for i in 12:
		var mp := _pick_spot(-900.0, 900.0, -1200.0, -400.0)
		if mp == Vector3.INF:
			continue
		var mh: float = _rng.randf_range(34.0, 78.0)
		var mw: float = _rng.randf_range(90.0, 190.0)
		_rock(t, "mesa", Vector3(mw, mh, mw), Vector3(mp.x, mh * 0.5, mp.z), m["rock2"],
			true, _rng.randf_range(0, TAU))
		make_box(t, Vector3(mw * 0.7, 0.5, 1.0), Vector3(mp.x, mh + 0.4, mp.z), m["vein"])

	# 岩拱門
	for i in 3:
		var ax: float = [-520.0, 560.0, -720.0][i]
		var az: float = [-560.0, -820.0, -400.0][i]
		var ah := 92.0
		_rock(t, "box", Vector3(26, ah, 30), Vector3(ax - 56, ah * 0.5, az), m["cliff"])
		_rock(t, "box", Vector3(26, ah, 30), Vector3(ax + 56, ah * 0.5, az), m["cliff"])
		_rock(t, "box", Vector3(160, 24, 30), Vector3(ax, ah + 12, az), m["cliff"])
		make_box(t, Vector3(140, 0.5, 1.0), Vector3(ax, ah + 24.4, az), m["vein"])

	_build_forest(t, m, 420, -1000.0, 1000.0, -1300.0, -380.0)


#══════════════════════════════════════════════════════════════════════════════
#  地圖 2：平原 PLAINS ─ 緩丘與大片林帶，天空開闊，適合純纏鬥
#══════════════════════════════════════════════════════════════════════════════
func _map_plains(t: Node3D, m: Dictionary) -> void:
	# 緩丘：用低矮寬闊的錐體堆出起伏地貌
	for i in 46:
		var p := _pick_spot(-1100.0, 1100.0, -1350.0, -370.0)
		if p == Vector3.INF:
			continue
		var h: float = 10.0 + absf(_noise.get_noise_2d(p.x, p.z)) * 46.0
		var w: float = _rng.randf_range(130.0, 280.0)
		_rock(t, "cone", Vector3(w, h, w), Vector3(p.x, LAND_Y + h * 0.5 - 3.0, p.z),
			m["grass"], h > 26.0, _rng.randf_range(0, TAU))

	# 孤立岩塔：平原上少數的垂直地標
	for i in 14:
		var p2 := _pick_spot(-1000.0, 1000.0, -1300.0, -400.0)
		if p2 == Vector3.INF:
			continue
		var h2: float = _rng.randf_range(56.0, 104.0)
		_rock(t, "prism", Vector3(30, h2, 30), Vector3(p2.x, h2 * 0.5, p2.z), m["rock"],
			true, _rng.randf_range(0, TAU))
		make_box(t, Vector3(22, 0.5, 0.9), Vector3(p2.x, h2 * 0.96, p2.z), m["vein"])

	_build_forest(t, m, 340, -1050.0, -260.0, -1250.0, -420.0)
	_build_forest(t, m, 340, 260.0, 1050.0, -1250.0, -420.0)
	_build_forest(t, m, 220, -320.0, 320.0, -1350.0, -1050.0)

	# 蜿蜒河流：沿著噪聲彎曲，給開闊地形方向感
	for i in 26:
		var rz: float = -380.0 - i * 40.0
		var rx: float = _noise.get_noise_2d(rz * 1.2, 900.0) * 320.0 + 300.0
		make_box(t, Vector3(58, 0.4, 44), Vector3(rx, LAND_Y + 0.3, rz),
			make_material(Color(0.05, 0.16, 0.26), 0.7))


#══════════════════════════════════════════════════════════════════════════════
#  地圖 3：高原 PLATEAU ─ 巨大台地被深切峽溝切開，可貼溝飛也可越頂
#══════════════════════════════════════════════════════════════════════════════
func _map_plateau(t: Node3D, m: Dictionary) -> void:
	var bw := 300.0
	var gap := 130.0
	for gx in 7:
		for gz in 5:
			var x := -3.0 * (bw + gap) + gx * (bw + gap)
			var z := -430.0 - gz * (bw * 0.78 + gap)
			var c := Vector3(x, 0, z)
			if _in_corridor(c, 90.0):
				continue
			var h: float = 78.0 + _noise.get_noise_2d(x, z) * 34.0
			if h < 30.0:
				continue
			_rock(t, "mesa", Vector3(bw, h, bw), Vector3(x, h * 0.5, z), m["rock2"],
				true, _rng.randf_range(0, TAU))
			# 台地邊緣發光線，夜戰能看出峽溝走向
			make_box(t, Vector3(bw * 0.8, 0.5, 1.0), Vector3(x, h + 0.4, z - bw * 0.34), m["vein"])
			make_box(t, Vector3(bw * 0.8, 0.5, 1.0), Vector3(x, h + 0.4, z + bw * 0.34), m["vein"])
			if _rng.randf() < 0.6:
				_build_forest(t, m, 34, x - bw * 0.32, x + bw * 0.32,
					z - bw * 0.28, z + bw * 0.28, h)

	# 溝底落石
	for i in 22:
		var p := _pick_spot(-1050.0, 1050.0, -1350.0, -400.0)
		if p == Vector3.INF:
			continue
		var h2: float = _rng.randf_range(16.0, 38.0)
		_rock(t, "cone", Vector3(34, h2, 34), Vector3(p.x, h2 * 0.5, p.z), m["rock"],
			true, _rng.randf_range(0, TAU))


#══════════════════════════════════════════════════════════════════════════════
#  地圖 4：橫斷山脈 TRANSVERSE ─ 橫向山嶺層層阻隔，隘口錯開，必須反覆穿越
#══════════════════════════════════════════════════════════════════════════════
func _map_transverse(t: Node3D, m: Dictionary) -> void:
	var lines := [
		{ "z": 300.0,   "h": 90.0,  "snow": false },
		{ "z": 60.0,    "h": 130.0, "snow": false },
		{ "z": -190.0,  "h": 160.0, "snow": true },
		{ "z": -450.0,  "h": 175.0, "snow": true },
		{ "z": -1250.0, "h": 140.0, "snow": true },
	]
	for li in lines.size():
		var line: Dictionary = lines[li]
		var z: float = line["z"]
		var h: float = line["h"]
		# 每道山嶺開兩個隘口，位置逐道錯開，逼玩家橫向機動
		var pass_a: float = _rng.randf_range(-950.0, -250.0)
		var pass_b: float = _rng.randf_range(250.0, 980.0)
		# 用山脊鏈拼出彎曲的山嶺，隘口處直接斷開
		_ridge_chain(t, m, Vector3(-1150, 0, z), Vector3(pass_a - 150.0, 0, z + 40.0),
			150.0, h, line["snow"])
		_ridge_chain(t, m, Vector3(pass_a + 150.0, 0, z - 30.0), Vector3(pass_b - 150.0, 0, z + 30.0),
			150.0, h, line["snow"])
		_ridge_chain(t, m, Vector3(pass_b + 150.0, 0, z - 40.0), Vector3(1150, 0, z),
			150.0, h, line["snow"])
		# 隘口標示燈，遠遠就能看到路在哪
		for px in [pass_a, pass_b]:
			make_sphere(t, 4.0, Vector3(px, 34.0, z), make_material(Color(1.0, 0.75, 0.25), 5.5))
			make_sphere(t, 4.0, Vector3(px, 70.0, z), make_material(Color(1.0, 0.75, 0.25), 5.5))

	_build_forest(t, m, 300, -1050.0, 1050.0, -1250.0, -520.0)


#══════════════════════════════════════════════════════════════════════════════
#  地圖 6：黃土丘陵 LOESS HILLS
#  連綿的圓潤土丘與沖蝕溝壑，遠方一道高山當背景，谷底有蜿蜒的綠色河道。
#══════════════════════════════════════════════════════════════════════════════
func _map_hills(t: Node3D, m: Dictionary) -> void:
	# 主體：整片起伏的丘陵，用多層不同尺度的圓丘疊出沖蝕紋理
	for i in 150:
		var p := _pick_spot(-1150.0, 1150.0, -1400.0, -360.0)
		if p == Vector3.INF:
			continue
		var n := _noise.get_noise_2d(p.x, p.z)
		var h: float = 26.0 + absf(n) * 92.0
		var w: float = _rng.randf_range(140.0, 300.0)
		# 迎光面用亮色、背光面用陰影色，交錯出照片裡那種明暗相間的稜脊
		var mat: StandardMaterial3D = m["rock"] if n > 0.0 else m["rock2"]
		_rock(t, "dome", Vector3(w, h, w), Vector3(p.x, 0.0, p.z), mat,
			h > 55.0, _rng.randf_range(0, TAU))
		# 每座丘陵掛幾個小丘當溝壑
		for k in 3:
			if _rng.randf() > 0.6:
				continue
			var ox := p.x + _rng.randf_range(-1.0, 1.0) * w * 0.55
			var oz := p.z + _rng.randf_range(-1.0, 1.0) * w * 0.55
			var sh: float = h * _rng.randf_range(0.30, 0.62)
			var sw: float = w * _rng.randf_range(0.34, 0.58)
			_rock(t, "dome", Vector3(sw, sh, sw), Vector3(ox, 0.0, oz), m["shade"], false,
				_rng.randf_range(0, TAU))

	# 遠景高山：在地圖最深處拉一道高稜線當天際線
	_ridge_chain(t, m, Vector3(-1150, 0, -1460), Vector3(1150, 0, -1400), 220.0, 300.0, true)

	# 蜿蜒的綠色河谷：沿噪聲彎曲，兩側鋪低矮綠丘
	for i in 40:
		var rz: float = -400.0 - i * 26.0
		var rx: float = _noise.get_noise_2d(rz * 1.4, 2600.0) * 460.0
		make_box(t, Vector3(70, 0.5, 30), Vector3(rx, LAND_Y + 0.4, rz),
			make_terrain_material(Color(0.14, 0.24, 0.11)))
		if _rng.randf() < 0.5:
			_rock(t, "dome", Vector3(90, 16, 90),
				Vector3(rx + _rng.randf_range(-90, 90), 0.0, rz), m["grass"], false)

	_build_forest(t, m, 260, -1100.0, 1100.0, -1400.0, -420.0)


#══════════════════════════════════════════════════════════════════════════════
#  地圖 5：高山 ALPINE ─ 高聳雪峰，飛行空間被壓縮到峰間縫隙
#══════════════════════════════════════════════════════════════════════════════
func _map_alpine(t: Node3D, m: Dictionary) -> void:
	# 主脈：三條長山脊構成骨架
	_ridge_chain(t, m, Vector3(-780, 0, 180), Vector3(-420, 0, -1250), 200.0, 300.0, true)
	_ridge_chain(t, m, Vector3(760, 0, 200), Vector3(400, 0, -1250), 200.0, 300.0, true)
	_ridge_chain(t, m, Vector3(-200, 0, -520), Vector3(220, 0, -1300), 180.0, 260.0, true)

	# 獨立高峰
	for i in 12:
		var p := _pick_spot(-1050.0, 1050.0, -1300.0, -300.0)
		if p == Vector3.INF:
			continue
		var h: float = _rng.randf_range(170.0, 330.0)
		var w: float = _rng.randf_range(160.0, 260.0)
		_rock(t, "cone", Vector3(w, h, w), Vector3(p.x, h * 0.5, p.z), m["rock"],
			true, _rng.randf_range(0, TAU))
		make_cyl(t, w * 0.07, w * 0.23, h * 0.26, Vector3(p.x, h * 0.87, p.z), m["snow"])
		make_sphere(t, 3.5, Vector3(p.x, h + 3.0, p.z), make_material(Color(0.7, 0.9, 1.0), 4.5))

	# 海上前哨孤峰
	for i in 7:
		var p2 := _pick_spot(-800.0, 800.0, 60.0, 460.0)
		if p2 == Vector3.INF:
			continue
		var h2: float = _rng.randf_range(90.0, 180.0)
		_rock(t, "cone", Vector3(120, h2, 120), Vector3(p2.x, h2 * 0.5, p2.z), m["rock"],
			true, _rng.randf_range(0, TAU))
		make_cyl(t, 5.0, 16.0, h2 * 0.22, Vector3(p2.x, h2 * 0.88, p2.z), m["snow"])

	# 冰河：低處的發光帶，當低空航道指引
	for i in 5:
		var gx: float = -700.0 + i * 350.0
		make_box(t, Vector3(44, 0.5, 900), Vector3(gx, LAND_Y + 0.4, -900),
			make_material(Color(0.35, 0.75, 1.0), 1.6))

	_build_forest(t, m, 140, -1000.0, 1000.0, -1350.0, -900.0)


#══════════════════════════════════════════════════════════════════════════════
#  共用設施：水壩、大橋、雷達站、油庫、機庫
#══════════════════════════════════════════════════════════════════════════════
func _build_base_props(t: Node3D, m: Dictionary) -> void:
	var metal: StandardMaterial3D = m["metal"]
	var vein: StandardMaterial3D = m["vein"]

	# 水壩 + 跨谷大橋
	_rock(t, "box", Vector3(120, 56, 22), Vector3(-620, 28, -600), metal)
	make_box(t, Vector3(112, 1.0, 2.0), Vector3(-620, 56.4, -600), vein)
	for i in 5:
		_rock(t, "box", Vector3(12, 60, 12), Vector3(-720 + i * 50, 30, -900), metal)
	make_box(t, Vector3(260, 4, 24), Vector3(-620, 62, -900), metal)

	# 雷達站
	var radar := Node3D.new()
	radar.position = Vector3(660, 0, -1010)
	t.add_child(radar)
	make_cyl(radar, 4, 5, 34, Vector3(0, 17, 0), metal)
	var dish := make_cyl(radar, 1.0, 18.0, 5.0, Vector3(0, 36, 0), make_material(MainGame.C_DEF, 1.8))
	dish.rotation_degrees = Vector3(-40, 0, 0)
	_stamp_height(radar.position, 26.0, 42.0)
	add_static_box(radar, Vector3(10, 34, 10), Vector3(0, 17, 0))

	# 油庫
	for i in 4:
		make_cyl(t, 14, 14, 18, Vector3(520 + i * 38, 9, -1120), metal)
		make_cyl(t, 14.5, 14.5, 1.0, Vector3(520 + i * 38, 18.5, -1120),
			make_material(Color(1.0, 0.7, 0.2), 1.6))

	# 機庫（跑道旁）
	for i in 4:
		var hx := -150.0 if i < 2 else 150.0
		var hz := RUNWAY_POS.z + (-60.0 if i % 2 == 0 else 60.0)
		make_box(t, Vector3(38, 18, 52), Vector3(hx, LAND_Y + 9, hz), metal)
		make_box(t, Vector3(39, 1.0, 2.0), Vector3(hx, LAND_Y + 18.5, hz), vein)
		add_static_box(t, Vector3(38, 18, 52), Vector3(hx, LAND_Y + 9, hz))
		_stamp_height(Vector3(hx, 0, hz), 32.0, LAND_Y + 18.0)


func _build_forest(parent: Node3D, m: Dictionary, count: int,
		x0: float, x1: float, z0: float, z1: float, base_y: float = -1.0) -> void:
	if count <= 0:
		return
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var cone := CylinderMesh.new()
	cone.top_radius = 0.2
	cone.bottom_radius = 4.5
	cone.height = 20.0
	cone.radial_segments = 5
	mm.mesh = cone
	mm.instance_count = count
	for i in count:
		var x := _rng.randf_range(x0, x1)
		var z := _rng.randf_range(z0, z1)
		var sc := _rng.randf_range(0.6, 1.7)
		var y := (LAND_Y if base_y < 0.0 else base_y) + 10.0 * sc
		mm.set_instance_transform(i, Transform3D(
			Basis().rotated(Vector3.UP, _rng.randf_range(0, TAU)).scaled(Vector3(sc, sc, sc)),
			Vector3(x, y, z)))
	mmi.multimesh = mm
	mmi.material_override = m["tree"]
	parent.add_child(mmi)


func _build_sea_features(parent: Node3D, m: Dictionary) -> void:
	var rock: StandardMaterial3D = m["rock"]
	var rock2: StandardMaterial3D = m["rock2"]
	var metal: StandardMaterial3D = m["metal"]
	var vein: StandardMaterial3D = m["vein"]

	# 島嶼：環礁平台 + 圓錐山
	for i in 11:
		var ip := _pick_spot(-1000.0, 1000.0, 60.0, 720.0)
		if ip == Vector3.INF:
			continue
		var ih: float = _rng.randf_range(44.0, 118.0)
		var iw: float = _rng.randf_range(70.0, 160.0)
		make_cyl(parent, iw * 0.58, iw * 0.95, 6.0, Vector3(ip.x, 2.5, ip.z), rock2)
		make_cyl(parent, iw * 0.62, iw * 1.02, 1.0, Vector3(ip.x, 5.6, ip.z), m["sand"])
		_rock(parent, "cone", Vector3(iw, ih, iw), Vector3(ip.x, ih * 0.5, ip.z), rock,
			true, _rng.randf_range(0, TAU))
		if _rng.randf() < 0.5:
			make_box(parent, Vector3(iw * 0.4, 0.5, 0.8), Vector3(ip.x, ih * 0.92, ip.z), vein)

	# 孤立岩礁（低空航線障礙）
	for i in 18:
		var rp := _pick_spot(-900.0, 900.0, 100.0, 700.0)
		if rp == Vector3.INF:
			continue
		var h2: float = _rng.randf_range(20.0, 62.0)
		_rock(parent, "prism", Vector3(34, h2, 34), Vector3(rp.x, h2 * 0.5, rp.z), rock,
			true, _rng.randf_range(0, TAU))

	# 燈塔
	var lh := Vector3(-760, 0, 300)
	make_cyl(parent, 6, 10, 54, lh + Vector3(0, 27, 0), make_material(Color(0.16, 0.17, 0.20)))
	make_sphere(parent, 6.0, lh + Vector3(0, 56, 0), make_material(Color(1.0, 0.85, 0.35), 6.5))
	var beacon := OmniLight3D.new()
	beacon.position = lh + Vector3(0, 56, 0)
	beacon.light_color = Color(1.0, 0.85, 0.4)
	beacon.light_energy = 5.0
	beacon.omni_range = 240.0
	parent.add_child(beacon)
	add_static_box(parent, Vector3(16, 54, 16), lh + Vector3(0, 27, 0))
	_stamp_height(lh, 20.0, 60.0)

	# 鑽油平台
	for i in 3:
		var px: float = [420.0, -480.0, 760.0][i]
		var pz: float = [540.0, 230.0, 430.0][i]
		var base := Vector3(px, 0, pz)
		for c in 4:
			var off := Vector3(-18 if c % 2 == 0 else 18, 16, -18 if c < 2 else 18)
			make_cyl(parent, 3.0, 3.0, 34, base + off, metal)
		make_box(parent, Vector3(56, 4, 56), base + Vector3(0, 34, 0), metal)
		make_box(parent, Vector3(10, 38, 10), base + Vector3(0, 54, 0), metal)
		make_sphere(parent, 3.0, base + Vector3(0, 75, 0), make_material(Color(1.0, 0.35, 0.15), 5.0))
		add_static_box(parent, Vector3(56, 5, 56), base + Vector3(0, 34, 0))
		_stamp_height(base, 34.0, 75.0)

	# 擱淺貨輪（卡在海岸線上，強化陸海交界的視覺）
	var sh := Vector3(300, 0, COAST_Z + 40.0)
	make_box(parent, Vector3(34, 16, 170), sh + Vector3(0, 7, 0), make_material(Color(0.13, 0.10, 0.09)))
	make_box(parent, Vector3(22, 20, 32), sh + Vector3(0, 24, 52), make_material(Color(0.16, 0.13, 0.11)))
	make_cyl(parent, 2.5, 2.5, 28, sh + Vector3(0, 44, 52), metal)
	add_static_box(parent, Vector3(34, 16, 170), sh + Vector3(0, 7, 0))
	_stamp_height(sh, 50.0, 34.0)


#══════════════════════════════════════════════════════════════════════════════
#  設施：航艦 / 跑道 / 核設施 / 防空塔
#══════════════════════════════════════════════════════════════════════════════
func _register_structure(key: String, node: Node3D, team: int, kind: String, hp: float) -> void:
	structures[key] = { "node": node, "hp": hp, "max": hp, "team": team, "kind": kind }
	# 讓砲彈能從碰撞體回查是哪一棟建築
	for c in node.get_children():
		if c is StaticBody3D:
			c.set_meta("struct_key", key)


func _build_carrier() -> void:
	var root := Node3D.new()
	root.name = "Carrier"
	# 部署階段從遠海駛來，時間到剛好停在 CARRIER_POS，
	# 之後所有彈射／停機座標都以 CARRIER_POS 為準，不受過場影響。
	root.position = CARRIER_POS + Vector3(0, 0, CARRIER_APPROACH)
	add_child(root)
	_carrier_node = root

	var hull := make_material(Color(0.10, 0.11, 0.14))
	var deck := make_material(Color(0.14, 0.15, 0.19))
	var glow := make_material(MainGame.C_ATK, 3.0)

	var dark := make_material(Color(0.07, 0.08, 0.10))
	var warn := make_material(Color(1.0, 0.72, 0.15), 2.6)

	# ── 船體：主體 + 收窄的艦艏 + 艦艉 ──
	make_box(root, Vector3(58, 16, 240), Vector3(0, 8, 10), hull)
	# 艦艏用逐段收窄的箱體做出破浪外形。
	# （原本用旋轉的 PrismMesh，尖端會穿出飛行甲板變成甲板上的三角體。）
	for i in 4:
		var f := float(i) / 4.0
		make_box(root, Vector3(58.0 - f * 34.0, 16.0 - f * 5.0, 20),
			Vector3(0, 8.0 - f * 2.0, -100.0 - i * 20.0), hull)
	make_box(root, Vector3(50, 14, 30), Vector3(0, 7, 140), hull)
	# 吃水線（深色帶）與艦體側面陰影
	make_box(root, Vector3(59, 5, 300), Vector3(0, 2.5, 5), dark)

	# ── 飛行甲板：主甲板 + 左側外伸的斜角甲板 ──
	make_box(root, Vector3(64, 2.0, 290), Vector3(0, 16.5, 0), deck)
	var angled := make_box(root, Vector3(30, 1.8, 160), Vector3(-30, 16.5, -40), deck)
	angled.rotation_degrees = Vector3(0, 9.0, 0)       # 斜角甲板向左外伸 9 度
	# 甲板邊緣護欄
	make_box(root, Vector3(1.2, 2.4, 290), Vector3(32.6, 18.0, 0), dark)
	make_box(root, Vector3(1.2, 2.4, 290), Vector3(-32.6, 18.0, 0), dark)

	# ── 艦島：分層塔體 + 桅桿 + 旋轉雷達 ──
	var island := Node3D.new()
	island.position = Vector3(26, 17.5, 60)
	root.add_child(island)
	make_box(island, Vector3(14, 12, 40), Vector3(0, 6, 0), hull)
	make_box(island, Vector3(11, 8, 26), Vector3(0, 16, -2), hull)
	make_box(island, Vector3(12.4, 1.0, 27), Vector3(0, 20.4, -2), glow)   # 艦橋窗帶
	make_box(island, Vector3(2.0, 22, 2.0), Vector3(0, 31, 6), dark)       # 桅桿
	make_box(island, Vector3(9, 0.8, 0.8), Vector3(0, 38, 6), dark)
	var cradar := make_box(island, Vector3(10, 0.6, 3.0), Vector3(0, 42, 6), glow)
	_carrier_radar = cradar
	make_sphere(island, 1.6, Vector3(0, 44, 6), make_material(Color(1.0, 0.3, 0.2), 5.0))

	# ── 甲板標線 ──
	# 兩條彈射器導軌（進攻方就是從這裡被彈出去的）
	make_box(root, Vector3(2.6, 0.4, 210), Vector3(-11, 17.6, -30), glow)
	make_box(root, Vector3(2.6, 0.4, 210), Vector3(11, 17.6, -30), glow)
	# 中線虛線
	for i in 13:
		make_box(root, Vector3(2.2, 0.35, 12), Vector3(0, 17.6, -130 + i * 22), deck)
	# 攔阻索
	for i in 4:
		make_box(root, Vector3(52, 0.3, 0.8), Vector3(-4, 17.6, 40 + i * 16), warn)
	# 降落區邊線與甲板前緣
	make_box(root, Vector3(0.8, 0.35, 160), Vector3(-45, 17.5, -40), warn)
	make_box(root, Vector3(62, 0.5, 2.4), Vector3(0, 17.8, -146),
		make_material(Color(0.3, 1.0, 0.6), 4.0))
	# 甲板邊燈
	for i in 15:
		make_box(root, Vector3(0.8, 0.5, 2.4), Vector3(32.0, 18.2, -140 + i * 20), warn)
		make_box(root, Vector3(0.8, 0.5, 2.4), Vector3(-32.0, 18.2, -140 + i * 20), warn)

	# ── 艦艏破浪與艦艉航跡 ──
	_build_carrier_wake(root)

	add_static_box(root, Vector3(58, 16, 300), Vector3(0, 8, 0))
	_register_structure("CARRIER", root, MainGame.TEAM_ATTACKER, "carrier", 3000.0)


## 艦艏破浪 + 艦艉航跡：全部用 GPUParticles3D，讓航母看起來是在「開」而不是停著
func _build_carrier_wake(root: Node3D) -> void:
	var foam := StandardMaterial3D.new()
	foam.albedo_color = Color(0.92, 0.97, 1.0, 0.32)
	foam.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	foam.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	foam.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	foam.emission_enabled = true
	foam.emission = Color(0.75, 0.90, 1.0)
	foam.emission_energy_multiplier = 1.6

	var quad := QuadMesh.new()
	quad.size = Vector2(4.5, 4.5)

	# 艦艏兩側的破浪
	for s in [-1.0, 1.0]:
		var p := GPUParticles3D.new()
		p.amount = 90
		p.lifetime = 3.2
		p.position = Vector3(s * 22.0, 2.0, -140.0)
		p.draw_pass_1 = quad
		p.material_override = foam
		var pm := ParticleProcessMaterial.new()
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = Vector3(4, 1, 10)
		pm.direction = Vector3(s * 0.9, 0.25, 1.0)
		pm.spread = 18.0
		pm.initial_velocity_min = 10.0
		pm.initial_velocity_max = 20.0
		pm.gravity = Vector3(0, -1.5, 0)
		pm.scale_min = 0.5
		pm.scale_max = 1.6
		pm.color = Color(1, 1, 1, 0.7)
		p.process_material = pm
		root.add_child(p)

	# 艦艉航跡：長長的白色尾流
	var wake := GPUParticles3D.new()
	wake.amount = 200
	wake.lifetime = 9.0
	wake.position = Vector3(0, 1.5, 150.0)
	wake.draw_pass_1 = quad
	wake.material_override = foam
	var wm := ParticleProcessMaterial.new()
	wm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	wm.emission_box_extents = Vector3(26, 0.5, 4)
	wm.direction = Vector3(0, 0, 1)
	wm.spread = 12.0
	wm.initial_velocity_min = 6.0
	wm.initial_velocity_max = 14.0
	wm.gravity = Vector3.ZERO
	wm.scale_min = 1.0
	wm.scale_max = 3.0
	wm.color = Color(1, 1, 1, 0.45)
	wake.process_material = wm
	root.add_child(wake)


#══════════════════════════════════════════════════════════════════════════════
#  護航艦隊：航母周圍的防空火網
#══════════════════════════════════════════════════════════════════════════════
func _build_escort_fleet() -> void:
	if _carrier_node == null:
		return
	_fleet = load("res://EscortFleet.gd").new()
	_fleet.name = "EscortFleet"
	_fleet.world = self
	_fleet.build(_carrier_node, MainGame.TEAM_ATTACKER)


## CIWS 近迫防空砲：一串密集曳光（傷害已由房主裁決，這裡只做視覺）
@rpc("authority", "call_remote", "reliable")
func cli_ship_ciws(key: String, from: Vector3, to: Vector3) -> void:
	if not structures.has(key):
		return
	for i in 3:
		var jitter := Vector3(_rng.randf_range(-6, 6), _rng.randf_range(-6, 6),
			_rng.randf_range(-6, 6))
		cli_gun_tracer(-9998, from, to + jitter, false)
	_spawn_flash(from, 2.6, Color(1.0, 0.85, 0.45))


## 艦對空飛彈
@rpc("authority", "call_remote", "reliable")
func cli_ship_sam(key: String, target_id: int) -> void:
	if not structures.has(key) or not aircraft.has(target_id):
		return
	var origin: Vector3 = (structures[key]["node"] as Node3D).global_position + Vector3.UP * 14.0
	var tgt: Aircraft = aircraft[target_id]
	var pr := Projectile.new()
	pr.world = self
	pr.team = int(structures[key]["team"])
	pr.shooter = -9998
	pr.is_bomb = false
	pr.damage = 26.0 * _dmg_mult(pr.team)
	pr.struct_mult = 0.2
	pr.vel = (tgt.global_position - origin).normalized() * 165.0
	pr.homing_target = tgt
	pr.turn = 2.8
	pr.life = 8.0
	pr.kind = "sam"
	add_child(pr)
	pr.global_position = origin
	pr.setup()
	play_sfx("missile", -20.0)


#══════════════════════════════════════════════════════════════════════════════
#  陸軍：高射砲陣地 / 機動防空車 / 補給車隊 / 地勤
#══════════════════════════════════════════════════════════════════════════════
func _build_ground_forces() -> void:
	_ground = load("res://GroundForces.gd").new()
	_ground.name = "GroundForces"
	_ground.w = self
	_ground.land_y = LAND_Y
	_ground.runway_pos = RUNWAY_POS
	_ground.nuke_pos = NUKE_POS
	_ground.build(self, _biome(_mg().map_id))


## 高射砲的空爆彈幕（純視覺，傷害已由房主裁決）
@rpc("authority", "call_remote", "reliable")
func cli_flak_burst(pos: Vector3) -> void:
	for i in 3:
		var off := Vector3(_rng.randf_range(-14, 14), _rng.randf_range(-10, 10),
			_rng.randf_range(-14, 14))
		_spawn_flash(pos + off, 5.0, Color(0.95, 0.85, 0.55))
	play_sfx("explode", -24.0)


## 機動防空車發射的地對空飛彈
@rpc("authority", "call_remote", "reliable")
func cli_ground_sam(key: String, target_id: int) -> void:
	if not structures.has(key) or not aircraft.has(target_id):
		return
	var origin: Vector3 = (structures[key]["node"] as Node3D).global_position + Vector3.UP * 5.0
	var tgt: Aircraft = aircraft[target_id]
	var pr := Projectile.new()
	pr.world = self
	pr.team = MainGame.TEAM_DEFENDER
	pr.shooter = -9997
	pr.is_bomb = false
	pr.damage = 18.0
	pr.struct_mult = 0.2
	pr.vel = (tgt.global_position - origin).normalized() * 150.0
	pr.homing_target = tgt
	pr.turn = 2.1                    # 轉向較鈍，拉大 G 甩得掉
	pr.life = 7.5
	pr.kind = "sam"
	add_child(pr)
	pr.global_position = origin
	pr.setup()
	play_sfx("missile", -20.0)


## 補給車隊結算：抵達＝防守方補彈，全滅＝進攻方得利
@rpc("authority", "call_remote", "reliable")
func cli_convoy_result(arrived: bool, count: int) -> void:
	var me_def := _mg().my_team() == MainGame.TEAM_DEFENDER
	if arrived:
		# 防守方全隊補滿機槍彈與干擾彈
		for pid in aircraft:
			var a: Aircraft = aircraft[pid]
			if a.team != MainGame.TEAM_DEFENDER or not a.alive:
				continue
			a.gun_ammo = int(a.stats["gun_ammo"])
			a.flares = 6
		_mg().add_chat_line("[補給] 車隊抵達跑道（%d 車）─ 防守方彈藥與干擾彈補滿。" % count,
			MainGame.C_DEF)
		officer_say("補給到了，彈藥補滿 ─ 繼續守。" if me_def
			else "他們的補給進了跑道，早知道就順手拆掉。", "good" if me_def else "calm", 3)
	else:
		# 全滅：防空塔與陣地射速下降 60 秒
		for t in towers:
			t["cd"] = float(t["cd"]) + 2.0
		_mg().add_chat_line("[補給] 補給車隊被全滅 ─ 防守方防空火力轉弱。", MainGame.C_ATK)
		officer_say("補給車隊被打光了，防空火力會撐不住。" if me_def
			else "車隊清乾淨了 ─ 他們的防空要斷炊了。", "urgent" if me_def else "good", 3)
		if not me_def:
			_mg().add_credits(120, "殲滅補給車隊")


func _build_runway() -> void:
	var root := Node3D.new()
	root.name = "Runway"
	root.position = RUNWAY_POS + Vector3.UP * LAND_Y   # 坐落在陸地面上
	add_child(root)

	var pave := make_material(Color(0.11, 0.12, 0.15))
	var glow := make_material(MainGame.C_DEF, 3.4)

	make_box(root, Vector3(48, 2.0, 340), Vector3(0, 1.0, 0), pave)
	for i in 15:
		make_box(root, Vector3(3.0, 0.4, 16), Vector3(0, 2.1, -160 + i * 23), glow)
	# 兩側跑道燈
	for i in 16:
		make_box(root, Vector3(1.1, 0.4, 4), Vector3(-24.5, 2.1, -162 + i * 22), glow)
		make_box(root, Vector3(1.1, 0.4, 4), Vector3(24.5, 2.1, -162 + i * 22), glow)
	# 塔台
	make_box(root, Vector3(12, 28, 12), Vector3(-48, 14, -90), pave)
	make_box(root, Vector3(16, 5, 16), Vector3(-48, 30, -90), make_material(MainGame.C_DEF, 1.6))

	add_static_box(root, Vector3(48, 2.4, 340), Vector3(0, 1.0, 0))
	_register_structure("RUNWAY", root, MainGame.TEAM_DEFENDER, "runway", 420.0)


func _build_nuclear_facility() -> void:
	var root := Node3D.new()
	root.name = "NuclearFacility"
	root.position = NUKE_POS + Vector3.UP * LAND_Y     # 坐落在陸地面上
	add_child(root)

	var conc := make_material(Color(0.13, 0.14, 0.13))
	var core := make_material(Color(0.35, 1.0, 0.35), 5.0)
	var warn := make_material(Color(1.0, 0.85, 0.15), 3.0)

	# 冷卻塔
	make_cyl(root, 16, 24, 46, Vector3(-26, 23, 0), conc)
	make_cyl(root, 16, 24, 46, Vector3(26, 23, 8), conc)
	make_cyl(root, 15, 15, 2, Vector3(-26, 46.5, 0), core)
	make_cyl(root, 15, 15, 2, Vector3(26, 46.5, 8), core)
	# 反應爐圓頂
	make_cyl(root, 20, 20, 22, Vector3(0, 11, -34), conc)
	make_sphere(root, 20, Vector3(0, 22, -34), core)
	# 圍牆與警示燈
	make_box(root, Vector3(120, 6, 2), Vector3(0, 3, 40), conc)
	make_box(root, Vector3(120, 6, 2), Vector3(0, 3, -70), conc)
	for i in 6:
		make_box(root, Vector3(2, 1, 2), Vector3(-50 + i * 20, 6.5, 40), warn)

	add_static_box(root, Vector3(40, 46, 30), Vector3(-26, 23, 0))
	add_static_box(root, Vector3(40, 46, 30), Vector3(26, 23, 8))
	add_static_box(root, Vector3(40, 44, 40), Vector3(0, 22, -34))

	_register_structure("NUKE", root, MainGame.TEAM_DEFENDER, "nuke", 1200.0)


func _build_initial_towers() -> void:
	_make_tower(Vector3(-230, 0, -640))
	_make_tower(Vector3(230, 0, -640))
	_make_tower(Vector3(0, 0, -480))


func _make_tower(pos: Vector3) -> void:
	var idx := towers.size()
	var ground := maxf(terrain_height(pos), LAND_Y if is_land(pos) else 0.0)
	var key := "TOWER_%d" % idx
	var root := Node3D.new()
	root.name = key
	root.position = Vector3(pos.x, ground, pos.z)
	add_child(root)

	var body := make_material(Color(0.12, 0.13, 0.16))
	var glow := make_material(MainGame.C_DEF, 3.0)
	make_cyl(root, 3.5, 5.0, 12, Vector3(0, 6, 0), body)
	var turret := make_box(root, Vector3(6, 3, 6), Vector3(0, 13.5, 0), body)
	make_box(root, Vector3(0.9, 0.9, 9), Vector3(0, 13.5, -5), glow)
	make_sphere(root, 1.2, Vector3(0, 16, 0), glow)

	add_static_box(root, Vector3(7, 12, 7), Vector3(0, 6, 0))
	_register_structure(key, root, MainGame.TEAM_DEFENDER, "tower", 180.0)
	towers.append({ "key": key, "node": root, "turret": turret, "cd": 0.0, "range": 320.0 })


#══════════════════════════════════════════════════════════════════════════════
#  攝影機
#══════════════════════════════════════════════════════════════════════════════
func _build_camera() -> void:
	_cam_pivot = Node3D.new()
	_cam_pivot.name = "CamPivot"
	add_child(_cam_pivot)
	_cam = Camera3D.new()
	_cam.fov = 78.0
	_cam.far = 5200.0
	_cam.current = true
	_cam_pivot.add_child(_cam)
	_cam.position = Vector3(0, 6, 20)


#══════════════════════════════════════════════════════════════════════════════
#  戰術部署階段
#    防守方：俯瞰全息立體地圖，點擊配置防空炮
#    進攻方：航母乘風破浪駛近海岸的過場鏡頭
#══════════════════════════════════════════════════════════════════════════════
func _build_deploy_ui() -> void:
	_deploy_root = Control.new()
	_deploy_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_deploy_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_deploy_root)

	# 上下黑邊，做出過場的電影感
	for side in [true, false]:
		var bar := ColorRect.new()
		bar.color = Color(0, 0, 0, 0.82)
		bar.set_anchors_preset(Control.PRESET_TOP_WIDE if side else Control.PRESET_BOTTOM_WIDE)
		bar.offset_bottom = 84.0 if side else 0.0
		bar.offset_top = 0.0 if side else -84.0
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_deploy_root.add_child(bar)

	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_CENTER_TOP)
	v.offset_left = -520; v.offset_right = 520; v.offset_top = 14
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_deploy_root.add_child(v)

	var t := _hud_label("作 戰 部 署", 26, Color.WHITE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	_lbl_deploy_time = _hud_label("", 20, Color(1.0, 0.85, 0.35))
	_lbl_deploy_time.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_lbl_deploy_time)

	_lbl_deploy_hint = _hud_label("", 17, MainGame.C_TEXT)
	_lbl_deploy_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_lbl_deploy_hint.offset_left = -600; _lbl_deploy_hint.offset_right = 600
	_lbl_deploy_hint.offset_top = -70; _lbl_deploy_hint.offset_bottom = -14
	_lbl_deploy_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_deploy_root.add_child(_lbl_deploy_hint)

	_lbl_deploy_count = _hud_label("", 18, MainGame.C_DEF)
	_lbl_deploy_count.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_lbl_deploy_count.offset_left = 24; _lbl_deploy_count.offset_top = 100
	_deploy_root.add_child(_lbl_deploy_count)


## 全息立體地圖：用高度圖跑 marching squares 產生等高線，做成漂浮的全息投影。
## 部署期間會把實體地形藏起來，只留下發光的等高線。
const HOLO_HALF   := 620.0     # 可部署範圍半徑（黃框）
const HOLO_SCAN   := 2200.0    # 等高線取樣半徑：整張（放大後的）地圖都要畫
const HOLO_STEP   := 12.0      # 等高線間距（公尺）─ 越小越密
const HOLO_LEVELS := 26        # 等高線層數

func _build_holo_map() -> void:
	_holo = Node3D.new()
	_holo.name = "HoloMap"
	_holo.visible = false
	add_child(_holo)

	var cx := RUNWAY_POS.x
	var cz := RUNWAY_POS.z

	# ── 等高線 ──
	var im := ImmediateMesh.new()
	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.vertex_color_use_as_albedo = true
	line_mat.emission_enabled = true
	# 遠處山脈的等高線會密集擠在一起，發光疊加後整片爆白，所以亮度壓低
	line_mat.emission_energy_multiplier = 0.35
	line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	line_mat.disable_fog = true

	# 取樣間距：越小線條越平滑。掃描半徑放大後同步放寬間距，
	# 否則 marching squares 的格數是平方成長，載入會卡住好幾秒。
	var s := 32.0
	var n := int(HOLO_SCAN * 2.0 / s)

	im.surface_begin(Mesh.PRIMITIVE_LINES, line_mat)
	for lv in HOLO_LEVELS:
		var level := LAND_Y + float(lv + 1) * HOLO_STEP
		# 低處冷藍、高處暖橙，一眼看出地勢
		var f := float(lv) / float(HOLO_LEVELS - 1)
		var col := Color(0.25, 0.85, 1.0).lerp(Color(1.0, 0.72, 0.30), f)
		# 海拔越高的線越淡：高處線條最密，不壓下來會糊成一片白
		var fade := 1.0 - f * 0.55
		col.a = (0.85 if lv % 5 == 0 else 0.20) * fade        # 每四條加粗一條計曲線
		for gj in n:
			for gi in n:
				_holo_cell_at(im, cx - HOLO_SCAN + gi * s, cz - HOLO_SCAN + gj * s, s, level, col)

	im.surface_end()

	var mi := MeshInstance3D.new()
	mi.mesh = im
	_holo.add_child(mi)


	# ── 掃描基準面與外框 ──
	var base := make_material(MainGame.C_DEF, 0.6)
	base.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	base.albedo_color = Color(MainGame.C_DEF.r, MainGame.C_DEF.g, MainGame.C_DEF.b, 0.06)
	base.disable_fog = true
	make_box(_holo, Vector3(HOLO_SCAN * 2.0, 0.2, HOLO_SCAN * 2.0),
		Vector3(cx, LAND_Y - 1.0, cz), base)



	# 標出要守的目標
	for target in [{ "p": RUNWAY_POS, "c": MainGame.C_DEF, "t": "跑道" },
			{ "p": NUKE_POS, "c": Color(0.4, 1.0, 0.4), "t": "核設施" }]:
		var mark := Label3D.new()
		mark.text = String(target["t"])
		mark.font_size = 64
		mark.pixel_size = 0.14
		mark.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		mark.no_depth_test = true
		mark.modulate = target["c"]
		mark.outline_size = 16
		mark.position = Vector3(target["p"].x, LAND_Y + 120.0, target["p"].z)
		_holo.add_child(mark)
		make_cyl(_holo, 2.0, 2.0, 110.0, Vector3(target["p"].x, LAND_Y + 55.0, target["p"].z),
			make_material(target["c"], 2.0))


## 高度圖是「整塊填最大值」的網格，直接拿去畫等高線只會得到一堆格線。
## 這裡用雙線性內插把它當成平滑高度場取樣，等高線才會是有機的曲線。
func _holo_h(x: float, z: float) -> float:
	var cell := GRID_SPAN / float(GRID_N)
	var fx := (x + GRID_SPAN * 0.5) / cell
	var fz := (z + GRID_SPAN * 0.5) / cell
	var i := int(floor(fx))
	var j := int(floor(fz))
	if i < 0 or j < 0 or i + 1 >= GRID_N or j + 1 >= GRID_N:
		return 0.0
	var tx := fx - float(i)
	var tz := fz - float(j)
	var h00 := _hgrid[j * GRID_N + i]
	var h10 := _hgrid[j * GRID_N + i + 1]
	var h01 := _hgrid[(j + 1) * GRID_N + i]
	var h11 := _hgrid[(j + 1) * GRID_N + i + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


## 邊上的交點比例，永遠落在 0~1 之間
func _cross_t(ha: float, hb: float, level: float) -> float:
	var d := hb - ha
	if absf(d) < 0.0001:
		return 0.5
	return clampf((level - ha) / d, 0.0, 1.0)


## Marching squares：在平滑高度場上找等高線穿過的位置，畫成線段
func _holo_cell_at(im: ImmediateMesh, x0: float, z0: float, s: float,
		level: float, col: Color) -> void:
	var x1 := x0 + s
	var z1 := z0 + s
	var h00 := _holo_h(x0, z0)
	var h10 := _holo_h(x1, z0)
	var h01 := _holo_h(x0, z1)
	var h11 := _holo_h(x1, z1)

	# 完全平坦或整格都在同一側，就不可能有等高線穿過
	var mn := minf(minf(h00, h10), minf(h01, h11))
	var mx := maxf(maxf(h00, h10), maxf(h01, h11))
	if mx - mn < 0.02 or level < mn or level > mx:
		return

	var pts: Array = []
	# 四條邊各檢查一次是否被等高線切過，切過就內插出交點。
	# 除數必須保留正負號──先前用 maxf(diff, 0.0001) 會把下降邊的負差值
	# 夾成 0.0001，t 爆成天文數字，交點飛出格外變成貫穿全圖的長直線。
	if (h00 < level) != (h10 < level):
		pts.append(Vector3(lerpf(x0, x1, _cross_t(h00, h10, level)), level, z0))
	if (h10 < level) != (h11 < level):
		pts.append(Vector3(x1, level, lerpf(z0, z1, _cross_t(h10, h11, level))))
	if (h01 < level) != (h11 < level):
		pts.append(Vector3(lerpf(x0, x1, _cross_t(h01, h11, level)), level, z1))
	if (h00 < level) != (h01 < level):
		pts.append(Vector3(x0, level, lerpf(z0, z1, _cross_t(h00, h01, level))))

	if pts.size() < 2:
		return
	im.surface_set_color(col)
	im.surface_add_vertex(pts[0])
	im.surface_set_color(col)
	im.surface_add_vertex(pts[1])
	if pts.size() == 4:                      # 鞍點：兩條線都畫
		im.surface_set_color(col)
		im.surface_add_vertex(pts[2])
		im.surface_set_color(col)
		im.surface_add_vertex(pts[3])


#══════════════════════════════════════════════════════════════════════════════
#  階段一：長官簡報
#══════════════════════════════════════════════════════════════════════════════
func _enter_brief() -> void:
	_deploy_root.visible = false
	_crosshair.visible = false
	if _lbl_help:
		_lbl_help.visible = false
	if _officer:
		_officer.modulate.a = 0.0
	if _minimap:
		_minimap.visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	_briefing = load("res://Briefing.gd").new()
	_briefing.name = "Briefing"
	_briefing.world = self
	add_child(_briefing)
	_briefing.build(_mg().my_team())
	_mg().add_chat_line("[簡報] 作戰簡報開始 ─ [Enter/滑鼠左鍵] 下一句，[ESC] 跳過。",
		Color(1.0, 0.85, 0.35))


func _update_brief(delta: float) -> void:
	brief_left = maxf(0.0, brief_left - delta)

	var running := false
	if _briefing != null and is_instance_valid(_briefing):
		running = _briefing.update(delta)

	# 自己看完（或跳過）之後，還要等房主宣布進入部署階段
	if not running and _lbl_wait != null:
		_lbl_wait.visible = true
		_lbl_wait.text = "簡報結束 ─ 等待各單位就位…　%0.0f" % brief_left

	if _is_host() and (brief_left <= 0.0 or (not running and _mg().solo_mode)):
		_broadcast("cli_begin_deploy", [])


@rpc("authority", "call_remote", "reliable")
func cli_begin_deploy() -> void:
	if phase != PHASE_BRIEF:
		return
	phase = PHASE_DEPLOY
	brief_left = 0.0
	if _briefing != null and is_instance_valid(_briefing):
		_briefing.finish()
		_briefing.queue_free()
		_briefing = null
	if _lbl_wait:
		_lbl_wait.visible = false
	if _minimap:
		_minimap.visible = true
	if _cam:
		_cam.current = true
	deploy_left = DEPLOY_TIME
	_enter_deploy()


func _enter_deploy() -> void:
	deploy_towers_left = DEPLOY_TOWERS
	var my_team := _mg().my_team()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)   # 部署要點地圖，游標必須看得到
	_deploy_root.visible = true
	_holo.visible = (my_team == MainGame.TEAM_DEFENDER)
	if _lbl_help:
		_lbl_help.visible = false
	if my_team == MainGame.TEAM_DEFENDER and _terrain_node:
		_terrain_node.visible = false          # 只留下全息等高線
	# 部署階段不顯示戰鬥 HUD
	_crosshair.visible = false
	_lbl_vitals.text = ""
	_lbl_obj.text = ""
	_lbl_timer.text = ""

	if my_team == MainGame.TEAM_DEFENDER:
		_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		_cam.size = 3400.0
		_lbl_deploy_hint.text = "點擊滑鼠左鍵在任意地形配置防空炮（山頂、丘陵、平地皆可）　│　時間結束後自動進入戰鬥"
	else:
		_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		_lbl_deploy_hint.text = "艦隊正駛向作戰海域…　│　抵達後於甲板選擇座機"
	officer_say(("敵艦隊正在接近，甲板準備出擊。" if my_team == MainGame.TEAM_ATTACKER else "各單位注意，配置防空火力，我們只有三十秒。"), "order", 5)
	_mg().add_chat_line("[部署] 作戰部署開始，%.0f 秒後進入戰鬥。" % DEPLOY_TIME, Color(1.0, 0.85, 0.35))


func _update_deploy(delta: float) -> void:
	deploy_left = maxf(0.0, deploy_left - delta)

	# 航母駛近：用平滑曲線減速靠位，看起來是「開進來停下」而不是等速平移
	var f := 1.0 - clampf(deploy_left / DEPLOY_TIME, 0.0, 1.0)
	var eased := 1.0 - pow(1.0 - f, 2.2)
	if _carrier_node:
		_carrier_node.position = CARRIER_POS + Vector3(0, 0, CARRIER_APPROACH * (1.0 - eased))

	_lbl_deploy_time.text = "距離出擊　%0.1f 秒" % deploy_left
	if _mg().my_team() == MainGame.TEAM_DEFENDER:
		_lbl_deploy_count.text = "可配置防空炮：%d / %d" % [deploy_towers_left, DEPLOY_TOWERS]
		# 部署階段用滑鼠左鍵點地面放砲（左鍵在戰鬥中是飛彈）
		if deploy_towers_left > 0 and Input.is_action_just_pressed("ac_missile"):
			_try_place_tower()
	else:
		_lbl_deploy_count.text = ""

	if _is_host() and deploy_left <= 0.0:
		_broadcast("cli_begin_combat", [])


## 從正射鏡頭往地面投射，決定玩家點在哪裡
func _try_place_tower() -> void:
	var mouse := get_viewport().get_mouse_position()
	var from := _cam.project_ray_origin(mouse)
	var dir := _cam.project_ray_normal(mouse)
	if absf(dir.y) < 0.001:
		return

	# 沿射線前進找真實地表交點：山頂、山坡、平地都能放，不再只認一個平面
	var hit := Vector3.INF
	var step := 12.0
	var travelled := 0.0
	var p := from
	while travelled < 6000.0:
		p += dir * step
		travelled += step
		if p.y <= maxf(terrain_height(p), LAND_Y if is_land(p) else 0.0):
			hit = p
			break
	if hit == Vector3.INF:
		return

	if absf(hit.x) > MAP_LIMIT or absf(hit.z) > MAP_LIMIT:
		_set_alert("超出戰區。")
		return
	# 不要蓋在跑道正上方
	if absf(hit.x - RUNWAY_POS.x) < 40.0 and absf(hit.z - RUNWAY_POS.z) < 190.0:
		_set_alert("不能蓋在跑道上。")
		return

	deploy_towers_left -= 1
	_request_tower(hit)
	play_sfx("lock", -10.0)


@rpc("authority", "call_remote", "reliable")
func cli_begin_combat() -> void:
	if phase == PHASE_COMBAT:
		return
	phase = PHASE_COMBAT
	deploy_left = 0.0
	if _carrier_node:
		_carrier_node.position = CARRIER_POS      # 對齊，讓彈射座標完全正確
	_deploy_root.visible = false
	_holo.visible = false
	if _lbl_help:
		_lbl_help.visible = true
	if _terrain_node:
		_terrain_node.visible = true
	_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	_cam.size = 1.0
	_spawn_all_pilots()
	_spawn_uav(MainGame.TEAM_DEFENDER)
	match_running = true
	if _mouse:
		_mouse.visible = true
	officer_say("作戰開始 ─ 各機出擊！", "order", 5)
	_mg().add_chat_line("[系統] 部署結束 ─ 作戰開始！", Color(0.4, 1.0, 0.6))
	play_sfx("catapult", -12.0)


## 部署階段的鏡頭：防守方俯瞰全息圖，進攻方跟拍航母
func _update_camera_deploy(delta: float) -> void:
	var t := 1.0 - clampf(deploy_left / DEPLOY_TIME, 0.0, 1.0)
	if _mg().my_team() == MainGame.TEAM_DEFENDER:
		var target := Vector3(RUNWAY_POS.x, LAND_Y + 1200.0, RUNWAY_POS.z + 60.0)
		_cam_pivot.global_position = _cam_pivot.global_position.lerp(target, clampf(delta * 3.0, 0, 1))
		# 略帶傾角的俯視，讓地形有立體感
		_cam_pivot.global_rotation = Vector3(-PI * 0.46, 0.0, 0.0)
	else:
		var c := _carrier_node.global_position if _carrier_node else CARRIER_POS
		# 貼近海面的艦艏斜側視角，看得到艦艏切開水面；隨時間由艏側慢慢繞到艦舯
		var ang := lerpf(0.55, 1.25, t)              # 弧度：越大越靠正側面
		var dist := lerpf(340.0, 400.0, t)
		var pos := c + Vector3(cos(ang) * dist, lerpf(32.0, 52.0, t), sin(ang) * dist - 60.0)
		_cam_pivot.global_position = _cam_pivot.global_position.lerp(pos, clampf(delta * 2.0, 0, 1))
		_cam_pivot.look_at(c + Vector3(0, 16, -20.0), Vector3.UP)   # 對準艦體中段，整艘入鏡
	_cam.position = Vector3.ZERO
	_cam.fov = lerpf(_cam.fov, 62.0, clampf(delta * 3.0, 0, 1))


func _update_camera(delta: float) -> void:
	var me: Aircraft = aircraft.get(_local_id())
	var target_pos: Vector3
	var target_basis: Basis

	# 步行狀態：肩後跟隨鏡頭
	var walker = pilots.get(_local_id())
	if me == null and walker != null:
		var wb := (walker as Node3D).global_transform.basis
		_cam_pivot.global_position = _cam_pivot.global_position.lerp(
			(walker as Node3D).global_position + Vector3(0, 3.2, 0) + wb.z * 7.0,
			clampf(delta * 9.0, 0, 1))
		var wq := _cam_pivot.global_transform.basis.get_rotation_quaternion().slerp(
			wb.get_rotation_quaternion(), clampf(delta * 9.0, 0, 1))
		_cam_pivot.global_transform.basis = Basis(wq)
		_cam.position = _cam.position.lerp(Vector3(0, 0, 0), clampf(delta * 10.0, 0, 1))
		_cam.fov = lerp(_cam.fov, 70.0, delta * 4.0)
		return

	if me != null and me.alive:
		var b := me.global_transform.basis
		# 彈射瞬間鏡頭往後拉、FOV 撐開，做出被甩出去的加速感
		me.catapult_kick = maxf(0.0, me.catapult_kick - delta * 1.6)
		var kick := me.catapult_kick
		if first_person:
			# 座艙：鏡頭放在該機種實際的座艙罩位置（eye_offset 由機體尺寸算出）
			var e := me.eye_offset
			target_pos = me.global_position + b.x * e.x + b.y * e.y + b.z * e.z
		else:
			target_pos = me.global_position + b.y * (5.5 + kick * 1.5) + b.z * (20.0 + kick * 9.0)
		target_basis = b
		var want_fov := (68.0 + me.speed * 0.10) if first_person \
			else (74.0 + me.speed * 0.16 + kick * 22.0)
		_cam.fov = lerp(_cam.fov, want_fov, delta * 6.0)
	else:
		# 陣亡 / 觀戰：繞著出生點緩慢環繞
		var home := CARRIER_POS if _mg().my_team() == MainGame.TEAM_ATTACKER else RUNWAY_POS
		var a := match_time * 0.15
		target_pos = home + Vector3(cos(a) * 300.0, 170.0, sin(a) * 300.0)
		target_basis = Transform3D().looking_at(home - target_pos, Vector3.UP).basis
		_cam.fov = lerp(_cam.fov, 70.0, delta * 3.0)

	# 第一人稱＝剛性固定在座艙上，絕對不能用 lerp：
	# 以 26/s 的追隨係數配上 85 m/s 的速度，穩定誤差就有 3 公尺 ─
	# 鏡頭會一直停在座艙後方（等於坐在機體裡面），畫面全被機殼擋住。
	if first_person and me != null and me.alive:
		_cam_pivot.global_position = target_pos
		_cam_pivot.global_transform.basis = target_basis
	else:
		_cam_pivot.global_position = _cam_pivot.global_position.lerp(target_pos, clampf(delta * 8.0, 0, 1))
		var q := _cam_pivot.global_transform.basis.get_rotation_quaternion().slerp(
			target_basis.get_rotation_quaternion(), clampf(delta * 6.0, 0, 1))
		_cam_pivot.global_transform.basis = Basis(q)

	# 鏡頭震動（彈射、爆炸、雷擊）
	if _shake_left > 0.0:
		_shake_left = maxf(0.0, _shake_left - delta)
		var k := _shake_amt * (_shake_left / 0.6)
		_cam.position = Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1),
			_rng.randf_range(-1, 1)) * k
		if _shake_left <= 0.0:
			_shake_amt = 0.0
	else:
		_cam.position = _cam.position.lerp(Vector3.ZERO, clampf(delta * 10.0, 0, 1))


#══════════════════════════════════════════════════════════════════════════════
#  HUD（純程式碼）
#══════════════════════════════════════════════════════════════════════════════
func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.name = "HUD"
	_hud.layer = 5
	add_child(_hud)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(root)

	# 上方中央：時間 + 目標狀態
	var top := VBoxContainer.new()
	top.set_anchors_preset(Control.PRESET_CENTER_TOP)
	top.offset_left = -300; top.offset_right = 300; top.offset_top = 12
	top.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(top)
	_lbl_timer = _hud_label("", 26, MainGame.C_TEXT)
	_lbl_timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(_lbl_timer)
	_lbl_obj = _hud_label("", 14, MainGame.C_DIM)
	_lbl_obj.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(_lbl_obj)

	# 中央警示
	_lbl_alert = _hud_label("", 22, Color(1.0, 0.35, 0.35))
	_lbl_alert.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_lbl_alert.offset_left = -400; _lbl_alert.offset_right = 400; _lbl_alert.offset_top = 112
	_lbl_alert.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_lbl_alert)

	# 準星
	_crosshair = Control.new()
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_crosshair)
	for v in [Vector2(-18, 0), Vector2(10, 0), Vector2(0, -18), Vector2(0, 10)]:
		var r := ColorRect.new()
		r.color = Color(0.4, 1.0, 0.8, 0.75)
		r.size = Vector2(8, 2) if absf(v.x) > 0.0 else Vector2(2, 8)
		r.position = v
		_crosshair.add_child(r)

	# 中央大字（復活倒數 / 勝負）
	_lbl_center = _hud_label("", 30, Color(1, 1, 1))
	_lbl_center.set_anchors_preset(Control.PRESET_CENTER)
	_lbl_center.offset_left = -400; _lbl_center.offset_right = 400
	_lbl_center.offset_top = 40; _lbl_center.offset_bottom = 120
	_lbl_center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_lbl_center)

	_lbl_board = _hud_label("", 20, Color(1.0, 0.92, 0.5))
	_lbl_board.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_lbl_board.offset_left = -420; _lbl_board.offset_right = 420
	_lbl_board.offset_top = -170; _lbl_board.offset_bottom = -90
	_lbl_board.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_lbl_board)

	# 右下：儀表
	_lbl_vitals = _hud_label("", 15, MainGame.C_TEXT)
	_lbl_vitals.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	# 往上挪，避免被右下角的圓形小地圖蓋住
	_lbl_vitals.offset_left = -330; _lbl_vitals.offset_top = -400
	_lbl_vitals.offset_right = -18; _lbl_vitals.offset_bottom = -228
	_lbl_vitals.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	root.add_child(_lbl_vitals)

	# 右上：空投進度
	_drop_box = VBoxContainer.new()
	_drop_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_drop_box.offset_left = -300; _drop_box.offset_right = -18; _drop_box.offset_top = 16
	_drop_box.visible = false
	root.add_child(_drop_box)
	_drop_box.add_child(_hud_label("◆ 空投爭奪 AIR DROP", 15, Color(1.0, 0.9, 0.4)))
	_bar_atk = _hud_bar(MainGame.C_ATK)
	_bar_def = _hud_bar(MainGame.C_DEF)
	_drop_box.add_child(_hud_label("進攻方", 12, MainGame.C_ATK))
	_drop_box.add_child(_bar_atk)
	_drop_box.add_child(_hud_label("防守方", 12, MainGame.C_DEF))
	_drop_box.add_child(_bar_def)

	_build_hud_overlay(root)
	_build_health_bars(root)
	_build_minimap(root)
	_build_officer(root)

	# 飛行視覺層：滾轉刻度、鎖定進度環、加速速度線
	_mouse = load("res://FlightHud.gd").new()
	_mouse.name = "FlightHud"
	root.add_child(_mouse)
	_mouse.setup()
	_mouse.visible = false

	# 手機／平板的觸控操控層。桌面沒有觸控螢幕就根本不會建立，
	# 想在電腦上調版面或截圖的話設環境變數 FORCE_TOUCH=1。
	var touch_script := load("res://TouchControls.gd")
	if touch_script.should_enable():
		_touch = touch_script.new()
		_touch.name = "TouchControls"
		root.add_child(_touch)
		_touch.setup(self)

	# 練習場的逐步提示
	_lbl_tutorial = _hud_label("", 19, Color(0.55, 1.00, 0.85))
	_lbl_tutorial.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_lbl_tutorial.offset_left = -520; _lbl_tutorial.offset_right = 520
	_lbl_tutorial.offset_top = 176; _lbl_tutorial.offset_bottom = 250
	_lbl_tutorial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lbl_tutorial.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_tutorial.visible = false
	root.add_child(_lbl_tutorial)

	# 簡報結束後的等待提示
	_lbl_wait = _hud_label("", 20, Color(1.0, 0.90, 0.50))
	_lbl_wait.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_lbl_wait.offset_left = -400; _lbl_wait.offset_right = 400
	_lbl_wait.offset_top = -260; _lbl_wait.offset_bottom = -220
	_lbl_wait.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lbl_wait.visible = false
	root.add_child(_lbl_wait)

	# 左上：操作提示
	_lbl_help = _hud_label(
		"W/S 俯仰　A/D 轉向　Z/C 滾轉　R/F 油門\n滑鼠右鍵 機炮　滑鼠左鍵 鎖定+飛彈\n1/2/3 換副武裝　SPACE 後燃器　V 視角\nSHIFT 干擾彈　CTRL 懸停(直升機)\nG 防空塔　T 聊天　F1~F4 無線電", 12, MainGame.C_DIM)
	_lbl_help.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_lbl_help.offset_left = 18; _lbl_help.offset_top = 14
	root.add_child(_lbl_help)

	# 一定要等整個 HUD 都建好才調整：_lbl_help / _lbl_vitals 都是在觸控層之後才生出來的，
	# 提早呼叫的話它們還是 null，設定會靜悄悄失效。
	if _touch != null:
		_apply_mobile_hud()


#══════════════════════════════════════════════════════════════════════════════
#  血量條：自機 / 鎖定目標 / 兩座基地
#══════════════════════════════════════════════════════════════════════════════
func _build_health_bars(root: Control) -> void:
	# ── 畫面正下方：自機血量 + 後燃器燃料 ──
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	box.offset_left = -240; box.offset_right = 240
	box.offset_top = -138; box.offset_bottom = -56
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(box)
	_hp_box = box

	_lbl_hp = _hud_label("", 13, MainGame.C_TEXT)
	box.add_child(_lbl_hp)
	_bar_hp = _hud_bar(Color(0.35, 1.00, 0.55))
	_bar_hp.custom_minimum_size = Vector2(0, 18)
	_bar_hp.show_percentage = false
	box.add_child(_bar_hp)

	_lbl_boost = _hud_label("後燃器 AFTERBURNER　[SPACE]", 11, MainGame.C_DIM)
	box.add_child(_lbl_boost)
	_bar_boost = _hud_bar(Color(1.00, 0.62, 0.22))
	_bar_boost.custom_minimum_size = Vector2(0, 10)
	_bar_boost.show_percentage = false
	box.add_child(_bar_boost)

	# ── 左上：目前鎖定／瞄準的敵機血量 ──
	_tgt_box = VBoxContainer.new()
	_tgt_box.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_tgt_box.offset_left = 18; _tgt_box.offset_top = 118
	_tgt_box.offset_right = 320; _tgt_box.offset_bottom = 180
	_tgt_box.add_theme_constant_override("separation", 2)
	_tgt_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tgt_box.visible = false
	root.add_child(_tgt_box)
	_tgt_name = _hud_label("", 13, Color(1.0, 0.45, 0.40))
	_tgt_box.add_child(_tgt_name)
	_bar_tgt = _hud_bar(Color(1.00, 0.38, 0.34))
	_bar_tgt.custom_minimum_size = Vector2(280, 12)
	_bar_tgt.show_percentage = false
	_tgt_box.add_child(_bar_tgt)

	# ── 上方中央：兩座基地的血量（貼在目標文字下方，不要壓到字）──
	var bases := VBoxContainer.new()
	bases.set_anchors_preset(Control.PRESET_CENTER_TOP)
	bases.offset_left = -190; bases.offset_right = 190
	bases.offset_top = 76; bases.offset_bottom = 104
	bases.add_theme_constant_override("separation", 1)
	bases.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bases)
	_bar_runway = _hud_bar(MainGame.C_DEF)
	_bar_runway.custom_minimum_size = Vector2(0, 9)
	_bar_runway.show_percentage = false
	bases.add_child(_bar_runway)
	_bar_nuke = _hud_bar(Color(0.42, 1.00, 0.45))
	_bar_nuke.custom_minimum_size = Vector2(0, 9)
	_bar_nuke.show_percentage = false
	bases.add_child(_bar_nuke)


#══════════════════════════════════════════════════════════════════════════════
#  HUD 強化：敵機螢幕標框、受傷暈影、被鎖定警告
#══════════════════════════════════════════════════════════════════════════════
class TargetBoxes extends Control:
	var world: Node3D

	func _draw() -> void:
		if world != null:
			world.draw_target_boxes(self)


## 觸控模式的 HUD 讓位。三個地方非讓不可：
##   ‧ 左上角那段「W/S 俯仰　A/D 轉向…」全是鍵盤按鍵，手機上完全沒有意義
##   ‧ 聊天面板佔滿整個左下角，正好是搖桿要放的位置（手機也打不了字）
##   ‧ 速度／高度／彈藥讀數在右下，剛好被武器鈕壓住
func _apply_mobile_hud() -> void:
	if _lbl_help != null:
		# 清成空字串而不是只設 visible ─ cli_begin_combat() 之後還會把它設回 visible
		_lbl_help.text = ""
	if _lbl_vitals != null:
		_lbl_vitals.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		_lbl_vitals.offset_left = -340; _lbl_vitals.offset_top = 120
		_lbl_vitals.offset_right = -18; _lbl_vitals.offset_bottom = 290
	# 聊天面板本來在左下角，正好是搖桿的位置。不是把它藏起來 ─ 隊友的訊息、
	# 擊墜播報、目標提示全都走這個面板，手機上照樣要看得到 ─ 而是搬到左上角
	# 那塊被鍵盤說明空出來的位置，並縮小一點。
	var mg := _mg()
	if mg != null and mg._chat_panel != null:
		var p: Control = mg._chat_panel
		p.set_anchors_preset(Control.PRESET_TOP_LEFT)
		p.offset_left = 14; p.offset_top = 8
		p.offset_right = 486; p.offset_bottom = 214


func _build_hud_overlay(root: Control) -> void:
	# 受傷暈影：血量越低邊緣越紅
	_vignette = ColorRect.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.color = Color(0.8, 0.05, 0.05, 0.0)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_vignette)

	_boxes = TargetBoxes.new()
	_boxes.world = self
	_boxes.set_anchors_preset(Control.PRESET_FULL_RECT)
	_boxes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_boxes)

	_lbl_warn = _hud_label("", 24, Color(1.0, 0.3, 0.3))
	_lbl_warn.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_lbl_warn.offset_left = -400; _lbl_warn.offset_right = 400; _lbl_warn.offset_top = 148
	_lbl_warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_lbl_warn)


## 把畫面上的敵機框起來，附距離；被自己鎖定的目標特別標示
func draw_target_boxes(ctl: Control) -> void:
	if _cam == null or phase != PHASE_COMBAT:
		return
	var me: Aircraft = aircraft.get(_local_id())
	if me == null or not me.alive:
		return
	var my_team := _mg().my_team()
	for pid in aircraft:
		var a: Aircraft = aircraft[pid]
		if not a.alive or a.pilot_id == _local_id():
			continue
		var friendly: bool = (a.team == my_team)
		if not friendly and not _is_detected(a):
			continue
		if _cam.is_position_behind(a.global_position):
			continue
		var sp := _cam.unproject_position(a.global_position)
		var d := me.global_position.distance_to(a.global_position)
		var s := clampf(2600.0 / maxf(d, 40.0), 12.0, 90.0)
		var col: Color = Color(0.45, 1.0, 0.55, 0.8) if friendly else Color(1.0, 0.35, 0.35, 0.9)
		var locked: bool = (me.lock_target == a)
		if locked:
			col = Color(1.0, 0.85, 0.2)
		# 四角括號比整框好讀
		var h := s * 0.5
		var arm := s * 0.28
		for cx in [-1.0, 1.0]:
			for cy in [-1.0, 1.0]:
				var cpt := sp + Vector2(cx * h, cy * h)
				ctl.draw_line(cpt, cpt - Vector2(cx * arm, 0), col, 2.0)
				ctl.draw_line(cpt, cpt - Vector2(0, cy * arm), col, 2.0)
		if not friendly:
			ctl.draw_string(ThemeDB.fallback_font, sp + Vector2(h + 6, 4),
				"%dm" % int(d), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)
			# 標框下方的小血條：一眼看出這台還剩多少
			var bw: float = s * 1.15
			var bx: float = sp.x - bw * 0.5
			var by: float = sp.y + h + 9.0
			var frac: float = clampf(a.hp / maxf(a.max_hp, 1.0), 0.0, 1.0)
			ctl.draw_rect(Rect2(Vector2(bx, by), Vector2(bw, 4.0)), Color(0, 0, 0, 0.55), true)
			ctl.draw_rect(Rect2(Vector2(bx, by), Vector2(bw * frac, 4.0)),
				Color(1.0 - frac * 0.55, 0.25 + frac * 0.70, 0.30, 0.95), true)
		if locked:
			ctl.draw_arc(sp, h + 8.0, 0, TAU, 20, col, 1.5)


func _update_hud_overlay(delta: float) -> void:
	if _boxes:
		_boxes.queue_redraw()
	var me: Aircraft = aircraft.get(_local_id())

	# 受傷暈影
	if _vignette:
		var want := 0.0
		if me != null and me.alive:
			var f := 1.0 - clampf(me.hp / maxf(me.max_hp, 1.0), 0.0, 1.0)
			want = maxf(0.0, (f - 0.5) * 0.7)          # 血量低於一半才開始泛紅
			if want > 0.0:
				want *= 0.75 + 0.25 * sin(Time.get_ticks_msec() * 0.006)
		_vignette.color.a = lerpf(_vignette.color.a, want, clampf(delta * 5.0, 0, 1))

	# 被敵方飛彈鎖定的警告
	if _lbl_warn:
		var warned := false
		if me != null and me.alive:
			for c in get_children():
				if c is Projectile and (c as Projectile).homing_target == me:
					warned = true
					break
		if warned:
			_lbl_warn.text = "⚠ 飛彈來襲 ─ 按 SHIFT 施放干擾彈"
			_warn_beep -= delta
			if _warn_beep <= 0.0:
				_warn_beep = 0.45
				play_sfx("lock", -12.0)
		else:
			_lbl_warn.text = ""


#══════════════════════════════════════════════════════════════════════════════
#  第一人稱座艙視角（V 鍵切換）
#══════════════════════════════════════════════════════════════════════════════
## 座艙框架掛在「駕駛眼睛」的位置上，只有第一人稱時顯示。
## 掛在 eye_offset 而不是機體原點：不同機種的座艙高低前後差很多，
## 用固定偏移會讓框架卡在機身裡或飄在機鼻前面。
func _build_cockpit(a: Aircraft) -> void:
	if a.cockpit != null:
		return
	var frame := Node3D.new()
	frame.position = a.eye_offset
	frame.visible = false
	a.add_child(frame)
	a.cockpit = frame

	# ── 材質 ──
	var metal := make_material(Color(0.115, 0.125, 0.140))        # 座艙罩骨架
	var panel := make_material(Color(0.080, 0.086, 0.098))        # 儀表板本體
	var dark := make_material(Color(0.040, 0.046, 0.058))         # 遮光罩／機鼻
	var bezel := make_material(Color(0.140, 0.150, 0.165))        # 螢幕外框
	# 儀表螢幕一律做成「關機的暗面板」：發光的大色塊會變成螢光綠色板，
	# 又亮又假，還會跟 HUD 的綠色符號搶注意力。只有 HUD 玻璃該發光。
	var scr := make_material(Color(0.035, 0.050, 0.058))
	var line := make_material(Color(0.25, 1.00, 0.50), 0.9)       # 只給 HUD 玻璃用
	var key := make_material(Color(0.26, 0.29, 0.33))             # 鍵盤按鍵（不發光）
	var amber := make_material(Color(1.00, 0.62, 0.15), 1.4)
	var red := make_material(Color(1.00, 0.25, 0.20), 1.6)
	var glass := make_material(Color(0.35, 1.00, 0.55), 0.5)      # HUD 玻璃
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.albedo_color = Color(0.35, 1.00, 0.55, 0.10)

	# ── 座艙罩：前方的弧形骨架 + 兩側縱樑 ──
	# 用一串小方塊拼出半圓弧，就是照片裡那道最明顯的罩樑。
	var arc_r := 1.02
	var arc_c := Vector3(0.0, -0.10, -2.35)
	for i in 19:
		var ang := PI * float(i) / 18.0                  # 0~180 度
		var seg := make_box(frame, Vector3(0.085, 0.20, 0.085),
			arc_c + Vector3(cos(ang) * arc_r, sin(ang) * arc_r, 0.0), metal)
		# 方塊的長軸（本地 Y）要對齊圓的切線 (-sin, cos)，也就是直接轉 ang。
		# 用別的角度會讓每一節都歪掉，整條弧變成散開的積木。
		seg.rotation.z = ang
	# 縱樑要壓在座艙壁的頂面上。留在高處會變成兩根浮在半空的黑棒子 ─
	# 牆一降低就會露出中間那道縫。
	for s in [-1.0, 1.0]:
		var rail := make_box(frame, Vector3(0.11, 0.15, 2.40), Vector3(s * 0.98, -0.40, -0.95), metal)
		rail.rotation_degrees = Vector3(0, 0, s * 6.0)
		# 罩框前端與縱樑之間的短柱，把弧樑的腳接到座艙緣
		make_box(frame, Vector3(0.10, 0.36, 0.16), Vector3(s * 1.01, -0.28, -2.33), metal)

	# ── 機鼻雷達罩 ──
	# 第一人稱看不到機體（外部模型沒有座艙內裝，鏡頭放進去只會穿模），
	# 所以機鼻要在這裡自己畫出來：從風擋前緣往前逐段收窄成尖錐。
	# 高度抓在準星下方約 10 度 ─ 看得到自己的機鼻，又不會擋住瞄準線。
	# 長度嚴格控制在「座艙到機體最前端」之內：畫太長會從機首戳出去一根尖角，
	# 第三人稱看自己的飛機時就會看到一塊怪東西掛在機鼻前面。
	var skin_col: Color = MainGame.instance.skin_color()
	var hull := make_material(skin_col.darkened(0.10))
	var radome := make_material(Color(0.085, 0.092, 0.105))
	# 從儀表板前緣起算，一路收到機首。起點不能離眼睛太近，
	# 不然第一節整流罩會像一塊板子糊在鏡頭前。
	var start_z := -1.35
	var reach: float = clampf(absf(a.nose_ahead - a.eye_offset.z) + start_z - 0.10, 0.4, 3.4)
	var segs := 5
	for i in segs:
		var f := float(i) / float(segs - 1)
		var nw: float = lerpf(0.72, 0.13, f)
		var nh: float = lerpf(0.26, 0.09, f)
		var nz: float = start_z - f * reach
		var ny: float = -0.46 - f * 0.16          # 機鼻往前微微下垂
		make_box(frame, Vector3(nw, nh, reach * 0.28 + 0.18),
			Vector3(0, ny, nz), hull if i < segs - 1 else radome)
	# 空速管
	var pitot := make_cyl(frame, 0.014, 0.022, 0.50, Vector3(0, -0.64, start_z - reach - 0.30), metal)
	pitot.rotation_degrees.x = 90

	# ── HUD：兩根立柱夾一片玻璃，玻璃上有綠色符號 ──
	var hud := Node3D.new()
	hud.position = Vector3(0, -0.26, -1.42)      # 太近會整片蓋住視野，退到約 1.4 公尺
	hud.scale = Vector3.ONE * 0.95
	frame.add_child(hud)
	for s2 in [-1.0, 1.0]:
		make_box(hud, Vector3(0.05, 0.62, 0.05), Vector3(s2 * 0.34, 0.10, 0.0), metal)
	make_box(hud, Vector3(0.74, 0.05, 0.06), Vector3(0, 0.42, 0.0), metal)   # 上框
	make_box(hud, Vector3(0.78, 0.10, 0.14), Vector3(0, -0.24, 0.02), bezel) # 投影器本體
	make_box(hud, Vector3(0.68, 0.52, 0.012), Vector3(0, 0.10, 0.0), glass)  # 玻璃
	# 玻璃上的符號：中央十字、水平儀刻線、左右速度／高度框
	make_box(hud, Vector3(0.16, 0.012, 0.014), Vector3(0, 0.10, 0.01), line)
	make_box(hud, Vector3(0.012, 0.16, 0.014), Vector3(0, 0.10, 0.01), line)
	for i2 in 2:
		var y := 0.10 + (0.14 if i2 == 0 else -0.14)
		make_box(hud, Vector3(0.30, 0.010, 0.014), Vector3(0, y, 0.01), line)
	for s3 in [-1.0, 1.0]:
		make_box(hud, Vector3(0.010, 0.20, 0.014), Vector3(s3 * 0.26, 0.10, 0.01), line)
		make_box(hud, Vector3(0.09, 0.010, 0.014), Vector3(s3 * 0.235, 0.20, 0.01), line)
		make_box(hud, Vector3(0.09, 0.010, 0.014), Vector3(s3 * 0.235, 0.00, 0.01), line)

	# ── 遮光罩（儀表板上方那道黑色帽簷）──
	#    位置要在面板「上緣之上」：擺低了就會從正面把整片儀表板遮住。
	#    寬度接到兩側座艙壁，整條下緣連成一片實心結構。
	# 高度要壓在「機鼻頂線」以下，否則從座艙看出去機鼻會被自己的遮光罩切掉
	make_box(frame, Vector3(1.70, 0.10, 0.44), Vector3(0, -0.66, -1.44), dark)

	# ── 主儀表板 ──
	# 面板在眼睛的「前下方」，所以它的正面要朝「後上方」才看得到 ─
	# 儀表與螢幕全部掛在本地 +Z 面，面板再往前傾 25 度。
	# （早先把元件放在 -Z 面，等於整片背對駕駛，畫面上只剩一塊黑板。）
	# 位置也刻意比真機高一點：鏡頭是水平朝前的，擺在真實高度會整片掉出畫面下緣。
	var board := Node3D.new()
	board.position = Vector3(0, -0.66, -1.24)
	board.rotation_degrees = Vector3(-25.0, 0, 0)
	board.scale = Vector3.ONE * 0.82
	frame.add_child(board)
	make_box(board, Vector3(1.30, 0.86, 0.10), Vector3.ZERO, panel)
	make_box(board, Vector3(1.34, 0.05, 0.12), Vector3(0, 0.44, 0.0), bezel)

	# 中央 UFC：鍵盤 + 上方的小顯示條（顯示條同樣不發光）
	make_box(board, Vector3(0.44, 0.34, 0.06), Vector3(0, 0.12, 0.07), bezel)
	make_box(board, Vector3(0.36, 0.08, 0.02), Vector3(0, 0.23, 0.10), scr)
	for r in 3:
		for c in 5:
			make_box(board, Vector3(0.048, 0.040, 0.02),
				Vector3(-0.148 + c * 0.074, 0.06 - r * 0.070, 0.10), key)

	# 左右 MFD：外框 + 暗掉的螢幕 + 四周的軟鍵（不放發光圖形）
	for s5 in [-1.0, 1.0]:
		var mx: float = s5 * 0.42
		make_box(board, Vector3(0.38, 0.40, 0.06), Vector3(mx, 0.02, 0.07), bezel)
		make_box(board, Vector3(0.30, 0.32, 0.02), Vector3(mx, 0.02, 0.10), scr)
		for k in 4:
			make_box(board, Vector3(0.05, 0.030, 0.02), Vector3(mx - 0.12 + k * 0.08, -0.19, 0.10), key)
			make_box(board, Vector3(0.030, 0.05, 0.02), Vector3(mx - 0.17, -0.10 + k * 0.08, 0.10), key)

	# 中央下方：三個圓錶（暗面 + 指針）與兩顆警告燈
	for g in 3:
		var gx := -0.16 + g * 0.16
		var gauge := make_cyl(board, 0.062, 0.062, 0.03, Vector3(gx, -0.28, 0.09), bezel)
		gauge.rotation_degrees.x = 90
		var face := make_cyl(board, 0.048, 0.048, 0.01, Vector3(gx, -0.28, 0.11), scr)
		face.rotation_degrees.x = 90
		make_box(board, Vector3(0.007, 0.04, 0.012), Vector3(gx, -0.26, 0.12), key)
	make_box(board, Vector3(0.10, 0.04, 0.02), Vector3(-0.52, 0.34, 0.10), red)
	make_box(board, Vector3(0.10, 0.04, 0.02), Vector3(0.52, 0.34, 0.10), amber)

	# ── 操縱桿與握著它的右手 ──
	# 桿掛在一個 pivot 上，飛行輸入會讓整支桿（連同手）跟著前後左右擺動。
	# 位置刻意抬到儀表板前方看得到的地方 ─ 真機的中央桿在膝蓋之間，
	# 水平視角其實看不到，那樣就白做了。
	var glove := make_material(Color(0.19, 0.21, 0.25))
	var sleeve := make_material(Color(0.15, 0.17, 0.21))
	var stick_pivot := Node3D.new()
	stick_pivot.position = Vector3(0.14, -0.96, -0.99)
	frame.add_child(stick_pivot)
	a.cockpit_stick = stick_pivot

	make_cyl(stick_pivot, 0.030, 0.042, 0.40, Vector3(0, 0.20, 0), bezel)          # 桿身
	make_cyl(stick_pivot, 0.052, 0.046, 0.17, Vector3(0, 0.45, -0.01), dark)       # 握把
	make_sphere(stick_pivot, 0.052, Vector3(0, 0.535, -0.01), dark)                # 握把頂
	make_box(stick_pivot, Vector3(0.038, 0.05, 0.028), Vector3(0, 0.47, -0.058), red)   # 扳機
	make_box(stick_pivot, Vector3(0.030, 0.022, 0.030), Vector3(0, 0.585, -0.03), amber) # 頂部按鈕
	# 右手：手掌 + 四指包住握把 + 拇指
	make_box(stick_pivot, Vector3(0.125, 0.155, 0.145), Vector3(0.050, 0.475, -0.005), glove)
	for fi in 4:
		make_box(stick_pivot, Vector3(0.105, 0.030, 0.034),
			Vector3(0.010, 0.535 - float(fi) * 0.042, -0.052), glove)
	make_box(stick_pivot, Vector3(0.048, 0.085, 0.048), Vector3(0.082, 0.535, -0.028), glove)
	# 前臂與袖口，往右下延伸出畫面
	var cuff := make_cyl(stick_pivot, 0.088, 0.082, 0.07, Vector3(0.105, 0.395, 0.055), dark)
	cuff.rotation_degrees = Vector3(34, 0, -30)
	var arm := make_cyl(stick_pivot, 0.082, 0.100, 0.60, Vector3(0.215, 0.235, 0.235), sleeve)
	arm.rotation_degrees = Vector3(34, 0, -30)

	# ── 兩側座艙壁 ──
	# 這一段是機身蒙皮加控制台，是實心的：座艙罩「以下」看不到外面，
	# 只有罩框以上才是透明的。牆頂正好接到兩側縱樑。
	# 牆頂（座艙緣）壓在視線下方約 24 度：太高會把兩側的地平線整條蓋掉，
	# 太低又會露出座艙外的機身。緣以上是側窗，看得到外面。
	for s6 in [-1.0, 1.0]:
		var wall := make_box(frame, Vector3(0.60, 1.45, 2.60), Vector3(s6 * 0.88, -1.14, -0.95), dark)
		wall.rotation_degrees = Vector3(0, 0, s6 * -5.0)
		# 牆頂的控制台面板與按鈕
		var con := make_box(frame, Vector3(0.46, 0.12, 1.90), Vector3(s6 * 0.82, -0.44, -1.00), panel)
		con.rotation_degrees = Vector3(0, 0, s6 * -5.0)
		for b2 in 4:
			make_box(frame, Vector3(0.05, 0.03, 0.05),
				Vector3(s6 * 0.80, -0.37, -1.60 + b2 * 0.34),
				key if b2 % 2 == 0 else amber)
	# 左側油門桿
	make_box(frame, Vector3(0.07, 0.07, 0.34), Vector3(-0.76, -0.30, -1.05), bezel)
	make_sphere(frame, 0.06, Vector3(-0.76, -0.27, -1.20), dark)


## 自動駕駛開關（回傳切換後的狀態）。開啟時自機交給 AI 的 FSM 操縱，
## 玩家仍然可以切視角、聊天、按無線電。
func toggle_autopilot() -> bool:
	autopilot = not autopilot
	var me: Aircraft = aircraft.get(_local_id())
	if autopilot and me != null:
		# 交接時給一組乾淨的 AI 狀態，免得沿用上一次的殘留目標
		me.ai_state = "PATROL"
		me.ai_target = null
		me.ai_timer = 0.0
		me.ai_wp = Vector3.ZERO
	# 有提醒，但**不會進聊天框**：只在畫面中央閃一下，並在右下角儀表常駐一行小字。
	# 聊天紀錄會被別人看到（截圖、直播），HUD 只有你自己看得到。
	_set_alert("自動駕駛 %s" % ("接手中 AUTOPILOT ON" if autopilot else "已解除 OFF"))
	return autopilot


func _toggle_cockpit() -> void:
	first_person = not first_person
	var me: Aircraft = aircraft.get(_local_id())
	if me != null:
		_build_cockpit(me)
		if me.cockpit:
			me.cockpit.visible = first_person
		# 第一人稱要把機體藏起來：外部 .glb 沒有座艙內裝，
		# 鏡頭一放進去就會被機殼糊滿整個畫面。視野裡的機鼻由座艙框架自己畫。
		if me.pivot:
			me.pivot.visible = not first_person
	if _cam:
		_cam.near = 0.05 if first_person else 0.1
	_set_alert("視角：%s" % ("座艙 COCKPIT" if first_person else "第三人稱 CHASE"))


#══════════════════════════════════════════════════════════════════════════════
#  萊特兄弟事件：隨機把雙方的戰鬥機換成 1903 年的雙翼機，持續 60 秒
#══════════════════════════════════════════════════════════════════════════════
const WRIGHT_TIME := 60.0

func _update_wright(delta: float) -> void:
	if wright_left > 0.0:
		wright_left = maxf(0.0, wright_left - delta)
		if wright_left <= 0.0:
			_broadcast("cli_wright", [false])
		return
	_wright_cd -= delta
	if _wright_cd <= 0.0:
		_wright_cd = _rng.randf_range(90.0, 180.0)
		if _rng.randf() < 0.5:
			_broadcast("cli_wright", [true])


@rpc("authority", "call_remote", "reliable")
func cli_wright(on: bool) -> void:
	wright_left = WRIGHT_TIME if on else 0.0
	if on:
		_mg().add_chat_line("[???] 後勤把一九〇三年的庫存推上跑道了 ─ 戰鬥機停機位變成萊特飛行者，60 秒。",
			Color(1.0, 0.8, 0.4))
		officer_say("我不管這是誰的主意 ─ 接下來六十秒，戰鬥機位只有萊特飛行者。給我飛。", "order", 6)
		play_sfx("lock", -10.0)
	else:
		_mg().add_chat_line("[系統] 萊特飛行者已收回機庫，戰鬥機恢復正常。", MainGame.C_DIM)
		officer_say("正常機種恢復供應，剛才的事誰都不准再提。", "calm", 3)
	# 重建停機坪上的展示機，讓玩家看到換了什麼
	for e in _parked:
		(e["node"] as Node3D).queue_free()
	_parked.clear()
	_build_parked_aircraft()


## 現在戰鬥機位是不是萊特飛行者
func _is_wright(vtype: int) -> bool:
	return wright_left > 0.0 and vtype == MainGame.VType.FIGHTER


#══════════════════════════════════════════════════════════════════════════════
#  圓形雷達小地圖（右下角）
#══════════════════════════════════════════════════════════════════════════════
class Minimap extends Control:
	var world: Node3D
	var radius: float = 96.0
	var range_m: float = 2400.0        # 地圖邊緣代表多遠（跟著放大的戰場調整）

	func _draw() -> void:
		var c := Vector2(radius, radius)
		# 底盤與刻度環
		draw_circle(c, radius, Color(0.02, 0.05, 0.08, 0.82))
		draw_arc(c, radius, 0, TAU, 64, Color(0.35, 0.85, 1.0, 0.85), 2.0)
		draw_arc(c, radius * 0.66, 0, TAU, 48, Color(0.35, 0.85, 1.0, 0.30), 1.0)
		draw_arc(c, radius * 0.33, 0, TAU, 32, Color(0.35, 0.85, 1.0, 0.30), 1.0)
		draw_line(c - Vector2(radius, 0), c + Vector2(radius, 0), Color(0.35, 0.85, 1.0, 0.22), 1.0)
		draw_line(c - Vector2(0, radius), c + Vector2(0, radius), Color(0.35, 0.85, 1.0, 0.22), 1.0)
		if world == null:
			return
		world.draw_minimap(self, c)

	## 世界座標 → 小地圖座標（以自機為中心、機首朝上）
	func to_map(centre: Vector3, yaw: float, p: Vector3, c: Vector2) -> Vector2:
		var d := Vector2(p.x - centre.x, p.z - centre.z) / range_m * radius
		var s := sin(-yaw)
		var co := cos(-yaw)
		var r := Vector2(d.x * co - d.y * s, d.x * s + d.y * co)
		return c + Vector2(r.x, r.y)


func _build_minimap(root: Control) -> void:
	_minimap = Minimap.new()
	_minimap.world = self
	_minimap.custom_minimum_size = Vector2(192, 192)
	_minimap.size = Vector2(192, 192)
	_minimap.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_minimap.offset_left = -212; _minimap.offset_top = -212
	_minimap.offset_right = -20; _minimap.offset_bottom = -20
	_minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_minimap)


## 由 Minimap._draw 呼叫；把場上物件畫上去
func draw_minimap(m, c: Vector2) -> void:
	var me: Aircraft = aircraft.get(_local_id())
	var centre := me.global_position if me != null else \
		(CARRIER_POS if _mg().my_team() == MainGame.TEAM_ATTACKER else RUNWAY_POS)
	var yaw := me.global_rotation.y if me != null else 0.0
	var my_team := _mg().my_team()

	# 目標建築
	for key in structures:
		var st: Dictionary = structures[key]
		# 防空塔與陸軍載具太多，全畫上去小地圖會糊掉；車隊是任務目標所以留著
		var kind := String(st["kind"])
		if kind == "tower" or kind == "aaa" or kind == "sam":
			continue
		var col: Color = MainGame.C_DEF if int(st["team"]) == MainGame.TEAM_DEFENDER else MainGame.C_ATK
		if float(st["hp"]) <= 0.0:
			col = Color(0.45, 0.45, 0.45)
		var p: Vector2 = m.to_map(centre, yaw, (st["node"] as Node3D).global_position, c)
		if p.distance_to(c) > m.radius - 4.0:
			continue
		m.draw_rect(Rect2(p - Vector2(4, 4), Vector2(8, 8)), col, false, 2.0)

	# 空投
	if drop_spawned and not drop_done and drop_node:
		var dp: Vector2 = m.to_map(centre, yaw, drop_node.global_position, c)
		if dp.distance_to(c) <= m.radius - 4.0:
			m.draw_circle(dp, 5.0, Color(1.0, 0.9, 0.35))

	# 飛機：隊友全顯示；敵機需被偵測到
	for pid in aircraft:
		var a: Aircraft = aircraft[pid]
		if not a.alive:
			continue
		var friendly: bool = (a.team == my_team)
		if not friendly and not _is_detected(a):
			continue
		var p2: Vector2 = m.to_map(centre, yaw, a.global_position, c)
		if p2.distance_to(c) > m.radius - 3.0:
			continue
		var col2: Color = Color(0.45, 1.0, 0.55) if friendly else Color(1.0, 0.35, 0.35)
		if a.pilot_id == _local_id():
			col2 = Color.WHITE
		# 用小三角表示航向
		var ang := a.global_rotation.y - yaw
		var tip: Vector2 = p2 + Vector2(sin(ang), -cos(ang)) * 6.0
		var l: Vector2 = p2 + Vector2(sin(ang + 2.5), -cos(ang + 2.5)) * 4.0
		var r: Vector2 = p2 + Vector2(sin(ang - 2.5), -cos(ang - 2.5)) * 4.0
		m.draw_polygon(PackedVector2Array([tip, l, r]), PackedColorArray([col2, col2, col2]))

	# 我方 UAV 與敵方 UAV
	if _uav != null and is_instance_valid(_uav):
		var up: Vector2 = m.to_map(centre, yaw, _uav.global_position, c)
		if up.distance_to(c) <= m.radius - 4.0:
			var uc: Color = Color(0.5, 1.0, 1.0) if _uav_team == my_team else Color(1.0, 0.6, 0.2)
			m.draw_arc(up, 7.0, 0, TAU, 12, uc, 2.0)


## 敵機是否被我方偵測到：近距離目視、或被我方 UAV 標記
func _is_detected(a: Aircraft) -> bool:
	var my_team := _mg().my_team()
	# UAV 存活且是我方的 → 標記所有敵機
	if _uav != null and is_instance_valid(_uav) and _uav_team == my_team:
		return true
	var me: Aircraft = aircraft.get(_local_id())
	if me == null:
		return false
	var d := me.global_position.distance_to(a.global_position)
	var rng := 620.0 * weather_lock_scale()
	# 低空直升機匿蹤
	if float(a.stats["radar"]) < 1.0 and a.global_position.y < 60.0:
		rng *= 0.4
	return d < rng


#══════════════════════════════════════════════════════════════════════════════
#  偵查機 UAV：高空盤旋標記敵方位置，被擊落後停飛 60 秒
#══════════════════════════════════════════════════════════════════════════════
func _spawn_uav(team: int) -> void:
	if _uav != null and is_instance_valid(_uav):
		return
	var root := Area3D.new()
	root.name = "UAV"
	add_child(root)
	_uav = root
	_uav_team = team
	_uav_hp = 140.0
	_uav_angle = _rng.randf_range(0.0, TAU)

	var col: Color = MainGame.C_ATK if team == MainGame.TEAM_ATTACKER else MainGame.C_DEF
	var body := make_material(Color(0.16, 0.17, 0.20))
	make_box(root, Vector3(2.2, 1.0, 7.0), Vector3.ZERO, body)
	make_box(root, Vector3(20.0, 0.3, 1.6), Vector3(0, 0.4, 0.5), body)   # 長直機翼
	make_box(root, Vector3(20.2, 0.14, 0.4), Vector3(0, 0.6, 0.5), make_material(col, 2.4))
	make_sphere(root, 0.9, Vector3(0, -0.4, -2.4), make_material(col, 4.0))  # 光電球
	make_box(root, Vector3(0.3, 2.0, 1.2), Vector3(0, 1.2, 3.0), body)

	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(20, 3, 8)
	cs.shape = bs
	root.add_child(cs)
	root.collision_layer = 2
	root.collision_mask = 0

	var tag := Label3D.new()
	tag.text = "UAV"
	tag.font_size = 40
	tag.pixel_size = 0.05
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true
	tag.modulate = col
	tag.position = Vector3(0, 5, 0)
	root.add_child(tag)


func _update_uav(delta: float) -> void:
	if _uav_down > 0.0:
		_uav_down = maxf(0.0, _uav_down - delta)
		if _uav_down <= 0.0:
			_spawn_uav(MainGame.TEAM_DEFENDER)
			_broadcast("cli_uav_state", [true])
		return
	if _uav == null or not is_instance_valid(_uav):
		return
	# 高空繞著戰場中心盤旋
	_uav_angle += delta * 0.10
	var r := 700.0
	var pos := Vector3(cos(_uav_angle) * r, 330.0, DROP_POS.z + sin(_uav_angle) * r)
	_uav.global_position = pos
	_uav.global_rotation.y = -_uav_angle + PI * 0.5


## UAV 被擊落 → 敵方位置隱藏 60 秒
func uav_take_damage(dmg: float) -> void:
	if _uav == null or not is_instance_valid(_uav) or not _is_host():
		return
	_uav_hp -= dmg
	if _uav_hp <= 0.0:
		_broadcast("cli_uav_state", [false])


@rpc("authority", "call_remote", "reliable")
func cli_uav_state(alive: bool) -> void:
	if alive:
		_uav_down = 0.0
		if _uav == null or not is_instance_valid(_uav):
			_spawn_uav(MainGame.TEAM_DEFENDER)
		_mg().add_chat_line("[UAV] 偵查機重新升空，敵機位置恢復標記。", MainGame.C_DEF)
		if _mg().my_team() == MainGame.TEAM_DEFENDER:
			officer_say("偵查機重新升空 ─ 敵機位置回到雷達上。", "good", 3)
		else:
			officer_say("對方偵查機又飛起來了，我們的位置暴露了。", "urgent", 3)
	else:
		if _uav != null and is_instance_valid(_uav):
			_spawn_flash(_uav.global_position, 18.0, Color(1.0, 0.6, 0.2))
			_uav.queue_free()
		_uav = null
		_uav_down = 60.0
		_mg().add_chat_line("[UAV] 偵查機被擊落！敵機位置標記中斷 60 秒。", Color(1.0, 0.5, 0.3))
		if _mg().my_team() == MainGame.TEAM_ATTACKER:
			officer_say("偵查機打下來了！接下來六十秒他們看不到我們 ─ 衝！", "good", 5)
		else:
			officer_say("偵查機被擊落，六十秒內失去敵機標記 ─ 靠目視！", "urgent", 5)


#══════════════════════════════════════════════════════════════════════════════
#  右上角長官：依戰況即時下達指令
#══════════════════════════════════════════════════════════════════════════════
const OFFICER_MOODS := {
	"calm":   Color(0.55, 0.85, 1.00),
	"order":  Color(1.00, 0.85, 0.35),
	"urgent": Color(1.00, 0.45, 0.35),
	"good":   Color(0.45, 1.00, 0.60),
}

func _build_officer(root: Control) -> void:
	_officer = PanelContainer.new()
	_officer.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_officer.offset_left = -430; _officer.offset_right = -16
	_officer.offset_top = 16; _officer.offset_bottom = 126
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.10, 0.92)
	sb.border_width_left = 2; sb.border_width_right = 2
	sb.border_width_top = 2; sb.border_width_bottom = 2
	sb.border_color = MainGame.C_DEF
	sb.corner_radius_top_left = 6; sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6; sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 10; sb.content_margin_right = 10
	sb.content_margin_top = 8; sb.content_margin_bottom = 8
	_officer.add_theme_stylebox_override("panel", sb)
	_officer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_officer.modulate.a = 0.0
	root.add_child(_officer)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_officer.add_child(hb)

	# ── 純程式碼畫出來的長官頭像 ──
	var face := Control.new()
	face.custom_minimum_size = Vector2(74, 88)
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(face)

	var skin := ColorRect.new()          # 臉
	skin.color = Color(0.62, 0.48, 0.38)
	skin.position = Vector2(13, 24); skin.size = Vector2(48, 52)
	face.add_child(skin)
	var cap := ColorRect.new()           # 軍帽
	cap.color = Color(0.14, 0.18, 0.24)
	cap.position = Vector2(6, 6); cap.size = Vector2(62, 22)
	face.add_child(cap)
	var brim := ColorRect.new()          # 帽簷
	brim.color = Color(0.08, 0.10, 0.14)
	brim.position = Vector2(2, 26); brim.size = Vector2(70, 7)
	face.add_child(brim)
	var badge := ColorRect.new()         # 帽徽
	badge.color = Color(1.0, 0.82, 0.25)
	badge.position = Vector2(32, 11); badge.size = Vector2(10, 10)
	face.add_child(badge)
	for ex in [22, 44]:                  # 墨鏡
		var eye := ColorRect.new()
		eye.color = Color(0.05, 0.07, 0.10)
		eye.position = Vector2(ex, 40); eye.size = Vector2(14, 9)
		face.add_child(eye)
	var stache := ColorRect.new()        # 鬍子
	stache.color = Color(0.20, 0.16, 0.13)
	stache.position = Vector2(26, 56); stache.size = Vector2(22, 5)
	face.add_child(stache)
	_officer_mouth = ColorRect.new()     # 會動的嘴
	_officer_mouth.color = Color(0.20, 0.10, 0.10)
	_officer_mouth.position = Vector2(30, 64); _officer_mouth.size = Vector2(14, 3)
	face.add_child(_officer_mouth)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 2)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(vb)
	_officer_name = _hud_label("戰術管制官 ─ 「老鷹」", 13, MainGame.C_DEF)
	vb.add_child(_officer_name)
	_officer_text = _hud_label("", 15, Color.WHITE)
	_officer_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_officer_text.custom_minimum_size = Vector2(280, 60)
	vb.add_child(_officer_text)


## 讓長官說話。priority 高的可以蓋掉正在說的話。
func officer_say(text: String, mood: String = "calm", priority: int = 1) -> void:
	if _officer == null:
		return
	if _officer_hold > 0.0 and priority < _officer_prio:
		return
	_officer_prio = priority
	_officer_hold = 5.0
	_officer_speak = 1.4
	_officer_text.text = text
	var col: Color = OFFICER_MOODS.get(mood, OFFICER_MOODS["calm"])
	_officer_text.add_theme_color_override("font_color", col)
	_officer_name.add_theme_color_override("font_color", col)
	var sb: StyleBoxFlat = _officer.get_theme_stylebox("panel")
	sb.border_color = col
	if mood == "urgent":
		play_sfx("lock", -14.0)


func _update_officer(delta: float) -> void:
	if _officer == null:
		return
	# 講話時嘴巴上下開合
	if _officer_speak > 0.0:
		_officer_speak = maxf(0.0, _officer_speak - delta)
		var h := 3.0 + absf(sin(Time.get_ticks_msec() * 0.022)) * 8.0
		_officer_mouth.size.y = h
		_officer_mouth.position.y = 64.0 - (h - 3.0) * 0.5
	else:
		_officer_mouth.size.y = 3.0
		_officer_mouth.position.y = 64.0

	if _officer_hold > 0.0:
		_officer_hold = maxf(0.0, _officer_hold - delta)
		_officer.modulate.a = minf(1.0, _officer.modulate.a + delta * 5.0)
	else:
		_officer.modulate.a = maxf(0.0, _officer.modulate.a - delta * 1.6)

	# 沒事的時候，隔一陣子講一句戰況提示
	_officer_idle -= delta
	if _officer_idle <= 0.0:
		_officer_idle = _rng.randf_range(22.0, 38.0)
		if _officer_hold <= 0.0 and match_running:
			_officer_idle_line()


func _officer_idle_line() -> void:
	var me: Aircraft = aircraft.get(_local_id())
	var atk := _mg().my_team() == MainGame.TEAM_ATTACKER
	var pool: Array = []
	if runway_down:
		pool.append("跑道還癱著，他們一架都升不了空 ─ 把握時間打核設施！" if atk
			else "工兵正在搶修跑道，撐住！")
	if drop_spawned and not drop_done:
		pool.append("空投還在中央高空，誰有餘力就去搶。")
	if me != null and me.alive and me.hp < me.max_hp * 0.35:
		pool.append("你的機體損傷嚴重，考慮脫離接戰。")
	if _mg().weather == MainGame.WX_SANDSTORM:
		pool.append("沙塵讓紅外鎖定幾乎失效，靠機砲近戰。")
	elif _mg().weather == MainGame.WX_THUNDER:
		pool.append("雷暴亂流會把你吹偏，別貼太近地面。")
	if pool.is_empty():
		pool = ["保持隊形，注意六點鐘方向。",
			"彈藥省著點用，補給不會自己飛過來。",
			"核設施是我們的勝負手，別忘了主要目標。" if atk else "守住跑道就是守住全隊的命。"]
	officer_say(pool[_rng.randi() % pool.size()], "calm", 0)


func _hud_label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _hud_bar(col: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.min_value = 0; b.max_value = 100; b.value = 0
	b.show_percentage = true
	b.custom_minimum_size = Vector2(0, 16)
	var fg := StyleBoxFlat.new(); fg.bg_color = col
	var bg := StyleBoxFlat.new(); bg.bg_color = Color(0, 0, 0, 0.5)
	b.add_theme_stylebox_override("fill", fg)
	b.add_theme_stylebox_override("background", bg)
	return b


#══════════════════════════════════════════════════════════════════════════════
#  載具生成（含航艦彈射起飛）
#══════════════════════════════════════════════════════════════════════════════
func _spawn_all_pilots() -> void:
	_build_parked_aircraft()
	var ids: Array = _mg().players.keys()
	ids.sort()
	var slot := { MainGame.TEAM_ATTACKER: 0, MainGame.TEAM_DEFENDER: 0 }
	for id in ids:
		var p: Dictionary = _mg().players[id]
		var team: int = p["team"]
		# AI 直接上機；真人玩家出生在甲板上，自己走過去選機
		if bool(p["bot"]):
			var i: int = slot[team]
			slot[team] = i + 1
			_create_aircraft(int(id), team, int(p["vtype"]), true, _spawn_transform(team, i))
		else:
			_spawn_walking_pilot(int(id))


func _spawn_transform(team: int, slot: int) -> Transform3D:
	var t := Transform3D()
	if team == MainGame.TEAM_ATTACKER:
		# 航艦甲板：交錯排列，機首朝 -Z（敵方）
		var lane := -11.0 if slot % 2 == 0 else 11.0
		t.origin = CARRIER_POS + Vector3(lane, 18.0, 60.0 - float(slot) * 22.0)
		t.basis = Basis(Quaternion(Vector3.UP, 0.0))
	else:
		# 跑道面在 LAND_Y+2，起飛點再抬高留出離地餘裕
		t.origin = RUNWAY_POS + Vector3(float(slot % 3 - 1) * 12.0, LAND_Y + 8.0,
			-110.0 + float(slot % 6) * 22.0)
		t.basis = Basis(Quaternion(Vector3.UP, PI))   # 機首朝 +Z（敵方）
	return t


func _create_aircraft(pid: int, team: int, vtype: int, is_bot: bool, xform: Transform3D) -> void:
	if aircraft.has(pid):
		_forget_aircraft(aircraft[pid])
		aircraft[pid].queue_free()
		aircraft.erase(pid)

	var a := Aircraft.new()
	a.world = self
	a.pilot_id = pid
	a.team = team
	a.vtype = vtype
	a.weapon = int(_mg().players[pid].get("weapon", MainGame.instance.default_weapon(vtype))) if _mg().players.has(pid) else MainGame.instance.default_weapon(vtype)
	a.is_bot = is_bot
	a.is_local = (pid == _local_id() and not is_bot)
	a.pilot_name = String(_mg().players[pid]["name"]) if _mg().players.has(pid) else "?"
	add_child(a)
	a.global_transform = xform
	a.setup()

	# 重生／換機後仍維持第一人稱：新機體要立刻補上座艙並藏起機殼
	if a.is_local and first_person:
		_build_cockpit(a)
		a.cockpit.visible = true
		a.pivot.visible = false

	# 彈射器：進攻方自航艦以高初速彈射起飛
	if team == MainGame.TEAM_ATTACKER and not a.stats["hover"]:
		a.speed = float(a.stats["max_speed"]) * 1.15
		a.throttle = 1.0
		a.catapult_kick = 1.0                 # 給鏡頭與 HUD 的加速感訊號
		_spawn_catapult_fx(xform.origin, xform.basis)
		if a.is_local:
			_shake(0.9, 0.55)
			play_sfx("catapult")
	else:
		a.speed = float(a.stats["min_speed"])
		a.throttle = 0.7

	aircraft[pid] = a


#══════════════════════════════════════════════════════════════════════════════
#  步行登機：出生在甲板／停機坪上，走到停放的飛機旁按 E 上機
#══════════════════════════════════════════════════════════════════════════════
## 甲板／停機坪的表面高度（飛行員與展示機都要站在這個面上）
const DECK_Y  := 17.5      # 航母飛行甲板頂面（相對 CARRIER_POS）
const APRON_Y := 2.0       # 跑道旁停機坪頂面（相對 RUNWAY_POS + LAND_Y）


## 玩家出生站位。面向由 look_at 決定，不用向量推算，避免又算到甲板外。
func _apron_origin(team: int) -> Vector3:
	if team == MainGame.TEAM_ATTACKER:
		# 甲板 z 範圍約 -145~145，站在後段、面向前方停放的機群
		return CARRIER_POS + Vector3(0.0, DECK_Y + 1.2, 96.0)
	return RUNWAY_POS + Vector3(88.0, LAND_Y + APRON_Y + 1.2, 92.0)


## 三個停機位的實際座標，全部落在甲板／停機坪範圍內
func _parking_spot(team: int, index: int) -> Vector3:
	var lane := (float(index) - 1.0) * 21.0        # -21 / 0 / +21
	if team == MainGame.TEAM_ATTACKER:
		return CARRIER_POS + Vector3(lane, DECK_Y + 1.6, 44.0)
	return RUNWAY_POS + Vector3(64.0 + lane * 0.0, LAND_Y + APRON_Y + 1.6, 40.0 + lane)


## 停放的展示機：玩家走過去按 E 就是登這一架
func _build_parked_aircraft() -> void:
	for team in [MainGame.TEAM_ATTACKER, MainGame.TEAM_DEFENDER]:
		var list: Array = MainGame.TEAM_VTYPES[team]
		for i in list.size():
			var vt: int = list[i]
			var root := Node3D.new()
			add_child(root)
			root.global_position = _parking_spot(team, i)
			# 機首朝敵方：進攻方朝 -Z、防守方朝 +Z
			root.rotation.y = 0.0 if team == MainGame.TEAM_ATTACKER else PI

			# 用跟實機一樣的外形當展示機
			var demo := Aircraft.new()
			demo.world = self
			demo.pilot_id = -9000 - vt
			demo.team = team
			demo.vtype = vt
			demo.weapon = MainGame.instance.default_weapon(vt)
			demo.is_display = true
			root.add_child(demo)
			demo.setup()

			var tag := Label3D.new()
			tag.text = "[E] 登機\n%s" % MainGame.VTYPE_NAME[vt]
			tag.font_size = 40
			tag.pixel_size = 0.02
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.no_depth_test = true
			tag.modulate = MainGame.C_ATK if team == MainGame.TEAM_ATTACKER else MainGame.C_DEF
			tag.outline_size = 12
			tag.position = Vector3(0, 7.0, 0)
			root.add_child(tag)

			_parked.append({ "team": team, "vtype": vt, "node": root, "tag": tag })


func _spawn_walking_pilot(pid: int) -> void:
	if pilots.has(pid):
		pilots[pid].queue_free()
		pilots.erase(pid)
	var mg := _mg()
	if not mg.players.has(pid):
		return
	var team: int = mg.players[pid]["team"]
	var p := Pilot.new()
	p.world = self
	p.pilot_id = pid
	p.team = team
	p.is_local = (pid == _local_id())
	add_child(p)
	p.global_position = _apron_origin(team) + Vector3(_rng.randf_range(-6, 6), 0, _rng.randf_range(-4, 4))
	p.setup()
	# 面向停放的機群
	var look := _parking_spot(team, 1)
	p.global_rotation.y = atan2(look.x - p.global_position.x, look.z - p.global_position.z) + PI
	pilots[pid] = p


## 找出玩家目前站在哪一架展示機旁邊（同隊、距離 16m 內）
func _nearby_parked(p) -> Dictionary:
	var best := {}
	var bd := 16.0
	for e in _parked:
		if int(e["team"]) != p.team:
			continue
		var d: float = (e["node"] as Node3D).global_position.distance_to(p.global_position)
		if d < bd:
			bd = d
			best = e
	return best


func _update_on_foot(delta: float) -> void:
	var p = pilots.get(_local_id())
	if p == null:
		return
	var typing: bool = _mg().is_typing()
	var fwd := 0.0
	var strafe := 0.0
	var turn := 0.0
	if not typing:
		fwd = Input.get_action_strength("ac_pitch_up") - Input.get_action_strength("ac_pitch_down")
		turn = Input.get_action_strength("ac_yaw_right") - Input.get_action_strength("ac_yaw_left")
	p.walk(delta, fwd, strafe, turn)

	# 靠近展示機時顯示提示；按 E 登機
	var near := _nearby_parked(p)
	for e in _parked:
		(e["tag"] as Label3D).modulate.a = 1.0 if (not near.is_empty() and e == near) else 0.35
	if near.is_empty():
		_lbl_board.text = ""
		return
	var vt: int = near["vtype"]
	var wname: String = MainGame.WEAPONS[_mg().players[_local_id()].get("weapon",
		_mg().default_weapon(vt))]["name"] if _mg().players.has(_local_id()) else ""
	_lbl_board.text = "按 [E] 登上 %s\n（副武裝：%s ─ 按 [Q] 切換）" % [MainGame.VTYPE_NAME[vt], wname]

	if not typing and Input.is_action_just_pressed("ac_board"):
		_request_board(vt)
	if not typing and Input.is_action_just_pressed("ac_swap_weapon"):
		_cycle_weapon(vt)


func _cycle_weapon(vt: int) -> void:
	var mg := _mg()
	var id := _local_id()
	if not mg.players.has(id):
		return
	var allowed: Array = MainGame.VSTATS[vt]["weapons"]
	var cur: int = int(mg.players[id].get("weapon", allowed[0]))
	var idx := allowed.find(cur)
	mg._request_weapon(int(allowed[(idx + 1) % allowed.size()]))


func _request_board(vt: int) -> void:
	if _is_host() or not _has_net():
		srv_board(vt)
	else:
		rpc_id(1, "srv_board", vt)


@rpc("any_peer", "reliable")
func srv_board(vt: int) -> void:
	if not _is_host() and _has_net():
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = _local_id()
	if not _mg().players.has(id) or aircraft.has(id):
		return
	# 防守方在跑道被毀期間不能登機起飛
	var team: int = _mg().players[id]["team"]
	if team == MainGame.TEAM_DEFENDER and runway_down:
		return
	_mg()._apply_vtype(id, vt)
	_mg()._broadcast_players()
	_respawn_slot[team] = (int(_respawn_slot[team]) + 1) % 6
	var xf := _spawn_transform(team, int(_respawn_slot[team]))
	_broadcast("cli_board", [id, vt, xf.origin, xf.basis.get_rotation_quaternion()])


@rpc("authority", "call_remote", "reliable")
func cli_board(pid: int, vt: int, pos: Vector3, rot: Quaternion) -> void:
	if pilots.has(pid):
		pilots[pid].queue_free()
		pilots.erase(pid)
	var mg := _mg()
	if not mg.players.has(pid):
		return
	mg.players[pid]["vtype"] = vt
	_create_aircraft(pid, int(mg.players[pid]["team"]), vt, bool(mg.players[pid]["bot"]),
		Transform3D(Basis(rot), pos))
	if pid == _local_id():
		_lbl_board.text = ""
		_lbl_center.text = ""
		var na: Aircraft = aircraft.get(pid)
		if na != null and first_person:
			_build_cockpit(na)
			na.cockpit.visible = true
			na.pivot.visible = false


func remove_pilot(pid: int) -> void:
	if pilots.has(pid):
		pilots[pid].queue_free()
		pilots.erase(pid)
	if aircraft.has(pid):
		_forget_aircraft(aircraft[pid])
		aircraft[pid].queue_free()
		aircraft.erase(pid)
	respawn_queue.erase(pid)


## 機體被釋放前，把所有還指著它的參考清掉。
## 少了這一步，AI 的 ai_target、玩家的鎖定、飛行中的飛彈都會抓著已釋放的實例，
## 下一幀做 `var t: Aircraft = a.ai_target` 就會噴 "previously freed instance"。
func _forget_aircraft(victim) -> void:
	for pid in aircraft:
		var o: Aircraft = aircraft[pid]
		if o == victim:
			continue
		if o.ai_target == victim:
			o.ai_target = null
		if o.lock_target == victim:
			o.lock_target = null
		if o.lock_candidate == victim:
			o.lock_candidate = null
	for c in get_children():
		if c is Projectile and (c as Projectile).homing_target == victim:
			(c as Projectile).homing_target = null


#══════════════════════════════════════════════════════════════════════════════
#  主迴圈
#══════════════════════════════════════════════════════════════════════════════
func _physics_process(delta: float) -> void:
	# 簡報階段：只跑簡報與環境，戰場完全靜止
	if phase == PHASE_BRIEF:
		_update_brief(delta)
		_update_weather(delta)
		if _carrier_radar:
			_carrier_radar.rotate_y(delta * 1.2)
		return

	# 部署階段走獨立的更新路徑：不推進比賽時間、不生成飛機
	if phase == PHASE_DEPLOY:
		_update_deploy(delta)
		_update_camera_deploy(delta)
		_update_weather(delta)
		_update_time_of_day(delta)
		_update_officer(delta)
		if _carrier_radar:
			_carrier_radar.rotate_y(delta * 1.2)
		return

	if not match_running:
		return
	match_time += delta

	_update_on_foot(delta)
	_update_local_control(delta)
	_update_remote_interp(delta)

	# 地面防空的集火計數每幀重算
	_aa_focus.clear()

	# 陸軍：移動由 match_time 推算（各端一致），開火由房主裁決
	if _ground != null:
		_ground.update(delta, match_time, _is_host())

	if _is_host():
		_update_bots(delta)
		_update_towers(delta)
		if _fleet != null:
			_fleet.update_aa(delta)          # 護航艦隊防空火網
		_update_respawns(delta)
		_update_runway_lock(delta)
		_update_airdrop(delta)
		_update_uav(delta)
		_update_wright(delta)
		_check_win_conditions()

	for t in team_boost.keys():
		if team_boost[t] > 0.0:
			team_boost[t] = maxf(0.0, team_boost[t] - delta)

	_net_acc += delta
	if _net_acc >= NET_TICK:
		_net_acc = 0.0
		_push_states()

	_update_camera(delta)
	_update_weather(delta)
	_update_time_of_day(delta)
	_update_officer(delta)
	_update_hud_overlay(delta)
	if _minimap:
		_minimap.queue_redraw()
	_update_hud()
	_update_tutorial(delta)
	if _carrier_radar:
		_carrier_radar.rotate_y(delta * 1.2)


#──────────────────────────── 本地操控 ────────────────────────────
## 轉向一律用鍵盤：W/S 俯仰、A/D 偏航、Z/C 滾轉
## 滑鼠只負責開火：右鍵 機炮、左鍵 鎖定並發射飛彈；Space 後燃器加速
func _update_local_control(delta: float) -> void:
	# 聊天輸入中不吃飛行操控
	var typing: bool = _mg().is_typing()
	var me: Aircraft = aircraft.get(_local_id())
	if me == null or not me.alive:
		if _mouse:
			_mouse.enabled = false
			_mouse.queue_redraw()
		return

	if _mouse:
		_mouse.enabled = not typing
		_mouse.tick(delta)

	# ── 自動駕駛（聊天框輸入專屬密碼啟動）：整架交給 AI 的 FSM 開 ──
	if autopilot:
		_ai_think(me, delta)
		_check_bounds(me)
		if first_person:
			if me.cockpit_sweep != null:
				me.cockpit_sweep.rotation.z -= delta * 2.2
			_animate_stick(me, delta)   # 電腦在開，桿子照樣會動
		# 自動駕駛其實一直在放飛彈（_ai_think 會呼叫 _try_missile，而且 AI 不需要
		# 累積 0.75 秒的鎖定），但舊版在這裡把鎖定 HUD 直接歸零 ─ 鎖定環不轉、
		# 左上角也不顯示目標，看起來就像「它都不用飛彈」。這裡把目標算出來餵給 HUD。
		var auto_guided: bool = bool(MainGame.WEAPONS[me.weapon]["guided"])
		var auto_tgt: Aircraft = _find_lock_target(me) if auto_guided else null
		me.lock_target = auto_tgt
		me.lock_progress = 1.0 if auto_tgt != null else 0.0
		if _mouse:
			_mouse.boost = me.boost_power
			_mouse.boost_fuel = me.boost_fuel
			_mouse.speed_norm = clampf(me.speed / maxf(float(me.stats["max_speed"]), 1.0), 0.0, 1.6)
			_mouse.roll_angle = me.get_roll_angle()
			_mouse.locked = auto_tgt != null
			_mouse.lock_progress = me.lock_progress
			_mouse.queue_redraw()
		return

	var pitch := 0.0
	var yaw := 0.0
	var roll := 0.0
	var thr := 0.0
	var boosting := false

	if not typing:
		pitch = Input.get_action_strength("ac_pitch_up") - Input.get_action_strength("ac_pitch_down")
		yaw = Input.get_action_strength("ac_yaw_right") - Input.get_action_strength("ac_yaw_left")
		roll = Input.get_action_strength("ac_roll_right") - Input.get_action_strength("ac_roll_left")
		thr = Input.get_action_strength("ac_thr_up") - Input.get_action_strength("ac_thr_down")

		boosting = Input.is_action_pressed("ac_boost")

		# 1 / 2 / 3：空中即時切換副武裝（不必在登機前決定）
		for wi in 3:
			if Input.is_action_just_pressed("ac_wpn_%d" % (wi + 1)):
				_switch_weapon(me, wi)

		if Input.is_action_just_pressed("ac_view"):
			_toggle_cockpit()
		if me.stats["hover"] and Input.is_action_just_pressed("ac_hover"):
			me.hover_mode = not me.hover_mode
		if Input.is_action_pressed("ac_gun"):          # 滑鼠右鍵：機炮／機槍
			_try_gun(me)
		if Input.is_action_pressed("ac_missile"):      # 滑鼠左鍵：鎖定並發射
			_try_missile(me)
		if Input.is_action_just_pressed("ac_flare"):
			_try_flare(me)
		if Input.is_action_just_pressed("ac_deploy") and me.team == MainGame.TEAM_DEFENDER:
			_request_tower(me.global_position)

	# 飛彈鎖定狀態（HUD 用；轟炸機投彈不需要鎖定）
	var guided: bool = bool(MainGame.WEAPONS[me.weapon]["guided"])
	var tgt: Aircraft = _find_lock_target(me) if guided else null
	# 鎖定需要把目標留在錐形內一段時間，離開就快速衰減
	if tgt != null and tgt == me.lock_candidate:
		me.lock_progress = minf(1.0, me.lock_progress + delta / Aircraft.LOCK_TIME)
	elif tgt != null:
		me.lock_candidate = tgt
		me.lock_progress = 0.0
	else:
		me.lock_candidate = null
		me.lock_progress = maxf(0.0, me.lock_progress - delta * 2.5)
	me.lock_target = tgt if (tgt != null and me.lock_progress >= 1.0) else null

	# 後燃器
	me.set_boost(boosting, delta)

	# 座艙雷達幕的掃描線與操縱桿擺動
	if first_person:
		if me.cockpit_sweep != null:
			me.cockpit_sweep.rotation.z -= delta * 2.2
		_animate_stick(me, delta)

	me.fly(delta, pitch, yaw, thr, roll)
	_check_bounds(me)

	# HUD 回饋
	if _mouse:
		_mouse.boost = me.boost_power
		_mouse.boost_fuel = me.boost_fuel
		_mouse.speed_norm = clampf(me.speed / maxf(float(me.stats["max_speed"]), 1.0), 0.0, 1.6)
		_mouse.roll_angle = me.get_roll_angle()
		_mouse.locked = me.lock_target != null
		_mouse.lock_progress = me.lock_progress
		_mouse.queue_redraw()


#══════════════════════════════════════════════════════════════════════════════
#  練習場：逐步提示（只有從「新手教學 → 進入練習場」進來才會跑）
#══════════════════════════════════════════════════════════════════════════════
const TUTORIAL_STEPS := [
	{ "k": "board", "t": "① 走到停機坪的飛機旁，按 [E] 登機" },
	{ "k": "fly",   "t": "② 按住 [R] 加滿油門，用 [W] 拉桿爬升到 80 公尺以上" },
	{ "k": "roll",  "t": "③ 用 [Z] / [C] 滾轉，[A] / [D] 轉向 ─ 感受一下機體的反應" },
	{ "k": "boost", "t": "④ 按住 [SPACE] 開後燃器加速（注意右下角的燃料條）" },
	{ "k": "gun",   "t": "⑤ 按住 [滑鼠右鍵] 掃機炮" },
	{ "k": "wpn",   "t": "⑥ 按 [1] / [2] / [3] 切換副武裝（每種都有自己的備彈）" },
	{ "k": "msl",   "t": "⑦ 把敵機留在準星內等鎖定環轉滿，按 [滑鼠左鍵] 發射飛彈" },
	{ "k": "end",   "t": "訓練完成！剩下的時間自由練習，或按 ESC 之後回主選單。" },
]


func _update_tutorial(delta: float) -> void:
	if _lbl_tutorial == null or not _mg().tutorial_mode:
		return
	_lbl_tutorial.visible = true
	var me: Aircraft = aircraft.get(_local_id())
	var step: Dictionary = TUTORIAL_STEPS[_tut_step]
	var key := String(step["k"])
	var done := false

	match key:
		"board": done = me != null
		"fly":   done = me != null and me.global_position.y > 80.0
		"roll":  done = me != null and absf(me.get_roll_angle()) > 0.55
		"boost": done = bool(_tut_flags.get("boost", false))
		"gun":   done = bool(_tut_flags.get("gun", false))
		"wpn":   done = bool(_tut_flags.get("wpn", false))
		"msl":   done = bool(_tut_flags.get("msl", false))
		"end":   done = false

	if me != null and me.boost_on:
		_tut_flags["boost"] = true

	if done:
		_tut_step = mini(_tut_step + 1, TUTORIAL_STEPS.size() - 1)
		_tut_done_t = 1.6
		play_sfx("lock", -12.0)
		officer_say("很好，下一項。", "good", 2)

	if _tut_done_t > 0.0:
		_tut_done_t = maxf(0.0, _tut_done_t - delta)
		_lbl_tutorial.text = "✔  完成！\n" + String(TUTORIAL_STEPS[_tut_step]["t"])
	else:
		_lbl_tutorial.text = "教學 %d / %d\n%s" % [
			mini(_tut_step + 1, TUTORIAL_STEPS.size() - 1), TUTORIAL_STEPS.size() - 1,
			String(TUTORIAL_STEPS[_tut_step]["t"])]


## 空中切換副武裝。每種武裝有自己的備彈池，切來切去不會互相偷彈。
func _switch_weapon(a: Aircraft, index: int) -> void:
	var allowed: Array = MainGame.VSTATS[a.vtype]["weapons"]
	if index < 0 or index >= allowed.size():
		return
	var w := int(allowed[index])
	if w == a.weapon:
		return
	a.set_weapon(w)
	_tut_flags["wpn"] = true
	_mg()._request_weapon(w)                    # 名單同步（重生後沿用）
	if _has_net():
		rpc("cli_switch_weapon", a.pilot_id, w)  # 其他端的彈丸種類要跟著換
	var info: Dictionary = MainGame.WEAPONS[w]
	_set_alert("武裝 %d：%s　（%d 發）" % [index + 1, info["name"], a.msl_ammo])
	play_sfx("lock", -16.0)


@rpc("any_peer", "call_remote", "reliable")
func cli_switch_weapon(pid: int, w: int) -> void:
	var a: Aircraft = aircraft.get(pid)
	if a != null:
		a.set_weapon(w)


## 座艙操縱桿：跟著實際的操縱輸入前後左右擺（拉桿往後倒、右滾往右倒）
func _animate_stick(a: Aircraft, delta: float) -> void:
	if a.cockpit_stick == null:
		return
	var k := clampf(delta * 10.0, 0.0, 1.0)
	var p := a.cockpit_stick
	p.rotation.x = lerpf(p.rotation.x, a.stick_pitch * 0.22, k)
	p.rotation.z = lerpf(p.rotation.z, -a.stick_roll * 0.28, k)


func _check_bounds(a: Aircraft) -> void:
	var p := a.global_position

	# 撞海
	if p.y <= 2.0:
		_local_report_death(a, "墜海")
		return
	# 實際碰撞體
	if a.get_slide_collision_count() > 0:
		_local_report_death(a, "撞毀")
		return
	# 備援：地形的碰撞盒只有視覺尺寸的 6 成、山脊鏈也只隔顆加碰撞，
	# 單靠物理判定會出現「明明撞進山裡卻沒反應」。這裡用高度圖補上。
	if p.y <= terrain_height(p) + 1.5:
		_local_report_death(a, "撞山")
		return
	# 陸地上空的最低安全高度
	if is_land(p) and p.y <= LAND_Y + 1.5:
		_local_report_death(a, "觸地")
		return
	if p.y > CEILING:
		a.global_position.y = CEILING
	if absf(p.x) > MAP_LIMIT or absf(p.z) > MAP_LIMIT:
		if a.is_local:
			_set_alert("⚠ 已離開作戰區域，請立即返航！")
		if absf(p.x) > MAP_LIMIT * 1.15 or absf(p.z) > MAP_LIMIT * 1.15:
			_local_report_death(a, "離開戰區")


## 本機自己摔掉的死因統計（撞山／墜海／觸地／離開戰區）。
## 被敵人打下來不會走這條路徑，所以可以用它分辨「摔的」和「被打下來的」，
## 調平衡時才不會把撞山的死亡算到敵人頭上。
var last_death_cause: String = ""
var local_env_deaths: int = 0
var death_causes: Dictionary = {}      # 死因 -> 次數（含 AI）

## 最後一次把本機打下來的來源 id（cli_kill 的 attacker）。
## 正數＝某架飛機，其餘是地面／艦上系統的固定編號：
const KILLER_NAME := {
	-9997: "陸軍防空（高射砲／防空車）",
	-9998: "護航艦 CIWS/SAM",
	-9999: "防空塔",
}
var last_killer: int = 0
## 本機這一局總共射出幾發副武裝（拿來確認自動駕駛到底有沒有在用飛彈）
var local_missiles_fired: int = 0


func _local_report_death(a: Aircraft, reason: String) -> void:
	if not a.alive:
		return
	# 連機種一起記：只知道「撞山 40 次」沒辦法判斷是哪一種機體撐不住避地形
	var tag := "%s/%s" % [reason, MainGame.VTYPE_NAME[a.vtype]]
	death_causes[tag] = int(death_causes.get(tag, 0)) + 1
	if a.is_local:
		last_death_cause = reason
		local_env_deaths += 1
	# 由本機宣告自己（或本機託管的 AI）陣亡，交給房主裁決
	request_damage(a.pilot_id, 99999.0, a.pilot_id)


#──────────────────────────── 遠端插值 ────────────────────────────
func _update_remote_interp(delta: float) -> void:
	for pid in aircraft:
		var a: Aircraft = aircraft[pid]
		if a.is_local or not a.alive:
			continue
		if _is_host() and a.is_bot:
			continue          # 房主本機模擬 AI，不插值
		if not a.has_net:
			continue
		a.global_position = a.global_position.lerp(a.net_pos, clampf(delta * 12.0, 0, 1))
		var q := a.global_transform.basis.get_rotation_quaternion().slerp(a.net_rot, clampf(delta * 12.0, 0, 1))
		a.global_transform.basis = Basis(q)
		a.animate_visual(delta)
		# 遠端機體的後燃器：跟著同步過來的 boost_on 開關淡入淡出
		a.boost_power = move_toward(a.boost_power, 1.0 if a.boost_on else 0.0, delta * 3.0)
		a.update_afterburner()


func _push_states() -> void:
	if not _has_net():
		return
	for pid in aircraft:
		var a: Aircraft = aircraft[pid]
		if not a.alive:
			continue
		var mine := a.is_local or (_is_host() and a.is_bot)
		if not mine:
			continue
		rpc("cli_state", a.pilot_id, a.global_position,
			a.global_transform.basis.get_rotation_quaternion(), a.speed, a.hover_mode,
			a.boost_on)


@rpc("any_peer", "unreliable_ordered")
func cli_state(pid: int, pos: Vector3, rot: Quaternion, spd: float, hover: bool,
		boosting: bool = false) -> void:
	var a: Aircraft = aircraft.get(pid)
	if a == null:
		return
	a.net_pos = pos
	a.net_rot = rot
	a.speed = spd
	a.hover_mode = hover
	a.boost_on = boosting        # 遠端機體的後燃器特效也要跟著亮
	a.has_net = true


#══════════════════════════════════════════════════════════════════════════════
#  武器
#══════════════════════════════════════════════════════════════════════════════
#────────────────────────── 機槍（滑鼠左鍵）──────────────────────────
## 機槍走射線判定：射速高，若用實體彈丸會在網頁端塞爆場景樹。
func _try_gun(a: Aircraft) -> void:
	if a.gun_cd > 0.0 or a.gun_ammo <= 0 or not a.alive:
		return
	a.gun_cd = float(a.stats["gun_rof"])
	a.gun_ammo -= 1

	var b := a.global_transform.basis
	var muzzle := a.global_position - b.z * 6.0
	# 垂直散布收窄到水平的 6 成：機身寬度遠大於高度，否則彈著會大量從上下擦過
	# AI 的散布刻意放大：牠們的瞄準是用向量算的，不放寬會變成百發百中
	var sp := float(a.stats["gun_spread"]) * (2.0 if a.is_bot else 1.0)
	var dir := (-b.z + b.x * _rng.randf_range(-sp, sp)
		+ b.y * _rng.randf_range(-sp, sp) * 0.6).normalized()
	var hit_pos := muzzle + dir * GUN_RANGE

	var q := PhysicsRayQueryParameters3D.create(muzzle, hit_pos, 1 | 2, [a.get_rid()])
	var res := get_world_3d().direct_space_state.intersect_ray(q)
	var hit_air := false
	if not res.is_empty():
		hit_pos = res["position"]
		var body: Object = res["collider"]
		var dmg := float(a.stats["gun_dmg"]) * _dmg_mult(a.team)
		if a.is_local:
			dmg *= 1.0 + _mg().upgrade_bonus("gun_dmg")
		# 自動駕駛接手的自機不是 bot，但也要吃 ACE_PILOT 的傷害倍率，
		# 否則 README 寫的「傷害 ×1.6」完全沒生效 ─ 外掛只剩瞄準角度變寬。
		if a.is_bot or (a.is_local and autopilot):
			dmg *= float(_bot_diff(a)["dmg"])
		if body.has_meta("struct_key"):
			var key := String(body.get_meta("struct_key"))
			var st: Dictionary = structures.get(key, {})
			if not st.is_empty() and int(st["team"]) != a.team and float(st["hp"]) > 0.0:
				request_damage(key, dmg * float(a.stats["gun_struct"]), a.pilot_id)
		elif body.has_method("fly") and int(body.team) != a.team and body.alive:
			request_damage(int(body.pilot_id), dmg, a.pilot_id)
			hit_air = true

	if _has_net():
		rpc("cli_gun_tracer", a.pilot_id, muzzle, hit_pos, hit_air)
	cli_gun_tracer(a.pilot_id, muzzle, hit_pos, hit_air)
	if a.is_local:
		play_sfx("gun", -18.0)
		_tut_flags["gun"] = true


## 曳光彈純視覺，掉封包無所謂 → unreliable
@rpc("any_peer", "call_remote", "unreliable")
func cli_gun_tracer(shooter: int, from: Vector3, to: Vector3, hit_air: bool) -> void:
	var d := to - from
	var dist := d.length()
	if dist < 2.0:
		return
	var a: Aircraft = aircraft.get(shooter)
	var team := a.team if a != null else 0

	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.22, 0.22, dist)
	mi.mesh = bm
	mi.material_override = _tracer_mat[team]     # 共用材質，不逐發配置
	add_child(mi)
	mi.global_position = from + d * 0.5
	var up := Vector3.UP if absf(d.normalized().dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
	mi.look_at(to, up)
	get_tree().create_timer(0.05).timeout.connect(mi.queue_free)

	if hit_air:
		_spawn_flash(to, 2.2, Color(1.0, 0.85, 0.45))


#────────────────────────── 飛彈 / 炸彈（Space）──────────────────────────
func _try_missile(a: Aircraft) -> void:
	if a.msl_cd > 0.0 or a.msl_ammo <= 0 or not a.alive:
		return
	var wpn: Dictionary = MainGame.WEAPONS[a.weapon]
	# AI 的發射間隔拉長：牠們不像人會猶豫，照原本節奏會變成飛彈雨
	a.msl_cd = float(wpn["rof"]) * (1.8 if a.is_bot else 1.0)
	a.msl_ammo -= 1
	if a.is_local:
		local_missiles_fired += 1
	a.ammo_pool[a.weapon] = a.msl_ammo

	var muzzle := a.global_position - a.global_transform.basis.z * 7.0
	var dir := -a.global_transform.basis.z
	var target_id := -1
	if bool(wpn["guided"]):
		var tgt := _find_lock_target(a)
		if tgt != null:
			target_id = tgt.pilot_id

	if _has_net():
		rpc("cli_missile", a.pilot_id, muzzle, dir, a.speed, target_id)
	cli_missile(a.pilot_id, muzzle, dir, a.speed, target_id)
	if a.is_local:
		play_sfx("missile", -8.0)
		_tut_flags["msl"] = true


@rpc("any_peer", "call_remote", "reliable")
func cli_missile(shooter: int, pos: Vector3, dir: Vector3, carrier_spd: float, target_id: int) -> void:
	var a: Aircraft = aircraft.get(shooter)
	if a == null:
		return
	var wpn: Dictionary = MainGame.WEAPONS[a.weapon]

	var pr := Projectile.new()
	pr.world = self
	pr.team = a.team
	pr.shooter = shooter
	pr.is_bomb = bool(wpn["ballistic"])
	pr.guided = bool(wpn["guided"])
	pr.damage = float(wpn["dmg"]) * _dmg_mult(a.team)
	if a.is_local:
		pr.damage *= 1.0 + _mg().upgrade_bonus("msl_dmg")
	if a.is_bot or (a.is_local and autopilot):
		pr.damage *= float(_bot_diff(a)["dmg"])
	pr.struct_mult = float(wpn["struct"])
	pr.life = float(wpn["life"])
	pr.turn = float(wpn["turn"])

	if pr.is_bomb:
		pr.vel = dir * (carrier_spd * 0.9) + Vector3.DOWN * 2.0
	else:
		pr.vel = dir * (carrier_spd + float(wpn["speed"]))
		if pr.guided and target_id >= 0 and aircraft.has(target_id):
			pr.homing_target = aircraft[target_id]

	add_child(pr)
	pr.global_position = pos
	pr.setup()


func _dmg_mult(team: int) -> float:
	return BOOST_MULT if team_boost.get(team, 0.0) > 0.0 else 1.0


## 地面防空的集火上限：同一架飛機同時最多被 2 個地面系統瞄準。
## 沒有這個上限，3 座防空塔 + 4 座高射砲 + 2 台防空車會一起打同一台，
## 玩家停在敵方基地上空幾秒就沒了。
const AA_MAX_FOCUS := 2
var _aa_focus := {}          # pilot_id -> 這一幀已經有幾個系統對他開火


## 這一幀還能不能對這個目標開火（可以的話順便登記）
func aa_can_fire(target_id: int) -> bool:
	var n := int(_aa_focus.get(target_id, 0))
	if n >= AA_MAX_FOCUS:
		return false
	_aa_focus[target_id] = n + 1
	return true


## 某一方目前還在空中的防空飛彈數量（護航艦 SAM 與防空塔共用這個上限）
func active_sam_count(team: int) -> int:
	var n := 0
	for c in get_children():
		if c is Projectile:
			var pr: Projectile = c
			if pr.kind == "sam" and pr.team == team and not pr.exploded:
				n += 1
	return n


## 前方 40 度錐形內、最近的敵機（干擾彈生效中的目標無法鎖定）
func _find_lock_target(a: Aircraft) -> Aircraft:
	var best: Aircraft = null
	var best_d := 900.0 * weather_lock_scale() * (1.0 + (_mg().upgrade_bonus("lock") if a.is_local else 0.0))
	var fwd := -a.global_transform.basis.z
	for pid in aircraft:
		var o: Aircraft = aircraft[pid]
		if o == a or not o.alive or o.team == a.team:
			continue
		if o.flare_active > 0.0:
			continue
		var to := o.global_position - a.global_position
		var d := to.length()
		if d > best_d or d < 12.0:
			continue
		if fwd.dot(to.normalized()) < 0.77:      # cos(40°)
			continue
		# 直升機低空匿蹤：貼地飛行時很難被鎖定
		if float(o.stats["radar"]) < 1.0 and o.global_position.y < 45.0 and d > 260.0:
			continue
		# 地形遮蔽：山壁擋住視線就鎖不上 ─ 這是低空穿峽谷的戰術價值所在
		if not _has_line_of_sight(a.global_position, o.global_position, a):
			continue
		best = o
		best_d = d
	return best


## 兩點之間有沒有被地形／建築擋住（碰撞層 1）
func _has_line_of_sight(from: Vector3, to: Vector3, ignore: CollisionObject3D = null) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, to, 1,
		[ignore.get_rid()] if ignore != null else [])
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## 飛行中的飛彈自行尋標：前方 30 度錐形內、未被干擾彈騙開過的最近敵機
func _find_lock_target_for_projectile(pr: Projectile) -> Aircraft:
	var best: Aircraft = null
	var best_d := 420.0 * weather_lock_scale()
	var fwd := pr.vel.normalized()
	for pid in aircraft:
		var o: Aircraft = aircraft[pid]
		if not o.alive or o.team == pr.team or o.flare_active > 0.0:
			continue
		if pr.decoyed.has(o.pilot_id):
			continue
		var to := o.global_position - pr.global_position
		var d := to.length()
		if d > best_d or d < 4.0:
			continue
		if fwd.dot(to / d) < 0.866:      # cos(30°)
			continue
		# 飛行中的飛彈同樣看不穿山壁
		if not _has_line_of_sight(pr.global_position, o.global_position):
			continue
		best = o
		best_d = d
	return best


func _try_flare(a: Aircraft) -> void:
	if a.flares <= 0 or a.flare_cd > 0.0:
		return
	a.flares -= 1
	a.flare_cd = 4.5
	a.flare_active = 3.5
	if _has_net():
		rpc("cli_flare", a.pilot_id)
	cli_flare(a.pilot_id)


@rpc("any_peer", "call_remote", "reliable")
func cli_flare(pid: int) -> void:
	var a: Aircraft = aircraft.get(pid)
	if a == null:
		return
	a.flare_active = 3.5
	for i in 8:
		var f := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.5; sm.height = 1.0
		f.mesh = sm
		f.material_override = make_material(Color(1.0, 0.85, 0.3), 6.0)
		add_child(f)
		f.global_position = a.global_position
		var dir := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 0.2), _rng.randf_range(-1, 1)).normalized()
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(f, "global_position", a.global_position + dir * 34.0, 1.6)
		tw.tween_property(f, "scale", Vector3.ONE * 0.1, 1.6)
		tw.chain().tween_callback(f.queue_free)


#══════════════════════════════════════════════════════════════════════════════
#  傷害裁決（房主權威）
#══════════════════════════════════════════════════════════════════════════════
## key: int = 飛行員 id ／ String = 建築物 key
func request_damage(key: Variant, amount: float, attacker: int) -> void:
	if _is_host() or not _has_net():
		srv_damage(key, amount, attacker)
	else:
		rpc_id(1, "srv_damage", key, amount, attacker)


@rpc("any_peer", "reliable")
func srv_damage(key: Variant, amount: float, attacker: int) -> void:
	if not _is_host() and _has_net():
		return

	if key is int:
		var a: Aircraft = aircraft.get(key)
		if a == null or not a.alive:
			return
		a.hp -= amount
		if a.hp <= 0.0:
			_broadcast("cli_kill", [int(key), attacker])
			respawn_queue[int(key)] = RESPAWN_TIME
		else:
			_broadcast("cli_set_hp", [key, a.hp])
		return

	var sk := String(key)
	if not structures.has(sk):
		return
	var st: Dictionary = structures[sk]
	if st["hp"] <= 0.0:
		return
	# 核設施沒有護盾：從開場第一秒就可以打。
	# （舊版要求「先炸跑道才打得動核設施」，規則太繞，玩家不容易搞懂。）
	st["hp"] = maxf(0.0, st["hp"] - amount)
	_broadcast("cli_set_hp", [key, st["hp"]])
	if st["hp"] <= 0.0:
		_broadcast("cli_structure_down", [sk, attacker])


func _broadcast(method: String, args: Array) -> void:
	if _has_net():
		callv("rpc", [method] + args)
	callv(method, args)


@rpc("authority", "call_remote", "reliable")
func cli_set_hp(key: Variant, hp: float) -> void:
	if key is int:
		if aircraft.has(key):
			aircraft[key].hp = hp
	elif structures.has(String(key)):
		structures[String(key)]["hp"] = hp


@rpc("authority", "call_remote", "reliable")
func cli_kill(pid: int, attacker: int) -> void:
	var a: Aircraft = aircraft.get(pid)
	if a == null:
		return
	a.alive = false
	a.hp = 0.0
	a.visible = false
	_spawn_flash(a.global_position, 14.0, Color(1.0, 0.6, 0.2))
	play_sfx("explode", -8.0)
	if a.is_local:
		_shake(1.6, 0.6)

	# 擊墜／陣亡統計。這是唯一「確定有人被打下來」的地方，而舊版 players[id] 裡的
	# kills / deaths 自從 _new_player_entry() 建立之後全專案沒有任何地方加過 ─
	# 名單上永遠是 0，SIDE_MISSIONS 的 A6「斬首」也因此不可能觸發。
	# cli_kill 是由房主 _broadcast 出去的，每一端都會各自加一次，結果一致。
	var mg := _mg()
	if mg.players.has(pid):
		mg.players[pid]["deaths"] = int(mg.players[pid].get("deaths", 0)) + 1
	if attacker != pid and mg.players.has(attacker):
		mg.players[attacker]["kills"] = int(mg.players[attacker].get("kills", 0)) + 1
	if a.is_local:
		last_killer = attacker

	var vn: String = _mg().players[pid]["name"] if _mg().players.has(pid) else "?"
	var an: String = _mg().players[attacker]["name"] if _mg().players.has(attacker) else "戰場"
	if attacker == _local_id() and pid != _local_id():
		_mg().add_credits(MainGame.REWARD_KILL, "擊墜 " + vn)
	_mg().add_chat_line("[擊墜] %s ✕ %s" % [an, vn], Color(1.0, 0.75, 0.35))


@rpc("authority", "call_remote", "reliable")
func cli_structure_down(key: String, _attacker: int) -> void:
	if _attacker == _local_id():
		_mg().add_credits(MainGame.REWARD_STRUCTURE, "摧毀設施")
	if not structures.has(key):
		return
	var st: Dictionary = structures[key]
	st["hp"] = 0.0
	var node: Node3D = st["node"]
	_spawn_flash(node.global_position + Vector3.UP * 12.0, 40.0, Color(1.0, 0.45, 0.15))

	match String(st["kind"]):
		"runway":
			runway_down = true
			runway_lock_left = MainGame.RUNWAY_LOCK_TIME
			officer_say("跑道被打穿了！防守方六十秒內無法起飛 ─ 進攻方把握時間全力突擊！", "urgent", 5)
			_tint_structure(node, Color(0.45, 0.10, 0.10), 1.5)
			_mg().add_chat_line("[警告] 跑道已被摧毀！防守方 60 秒內無法復活！", Color(1.0, 0.3, 0.3))
		"nuke":
			_mg().add_chat_line("[目標] 核設施已摧毀！", Color(1.0, 0.4, 0.4))
			officer_say("核設施命中！任務達成 ─ 全隊脫離。", "good", 6)
		"tower":
			_tint_structure(node, Color(0.3, 0.3, 0.32), 0.0)
			node.visible = false
		"aaa", "sam":
			_tint_structure(node, Color(0.22, 0.20, 0.18), 0.0)
			_spawn_flash(node.global_position + Vector3.UP * 3.0, 14.0, Color(1.0, 0.6, 0.2))
		"convoy":
			node.visible = false
			_spawn_flash(node.global_position + Vector3.UP * 2.0, 12.0, Color(1.0, 0.55, 0.2))
		"escort":
			# 護航艦被擊沉：停火、船身傾斜下沉
			if _fleet != null:
				_fleet.sink(key)
			_mg().add_chat_line("[艦隊] 護航艦被擊沉，該區防空火網出現缺口！", Color(1.0, 0.55, 0.30))
			if _mg().my_team() == MainGame.TEAM_ATTACKER:
				officer_say("我們少了一艘護航艦 ─ 那一側的防空破了。", "urgent", 4)
			else:
				officer_say("幹得好，擊沉一艘護航艦！", "good", 4)


func _tint_structure(node: Node3D, col: Color, emit: float) -> void:
	for c in node.get_children():
		if c is MeshInstance3D:
			c.material_override = make_material(col, emit)


#══════════════════════════════════════════════════════════════════════════════
#  跑道懲罰計時 & 復活
#══════════════════════════════════════════════════════════════════════════════
func _update_runway_lock(delta: float) -> void:
	if not runway_down:
		return
	runway_lock_left = maxf(0.0, runway_lock_left - delta)
	if runway_lock_left <= 0.0:
		_broadcast("cli_runway_repaired", [])


@rpc("authority", "call_remote", "reliable")
func cli_runway_repaired() -> void:
	runway_down = false
	officer_say("跑道搶修完成，防守方恢復出擊能力。", "order", 4)
	runway_lock_left = 0.0
	var st: Dictionary = structures["RUNWAY"]
	st["hp"] = st["max"]
	_tint_structure(st["node"], Color(0.11, 0.12, 0.15), 0.0)
	# 重建發光跑道燈
	var node: Node3D = st["node"]
	for c in node.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh is BoxMesh:
			var bm: BoxMesh = (c as MeshInstance3D).mesh
			if bm.size.y < 1.0:
				c.material_override = make_material(MainGame.C_DEF, 3.4)
	_mg().add_chat_line("[系統] 跑道搶修完成，防守方恢復復活能力。", MainGame.C_DEF)


func _update_respawns(delta: float) -> void:
	for pid in respawn_queue.keys():
		# 防守方在跑道被毀期間完全無法復活
		var team: int = int(_mg().players[pid]["team"]) if _mg().players.has(pid) else MainGame.TEAM_ATTACKER
		if team == MainGame.TEAM_DEFENDER and runway_down:
			continue
		respawn_queue[pid] = float(respawn_queue[pid]) - delta
		if respawn_queue[pid] <= 0.0:
			respawn_queue.erase(pid)
			# 用輪替的起飛位而非亂數，避免兩架重生後疊在同一點
			_respawn_slot[team] = (int(_respawn_slot[team]) + 1) % 6
			# AI 不會走路選機，直接重新上機；真人玩家回到甲板自己挑
			if bool(_mg().players[pid]["bot"]):
				_respawn_slot[team] = (int(_respawn_slot[team]) + 1) % 6
				var xf := _spawn_transform(team, int(_respawn_slot[team]))
				_broadcast("cli_respawn", [pid, xf.origin, xf.basis.get_rotation_quaternion()])
			else:
				_broadcast("cli_walk_respawn", [pid])


@rpc("authority", "call_remote", "reliable")
func cli_walk_respawn(pid: int) -> void:
	if aircraft.has(pid):
		aircraft[pid].queue_free()
		aircraft.erase(pid)
	_spawn_walking_pilot(pid)
	if pid == _local_id():
		_lbl_center.text = ""


@rpc("authority", "call_remote", "reliable")
func cli_respawn(pid: int, pos: Vector3, rot: Quaternion) -> void:
	if not _mg().players.has(pid):
		return
	var p: Dictionary = _mg().players[pid]
	var xf := Transform3D(Basis(rot), pos)
	_create_aircraft(pid, int(p["team"]), int(p["vtype"]), bool(p["bot"]), xf)
	if pid == _local_id():
		_lbl_center.text = ""
		_lbl_alert.text = ""


#══════════════════════════════════════════════════════════════════════════════
#  防空塔
#══════════════════════════════════════════════════════════════════════════════
func _request_tower(pos: Vector3) -> void:
	var ground := Vector3(pos.x, 0.0, pos.z)
	if not is_land(ground) and terrain_height(ground) < 6.0:
		_set_alert("不能蓋在水面上。")
		return
	if _is_host() or not _has_net():
		srv_deploy_tower(ground)
	else:
		rpc_id(1, "srv_deploy_tower", ground)


@rpc("any_peer", "reliable")
func srv_deploy_tower(pos: Vector3) -> void:
	if not _is_host() and _has_net():
		return
	if towers.size() >= 10:
		return
	_broadcast("cli_deploy_tower", [pos])


@rpc("authority", "call_remote", "reliable")
func cli_deploy_tower(pos: Vector3) -> void:
	_make_tower(pos)
	if _mg().my_team() == MainGame.TEAM_DEFENDER:
		_mg().add_chat_line("[系統] 防空塔已部署。", MainGame.C_DEF)


func _update_towers(delta: float) -> void:
	for t in towers:
		var st: Dictionary = structures.get(String(t["key"]), {})
		if st.is_empty() or st["hp"] <= 0.0:
			continue
		t["cd"] = float(t["cd"]) - delta
		var origin: Vector3 = (t["node"] as Node3D).global_position + Vector3.UP * 13.5
		var best: Aircraft = null
		var best_d: float = float(t["range"])
		for pid in aircraft:
			var a: Aircraft = aircraft[pid]
			if not a.alive or a.team != MainGame.TEAM_ATTACKER:
				continue
			if a.flare_active > 0.0:
				continue
			var d := origin.distance_to(a.global_position)
			if float(a.stats["radar"]) < 1.0 and a.global_position.y < 40.0:
				continue          # 低空直升機規避雷達
			if a.global_position.y > TOWER_CEILING:
				continue          # 拉高就打不到：高空投彈是有代價但可行的戰術
			if d < best_d:
				best = a
				best_d = d
		if best == null:
			continue
		var turret: MeshInstance3D = t["turret"]
		turret.look_at(best.global_position, Vector3.UP)
		# 防空飛彈系統：同時最多 MAX_SAM_IN_FLIGHT 發在空中
		if t["cd"] <= 0.0 and active_sam_count(MainGame.TEAM_DEFENDER) < MAX_SAM_IN_FLIGHT \
				and aa_can_fire(best.pilot_id):
			t["cd"] = TOWER_ROF
			_broadcast("cli_tower_fire", [String(t["key"]), best.pilot_id])


@rpc("authority", "call_remote", "reliable")
func cli_tower_fire(key: String, target_id: int) -> void:
	if not structures.has(key) or not aircraft.has(target_id):
		return
	var origin: Vector3 = (structures[key]["node"] as Node3D).global_position + Vector3.UP * 16.0
	var tgt: Aircraft = aircraft[target_id]
	var pr := Projectile.new()
	pr.world = self
	pr.team = MainGame.TEAM_DEFENDER
	pr.shooter = -9999
	pr.is_bomb = false
	pr.damage = TOWER_DMG
	pr.struct_mult = 0.2
	pr.vel = (tgt.global_position - origin).normalized() * 145.0
	pr.homing_target = tgt
	pr.turn = 2.0                    # 轉向鈍一點，拉大 G 或放干擾彈甩得掉
	pr.life = 7.0
	pr.kind = "sam"
	add_child(pr)
	pr.global_position = origin
	pr.setup()


#══════════════════════════════════════════════════════════════════════════════
#  空中爭奪空投（第 3 分鐘生成）
#══════════════════════════════════════════════════════════════════════════════
func _update_airdrop(delta: float) -> void:
	if drop_done:
		return
	if not drop_spawned:
		if match_time >= MainGame.AIRDROP_TIME:
			_broadcast("cli_spawn_drop", [])
		return

	var counts := { 0: 0, 1: 0 }
	var gain := { 0: 0.0, 1: 0.0 }

	for pid in aircraft:
		var a: Aircraft = aircraft[pid]
		if not a.alive:
			continue
		if a.global_position.distance_to(DROP_POS) > DROP_RADIUS:
			continue
		counts[a.team] += 1
		var rate := 7.0
		if a.vtype == MainGame.VType.HELI:
			# 直升機懸停 → 2 倍速度
			if a.speed < 8.0:
				rate *= 2.0
			else:
				rate *= 0.8
		else:
			# 戰鬥機需減速並盤旋繞圈
			var slow: bool = a.speed < float(a.stats["max_speed"]) * 0.62
			var circling: bool = absf(a.turn_rate) > 0.35
			rate *= 1.0 if (slow and circling) else 0.25
		gain[a.team] += rate * delta

	# 雙方同時在圈內 → 爭奪，效率減半
	var contested: bool = counts[0] > 0 and counts[1] > 0
	for team in [0, 1]:
		if gain[team] <= 0.0:
			continue
		var g: float = gain[team] * (0.5 if contested else 1.0)
		drop_progress[team] = minf(100.0, drop_progress[team] + g)

	_drop_sync_acc += delta
	if _drop_sync_acc >= 0.25:
		_drop_sync_acc = 0.0
		_broadcast("cli_drop_progress", [drop_progress[0], drop_progress[1]])

	for team in [0, 1]:
		if drop_progress[team] >= 100.0:
			drop_done = true
			_broadcast("cli_drop_captured", [team])
			break


@rpc("authority", "call_remote", "reliable")
func cli_spawn_drop() -> void:
	if drop_spawned:
		return
	drop_spawned = true

	drop_node = Node3D.new()
	drop_node.name = "AirDrop"
	drop_node.position = DROP_POS
	add_child(drop_node)

	var crate := make_material(Color(1.0, 0.92, 0.35), 4.5)
	make_box(drop_node, Vector3(6, 6, 6), Vector3.ZERO, crate)
	make_box(drop_node, Vector3(6.6, 1.0, 1.0), Vector3.ZERO, make_material(Color(1, 1, 1), 6.0))
	make_box(drop_node, Vector3(1.0, 1.0, 6.6), Vector3.ZERO, make_material(Color(1, 1, 1), 6.0))

	# 半徑 30 的接收圈
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = DROP_RADIUS - 1.0
	tm.outer_radius = DROP_RADIUS
	ring.mesh = tm
	ring.material_override = make_material(Color(1.0, 0.85, 0.3), 3.5)
	drop_node.add_child(ring)

	var beam := make_cyl(drop_node, DROP_RADIUS * 0.8, DROP_RADIUS * 0.8, 220.0, Vector3(0, -110, 0),
		make_material(Color(1.0, 0.9, 0.4, 0.10), 1.2))
	beam.material_override.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam.material_override.albedo_color = Color(1.0, 0.9, 0.4, 0.10)

	var area := Area3D.new()
	var cs := CollisionShape3D.new()
	var sp := SphereShape3D.new()
	sp.radius = DROP_RADIUS
	cs.shape = sp
	area.add_child(cs)
	drop_node.add_child(area)

	var tw := create_tween().set_loops()
	tw.tween_property(ring, "rotation:y", TAU, 6.0).from(0.0)

	_drop_box.visible = true
	officer_say("中央高空投下補給箱 ─ 搶下來全隊火力翻倍！", "order", 4)
	_mg().add_chat_line("[目標] 中央高空空投已投放！先累積 100% 的隊伍獲得火力強化。", Color(1.0, 0.9, 0.4))


@rpc("authority", "call_remote", "unreliable_ordered")
func cli_drop_progress(atk: float, def: float) -> void:
	drop_progress[0] = atk
	drop_progress[1] = def


@rpc("authority", "call_remote", "reliable")
func cli_drop_captured(team: int) -> void:
	drop_done = true
	officer_say("補給到手，火力全開！" if team == _mg().my_team() else "補給被對方拿走了，小心他們的火力。",
		"good" if team == _mg().my_team() else "urgent", 4)
	team_boost[team] = BOOST_TIME
	if drop_node:
		_spawn_flash(DROP_POS, 26.0, MainGame.C_ATK if team == 0 else MainGame.C_DEF)
		drop_node.queue_free()
		drop_node = null
	if team == _mg().my_team():
		_mg().add_credits(MainGame.REWARD_DROP, "奪得空投")
	_drop_box.visible = false
	_mg().add_chat_line("[空投] %s 奪得補給！全隊火力 ×%.1f 持續 %d 秒。"
		% [MainGame.TEAM_NAME[team], BOOST_MULT, int(BOOST_TIME)],
		MainGame.C_ATK if team == 0 else MainGame.C_DEF)


#══════════════════════════════════════════════════════════════════════════════
#  勝負判定
#══════════════════════════════════════════════════════════════════════════════
func _check_win_conditions() -> void:
	if structures["NUKE"]["hp"] <= 0.0:
		_broadcast("cli_end_match", [MainGame.TEAM_ATTACKER, "核設施已摧毀"])
	elif match_time >= MainGame.MATCH_TIME:
		_broadcast("cli_end_match", [MainGame.TEAM_DEFENDER, "成功守住 10 分鐘"])


@rpc("authority", "call_remote", "reliable")
func cli_end_match(team: int, reason: String) -> void:
	if not match_running:
		return
	match_running = false
	_lbl_center.text = "%s 獲勝\n%s" % [MainGame.TEAM_NAME[team], reason]
	_lbl_center.add_theme_color_override("font_color",
		MainGame.C_ATK if team == MainGame.TEAM_ATTACKER else MainGame.C_DEF)
	if team == _mg().my_team():
		_mg().add_credits(MainGame.REWARD_WIN, "作戰勝利")
	_mg().end_match(team, reason)


#══════════════════════════════════════════════════════════════════════════════
#  AI（簡易 FSM，房主端模擬）
#══════════════════════════════════════════════════════════════════════════════
## 難度只套用在「敵方」AI 身上：自己的 AI 隊友永遠維持普通水準，
## 否則調高難度反而會讓自己的僚機也變強，失去意義。連線對戰一律普通。
## 自動駕駛（專屬外掛）用的王牌數值：比任何難度的 AI 都強一截。
## 從更大的角度就敢開火、射程更遠、反應幾乎即時、還會主動用後燃器追擊。
const ACE_PILOT := {
	"name": "自動駕駛", "en": "AUTOPILOT",
	"aim": 0.780, "range": 520.0, "dmg": 1.60, "react": 0.22, "flare": 0.030,
}


func _bot_diff(a: Aircraft) -> Dictionary:
	# 玩家開了外掛：自己這台用王牌數值
	if a.is_local and autopilot:
		return ACE_PILOT
	if not _mg().solo_mode or a.team == _mg().my_team():
		return MainGame.DIFF[MainGame.DIFF_NORMAL]
	return MainGame.DIFF[_mg().difficulty]


func _update_bots(delta: float) -> void:
	for pid in aircraft:
		var a: Aircraft = aircraft[pid]
		if not a.is_bot or not a.alive:
			continue
		_ai_think(a, delta)
		_check_bounds(a)


func _ai_think(a: Aircraft, delta: float) -> void:
	var diff := _bot_diff(a)
	a.ai_timer -= delta

	# ── 狀態轉移 ──
	if a.ai_timer <= 0.0:
		a.ai_timer = float(diff["react"])
		if a.ai_state == "SUPPORT":
			var ally: Aircraft = aircraft.get(a.ai_help_id)
			if ally == null or not ally.alive or a.ai_support_left <= 0.0:
				a.ai_state = "PATROL"
		if a.ai_state != "SUPPORT":
			var enemy := _nearest_enemy(a, 520.0)
			# 圍毆上限：同一個目標最多兩架咬，其他人去做別的事。
			# 沒有這個限制，開場三架敵機會全部撲向玩家。
			if enemy != null and _gang_count(enemy, a) >= MainGame.AI_MAX_GANG:
				enemy = null
			if enemy != null and a.vtype != MainGame.VType.BOMBER:
				if a.ai_target != enemy:
					a.ai_spot = MainGame.AI_SPOT_DELAY    # 剛咬上來的一秒不開槍
				a.ai_target = enemy
				a.ai_state = "ATTACK"
			elif a.ai_state != "CAPTURE":
				a.ai_state = "STRIKE"
	a.ai_support_left = maxf(0.0, a.ai_support_left - delta)
	a.ai_spot = maxf(0.0, a.ai_spot - delta)

	# ── 決定目標點 ──
	var goal := Vector3.ZERO
	var fire_range := float(diff["range"])
	match a.ai_state:
		"ATTACK":
			# 目標可能在上一幀被釋放（重生／換機），這裡一定要驗證實例還在
			if a.ai_target != null and not is_instance_valid(a.ai_target):
				a.ai_target = null
			var t: Aircraft = a.ai_target
			if t == null or not t.alive:
				a.ai_state = "PATROL"
				return
			goal = t.global_position + t.global_transform.basis.z * -18.0
		"SUPPORT":
			var ally: Aircraft = aircraft.get(a.ai_help_id)
			if ally == null or not ally.alive:
				a.ai_state = "PATROL"
				return
			var threat := _nearest_enemy(ally, 400.0)
			goal = threat.global_position if threat != null else ally.global_position + Vector3(0, 30, 0)
		"CAPTURE":
			goal = DROP_POS
			if a.global_position.distance_to(DROP_POS) < DROP_RADIUS * 0.7:
				# 圈內：直升機懸停、戰機減速盤旋
				if a.stats["hover"]:
					a.hover_mode = true
					a.fly(delta, 0.0, 0.0, -1.0)
					return
				goal = DROP_POS + Vector3(cos(match_time * 0.9) * 22.0, 6.0, sin(match_time * 0.9) * 22.0)
		"STRIKE":
			if a.team == MainGame.TEAM_ATTACKER:
				# 核設施沒有護盾，隨時能打：轟炸機直接去拆核設施，
				# 其他機種先炸跑道（癱瘓復活），核設施被拆到一半時全員轉向核設施。
				goal = NUKE_POS + Vector3(0, 60, 0) if _ai_hits_nuke(a) \
					else RUNWAY_POS + Vector3(0, 55, 0)
			else:
				var atk := _nearest_enemy(a, 900.0)
				goal = atk.global_position if atk != null else Vector3(0, 150, 220)
			fire_range = float(diff["range"]) * 1.25
		_:
			goal = a.ai_wp
			if goal == Vector3.ZERO or a.global_position.distance_to(goal) < 60.0:
				# 戰場放大後巡邏範圍也跟著放大，AI 才不會全擠在中央
				a.ai_wp = Vector3(_rng.randf_range(-MAP_LIMIT * 0.58, MAP_LIMIT * 0.58),
					_rng.randf_range(120, 340),
					_rng.randf_range(-MAP_LIMIT * 0.52, MAP_LIMIT * 0.36))
				goal = a.ai_wp

	# ── 邊界：快飛出戰區就把目標拉回中央，否則會被離場判定擊落 ──
	if absf(a.global_position.x) > MAP_LIMIT * 0.74 or absf(a.global_position.z) > MAP_LIMIT * 0.85:
		goal = Vector3(0.0, 240.0, -200.0)

	# ── 避地形 ──
	# 舊版只取「目前位置」與「正前方 150 m」兩點，而且要等到離地不足 50 m 才反應。
	# 150 m 在 150 m/s 下只有一秒，戰機根本拉不起來；山脊剛好落在兩個取樣點之間
	# 更是完全看不到 ─ 這就是自動駕駛一路撞進大堤頓山壁的原因。
	# 現在沿著航向連續取樣，預看距離隨速度放大，餘裕也隨速度放大。
	var look := clampf(a.speed * 5.0, 350.0, 950.0)
	var fwd := -a.global_transform.basis.z
	var floor_ahead := terrain_height(a.global_position)
	# 門檻維持在 45 m：真正的修正是「看多遠」與「拉多用力」，不是把門檻拉高。
	# 門檻一大，平地上的低空投彈航線也會被判成危險，AI 會被抬到一百多公尺，
	# 結果永遠炸不到跑道與核設施。
	var pulling_up: bool = a.global_position.y < floor_ahead + 45.0
	for i in 8:
		# 取樣點沿著「實際航向」推進，比對的是該點的預測高度而不是目前高度。
		# 只比對目前高度的話，俯衝追擊時整段俯衝都不會示警 ─ 預測點一路往下，
		# 但機身當下還在高處，判定永遠是安全的，直到真的插進地面。
		var probe := a.global_position + fwd * (look * float(i + 1) / 8.0)
		var h := terrain_height(probe)
		floor_ahead = maxf(floor_ahead, h)
		if probe.y < h + 45.0:
			pulling_up = true
	if pulling_up:
		# 只把 goal.y 抬高沒有用：目標在一公里外時 _steer_to 只會給出幾度的抬頭，
		# 而山壁是幾秒內就到。改成把目標放到「正前方 90 m 的高空」，
		# 仰角才會大到逼出接近滿舵的拉升。
		var flat := Vector3(fwd.x, 0.0, fwd.z)
		flat = flat.normalized() if flat.length_squared() > 0.01 else Vector3(0, 0, -1)
		goal = Vector3(a.global_position.x + flat.x * 90.0,
			floor_ahead + 150.0,
			a.global_position.z + flat.z * 90.0)

	var inp := _steer_to(a, goal)
	var thr := 1.0
	if a.ai_state == "CAPTURE":
		thr = -1.0
	# 自動駕駛：距離目標還遠就開後燃器追上去（一般 AI 不會用）。
	# 正在拉升脫離地形時不要加速，否則只是更快撞上去。
	if a.is_local and autopilot:
		var far: bool = a.global_position.distance_to(goal) > 260.0
		a.set_boost(far and not pulling_up and a.boost_fuel > 0.25, delta)
	a.fly(delta, inp.y, inp.x, thr)

	# ── 開火判定 ──
	var target_pos := goal
	var can_fire := false
	if a.ai_state == "ATTACK" or a.ai_state == "SUPPORT":
		if a.ai_target != null and not is_instance_valid(a.ai_target):
			a.ai_target = null
		var t2: Aircraft = a.ai_target if a.ai_state == "ATTACK" else _nearest_enemy(a, 400.0)
		if t2 != null and t2.alive:
			target_pos = t2.global_position
			can_fire = true
	elif a.ai_state == "STRIKE" and a.team == MainGame.TEAM_ATTACKER:
		var key := "NUKE" if _ai_hits_nuke(a) else "RUNWAY"
		if structures[key]["hp"] > 0.0:
			target_pos = (structures[key]["node"] as Node3D).global_position + Vector3.UP * 8.0
			can_fire = true

	# 剛發現目標的那一秒不開火，玩家才有反應時間
	if a.ai_spot > 0.0 and a.ai_state == "ATTACK":
		can_fire = false

	if can_fire:
		var to := target_pos - a.global_position
		var d := to.length()
		var aim := (-a.global_transform.basis.z).dot(to.normalized())
		if aim > float(diff["aim"]):
			# 近距離掃機槍，中遠距離放飛彈／投彈
			if d < minf(GUN_RANGE, fire_range):
				_try_gun(a)
			if d < fire_range:
				_try_missile(a)
	# 被鎖定時偶爾放干擾彈
	if a.flares > 0 and a.flare_cd <= 0.0 and _rng.randf() < float(diff["flare"]):
		_try_flare(a)


## 這架 AI 該去打核設施還是跑道。
## 轟炸機是唯一能有效拆設施的機種，直接去核設施；
## 其他機種先癱瘓跑道，等核設施掉到七成以下再全員集火。
func _ai_hits_nuke(a: Aircraft) -> bool:
	if a.vtype == MainGame.VType.BOMBER:
		return true
	if runway_down:
		return true
	var nk: Dictionary = structures.get("NUKE", {})
	if nk.is_empty():
		return true
	return float(nk["hp"]) < float(nk["max"]) * 0.7


## 目前有幾架 AI 正在咬同一個目標
func _gang_count(target, except_a) -> int:
	if target == null or not is_instance_valid(target):
		return 0
	var n := 0
	for pid in aircraft:
		var o: Aircraft = aircraft[pid]
		if o == except_a or not o.is_bot or not o.alive:
			continue
		if o.ai_state == "ATTACK" and is_instance_valid(o.ai_target) and o.ai_target == target:
			n += 1
	return n


func _nearest_enemy(a: Aircraft, max_d: float) -> Aircraft:
	var best: Aircraft = null
	var bd := max_d
	for pid in aircraft:
		var o: Aircraft = aircraft[pid]
		if o == a or not o.alive or o.team == a.team:
			continue
		var d := a.global_position.distance_to(o.global_position)
		if d < bd:
			best = o
			bd = d
	return best


## 回傳 Vector2(yaw_input, pitch_input)，範圍 -1~1
func _steer_to(a: Aircraft, target: Vector3) -> Vector2:
	var local := a.global_transform.affine_inverse() * target
	var horiz := sqrt(local.x * local.x + local.z * local.z)
	var yaw_angle := atan2(local.x, -local.z)          # 正 = 目標在右
	var pitch_angle := atan2(local.y, maxf(horiz, 0.01))
	return Vector2(clampf(yaw_angle * 1.6, -1.0, 1.0), clampf(pitch_angle * 1.8, -1.0, 1.0))


#══════════════════════════════════════════════════════════════════════════════
#  無線電回應（由 MainGame.net_radio 轉呼叫）
#══════════════════════════════════════════════════════════════════════════════
func on_radio(sender_id: int, sender_team: int, idx: int) -> void:
	var sender: Aircraft = aircraft.get(sender_id)

	# Key 1：頭頂彈出 3D 驚嘆號，AI 隊友前來救援
	if idx == 0 and sender != null:
		sender.show_help_marker(3.0)

	if not _is_host():
		return

	for pid in aircraft:
		var a: Aircraft = aircraft[pid]
		if not a.is_bot or not a.alive or a.team != sender_team:
			continue
		match idx:
			0:
				if sender_team == _mg().my_team():
					officer_say("有人被咬住了 ─ 最近的機立刻支援！", "urgent", 4)
				if sender != null and a.pilot_id != sender_id:
					a.ai_state = "SUPPORT"
					a.ai_help_id = sender_id
					a.ai_support_left = 25.0
					a.ai_timer = 3.0
			1:
				a.ai_state = "STRIKE"
				a.ai_timer = 8.0
			2:
				if drop_spawned and not drop_done:
					a.ai_state = "CAPTURE"
					a.ai_timer = 12.0


#══════════════════════════════════════════════════════════════════════════════
#  特效 & HUD 更新
#══════════════════════════════════════════════════════════════════════════════
#══════════════════════════════════════════════════════════════════════════════
#  彈射特效 / 鏡頭震動 / 程序化音效
#══════════════════════════════════════════════════════════════════════════════
## 彈射蒸汽：沿彈射軌道往後噴的白色蒸氣柱
func _spawn_catapult_fx(pos: Vector3, basis: Basis) -> void:
	var steam := StandardMaterial3D.new()
	steam.albedo_color = Color(1, 1, 1, 0.5)
	steam.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	steam.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	steam.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES

	var quad := QuadMesh.new()
	quad.size = Vector2(7, 7)

	var p := GPUParticles3D.new()
	p.amount = 70
	p.lifetime = 1.6
	p.one_shot = true
	p.explosiveness = 0.55
	p.draw_pass_1 = quad
	p.material_override = steam
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(3, 1, 12)
	pm.direction = basis.z            # 往機尾方向噴
	pm.spread = 32.0
	pm.initial_velocity_min = 14.0
	pm.initial_velocity_max = 34.0
	pm.gravity = Vector3(0, 2.0, 0)
	pm.scale_min = 0.8
	pm.scale_max = 3.0
	pm.color = Color(1, 1, 1, 0.6)
	p.process_material = pm
	add_child(p)
	p.global_position = pos
	p.emitting = true
	get_tree().create_timer(3.0).timeout.connect(p.queue_free)


func _shake(amount: float, duration: float) -> void:
	_shake_amt = maxf(_shake_amt, amount)
	_shake_left = maxf(_shake_left, duration)


## 以程式碼合成音效，完全不依賴外部音檔（符合純程式碼建構的規範）
func _make_sfx(kind: String) -> AudioStreamWAV:
	var rate := 22050
	var dur := 0.3
	match kind:
		"catapult": dur = 1.1
		"gun":      dur = 0.07
		"missile":  dur = 0.8
		"explode":  dur = 1.4
		"thunder":  dur = 2.6
		"lock":     dur = 0.12
	var n := int(rate * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in n:
		var t := float(i) / float(rate)
		var f := t / dur                       # 0→1 進度
		var v := 0.0
		match kind:
			"catapult":
				# 白噪音 + 由低往高掃的嘶聲，模擬蒸汽彈射
				var env: float = sin(f * PI) * (1.0 - f * 0.3)
				phase += (90.0 + 520.0 * f) / float(rate) * TAU
				v = (_rng.randf_range(-1.0, 1.0) * 0.75 + sin(phase) * 0.25) * env
			"gun":
				v = _rng.randf_range(-1.0, 1.0) * pow(1.0 - f, 3.0)
			"missile":
				phase += (700.0 - 500.0 * f) / float(rate) * TAU
				v = (_rng.randf_range(-1.0, 1.0) * 0.6 + sin(phase) * 0.4) * pow(1.0 - f, 1.5)
			"explode":
				# 低頻轟鳴 + 噪音，指數衰減
				phase += (55.0 + 25.0 * (1.0 - f)) / float(rate) * TAU
				v = (_rng.randf_range(-1.0, 1.0) * 0.55 + sin(phase) * 0.45) * exp(-f * 4.5)
			"thunder":
				# 前段爆裂、後段長尾滾動的雷聲
				var roll: float = 0.55 + 0.45 * sin(t * 7.0) * sin(t * 2.3)
				phase += (40.0 + 18.0 * sin(t * 3.0)) / float(rate) * TAU
				v = (_rng.randf_range(-1.0, 1.0) * 0.6 + sin(phase) * 0.4) * roll * exp(-f * 2.2)
			"lock":
				phase += 1500.0 / float(rate) * TAU
				v = sin(phase) * (1.0 - f)
		var s := int(clampf(v, -1.0, 1.0) * 30000.0)
		data[i * 2] = s & 0xFF
		data[i * 2 + 1] = (s >> 8) & 0xFF

	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = rate
	st.stereo = false
	st.data = data
	return st


func _build_audio() -> void:
	for k in ["catapult", "gun", "missile", "explode", "thunder", "lock"]:
		_sfx[k] = _make_sfx(k)
	for i in 8:                                  # 小的播放器池，避免每次發聲都配置節點
		var pl := AudioStreamPlayer.new()
		add_child(pl)
		_sfx_players.append(pl)


func play_sfx(kind: String, volume_db: float = -6.0) -> void:
	if not _sfx.has(kind):
		return
	for pl in _sfx_players:
		if not pl.playing:
			pl.stream = _sfx[kind]
			pl.volume_db = volume_db
			pl.play()
			return


func _spawn_flash(pos: Vector3, radius: float, col: Color) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	mi.mesh = sm
	var mat := make_material(col, 8.0)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	add_child(mi)
	mi.global_position = pos
	mi.scale = Vector3.ONE * 0.6

	var light := OmniLight3D.new()
	light.light_color = col
	light.light_energy = 8.0
	light.omni_range = radius * 3.0
	mi.add_child(light)

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3.ONE * radius, 0.45)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.55)
	tw.tween_property(light, "light_energy", 0.0, 0.5)
	tw.chain().tween_callback(mi.queue_free)


func _set_crosshair_color(c: Color) -> void:
	for r in _crosshair.get_children():
		if r is ColorRect:
			(r as ColorRect).color = c


func _set_alert(msg: String) -> void:
	_lbl_alert.text = msg
	_alert_timer = 2.5


func _update_hud() -> void:
	if _alert_timer > 0.0:
		_alert_timer -= get_physics_process_delta_time()
		if _alert_timer <= 0.0:
			_lbl_alert.text = ""

	var left := maxf(0.0, MainGame.MATCH_TIME - match_time)
	_lbl_timer.text = "%02d:%02d" % [int(left) / 60, int(left) % 60]

	var rw: Dictionary = structures["RUNWAY"]
	var nk: Dictionary = structures["NUKE"]
	var rw_txt := "跑道 [毀壞 %ds]" % int(ceil(runway_lock_left)) if runway_down \
		else "跑道 %d%%" % int(rw["hp"] / rw["max"] * 100.0)
	var nk_txt := "核設施 %d%%" % int(nk["hp"] / nk["max"] * 100.0)
	_lbl_obj.text = "%s　│　%s" % [rw_txt, nk_txt]

	# 基地血量條
	if _bar_runway:
		_bar_runway.value = rw["hp"] / rw["max"] * 100.0
	if _bar_nuke:
		_bar_nuke.value = nk["hp"] / nk["max"] * 100.0

	# 空投進度
	if _drop_box.visible:
		_bar_atk.value = drop_progress[0]
		_bar_def.value = drop_progress[1]

	# 儀表
	var me: Aircraft = aircraft.get(_local_id())
	if me != null and me.alive:
		var boost := "　⚡火力強化" if team_boost.get(me.team, 0.0) > 0.0 else ""
		var msl_name: String = String(MainGame.WEAPONS[me.weapon]["name"])
		var lock_txt := ""
		var locked: bool = me.lock_target != null and is_instance_valid(me.lock_target)
		if locked:
			lock_txt = "\n◎ 鎖定 %s　%d m" % [me.lock_target.pilot_name,
				int(me.global_position.distance_to(me.lock_target.global_position))]
		# 外掛狀態只出現在自己的儀表上，不進聊天框
		if autopilot:
			boost += "　◆ AUTO"
		_lbl_vitals.text = "HP %d / %d%s\n速度 %d m/s　高度 %d m　油門 %d%%\n機槍 %d　%s %d　干擾彈 %d%s%s" % [
			int(me.hp), int(me.max_hp), boost,
			int(me.speed), int(me.global_position.y), int(me.throttle * 100.0),
			me.gun_ammo, msl_name, me.msl_ammo, me.flares,
			"\n[ 懸停模式 ]" if me.hover_mode else "", lock_txt]
		_crosshair.visible = true
		_set_crosshair_color(Color(1.0, 0.35, 0.35, 0.95) if locked else Color(0.4, 1.0, 0.8, 0.75))
		_update_health_bars(me, locked)
	else:
		_crosshair.visible = false
		_hide_health_bars()
		var t := _mg().my_team()
		if t == MainGame.TEAM_DEFENDER and runway_down:
			_lbl_center.text = "跑道已被摧毀\n無法復活　%d 秒" % int(ceil(runway_lock_left))
			_lbl_center.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
		elif respawn_queue.has(_local_id()):
			_lbl_center.text = "重新出擊　%d" % int(ceil(float(respawn_queue[_local_id()])))
			_lbl_center.add_theme_color_override("font_color", Color(1, 1, 1))
		elif pilots.has(_local_id()):
			_lbl_center.text = ""
		elif match_running:
			_lbl_center.text = "等待重新出擊…"
		_lbl_vitals.text = ""


## 自機血量、後燃器燃料、鎖定目標血量
func _update_health_bars(me: Aircraft, locked: bool) -> void:
	if _bar_hp == null:
		return
	_hp_box.visible = true
	var frac := clampf(me.hp / maxf(me.max_hp, 1.0), 0.0, 1.0)
	_bar_hp.value = frac * 100.0
	# 血量越低越紅，最後一段還會閃
	var col := Color(1.0 - frac * 0.65, 0.25 + frac * 0.72, 0.32)
	if frac < 0.28:
		col = col.lerp(Color(1, 1, 1), 0.35 * absf(sin(Time.get_ticks_msec() * 0.008)))
	var fg := StyleBoxFlat.new()
	fg.bg_color = col
	_bar_hp.add_theme_stylebox_override("fill", fg)
	_lbl_hp.text = "機體 HP　%d / %d" % [int(me.hp), int(me.max_hp)]

	_bar_boost.value = me.boost_fuel * 100.0
	var bcol := Color(1.00, 0.62, 0.22) if me.boost_fuel > 0.2 else Color(0.9, 0.35, 0.25)
	var bfg := StyleBoxFlat.new()
	bfg.bg_color = bcol
	_bar_boost.add_theme_stylebox_override("fill", bfg)
	_lbl_boost.text = "後燃器 AFTERBURNER　[SPACE]%s" % ("　▶ 加力中" if me.boost_on else "")
	_lbl_boost.add_theme_color_override("font_color",
		Color(1.0, 0.75, 0.35) if me.boost_on else MainGame.C_DIM)

	# 鎖定（或正在鎖定）的目標血量
	var t = me.lock_target if locked else me.lock_candidate
	if t != null and is_instance_valid(t) and t.alive:
		_tgt_box.visible = true
		var tf := clampf(t.hp / maxf(t.max_hp, 1.0), 0.0, 1.0)
		_bar_tgt.value = tf * 100.0
		var state := "◎ 鎖定" if locked else "◌ 鎖定中 %d%%" % int(me.lock_progress * 100.0)
		_tgt_name.text = "%s　%s　%d m" % [state, t.pilot_name,
			int(me.global_position.distance_to(t.global_position))]
		_tgt_name.add_theme_color_override("font_color",
			Color(1.0, 0.40, 0.36) if locked else Color(1.0, 0.82, 0.30))
	else:
		_tgt_box.visible = false


func _hide_health_bars() -> void:
	if _bar_hp == null:
		return
	# 整組收掉：只清空文字的話，空的進度條底色會留下兩條黑帶
	_hp_box.visible = false
	_tgt_box.visible = false


#══════════════════════════════════════════════════════════════════════════════
#  ── 內部類別：Aircraft ─────────────────────────────────────────────────────
#══════════════════════════════════════════════════════════════════════════════
class Aircraft extends CharacterBody3D:
	var world: Node3D
	var pilot_id: int = 0
	var pilot_name: String = ""
	var team: int = 0
	var vtype: int = 0
	var weapon: int = 0
	var stats: Dictionary = {}

	var hp: float = 100.0
	var max_hp: float = 100.0
	var speed: float = 40.0
	var throttle: float = 0.7
	var turn_rate: float = 0.0
	var alive: bool = true
	var is_bot: bool = false
	var is_local: bool = false
	var is_display: bool = false   # 停機坪展示機，不參與戰鬥
	var hover_mode: bool = false

	var gun_cd: float = 0.0
	var gun_ammo: int = 0
	var msl_cd: float = 0.0
	var msl_ammo: int = 0
	var ammo_pool: Dictionary = {}   # 武裝 id -> 剩餘彈數（切換武裝時各自保存）
	var lock_target = null          # 已完成鎖定的敵機（飛彈用）
	var lock_candidate = null       # 錐形內正在累積鎖定的目標
	var lock_progress: float = 0.0  # 0~1
	var catapult_kick: float = 0.0  # 彈射加速感殘量（給鏡頭 FOV 與震動用）
	var flare_cd: float = 0.0
	var flare_active: float = 0.0
	var flares: int = 6

	# ── 後燃器加速（Space）──
	const LOCK_TIME    := 0.75      # 鎖定所需的持續瞄準時間
	const BOOST_MULT   := 1.62      # 加速時的目標速度倍率（相對最高速）
	const BOOST_DRAIN  := 0.30      # 每秒消耗的燃料比例
	const BOOST_REGEN  := 0.17      # 每秒回充
	var roll_rate: float = 0.0
	var boost_on: bool = false
	var boost_fuel: float = 1.0     # 0~1
	var boost_power: float = 0.0    # 平滑後的強度，給特效與 HUD 用
	var afterburners: Array = []    # [{ particles, core, flame }]

	# 網路插值
	var net_pos := Vector3.ZERO
	var net_rot := Quaternion.IDENTITY
	var has_net := false

	# AI
	var ai_state: String = "PATROL"
	var ai_target = null
	var ai_help_id: int = 0
	var ai_support_left: float = 0.0
	var ai_timer: float = 0.0
	var ai_wp := Vector3.ZERO
	var ai_spot: float = 0.0        # 剛發現目標後的開火延遲

	var pivot: Node3D
	var rotor: Node3D
	var cockpit: Node3D
	var cockpit_sweep: Node3D       # 座艙左側 MFD 的雷達掃描線
	var cockpit_stick: Node3D       # 座艙操縱桿（含握著它的手）
	var stick_pitch: float = 0.0    # 最近一次的操縱輸入，用來擺動操縱桿
	var stick_roll: float = 0.0
	var eye_offset := Vector3(0.0, 0.9, -1.6)   # 駕駛眼睛的區域座標（第一人稱用）
	var nose_ahead: float = -4.0                # 機首的區域 z（機體最前端）
	var name_label: Label3D
	var help_label: Label3D


	func setup() -> void:
		stats = MainGame.VSTATS[vtype]
		if world != null and world._is_wright(vtype):
			# 一九〇三年的性能：慢、脆、轉不動，但機槍還在（別問）
			stats = stats.duplicate()
			stats["max_speed"] = 22.0
			stats["min_speed"] = 9.0
			stats["accel"] = 7.0
			stats["hp"] = 45.0
			stats["pitch"] = 1.1
			stats["yaw"] = 0.8
		var mg := MainGame.instance
		var up := is_local and not is_display
		max_hp = float(stats["hp"]) * (1.0 + (mg.upgrade_bonus("hp") if up else 0.0))
		hp = max_hp
		gun_ammo = int(float(stats["gun_ammo"]) * (1.0 + (mg.upgrade_bonus("gun_ammo") if up else 0.0)))
		# 三種副武裝各自有備彈池：空中用 1/2/3 切換時不會互相偷彈
		var bonus := int(mg.upgrade_bonus("msl_ammo")) if up else 0
		ammo_pool.clear()
		for aw in stats["weapons"]:
			ammo_pool[int(aw)] = int(MainGame.WEAPONS[aw]["ammo"]) + bonus
		if not ammo_pool.has(weapon):
			ammo_pool[weapon] = int(MainGame.WEAPONS[weapon]["ammo"]) + bonus
		msl_ammo = int(ammo_pool[weapon])
		flares = 6      # 被咬住的保命手段，給多一點

		# 飛機放在第 2 層，且只碰撞第 1 層（地形與建築）。
		# 若讓飛機彼此碰撞，雙方對頭衝鋒交錯時會整批同歸於盡。
		if is_display:
			collision_layer = 0
			collision_mask = 0
		else:
			collision_layer = 2
			collision_mask = 1

		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(6, 2.5, 8) if vtype == MainGame.VType.BOMBER else Vector3(4, 2, 6)
		cs.shape = box
		add_child(cs)

		pivot = Node3D.new()
		add_child(pivot)
		_build_mesh()
		_build_labels()


	## 機體外觀統一交給 AircraftMesh.gd（停機棚與商店預覽用的是同一份程式）
	func _build_mesh() -> void:
		var w: Node3D = world
		var team_col: Color = MainGame.C_ATK if team == MainGame.TEAM_ATTACKER else MainGame.C_DEF
		# 停在甲板上的展示機發光要壓低，否則近距離會被 Glow 糊成一團白，
		# 玩家根本看不出自己要登的是哪一種機。
		var emul := 0.18 if is_display else 1.0
		var base_col: Color = MainGame.instance.skin_color() if (is_local and not is_display) \
			else Color(0.13, 0.14, 0.18)
		var info: Dictionary = w._mesher.build(pivot, vtype, base_col, team_col, {
			"emul": emul,
			"wright": w._is_wright(vtype),
			"engine_col": Color(stats["color"]),
			# 自機才用塗裝色蓋掉外部模型的材質 ─ 商店買的塗裝要看得見
			"skin_col": base_col if (is_local and not is_display) else null,
		})
		rotor = info.get("rotor")

		# 座艙位置：照機體實際尺寸算出「駕駛的眼睛」在哪，
		# 寫死偏移在飛翼與細長機身上都會跑到機體裡面。
		var ab: AABB = info.get("aabb", AABB())
		if ab.size.length() > 0.5:
			var ctr := ab.get_center()
			# 機首在座艙前方多遠（負值），座艙的機鼻整流罩不能畫超過這個長度，
			# 否則會從機體外面戳出來一根尖角。
			nose_ahead = ab.position.z
			# 機首在 -Z（AABB 的最小 z），座艙罩大約在機首往後 26% 的位置；
			# 高度取機體中心再往上一點，剛好從座艙罩看得過機鼻。
			# 座艙罩大約在機身前 30% 處。抓太前面（16%）眼睛幾乎貼在機首上，
			# 機鼻就沒有空間可以畫，整流罩會變成糊在鏡頭前的一大片。
			eye_offset = Vector3(0.0,
				clampf(ctr.y + maxf(0.55, ab.size.y * 0.34), 0.5, 2.8),
				clampf(ab.position.z + ab.size.z * 0.30, -5.5, -0.8))
		else:
			eye_offset = Vector3(0.0, 0.9, -1.6)
		# 後燃器：尾噴口的火花與熱焰，只有真正在飛的機體才需要
		if not is_display:
			var ex: Array = info.get("exhaust", [])
			if not ex.is_empty():
				afterburners = w._mesher.build_afterburners(pivot, ex, team_col)


	func _build_labels() -> void:
		name_label = Label3D.new()
		name_label.text = pilot_name
		name_label.font_size = 48
		name_label.pixel_size = 0.012
		name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		name_label.no_depth_test = true
		name_label.modulate = MainGame.C_ATK if team == MainGame.TEAM_ATTACKER else MainGame.C_DEF
		name_label.outline_size = 12
		name_label.position = Vector3(0, 3.6, 0)
		name_label.visible = not is_local
		add_child(name_label)

		help_label = Label3D.new()
		help_label.text = "❗ [NEED HELP!]"
		help_label.font_size = 64
		help_label.pixel_size = 0.016
		help_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		help_label.no_depth_test = true
		help_label.modulate = Color(1.0, 0.85, 0.2)
		help_label.outline_size = 14
		help_label.position = Vector3(0, 6.2, 0)
		help_label.visible = false
		add_child(help_label)


	func show_help_marker(secs: float) -> void:
		help_label.visible = true
		var tw := create_tween()
		tw.tween_property(help_label, "position:y", 7.4, 0.5)
		tw.tween_interval(secs)
		tw.tween_callback(func():
			help_label.visible = false
			help_label.position.y = 6.2)


	## Arcade 飛行
	##   pitch_in 正 = 拉升　yaw_in 正 = 右偏航　thr_in 正 = 加油門
	##   roll_in  正 = 向右滾轉（鍵盤 Z / C）
	func fly(delta: float, pitch_in: float, yaw_in: float, thr_in: float,
			roll_in: float = 0.0) -> void:
		if not alive:
			return
		gun_cd = maxf(0.0, gun_cd - delta)
		msl_cd = maxf(0.0, msl_cd - delta)
		flare_cd = maxf(0.0, flare_cd - delta)
		flare_active = maxf(0.0, flare_active - delta)

		# 記下操縱輸入：座艙裡的操縱桿與手要跟著擺（自動駕駛時也一樣會動）
		stick_pitch = pitch_in
		stick_roll = roll_in

		var min_s := float(stats["min_speed"])
		var max_s := float(stats["max_speed"])
		var hover: bool = bool(stats["hover"])
		throttle = clampf(throttle + thr_in * delta * 0.55, 0.0, 1.0)

		var target_speed := lerpf(min_s, max_s, throttle)
		if hover and hover_mode:
			target_speed = minf(target_speed, 6.0)
		elif boost_on:
			target_speed = max_s * BOOST_MULT        # 後燃器：直接衝過平飛極速
		var acc := float(stats["accel"]) * (2.4 if boost_on else 1.0)
		speed = move_toward(speed, target_speed, acc * delta)

		# 低速時舵面效率下降（直升機不受影響）
		var authority := 1.0
		if not hover:
			authority = clampf(speed / (max_s * 0.5), 0.25, 1.0)

		turn_rate = yaw_in * authority
		roll_rate = roll_in * authority
		rotate_object_local(Vector3.RIGHT, pitch_in * float(stats["pitch"]) * authority * delta)
		rotate_object_local(Vector3.UP, -yaw_in * float(stats["yaw"]) * authority * delta)
		# 真正的滾轉：Vector3.FORWARD 是 -Z，正值＝右翼下沉
		if not (hover and hover_mode):
			rotate_object_local(Vector3.FORWARD, roll_in * float(stats["roll"]) * authority * delta)
		transform.basis = transform.basis.orthonormalized()

		velocity = -global_transform.basis.z * speed

		# 升力不足會掉高度；直升機懸停模式可原地維持
		if hover and hover_mode:
			velocity.y += pitch_in * 14.0            # 懸停時 W/S 控制升降
		else:
			var lift := clampf(speed / maxf(min_s, 1.0), 0.0, 1.0)
			velocity.y -= (1.0 - lift) * 26.0

		move_and_slide()
		# 有真的滾轉時就不要再疊視覺假傾斜（AI 仍然靠假傾斜表現轉彎）
		animate_visual(delta, 0.0 if absf(roll_in) > 0.01 else yaw_in)


	## 換副武裝：把目前的剩餘彈數收回自己的池子，再取出新武裝的
	func set_weapon(w: int) -> void:
		if w == weapon:
			return
		ammo_pool[weapon] = msl_ammo
		weapon = w
		if not ammo_pool.has(w):
			ammo_pool[w] = int(MainGame.WEAPONS[w]["ammo"])
		msl_ammo = int(ammo_pool[w])
		msl_cd = maxf(msl_cd, 0.4)      # 換掛架的小硬直


	## 機體目前的滾轉角：0 = 水平，正 = 左翼下沉
	func get_roll_angle() -> float:
		var b := global_transform.basis
		return atan2(b.x.y, b.y.y)


	## 後燃器開關與燃料收支（每幀呼叫）
	func set_boost(on: bool, delta: float) -> void:
		var hover: bool = bool(stats["hover"]) and hover_mode
		boost_on = on and boost_fuel > 0.02 and not hover and alive
		if boost_on:
			boost_fuel = maxf(0.0, boost_fuel - BOOST_DRAIN * delta)
		else:
			boost_fuel = minf(1.0, boost_fuel + BOOST_REGEN * delta)
		boost_power = move_toward(boost_power, 1.0 if boost_on else 0.0,
			delta * (3.2 if boost_on else 1.8))
		update_afterburner()


	## 尾噴口特效：粒子火花 + 內外焰，強度跟著 boost_power
	func update_afterburner() -> void:
		var vis := boost_power > 0.04
		for e in afterburners:
			var p: GPUParticles3D = e["particles"]
			var core: MeshInstance3D = e["core"]
			var flame: MeshInstance3D = e["flame"]
			if p.emitting != boost_on:
				p.emitting = boost_on
			core.visible = vis
			flame.visible = vis
			if vis:
				core.scale = Vector3(0.7 + boost_power * 0.5, 0.5 + boost_power * 0.8, 1.0)
				flame.scale = Vector3(0.6 + boost_power * 0.6, 0.4 + boost_power * 1.1, 1.0)


	func animate_visual(delta: float, bank_in: float = 0.0) -> void:
		if pivot:
			pivot.rotation.z = lerpf(pivot.rotation.z, -bank_in * 0.75, clampf(delta * 5.0, 0, 1))
		if rotor:
			rotor.rotation.y += delta * 26.0


#══════════════════════════════════════════════════════════════════════════════
#  ── 內部類別：Pilot（步行中的飛行員）────────────────────────────────────────
#══════════════════════════════════════════════════════════════════════════════
class Pilot extends CharacterBody3D:
	var world: Node3D
	var pilot_id: int = 0
	var team: int = 0
	var is_local: bool = false
	var speed: float = 11.0
	var body: Node3D

	func setup() -> void:
		collision_layer = 4          # 獨立層：不擋飛機也不被子彈打到
		collision_mask = 1           # 只跟地形／甲板碰撞

		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.5
		cap.height = 2.0
		cs.shape = cap
		add_child(cs)

		var w: Node3D = world
		body = Node3D.new()
		add_child(body)
		# 膠囊高 2.0（半高 1.0）：模型要正好從 y=-1.0 的腳底站到 y=+1.0 的頭頂，
		# 原本的版本重心算錯，人整個陷進甲板裡只露出頭盔。
		var team_col: Color = MainGame.C_ATK if team == MainGame.TEAM_ATTACKER else MainGame.C_DEF
		var suit: StandardMaterial3D = w.make_material(Color(0.16, 0.17, 0.21))   # 深色飛行衣
		var vest: StandardMaterial3D = w.make_material(team_col, 1.6)             # 隊色救生背心
		var helmet: StandardMaterial3D = w.make_material(Color(0.80, 0.82, 0.86)) # 白色頭盔
		var visor: StandardMaterial3D = w.make_material(Color(0.10, 0.35, 0.45), 2.2)
		var boot: StandardMaterial3D = w.make_material(Color(0.08, 0.08, 0.10))

		# 腿（-1.00 → -0.28）
		w.make_box(body, Vector3(0.19, 0.62, 0.20), Vector3(-0.13, -0.60, 0), suit)
		w.make_box(body, Vector3(0.19, 0.62, 0.20), Vector3(0.13, -0.60, 0), suit)
		w.make_box(body, Vector3(0.22, 0.12, 0.30), Vector3(-0.13, -0.95, -0.04), boot)
		w.make_box(body, Vector3(0.22, 0.12, 0.30), Vector3(0.13, -0.95, -0.04), boot)
		# 軀幹與救生背心（-0.28 → 0.36）
		w.make_box(body, Vector3(0.46, 0.66, 0.28), Vector3(0, 0.04, 0), suit)
		w.make_box(body, Vector3(0.50, 0.40, 0.33), Vector3(0, 0.08, 0), vest)
		w.make_box(body, Vector3(0.52, 0.06, 0.35), Vector3(0, -0.14, 0), boot)   # 腰帶
		# 手臂（自然垂在身側）
		w.make_box(body, Vector3(0.15, 0.58, 0.17), Vector3(-0.31, 0.00, 0.02), suit)
		w.make_box(body, Vector3(0.15, 0.58, 0.17), Vector3(0.31, 0.00, 0.02), suit)
		# 頸與頭盔（0.36 → 1.00）
		w.make_cyl(body, 0.09, 0.10, 0.10, Vector3(0, 0.41, 0), suit)
		w.make_sphere(body, 0.25, Vector3(0, 0.70, 0), helmet)
		w.make_box(body, Vector3(0.34, 0.15, 0.10), Vector3(0, 0.70, -0.20), visor)  # 面罩
		w.make_box(body, Vector3(0.30, 0.05, 0.06), Vector3(0, 0.86, -0.14), vest)   # 盔頂條紋
		w.make_cyl(body, 0.05, 0.05, 0.16, Vector3(0.16, 0.62, -0.16), boot)         # 氧氣管

		if not is_local:
			var tag := Label3D.new()
			tag.text = String(MainGame.instance.players[pilot_id]["name"]) \
				if MainGame.instance.players.has(pilot_id) else "?"
			tag.font_size = 32
			tag.pixel_size = 0.012
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.no_depth_test = true
			tag.modulate = MainGame.C_ATK if team == MainGame.TEAM_ATTACKER else MainGame.C_DEF
			tag.position = Vector3(0, 1.6, 0)
			add_child(tag)

	## fwd 前後、turn 左右轉身；甲板上會有重力把人壓在地面
	func walk(delta: float, fwd: float, _strafe: float, turn: float) -> void:
		rotate_y(-turn * 2.6 * delta)
		var dir := -global_transform.basis.z * fwd
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		velocity.y -= 26.0 * delta
		move_and_slide()
		if is_on_floor():
			velocity.y = 0.0
		# 保險：萬一腳下那塊地形忘了加碰撞體，也不能讓飛行員掉出世界。
		# 用地表高度直接把人夾在地面上。
		var floor_y: float = world.walk_floor(global_position)
		if global_position.y < floor_y + 1.0:
			global_position.y = floor_y + 1.0
			velocity.y = 0.0
		# 走路時身體微幅上下擺動
		if body:
			body.position.y = absf(sin(Time.get_ticks_msec() * 0.008)) * 0.09 * absf(fwd)


#══════════════════════════════════════════════════════════════════════════════
#  ── 內部類別：Projectile（飛彈 / 炸彈 / 防空砲）──────────────────────────────
#══════════════════════════════════════════════════════════════════════════════
class Projectile extends Area3D:
	var world: Node3D
	var team: int = 0
	var shooter: int = 0
	var damage: float = 20.0
	var struct_mult: float = 1.0
	var is_bomb: bool = false
	var guided: bool = true
	var vel := Vector3.ZERO
	var life: float = 6.0
	var turn: float = 2.0
	var kind: String = ""            # "sam" = 防空飛彈，用來限制同時在空中的數量
	var homing_target = null
	var decoyed: Array = []          # 已被干擾彈騙開的目標，不再重新鎖定
	var trail_acc: float = 0.0
	var exploded: bool = false


	func setup() -> void:
		collision_layer = 0
		collision_mask = 1 | 2      # 同時偵測地形/建築(1) 與飛機(2)
		monitoring = true

		var cs := CollisionShape3D.new()
		var sp := SphereShape3D.new()
		sp.radius = 1.4 if is_bomb else 0.9
		cs.shape = sp
		add_child(cs)

		var w: Node3D = world
		var col: Color = Color(1.0, 0.55, 0.15) if is_bomb else Color(0.5, 1.0, 1.0)
		if is_bomb:
			w.make_box(self, Vector3(1.0, 1.0, 3.0), Vector3.ZERO, w.make_material(Color(0.2, 0.2, 0.22)))
			w.make_prism(self, Vector3(1.2, 1.2, 1.0), Vector3(0, 0, 1.6), w.make_material(col, 3.0))
		else:
			var body: MeshInstance3D = w.make_cyl(self, 0.18, 0.18, 2.4, Vector3.ZERO, w.make_material(Color(0.8, 0.85, 0.9)))
			body.rotation_degrees.x = 90
			w.make_sphere(self, 0.55, Vector3(0, 0, 1.4), w.make_material(col, 7.0))

		var light := OmniLight3D.new()
		light.light_color = col
		light.light_energy = 2.5
		light.omni_range = 14.0
		add_child(light)

		body_entered.connect(_on_body_entered)
		_face_velocity()


	## look_at 在方向與 UP 平行時會報錯，這裡自動換參考軸
	func _face_velocity() -> void:
		var d := vel.normalized()
		if d.length_squared() < 0.5:
			return
		var up := Vector3.UP if absf(d.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
		look_at(global_position + d, up)


	func _physics_process(delta: float) -> void:
		if exploded:
			return
		life -= delta
		if life <= 0.0:
			_explode(false)
			return

		if is_bomb:
			vel.y -= 19.6 * delta            # 重力（加速下墜，投彈拋物線）
		elif guided:
			_guide(delta)

		global_position += vel * delta
		_face_velocity()
		_emit_trail(delta)

		if global_position.y <= 0.5:
			_explode(true)


	## 追蹤導引：預測攔截點（lead pursuit）而不是追著目標現在的位置跑，
	## 否則對橫向高速目標永遠只能追尾、幾乎打不中。
	func _guide(delta: float) -> void:
		# 發射後若沒有指定目標，仍會在前方錐形內自行尋標
		if homing_target == null or not is_instance_valid(homing_target) or not homing_target.alive:
			homing_target = world._find_lock_target_for_projectile(self)
			if homing_target == null:
				return

		# 干擾彈直接斷鎖，而且不會再重新鎖回同一架
		if homing_target.flare_active > 0.0:
			decoyed.append(homing_target.pilot_id)
			homing_target = null
			return

		var spd := vel.length()
		var to_t: Vector3 = homing_target.global_position - global_position
		var dist := to_t.length()

		# 近炸引信：高速目標可能在兩個物理影格之間穿過碰撞盒
		if dist < 9.0:
			world.request_damage(int(homing_target.pilot_id), damage, shooter)
			_explode(true)
			return

		var lead := clampf(dist / maxf(spd, 1.0), 0.0, 2.0)
		var predicted: Vector3 = homing_target.global_position + homing_target.velocity * lead
		var desired := (predicted - global_position).normalized()

		# 剛發射的 0.25 秒是助推段，轉向較鈍；之後全速修正
		var boost := clampf((6.0 - life) / 0.25, 0.35, 1.0) if life > 0.0 else 1.0
		vel = vel.normalized().slerp(desired, clampf(turn * boost * delta, 0.0, 1.0)) * spd


	func _emit_trail(delta: float) -> void:
		trail_acc -= delta
		if trail_acc > 0.0 or world == null:
			return
		trail_acc = 0.06
		var puff := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.7
		sm.height = 1.4
		sm.radial_segments = 5
		sm.rings = 3
		puff.mesh = sm
		puff.material_override = world._trail_mat
		world.add_child(puff)
		puff.global_position = global_position
		var tw := world.create_tween()
		tw.tween_property(puff, "scale", Vector3.ONE * 0.05, 0.45)
		tw.tween_callback(puff.queue_free)


	func _on_body_entered(body: Node3D) -> void:
		if exploded:
			return

		# 建築物
		if body.has_meta("struct_key"):
			var key := String(body.get_meta("struct_key"))
			var st: Dictionary = world.structures.get(key, {})
			if not st.is_empty() and int(st["team"]) != team and float(st["hp"]) > 0.0:
				world.request_damage(key, damage * struct_mult, shooter)
			_explode(true)
			return

		# 偵查機 UAV
		if body.name == "UAV":
			world.uav_take_damage(damage)
			_explode(true)
			return

		# 飛機（用 has_method 判斷，避免內部類別互相參照）
		if body.has_method("fly"):
			if int(body.pilot_id) == shooter or int(body.team) == team or not body.alive:
				return
			world.request_damage(int(body.pilot_id), damage, shooter)
			_explode(true)
			return

		# 地形
		_explode(true)


	func _explode(visual: bool) -> void:
		if exploded:
			return
		exploded = true
		set_physics_process(false)
		set_deferred("monitoring", false)
		if visual and world != null:
			world._spawn_flash(global_position, 8.0 if is_bomb else 4.0,
				Color(1.0, 0.6, 0.2) if is_bomb else Color(0.6, 1.0, 1.0))
		queue_free()
