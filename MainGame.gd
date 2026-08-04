extends Node
class_name MainGame
#══════════════════════════════════════════════════════════════════════════════
#  MainGame.gd ─ 大廳 UI / WebRTC 連線 / 房間管理 / 隊伍聊天 / Bot 自動補齊
#  Godot 4.2+ ／ 100% 純程式碼建構，場景檔內不含任何節點
#══════════════════════════════════════════════════════════════════════════════

# ─────────────────────────── 陣營與載具定義 ───────────────────────────
const TEAM_ATTACKER := 0
const TEAM_DEFENDER := 1

enum VType { FIGHTER, BOMBER, HELI, INTERCEPTOR }

const TEAM_NAME := {
	TEAM_ATTACKER: "進攻方 ATTACK",
	TEAM_DEFENDER: "防守方 DEFEND",
}
const VTYPE_NAME := {
	VType.FIGHTER:     "戰鬥機 Fighter",
	VType.BOMBER:      "轟炸機 Bomber",
	VType.HELI:        "武裝直升機 Helicopter",
	VType.INTERCEPTOR: "截擊機 Interceptor",
}
# 每個陣營可選的機種
const TEAM_VTYPES := {
	TEAM_ATTACKER: [VType.FIGHTER, VType.BOMBER, VType.HELI],
	TEAM_DEFENDER: [VType.INTERCEPTOR, VType.FIGHTER, VType.HELI],
}

# 載具數值表（GameWorld 也會讀這張表）
#   max_speed/min_speed : m/s      accel : m/s^2      pitch/yaw : rad/s
#
#   ── 機槍（Space，射線判定，無鎖定）──
#   gun_dmg    : 單發傷害      gun_rof   : 射擊間隔 (秒)
#   gun_ammo   : 備彈          gun_spread: 散布 (弧度)
#   gun_struct : 對建築傷害倍率
#
#   weapons    : 這個機種可以選配的副武裝清單（第一項為預設）
#
#   hover : 是否可懸停 (直升機)   radar : 雷達可見度 (1.0 正常, 0.35 低空匿蹤)
# ─────────────────────────── 副武裝（Space）───────────────────────────
#   機槍固定掛在滑鼠左鍵，副武裝則可自由選配。
#   guided : 是否追蹤   ballistic : 是否走拋物線（炸彈）
const WPN_HOMING  := 0
const WPN_MISSILE := 1
const WPN_CANNON  := 2
const WPN_BOMB    := 3
const WPN_ROCKET  := 4
const WEAPONS := {
	WPN_HOMING: {
		"name": "追蹤飛彈", "en": "HOMING", "desc": "自動追鎖目標，彈數少，會被干擾彈騙開",
		"dmg": 62.0, "rof": 1.40, "ammo": 6, "struct": 0.70,
		"guided": true, "ballistic": false, "speed": 140.0, "turn": 3.2, "life": 6.0,
	},
	WPN_MISSILE: {
		"name": "火箭彈", "en": "MISSILE", "desc": "無導引直飛，速度快傷害高，要自己算提前量",
		"dmg": 80.0, "rof": 0.70, "ammo": 14, "struct": 1.80,
		"guided": false, "ballistic": false, "speed": 240.0, "turn": 0.0, "life": 4.5,
	},
	WPN_CANNON: {
		"name": "重機砲", "en": "CANNON", "desc": "高初速砲彈，彈道平直、備彈多，近距離連射壓制",
		"dmg": 30.0, "rof": 0.25, "ammo": 52, "struct": 1.00,
		"guided": false, "ballistic": false, "speed": 400.0, "turn": 0.0, "life": 2.2,
	},
	WPN_BOMB: {
		"name": "炸彈", "en": "BOMB", "desc": "拋物線重彈，對地面設施 4 倍傷害",
		"dmg": 95.0, "rof": 0.90, "ammo": 14, "struct": 4.00,
		"guided": false, "ballistic": true, "speed": 0.0, "turn": 0.0, "life": 12.0,
	},
	WPN_ROCKET: {
		"name": "火箭巢", "en": "ROCKET", "desc": "輕型追蹤火箭，彈多轉向靈活但射程短",
		"dmg": 38.0, "rof": 0.45, "ammo": 18, "struct": 1.50,
		"guided": true, "ballistic": false, "speed": 170.0, "turn": 3.8, "life": 3.6,
	},
}

const VSTATS := {
	VType.FIGHTER: {
		"hp": 110.0, "max_speed": 95.0, "min_speed": 32.0, "accel": 26.0,
		"pitch": 1.9, "yaw": 1.35, "roll": 2.8,
		"gun_dmg": 9.0, "gun_rof": 0.085, "gun_ammo": 340, "gun_spread": 0.0055, "gun_struct": 0.25,
		"weapons": [WPN_HOMING, WPN_MISSILE, WPN_CANNON],
		"hover": false, "radar": 1.0, "color": Color(0.30, 0.90, 1.00),
	},
	VType.BOMBER: {
		"hp": 210.0, "max_speed": 58.0, "min_speed": 24.0, "accel": 12.0,
		"pitch": 0.95, "yaw": 0.70, "roll": 1.2,
		"gun_dmg": 7.0, "gun_rof": 0.130, "gun_ammo": 260, "gun_spread": 0.0090, "gun_struct": 0.20,
		"weapons": [WPN_BOMB, WPN_MISSILE, WPN_CANNON],
		"hover": false, "radar": 1.0, "color": Color(1.00, 0.62, 0.18),
	},
	VType.HELI: {
		"hp": 140.0, "max_speed": 38.0, "min_speed": 0.0, "accel": 16.0,
		"pitch": 1.5, "yaw": 1.9, "roll": 1.6,
		"gun_dmg": 8.0, "gun_rof": 0.075, "gun_ammo": 420, "gun_spread": 0.0065, "gun_struct": 0.30,
		"weapons": [WPN_ROCKET, WPN_HOMING, WPN_CANNON],
		"hover": true, "radar": 0.35, "color": Color(0.55, 1.00, 0.45),
	},
	VType.INTERCEPTOR: {
		"hp": 95.0, "max_speed": 108.0, "min_speed": 38.0, "accel": 32.0,
		"pitch": 2.0, "yaw": 1.45, "roll": 3.0,
		"gun_dmg": 10.0, "gun_rof": 0.080, "gun_ammo": 320, "gun_spread": 0.0050, "gun_struct": 0.20,
		"weapons": [WPN_HOMING, WPN_MISSILE, WPN_CANNON],
		"hover": false, "radar": 1.0, "color": Color(1.00, 0.35, 0.45),
	},
}

# ─────────────────────────── 規則常數 ───────────────────────────
const MIN_PER_TEAM        := 5      # 每隊人數（5v5），不足由 AI 補齊

# ─────────────────────────── 單人模式難度 ───────────────────────────
#   aim   : AI 開火所需的瞄準精度門檻（越高＝要對得越準才開火＝越弱）
#   range : AI 開火距離        dmg  : AI 傷害倍率
#   react : AI 重新判斷狀態的間隔（越小＝反應越快）
#   flare : AI 每幀丟干擾彈的機率
# ─────────────────────────── 商店 ───────────────────────────
## 點數靠擊墜與達成目標賺，購買後存進 user:// 跨局保留。
const SAVE_PATH := "user://profile.cfg"
const REWARD_KILL     := 60
const REWARD_STRUCTURE := 220
const REWARD_DROP     := 150
const REWARD_WIN      := 400

## 武器升級：每級加成會乘在該類武裝上
const UPGRADES := {
	"gun_dmg":  { "name": "機槍彈頭強化", "desc": "機槍傷害 +12% / 級", "max": 5, "cost": 320, "step": 0.12 },
	"gun_ammo": { "name": "擴充彈鏈",     "desc": "機槍備彈 +20% / 級", "max": 5, "cost": 240, "step": 0.20 },
	"msl_dmg":  { "name": "戰鬥部強化",   "desc": "副武裝傷害 +12% / 級", "max": 5, "cost": 420, "step": 0.12 },
	"msl_ammo": { "name": "增掛派龍",     "desc": "副武裝掛載 +1 / 級", "max": 4, "cost": 380, "step": 1.0 },
	"hp":       { "name": "複合裝甲",     "desc": "機體結構 +10% / 級", "max": 5, "cost": 360, "step": 0.10 },
	"lock":     { "name": "相位陣列雷達", "desc": "鎖定距離 +15% / 級", "max": 3, "cost": 300, "step": 0.15 },
}

## 塗裝：純外觀
const SKINS := {
	"default": { "name": "制式塗裝", "cost": 0,    "col": Color(0.13, 0.14, 0.18) },
	"desert":  { "name": "沙漠迷彩", "cost": 250,  "col": Color(0.42, 0.34, 0.19) },
	"arctic":  { "name": "極地白",   "cost": 250,  "col": Color(0.78, 0.82, 0.86) },
	"night":   { "name": "夜梟黑",   "cost": 400,  "col": Color(0.06, 0.06, 0.09) },
	"blood":   { "name": "血隼紅",   "cost": 550,  "col": Color(0.38, 0.07, 0.09) },
	"gold":    { "name": "王牌金",   "cost": 900,  "col": Color(0.62, 0.48, 0.10) },
}

## 機庫：可在商店購買／替換的機種。戰鬥機與截擊機開局就有，
## 這樣不管選哪個陣營都一定有能飛的機體。
const PLANES := {
	VType.FIGHTER: {
		"cost": 0, "tag": "制式主力",
		"desc": "均衡的多用途戰鬥機，追熱飛彈 + 高射速機槍，什麼場面都能打。",
	},
	VType.INTERCEPTOR: {
		"cost": 0, "tag": "制式主力",
		"desc": "最高速與加速度最強，機體脆弱；防守方攔截轟炸機的首選。",
	},
	VType.BOMBER: {
		"cost": 850, "tag": "重裝",
		"desc": "厚裝甲、慢，炸彈對地面設施 4 倍傷害 ─ 唯一能有效拆跑道與核設施的機種。",
	},
	VType.HELI: {
		"cost": 700, "tag": "特殊",
		"desc": "可懸停、低空匿蹤（雷達可見度 0.35），搶空投速度是別人的兩倍。",
	},
}

var credits: int = 0
var upgrades: Dictionary = {}     # key -> 等級
var skin: String = "default"
var owned_skins: Array = ["default"]
var owned_planes: Array = [VType.FIGHTER, VType.INTERCEPTOR]

## 帳號（Account.gd 的資料字典）；登入前是空的
var account: Dictionary = {}
var _accounts = null              # Account.gd 實例（動態載入）


func owns_plane(vt: int) -> bool:
	return owned_planes.has(int(vt))


func is_logged_in() -> bool:
	return not account.is_empty()


func upgrade_level(key: String) -> int:
	return int(upgrades.get(key, 0))


## 某項升級目前的加成倍率（或加值）
func upgrade_bonus(key: String) -> float:
	return float(UPGRADES[key]["step"]) * float(upgrade_level(key))


func skin_color() -> Color:
	return SKINS.get(skin, SKINS["default"])["col"]


func add_credits(n: int, reason: String) -> void:
	if n <= 0:
		return
	credits += n
	save_profile()
	_refresh_account_lbl()
	add_chat_line("[點數] +%d（%s）　目前 %d" % [n, reason, credits], Color(1.0, 0.85, 0.35))


## 把帳號資料套進執行期狀態（登入時呼叫）
func apply_account(data: Dictionary) -> void:
	account = data
	credits = int(data.get("credits", 0))
	upgrades = data.get("upgrades", {})
	skin = String(data.get("skin", "default"))
	owned_skins = data.get("owned_skins", ["default"])
	owned_planes = data.get("owned_planes", [VType.FIGHTER, VType.INTERCEPTOR])
	_local_name = String(data.get("name", _local_name))
	if _name_edit:
		_name_edit.text = _local_name
	if players.has(my_id()):
		players[my_id()]["name"] = _local_name
	# 舊版 user://profile.cfg 的進度只匯入一次，避免重複領點數
	_migrate_legacy_profile()
	save_profile()


## 存檔一律寫回目前登入的帳號
func save_profile() -> void:
	if _accounts == null or account.is_empty():
		return
	account["credits"] = credits
	account["upgrades"] = upgrades
	account["skin"] = skin
	account["owned_skins"] = owned_skins
	account["owned_planes"] = owned_planes
	account["name"] = _local_name
	_accounts.save_profile(account)


## 舊版單一存檔（改成帳號制之前的 profile.cfg）
func _migrate_legacy_profile() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) != OK:
		return
	if bool(cf.get_value("p", "migrated", false)):
		return
	credits += int(cf.get_value("p", "credits", 0))
	var old_up: Dictionary = cf.get_value("p", "upgrades", {})
	for k in old_up.keys():
		if int(old_up[k]) > upgrade_level(String(k)):
			upgrades[k] = int(old_up[k])
	for s in cf.get_value("p", "owned_skins", []):
		if not owned_skins.has(s):
			owned_skins.append(s)
	cf.set_value("p", "migrated", true)
	cf.save(SAVE_PATH)
	add_chat_line("[帳號] 已把舊版存檔的點數與塗裝匯入本帳號。", C_DIM)


# ─────────────────────────── 地圖 ───────────────────────────
const MAP_RANDOM  := -1
const MAP_CANYON  := 0
const MAP_PLAINS  := 1
const MAP_PLATEAU := 2
const MAP_RANGE   := 3
const MAP_ALPINE  := 4
const MAP_HILLS   := 5
const MAP_TETON   := 6
const MAP_CITY    := 7
const MAP_INFO := {
	MAP_CANYON:  { "name": "峽谷",     "en": "CANYON",     "desc": "深谷航道，兩側高壁夾出狹窄通道" },
	MAP_PLAINS:  { "name": "平原",     "en": "PLAINS",     "desc": "開闊低地與大片林帶，適合纏鬥" },
	MAP_PLATEAU: { "name": "高原",     "en": "PLATEAU",    "desc": "巨大台地被深切峽溝切開" },
	MAP_RANGE:   { "name": "橫斷山脈", "en": "TRANSVERSE", "desc": "橫向山嶺層層阻隔，必須找隘口穿越" },
	MAP_ALPINE:  { "name": "高山",     "en": "ALPINE",     "desc": "高聳雪峰，飛行空間極度壓縮" },
	MAP_HILLS:   { "name": "黃土丘陵", "en": "LOESS",      "desc": "連綿圓潤土丘與沖蝕溝壑，遠方高山為背景" },
	MAP_TETON:   { "name": "大堤頓峽谷", "en": "GRAND TETON",
		"desc": "高聳鋸齒巨峰與階狀大峽谷，谷底可低空穿線躲避飛彈鎖定" },
	MAP_CITY:    { "name": "濱海都會", "en": "METROPOLIS",
		"desc": "高樓林立的都市戰場，可在摩天樓之間穿梭並用建築擋掉鎖定" },
}

# ─────────────────────────── 天氣 ───────────────────────────
const WX_RANDOM    := -1
const WX_CLEAR     := 0
const WX_SANDSTORM := 1
const WX_HAIL      := 2
const WX_THUNDER   := 3
const WX_INFO := {
	WX_CLEAR:     { "name": "晴朗",   "en": "CLEAR",     "desc": "能見度良好" },
	WX_SANDSTORM: { "name": "沙塵暴", "en": "SANDSTORM", "desc": "橙黃濃塵遮蔽視線，飛彈鎖定距離大幅縮短" },
	WX_HAIL:      { "name": "冰雹",   "en": "HAIL",      "desc": "高速冰粒與灰霧，機體持續受損" },
	WX_THUNDER:   { "name": "雷暴",   "en": "THUNDER",   "desc": "暴雨與陣風亂流，不時有閃電與雷聲" },
}

# ─────────────────────────── 時間（日夜） ───────────────────────────
const TOD_DAY   := 0
const TOD_DUSK  := 1
const TOD_NIGHT := 2
const TOD_CYCLE := 3
const TOD_NAME := {
	TOD_DAY:   { "name": "白天", "en": "DAY" },
	TOD_DUSK:  { "name": "黃昏", "en": "DUSK" },
	TOD_NIGHT: { "name": "夜晚", "en": "NIGHT" },
	TOD_CYCLE: { "name": "日夜循環", "en": "CYCLE" },
}

const DIFF_EASY   := 0
const DIFF_NORMAL := 1
const DIFF_HARD   := 2
## 2026-08 調弱：原本普通難度的 AI 打得比人還準，玩家一出航艦就被咬死。
## 現在門檻更嚴（要對得更準才開火）、射程更短、傷害更低、反應更慢。
const DIFF := {
	DIFF_EASY:   { "name": "簡單", "en": "ROOKIE",  "aim": 0.996, "range": 130.0, "dmg": 0.30, "react": 3.6, "flare": 0.000 },
	DIFF_NORMAL: { "name": "普通", "en": "VETERAN", "aim": 0.980, "range": 180.0, "dmg": 0.55, "react": 2.4, "flare": 0.001 },
	DIFF_HARD:   { "name": "困難", "en": "ACE",     "aim": 0.945, "range": 250.0, "dmg": 0.90, "react": 1.2, "flare": 0.005 },
}
## AI 開火前的「發現目標」延遲：剛咬上來的那一秒不會馬上開槍，
## 玩家才有反應時間。沒有這個延遲，光靠數值調弱還是會覺得被瞬間點名。
const AI_SPOT_DELAY := 1.3
## 同一個目標最多同時被幾架 AI 咬 ─ 沒有這個上限，三架敵機開場就全部撲向玩家。
const AI_MAX_GANG := 2
const RUNWAY_LOCK_TIME    := 60.0   # 跑道被炸後，防守方禁止復活的秒數
const AIRDROP_TIME        := 180.0  # 第 3 分鐘生成空投
const MATCH_TIME          := 600.0  # 單局 10 分鐘

# 陣營顏色（UI 與載具塗裝共用）
const C_ATK  := Color(1.00, 0.48, 0.16)
const C_DEF  := Color(0.24, 0.80, 1.00)
const C_BG   := Color(0.035, 0.045, 0.070)
const C_PANE := Color(0.075, 0.095, 0.135, 0.94)
const C_TEXT := Color(0.86, 0.93, 1.00)
const C_DIM  := Color(0.52, 0.60, 0.72)

# 聊天頻道
const SCOPE_TEAM := 0
const SCOPE_ALL  := 1

# 快捷無線電
const RADIO_LINES := [
	"請求支援！敵機在我尾巴上！",
	"總攻跑道 / 核設施！",
	"前往爭奪空中包！",
	"剛才是誰在開飛機撞山的？",
]
const RADIO_SCOPE := [SCOPE_TEAM, SCOPE_TEAM, SCOPE_TEAM, SCOPE_ALL]

# ─────────────────────────── 網路設定 ───────────────────────────
enum NetMode { ENET, WEBRTC }
enum Screen { MENU, SOLO, ROOM, SHOP, LOGIN, TUTORIAL }

## 信令伺服器的預設位址（可用附帶的 signaling_server.js 架設）。
## 部署到 GitHub Pages 之後不需要為了換伺服器重新匯出 ─ 見 signaling_url()。
const SIGNALING_URL := "ws://127.0.0.1:9080"
const ICE_CONFIG := {
	"iceServers": [
		{ "urls": ["stun:stun.l.google.com:19302"] },
	]
}
const ENET_BASE_PORT := 10000   # ENet 測試模式：埠號 = 10000 + 房號

# ─────────────────────────── 執行期狀態 ───────────────────────────
static var instance: MainGame

## peer_id -> { name, team, vtype, bot, score }
var players: Dictionary = {}
var is_host: bool = false
var room_code: String = ""
var net_mode: int = NetMode.ENET
var in_match: bool = false
var solo_mode: bool = false           # 單人打電腦，完全不建立任何網路連線
var difficulty: int = DIFF_NORMAL
var time_of_day: int = TOD_DAY
var map_choice: int = MAP_RANDOM   # 一律隨機：玩家不可選（刻意設計）
var map_id: int = MAP_CANYON       # 本局實際使用的地圖
var map_seed: int = 20260726       # 地形亂數種子，同步給所有客戶端
var weather_choice: int = WX_RANDOM # 一律隨機：玩家不可選（刻意設計）
var weather: int = WX_CLEAR        # 本局實際天氣
var world: Node3D = null

var _next_bot_id: int = 0
var _local_name: String = ""
var _actions: Array = []          # 本遊戲註冊過的所有 InputMap 動作
var tutorial_mode: bool = false   # 練習場：世界會顯示逐步提示
var bots_per_team: int = MIN_PER_TEAM   # 練習場會調成 1

# WebRTC / 信令
var _ws: WebSocketPeer = null
var _ws_open: bool = false
var _pending_sig: Dictionary = {}
var _rtc: WebRTCMultiplayerPeer = null
var _conns: Dictionary = {}      # peer_id -> WebRTCPeerConnection

# UI 節點參考
var _ui: CanvasLayer
var _lobby: Control
var _status_lbl: Label
var _room_lbl: Label
var _code_edit: LineEdit
var _name_edit: LineEdit
var _host_btn: Button
var _join_btn: Button
var _start_btn: Button
var _mode_check: Button
var _screens: Dictionary = {}    # Screen -> Control
var _cur_screen: int = Screen.MENU
var _team_btn_list: Array = []   # [{ team, btn }]  同一組選擇器會出現在多個畫面
var _vtype_boxes: Array = []     # [HBoxContainer]
var _weapon_boxes: Array = []    # [HBoxContainer]
var _shop_credits: Label
var _shop_upgrades: VBoxContainer
var _shop_skins: GridContainer
var _diff_btns: Array = []       # [{ diff, btn }]
var _tod_btns: Array = []        # [{ tod, btn }]
var _help_overlay: Control
var _top_info: Label
var _roster: Dictionary = {}     # team -> VBoxContainer
var _chat_panel: PanelContainer
var _chat_log: RichTextLabel
var _chat_input: LineEdit
var _chat_scope_lbl: Label
var _chat_scope: int = SCOPE_TEAM

# ── 房間密碼（房主設定，加入者要輸入相同密碼）──
var room_pass: String = ""
var _pass_edit: LineEdit

# ── 新增的 UI 模組 ──
var _join_dlg = null              # TacticalDialog.gd 實例
var _hangar = null                # Hangar3D.gd 實例（主選單 3D 背景）
var _shop_stand = null            # Hangar3D.gd 實例（商店 SubViewport 預覽）
var _shop_vp: SubViewport
var _shop_plane_row: HBoxContainer
var _shop_info: Label
var _shop_wpn_row: HBoxContainer
var _login_name: LineEdit
var _login_pin: LineEdit
var _login_msg: Label
var _login_list: VBoxContainer
var _account_lbl: Label


#══════════════════════════════════════════════════════════════════════════════
#  生命週期
#══════════════════════════════════════════════════════════════════════════════
func _ready() -> void:
	instance = self
	_local_name = "PILOT-%03d" % (randi() % 1000)
	net_mode = NetMode.WEBRTC if OS.has_feature("web") else NetMode.ENET

	# 先放一筆本機玩家資料，主選單才能在未連線時就選陣營與機種
	players[1] = _new_player_entry(_local_name, TEAM_ATTACKER, VType.FIGHTER, false)

	_accounts = load("res://Account.gd").new()
	_register_input_actions()
	_build_ui()
	# 一定要先登入（訪客或帳號）才進得了主選單
	_show_screen(Screen.LOGIN)

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	add_chat_line("[系統] 歡迎來到 ASYMMETRIC AIR COMBAT。", C_DIM)
	add_chat_line("[系統] 建立或加入房間後選擇陣營，由房主開始遊戲。", C_DIM)

	# 測試用掛載：只有設了對應的環境變數才會執行，正式遊玩兩者都不會碰到
	if OS.get_environment("NETSMOKE").strip_edges() != "":
		add_child(load("res://NetSmoke.gd").new())      # 連線煙霧測試
	if OS.get_environment("AUTOPLAY").strip_edges() != "":
		add_child(load("res://AutoPlay.gd").new())      # 自動打一局單人作戰


func _process(_delta: float) -> void:
	_poll_signaling()


## 全部輸入動作以程式碼註冊，不使用專案設定的 InputMap
func _register_input_actions() -> void:
	## 轉向全部用鍵盤：W/S 俯仰、A/D 偏航（方向舵）、Z/C 滾轉、R/F 油門
	## 滑鼠只用來開火（右鍵機炮、左鍵鎖定發射），游標維持可見、不做捕捉
	var map := {
		"ac_pitch_up":   [KEY_W],
		"ac_pitch_down": [KEY_S],
		"ac_yaw_left":   [KEY_A],
		"ac_yaw_right":  [KEY_D],
		"ac_roll_left":  [KEY_Z],
		"ac_roll_right": [KEY_C],
		"ac_thr_up":     [KEY_R],
		"ac_thr_down":   [KEY_F],
		"ac_boost":      [KEY_SPACE],
		"ac_flare":      [KEY_SHIFT],
		"ac_hover":      [KEY_CTRL],
		"ac_deploy":     [KEY_G],
		"ac_board":      [KEY_E],
		"ac_view":       [KEY_V],
		"ac_swap_weapon":[KEY_Q],
		"ac_chat":       [KEY_T],
		# 1/2/3 改成空中即時切換副武裝；無線電讓位到 F1~F4
		"ac_wpn_1":      [KEY_1],
		"ac_wpn_2":      [KEY_2],
		"ac_wpn_3":      [KEY_3],
		"ac_radio_1":    [KEY_F1],
		"ac_radio_2":    [KEY_F2],
		"ac_radio_3":    [KEY_F3],
		"ac_radio_4":    [KEY_F4],
		"ac_ui_skip":    [KEY_ESCAPE],
	}
	_actions.clear()
	for action in map.keys():
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		InputMap.add_action(action)
		_actions.append(action)
		for key in map[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)

	# ── 武器：滑鼠右鍵＝機炮／機槍，滑鼠左鍵＝鎖定並發射飛彈 ──
	_bind_mouse_action("ac_gun", MOUSE_BUTTON_RIGHT, KEY_X)
	_bind_mouse_action("ac_missile", MOUSE_BUTTON_LEFT, KEY_B)
	# ── 簡報／對話推進：Enter、Space 或滑鼠左鍵 ──
	_bind_mouse_action("ac_ui_next", MOUSE_BUTTON_LEFT, KEY_ENTER)
	var extra := InputEventKey.new()
	extra.physical_keycode = KEY_SPACE
	InputMap.action_add_event("ac_ui_next", extra)


## 建一個「滑鼠按鍵 + 鍵盤備援鍵」的動作
func _bind_mouse_action(action: String, button: int, fallback_key: int) -> void:
	if InputMap.has_action(action):
		InputMap.erase_action(action)
	InputMap.add_action(action)
	if not _actions.has(action):
		_actions.append(action)
	var mb := InputEventMouseButton.new()
	mb.button_index = button
	InputMap.action_add_event(action, mb)
	var alt := InputEventKey.new()
	alt.physical_keycode = fallback_key
	InputMap.action_add_event(action, alt)


#══════════════════════════════════════════════════════════════════════════════
#  UI 建構（全部程式碼生成）
#══════════════════════════════════════════════════════════════════════════════
func _build_ui() -> void:
	_build_hangar()          # 3D 停機棚：主選單的實景背景，UI 疊在上面
	_ui = CanvasLayer.new()
	_ui.name = "UILayer"
	_ui.layer = 10
	add_child(_ui)
	_build_lobby()
	_build_chat()
	_build_join_dialog()


#══════════════════════════════════════════════════════════════════════════════
#  3D 停機棚（主選單背景）
#══════════════════════════════════════════════════════════════════════════════
## 主畫面不是平面色底，而是一座真的停機棚，中央轉盤上放玩家目前選用的戰機。
## 開賽前會整個釋放掉（它自帶 WorldEnvironment，留著會跟戰場的環境打架）。
func _build_hangar() -> void:
	if _hangar != null:
		return
	_hangar = load("res://Hangar3D.gd").new()
	_hangar.name = "MenuHangar"
	add_child(_hangar)
	_hangar.build("hangar")
	refresh_hangar_plane()


func _free_hangar() -> void:
	if _hangar != null:
		_hangar.queue_free()
		_hangar = null


## 換機種／換塗裝後，讓停機棚與商店預覽都跟著換
func refresh_hangar_plane() -> void:
	var vt := VType.FIGHTER
	if players.has(my_id()):
		vt = int(players[my_id()]["vtype"])
	var team_col: Color = C_ATK if my_team() == TEAM_ATTACKER else C_DEF
	if _hangar != null:
		_hangar.set_aircraft(vt, skin_color(), team_col,
			"%s　│　%s" % [VTYPE_NAME[vt], SKINS.get(skin, SKINS["default"])["name"]])
	# 商店展示台跟著「預覽中」的機種，不一定等於身上裝備的那台
	if _shop_stand != null:
		var pv := _shop_preview_vt if PLANES.has(_shop_preview_vt) else vt
		_shop_stand.set_aircraft(pv, skin_color(), team_col, String(VTYPE_NAME[pv]))


#══════════════════════════════════════════════════════════════════════════════
#  加入房間：戰術彈出視窗
#══════════════════════════════════════════════════════════════════════════════
func _build_join_dialog() -> void:
	_join_dlg = load("res://TacticalDialog.gd").new()
	_ui.add_child(_join_dlg)
	_join_dlg.build(self)
	_join_dlg.confirmed.connect(func(code: String, pw: String):
		join_game(code, pw))


func open_join_dialog() -> void:
	if _join_dlg != null:
		_join_dlg.open(_code_edit.text if _code_edit else "")


## 給 TacticalDialog 用的傳輸層切換
func toggle_net_mode() -> void:
	net_mode = NetMode.ENET if net_mode == NetMode.WEBRTC else NetMode.WEBRTC
	_refresh_mode_btn()
	_set_status("網路模式：%s" % ("WebRTC（網頁）" if net_mode == NetMode.WEBRTC else "ENet（本機測試）"))


## 主選單排版參考《貓咪大戰爭》：
##   頂部玩家資訊列 → 大標題橫幅 → 中央直式大按鈕堆疊 → 底部小圖示列
func _build_lobby() -> void:
	_lobby = Control.new()
	_lobby.name = "Lobby"
	_lobby.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lobby.mouse_filter = Control.MOUSE_FILTER_PASS
	_ui.add_child(_lobby)

	# 半透明底：讓後面的 3D 停機棚透出來，同時壓暗到文字仍然清楚
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(C_BG.r, C_BG.g, C_BG.b, 0.62)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lobby.add_child(bg)

	# 背景裝飾：斜向掃描帶，讓純色底不會太空
	for i in 7:
		var stripe := ColorRect.new()
		stripe.color = Color(C_DEF.r, C_DEF.g, C_DEF.b, 0.030 if i % 2 == 0 else 0.015)
		stripe.set_anchors_preset(Control.PRESET_FULL_RECT)
		stripe.offset_top = float(i) * 130.0 - 200.0
		stripe.offset_bottom = stripe.offset_top + 64.0
		stripe.rotation = -0.12
		stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_lobby.add_child(stripe)

	_build_top_bar()

	var stage := Control.new()
	stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	stage.offset_top = 72
	stage.offset_bottom = -84
	stage.mouse_filter = Control.MOUSE_FILTER_PASS
	_lobby.add_child(stage)

	_screens[Screen.MENU] = _build_screen_menu(stage)
	_screens[Screen.SOLO] = _build_screen_solo(stage)
	_screens[Screen.ROOM] = _build_screen_room(stage)
	_screens[Screen.SHOP] = _build_screen_shop(stage)
	_screens[Screen.LOGIN] = _build_screen_login(stage)
	_screens[Screen.TUTORIAL] = _build_screen_tutorial(stage)

	_build_bottom_bar()
	_build_help_overlay()

	_show_screen(Screen.MENU)
	_refresh_vtype_buttons()
	_refresh_roster()
	_refresh_difficulty()
	_refresh_tod()
	_refresh_shop()


# ─────────────────────── 頂部玩家資訊列 ───────────────────────
func _build_top_bar() -> void:
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left = 16; bar.offset_right = -16
	bar.offset_top = 12; bar.offset_bottom = 62
	bar.add_theme_stylebox_override("panel", _mk_stylebox(C_PANE, Color(1, 1, 1, 0.10)))
	_lobby.add_child(bar)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 12)
	bar.add_child(hb)

	var tag := _mk_label("✈", 22, C_DEF)
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hb.add_child(tag)

	hb.add_child(_mk_vcenter(_mk_label("呼號", 12, C_DIM)))
	_name_edit = LineEdit.new()
	_name_edit.text = _local_name
	_name_edit.max_length = 14
	_name_edit.custom_minimum_size = Vector2(170, 0)
	_name_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_name_edit.text_changed.connect(func(t: String):
		_local_name = t.strip_edges()
		if players.has(my_id()):
			players[my_id()]["name"] = _local_name
			_refresh_roster())
	hb.add_child(_name_edit)

	_account_lbl = _mk_label("", 12, Color(1.0, 0.85, 0.35))
	hb.add_child(_mk_vcenter(_account_lbl))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(spacer)

	_top_info = _mk_label("", 13, C_DIM)
	hb.add_child(_mk_vcenter(_top_info))

	var logout := _mk_button("登出", C_DIM)
	logout.custom_minimum_size = Vector2(70, 30)
	logout.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	logout.pressed.connect(_logout)
	hb.add_child(logout)


func _refresh_account_lbl() -> void:
	if _account_lbl == null:
		return
	if account.is_empty():
		_account_lbl.text = ""
		return
	var kind := "訪客" if bool(account.get("guest", false)) else "帳號"
	_account_lbl.text = "［%s］　點數 %d　戰績 %d 勝 / %d 場" % [
		kind, credits, int(account.get("wins", 0)), int(account.get("matches", 0))]


func _mk_vcenter(c: Control) -> Control:
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return c


# ─────────────────────── 畫面零：登入 ───────────────────────
## 兩種登入方式：
##   訪客 ─ 不需密碼，進度只留在本機
##   帳號 ─ 自訂呼號 + 4 位數 PIN，點數／升級／塗裝跟著帳號走
func _build_screen_login(parent: Control) -> Control:
	var scr := _mk_screen(parent)

	# 登入表單放在不透明的面板上：後面是 3D 停機棚，
	# 沒有底板的話棚裡的燈光與結構會把欄位文字吃掉。
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -350; panel.offset_right = 350
	panel.offset_top = -290; panel.offset_bottom = 300
	panel.add_theme_stylebox_override("panel",
		_mk_stylebox(Color(0.035, 0.050, 0.078, 0.985), C_DEF))
	scr.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	panel.add_child(col)

	col.add_child(_mk_screen_title("飛 行 員 登 入", "PILOT LOGIN ─ 選擇訪客或使用帳號"))

	var guest := _mk_big_button("👤", "訪客登入", "不需密碼，進度只留在這台機器", C_DIM)
	guest.pressed.connect(func():
		var r: Dictionary = _accounts.guest_login()
		_finish_login(r))
	col.add_child(guest)

	col.add_child(_mk_section("帳號登入 / 註冊　ACCOUNT"))

	var form := HBoxContainer.new()
	form.add_theme_constant_override("separation", 8)
	col.add_child(form)

	var nv := VBoxContainer.new()
	nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_child(nv)
	nv.add_child(_mk_label("呼號 CALLSIGN（2~14 字）", 12, C_DIM))
	_login_name = LineEdit.new()
	_login_name.max_length = 14
	_login_name.placeholder_text = "例如 VIPER"
	_login_name.custom_minimum_size = Vector2(0, 40)
	nv.add_child(_login_name)

	var pv := VBoxContainer.new()
	pv.custom_minimum_size = Vector2(180, 0)
	form.add_child(pv)
	pv.add_child(_mk_label("PIN 碼（4 位數字）", 12, C_DIM))
	_login_pin = LineEdit.new()
	_login_pin.max_length = 4
	_login_pin.secret = true
	_login_pin.placeholder_text = "••••"
	_login_pin.custom_minimum_size = Vector2(0, 40)
	_login_pin.text_submitted.connect(func(_t: String): _try_login())
	pv.add_child(_login_pin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)
	var login_btn := _mk_button("▶  登入  LOGIN", Color(0.40, 1.00, 0.60))
	login_btn.custom_minimum_size = Vector2(0, 48)
	login_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	login_btn.pressed.connect(_try_login)
	row.add_child(login_btn)
	var reg_btn := _mk_button("＋  註冊新帳號  REGISTER", C_DEF)
	reg_btn.custom_minimum_size = Vector2(0, 48)
	reg_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reg_btn.pressed.connect(_try_register)
	row.add_child(reg_btn)

	_login_msg = _mk_label("", 13, Color(1.0, 0.85, 0.35))
	_login_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_login_msg.custom_minimum_size = Vector2(0, 40)
	col.add_child(_login_msg)

	col.add_child(_mk_sep())
	col.add_child(_mk_label("本機已有的帳號（點一下填入呼號）", 12, C_DIM))
	_login_list = VBoxContainer.new()
	_login_list.add_theme_constant_override("separation", 4)
	col.add_child(_login_list)
	return scr


func _refresh_login_list() -> void:
	if _login_list == null:
		return
	for c in _login_list.get_children():
		c.queue_free()
	var names: Array = _accounts.account_names() if _accounts != null else []
	if names.is_empty():
		_login_list.add_child(_mk_label("　（還沒有任何帳號 ─ 填好呼號與 PIN 後按「註冊新帳號」）", 12, C_DIM))
		return
	for n in names:
		var b := _mk_button("　%s" % n, C_TEXT)
		b.pressed.connect(func():
			_login_name.text = String(n)
			_login_pin.grab_focus())
		_login_list.add_child(b)


func _try_login() -> void:
	var r: Dictionary = _accounts.login(_login_name.text, _login_pin.text)
	_finish_login(r)


func _try_register() -> void:
	var r: Dictionary = _accounts.register(_login_name.text, _login_pin.text)
	_finish_login(r)


func _finish_login(r: Dictionary) -> void:
	if not bool(r["ok"]):
		_login_msg.add_theme_color_override("font_color", Color(1.0, 0.45, 0.40))
		_login_msg.text = "✕  " + String(r["msg"])
		return
	_login_msg.add_theme_color_override("font_color", Color(0.45, 1.0, 0.6))
	_login_msg.text = "✓  " + String(r["msg"])
	apply_account(r["data"])
	_login_pin.text = ""
	_refresh_account_lbl()
	_refresh_roster()
	_refresh_vtype_buttons()
	_refresh_shop()
	refresh_hangar_plane()
	_name_edit.editable = bool(account.get("guest", false))
	add_chat_line("[帳號] %s ─ %s" % [_local_name, r["msg"]], C_DIM)
	_show_screen(Screen.MENU)


func _logout() -> void:
	if in_match:
		return
	save_profile()
	account = {}
	credits = 0
	upgrades = {}
	skin = "default"
	owned_skins = ["default"]
	owned_planes = [VType.FIGHTER, VType.INTERCEPTOR]
	_refresh_account_lbl()
	_refresh_shop()
	if _login_msg:
		_login_msg.text = ""
	_show_screen(Screen.LOGIN)


# ─────────────────────── 畫面一：主選單 ───────────────────────
func _build_screen_menu(parent: Control) -> Control:
	var scr := _mk_screen(parent)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_CENTER)
	col.offset_left = -300; col.offset_right = 300
	col.offset_top = -250; col.offset_bottom = 250
	col.add_theme_constant_override("separation", 14)
	scr.add_child(col)

	# ── 大標題橫幅 ──
	var banner := PanelContainer.new()
	banner.custom_minimum_size = Vector2(0, 132)
	var bsb := _mk_stylebox(Color(C_DEF.r, C_DEF.g, C_DEF.b, 0.10), C_DEF)
	bsb.border_width_left = 3; bsb.border_width_right = 3
	bsb.border_width_top = 3; bsb.border_width_bottom = 3
	bsb.corner_radius_top_left = 10; bsb.corner_radius_top_right = 10
	bsb.corner_radius_bottom_left = 10; bsb.corner_radius_bottom_right = 10
	banner.add_theme_stylebox_override("panel", bsb)
	col.add_child(banner)

	var bv := VBoxContainer.new()
	bv.alignment = BoxContainer.ALIGNMENT_CENTER
	bv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.add_child(bv)
	var t1 := _mk_label("ASYMMETRIC", 40, Color.WHITE)
	t1.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t1.add_theme_color_override("font_outline_color", C_DEF)
	t1.add_theme_constant_override("outline_size", 8)
	bv.add_child(t1)
	var t2 := _mk_label("A I R   C O M B A T", 22, C_DEF)
	t2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bv.add_child(t2)
	var t3 := _mk_label("非 對 稱 空 中 戰 鬥", 13, C_DIM)
	t3.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bv.add_child(t3)

	col.add_child(_mk_spacer(10))

	# ── 中央直式大按鈕堆疊 ──
	var solo := _mk_big_button("🎯", "單人作戰", "與電腦對戰，不需要其他玩家", Color(0.40, 1.00, 0.60))
	solo.pressed.connect(func(): _show_screen(Screen.SOLO))
	col.add_child(solo)

	var host := _mk_big_button("🛩", "建立房間", "開一局連線對戰，取得 4 位數房號", C_ATK)
	host.pressed.connect(func():
		_show_screen(Screen.ROOM)
		host_game())
	col.add_child(host)

	var shop := _mk_big_button("🛒", "補給商店", "用作戰點數升級武器與購買塗裝", Color(1.0, 0.82, 0.35))
	shop.pressed.connect(func(): _show_screen(Screen.SHOP))
	col.add_child(shop)

	var join := _mk_big_button("🔗", "加入房間", "開啟戰術連線視窗（房號／IP＋密碼）", C_DEF)
	join.pressed.connect(open_join_dialog)
	col.add_child(join)

	var tut := _mk_big_button("🎓", "新手教學", "四頁圖解 + 一場有步驟提示的練習", Color(0.55, 0.90, 1.00))
	tut.pressed.connect(func(): _show_screen(Screen.TUTORIAL))
	col.add_child(tut)

	return scr


# ─────────────────────── 畫面五：新手教學 ───────────────────────
const TUTORIAL_PAGES := [
	{
		"title": "1／4　飛起來",
		"body": "起飛：走到停機坪的飛機旁按 [E] 登機，按住 [R] 把油門推到底，機頭自然會離地。\n\n"
			+ "[W] / [S]　拉升 / 俯衝\n"
			+ "[A] / [D]　左右轉向（方向舵）\n"
			+ "[Z] / [C]　左右滾轉（機體真的會翻，HUD 上緣有滾轉刻度）\n"
			+ "[R] / [F]　油門增 / 減\n"
			+ "[SPACE]　後燃器加速 ─ 有燃料條，放開會自動回充\n\n"
			+ "速度太慢舵面會變鈍，撞山與墜海都是直接陣亡。",
	},
	{
		"title": "2／4　打中東西",
		"body": "[滑鼠右鍵]　機炮：射線判定，即時命中，射速快但傷害低，對建築幾乎無效。\n"
			+ "[滑鼠左鍵]　飛彈：把敵機留在準星錐形內 0.75 秒完成鎖定（準星外圈的環會轉滿），"
			+ "鎖定後發射才會追蹤。\n\n"
			+ "[1] / [2] / [3]　空中切換副武裝，每一種都有自己的備彈，切來切去不會互相偷彈。\n"
			+ "[SHIFT]　干擾彈：3.5 秒內不會被鎖定，被咬住時的保命鍵。\n\n"
			+ "拆建築要用炸彈或火箭 ─ 機炮打設施只有兩成傷害。",
	},
	{
		"title": "3／4　你要做什麼",
		"body": "這是一場十分鐘的非對稱空戰，兩邊的目標完全不同。\n\n"
			+ "▎進攻方：摧毀內陸的核設施就獲勝。核設施隨時可以打，但很厚，要炸彈。\n"
			+ "　順手炸掉跑道的話，防守方 60 秒內一架都升不了空 ─ 那是最好的突擊窗口。\n\n"
			+ "▎防守方：跑道與核設施撐過十分鐘就贏。部署階段有 30 秒可以配置 4 座防空炮。\n\n"
			+ "第 3 分鐘中央高空會投下補給箱，先累積到 100% 的隊伍全隊傷害 ×1.5，持續 90 秒。",
	},
	{
		"title": "4／4　活下來的訣竅",
		"body": "▎地形會擋住鎖定：山壁、峽谷、摩天樓都會切斷雷達視線。被咬住時往谷底鑽，\n"
			+ "　比直線加速逃跑有用得多。\n\n"
			+ "▎防空火網：敵方基地周圍有防空塔、高射砲陣地與會移動的防空車，\n"
			+ "　航艦周圍還有四艘護航艦。不要在敵方基地上空慢慢繞。\n\n"
			+ "▎機種特性：戰鬥機均衡、截擊機最快最脆、轟炸機厚但慢（唯一能有效拆設施）、\n"
			+ "　武裝直升機可懸停又低空匿蹤，搶空投速度是別人的兩倍。\n\n"
			+ "▎[V] 可以切第一人稱座艙；[F1]~[F4] 是快捷無線電，[T] 打字聊天。",
	},
]

var _tut_page: int = 0
var _tut_title: Label
var _tut_body: Label
var _tut_dots: Label


func _build_screen_tutorial(parent: Control) -> Control:
	var scr := _mk_screen(parent)

	# 往右偏一點：左下角是隊伍聊天框，置中會被它蓋住「進入練習場」
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -300; panel.offset_right = 540
	panel.offset_top = -285; panel.offset_bottom = 295
	panel.add_theme_stylebox_override("panel",
		_mk_stylebox(Color(0.035, 0.050, 0.078, 0.985), C_DEF))
	scr.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	panel.add_child(col)

	col.add_child(_mk_screen_title("新 手 教 學", "TRAINING — 四頁看完，然後直接進練習場"))

	_tut_title = _mk_label("", 20, Color(1.0, 0.85, 0.35))
	col.add_child(_tut_title)
	_tut_body = _mk_label("", 15, C_TEXT)
	_tut_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tut_body.custom_minimum_size = Vector2(0, 300)
	_tut_body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	col.add_child(_tut_body)

	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 8)
	col.add_child(nav)
	var prev := _mk_button("◀  上一頁", C_DIM)
	prev.custom_minimum_size = Vector2(0, 44)
	prev.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prev.pressed.connect(func(): _tut_show(_tut_page - 1))
	nav.add_child(prev)
	_tut_dots = _mk_label("", 15, C_DEF)
	_tut_dots.custom_minimum_size = Vector2(90, 0)
	_tut_dots.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tut_dots.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nav.add_child(_tut_dots)
	var next := _mk_button("下一頁  ▶", C_DEF)
	next.custom_minimum_size = Vector2(0, 44)
	next.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	next.pressed.connect(func(): _tut_show(_tut_page + 1))
	nav.add_child(next)

	var go := _mk_big_button("▶", "進入練習場", "簡單難度、只有 1 架敵機，全程有步驟提示",
		Color(0.40, 1.00, 0.60))
	go.pressed.connect(start_practice)
	col.add_child(go)

	col.add_child(_mk_back_button())
	_tut_show(0)
	return scr


func _tut_show(page: int) -> void:
	if _tut_title == null:
		return
	_tut_page = clampi(page, 0, TUTORIAL_PAGES.size() - 1)
	var p: Dictionary = TUTORIAL_PAGES[_tut_page]
	_tut_title.text = String(p["title"])
	_tut_body.text = String(p["body"])
	_tut_dots.text = "%d / %d" % [_tut_page + 1, TUTORIAL_PAGES.size()]


## 練習場：單人、簡單難度、每隊只補 1 架 AI、固定平原白天晴朗，全程有步驟提示
func start_practice() -> void:
	if in_match:
		return
	tutorial_mode = true
	difficulty = DIFF_EASY
	map_choice = MAP_PLAINS
	weather_choice = WX_CLEAR
	time_of_day = TOD_DAY
	bots_per_team = 1
	_request_team(TEAM_ATTACKER)
	start_solo_game()


# ─────────────────────── 畫面二：單人作戰 ───────────────────────
func _build_screen_solo(parent: Control) -> Control:
	var scr := _mk_screen(parent)

	# 選項一多就會超出畫面高度，外面包一層 ScrollContainer，
	# 否則地圖／天氣那幾排會被切掉而點不到。
	var sc := ScrollContainer.new()
	sc.set_anchors_preset(Control.PRESET_CENTER_TOP)
	sc.offset_left = -360; sc.offset_right = 360
	sc.offset_top = 16; sc.offset_bottom = 620
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scr.add_child(sc)

	# 底板：3D 停機棚在後面，沒有底板選項文字會看不清楚
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.custom_minimum_size = Vector2(700, 0)
	panel.add_theme_stylebox_override("panel",
		_mk_stylebox(Color(0.035, 0.050, 0.078, 0.96), Color(1, 1, 1, 0.10)))
	sc.add_child(panel)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 10)
	panel.add_child(col)

	col.add_child(_mk_screen_title("單人作戰", "SOLO — 兩隊不足 3 人的位置全部由 AI 補上"))

	col.add_child(_mk_section("選擇陣營  FACTION"))
	col.add_child(_build_faction_selector())

	col.add_child(_mk_section("選擇機種  AIRCRAFT"))
	col.add_child(_build_vtype_selector())

	col.add_child(_mk_section("副武裝  LOADOUT"))
	col.add_child(_build_weapon_selector())

	col.add_child(_mk_section("難度  DIFFICULTY"))
	var dh := HBoxContainer.new()
	dh.add_theme_constant_override("separation", 8)
	col.add_child(dh)
	for d in [DIFF_EASY, DIFF_NORMAL, DIFF_HARD]:
		var info: Dictionary = DIFF[d]
		var b := _mk_button("%s\n%s" % [info["name"], info["en"]], Color(1.0, 0.85, 0.35))
		b.custom_minimum_size = Vector2(0, 54)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func():
			difficulty = d
			_refresh_difficulty())
		dh.add_child(b)
		_diff_btns.append({ "diff": d, "btn": b })

	col.add_child(_mk_section("時段  TIME OF DAY"))
	col.add_child(_build_tod_selector())


	col.add_child(_mk_spacer(8))
	var go := _mk_big_button("▶", "出　擊", "立刻開始與電腦對戰", Color(0.40, 1.00, 0.60))
	go.pressed.connect(start_solo_game)
	col.add_child(go)

	col.add_child(_mk_back_button())
	return scr


# ─────────────────────── 畫面三：連線房間 ───────────────────────
func _build_screen_room(parent: Control) -> Control:
	var scr := _mk_screen(parent)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_CENTER_TOP)
	col.offset_left = -430; col.offset_right = 430
	col.offset_top = 16; col.offset_bottom = 560
	col.add_theme_constant_override("separation", 10)
	scr.add_child(col)

	col.add_child(_mk_screen_title("連線對戰", "ONLINE — 建立或加入房間"))

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(cols)

	# 左：連線
	var left := _mk_panel_column(cols, 400)
	_room_lbl = _mk_label("尚未開房", 24, C_TEXT)
	left.add_child(_room_lbl)
	_status_lbl = _mk_label("尚未連線。", 12, C_DIM)
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_lbl.custom_minimum_size = Vector2(0, 46)
	left.add_child(_status_lbl)
	left.add_child(_mk_sep())

	# 用可切換的 Button 取代 CheckBox：狀態直接寫在文字上，不依賴主題勾選圖示
	_mode_check = _mk_button("", C_DEF)
	_mode_check.toggle_mode = true
	_mode_check.button_pressed = (net_mode == NetMode.WEBRTC)
	_mode_check.toggled.connect(func(on: bool):
		net_mode = NetMode.WEBRTC if on else NetMode.ENET
		_refresh_mode_btn()
		_set_status("網路模式：%s" % ("WebRTC（網頁）" if on else "ENet（本機測試）")))
	left.add_child(_mode_check)
	_refresh_mode_btn()

	# 房主可以設密碼；加入者必須輸入相同密碼才會被接受
	left.add_child(_mk_label("房間密碼  PASSCODE（開房前設定，可留空）", 12, C_DIM))
	_pass_edit = LineEdit.new()
	_pass_edit.placeholder_text = "留空＝不設密碼"
	_pass_edit.max_length = 16
	_pass_edit.secret = true
	_pass_edit.text_changed.connect(func(t: String): room_pass = t.strip_edges())
	left.add_child(_pass_edit)

	_host_btn = _mk_button("建立房間  HOST", C_ATK)
	_host_btn.pressed.connect(host_game)
	left.add_child(_host_btn)

	left.add_child(_mk_label("房間碼 / 主機位址", 12, C_DIM))
	_code_edit = LineEdit.new()
	_code_edit.placeholder_text = "0000 或 192.168.0.5:10042"
	_code_edit.max_length = 42
	left.add_child(_code_edit)
	_join_btn = _mk_button("加入房間  JOIN（戰術視窗）", C_DEF)
	_join_btn.pressed.connect(open_join_dialog)
	left.add_child(_join_btn)

	# 右：陣營 / 機種 / 名單
	var right := _mk_panel_column(cols, 430)
	right.add_child(_mk_label("陣營", 14, C_TEXT))
	right.add_child(_build_faction_selector())
	right.add_child(_mk_label("機種", 14, C_TEXT))
	right.add_child(_build_vtype_selector())
	right.add_child(_mk_label("副武裝", 14, C_TEXT))
	right.add_child(_build_weapon_selector())
	right.add_child(_mk_label("時段（由房主決定）", 14, C_TEXT))
	right.add_child(_build_tod_selector())
	right.add_child(_mk_sep())
	right.add_child(_mk_label("作戰序列 ROSTER", 14, C_TEXT))
	for team in [TEAM_ATTACKER, TEAM_DEFENDER]:
		right.add_child(_mk_label(TEAM_NAME[team], 13, C_ATK if team == TEAM_ATTACKER else C_DEF))
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 2)
		right.add_child(vb)
		_roster[team] = vb
	right.add_child(_mk_label("每隊不足 3 名真人時，開賽會自動補上 AI 隊友。", 11, C_DIM))

	_start_btn = _mk_big_button("▶", "開始遊戲", "只有房主可以開始", Color(0.40, 1.00, 0.60))
	_start_btn.disabled = true
	_start_btn.pressed.connect(start_match)
	col.add_child(_start_btn)

	col.add_child(_mk_back_button())
	return scr


# ─────────────────────── 底部小圖示列 ───────────────────────
func _build_bottom_bar() -> void:
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	bar.offset_left = -420; bar.offset_right = -18
	bar.offset_top = -68; bar.offset_bottom = -18
	bar.alignment = BoxContainer.ALIGNMENT_END
	bar.add_theme_constant_override("separation", 8)
	_lobby.add_child(bar)

	var help := _mk_icon_button("？", "操作說明", C_DEF)
	help.pressed.connect(func(): _help_overlay.visible = not _help_overlay.visible)
	bar.add_child(help)

	var full := _mk_icon_button("⛶", "全螢幕", C_DIM)
	full.pressed.connect(func():
		var w := DisplayServer.window_get_mode()
		DisplayServer.window_set_mode(
			DisplayServer.WINDOW_MODE_WINDOWED if w == DisplayServer.WINDOW_MODE_FULLSCREEN
			else DisplayServer.WINDOW_MODE_FULLSCREEN))
	bar.add_child(full)

	if not OS.has_feature("web"):
		var quit := _mk_icon_button("✕", "離開", Color(1.0, 0.4, 0.4))
		quit.pressed.connect(func(): get_tree().quit())
		bar.add_child(quit)


func _build_help_overlay() -> void:
	_help_overlay = Control.new()
	_help_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_help_overlay.visible = false
	_lobby.add_child(_help_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.7)
	_help_overlay.add_child(dim)

	var p := PanelContainer.new()
	p.set_anchors_preset(Control.PRESET_CENTER)
	p.offset_left = -360; p.offset_right = 360
	p.offset_top = -300; p.offset_bottom = 300
	p.add_theme_stylebox_override("panel", _mk_stylebox(C_PANE, C_DEF))
	_help_overlay.add_child(p)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)
	v.add_child(_mk_label("操作說明  CONTROLS", 20, C_TEXT))
	v.add_child(_mk_sep())
	v.add_child(_mk_label(
		"W / S　　拉升 / 俯衝（直升機懸停時為升降）\n"
		+ "A / D　　左右轉向（方向舵）\n"
		+ "Z / C　　左右滾轉（Roll）\n"
		+ "滑鼠右鍵　機炮 / 機槍（射速快、傷害低；備援鍵 X）\n"
		+ "滑鼠左鍵　鎖定並發射飛彈 / 火箭 / 炸彈（備援鍵 B）\n"
		+ "Space　　後燃器加速（有燃料上限，會自動回充）\n"
		+ "1 / 2 / 3　空中切換副武裝（每種各有自己的備彈）\n"
		+ "V　　　　第一人稱座艙 ／ 第三人稱切換\n"
		+ "R / F　　油門增 / 減\n"
		+ "Shift　　干擾彈（3.5 秒內無法被鎖定）\n"
		+ "Ctrl 　　直升機懸停模式切換\n"
		+ "E / Q　　庫房登機 / 切換副武裝\n"
		+ "G　　　　防守方部署防空塔\n"
		+ "T　　　　隊伍聊天（開頭打 /all 為全場發言）\n"
		+ "F1 ~ F4　快捷無線電\n\n"
		+ "進攻方：摧毀核設施即獲勝（隨時可打）。炸毀跑道可讓防守方 60 秒無法復活。\n"
		+ "防守方：守住 10 分鐘即獲勝。\n"
		+ "峽谷低空穿線可以讓山壁擋掉敵方的飛彈鎖定。", 13, C_TEXT))
	var close := _mk_button("關閉", C_DEF)
	close.pressed.connect(func(): _help_overlay.visible = false)
	v.add_child(close)


# ─────────────────────── 共用元件 ───────────────────────
func _mk_screen(parent: Control) -> Control:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_PASS
	parent.add_child(c)
	return c


func _show_screen(s: int) -> void:
	_cur_screen = s
	if s == Screen.SHOP:
		_refresh_shop()
	elif s == Screen.LOGIN:
		_refresh_login_list()
	# 商店的 3D 預覽只在商店畫面更新，其他時候不要白燒 GPU
	if _shop_vp != null:
		_shop_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if s == Screen.SHOP \
			else SubViewport.UPDATE_DISABLED
	for k in _screens:
		(_screens[k] as Control).visible = (k == s)
	_refresh_top_info()


func _mk_screen_title(title: String, sub: String) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	var t := _mk_label(title, 28, Color.WHITE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var s := _mk_label(sub, 12, C_DIM)
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(s)
	return v


func _mk_section(text: String) -> Control:
	var l := _mk_label("▎" + text, 14, C_DEF)
	return l


func _mk_spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _mk_back_button() -> Button:
	var b := _mk_button("◀  返回主選單", C_DIM)
	b.pressed.connect(func(): _show_screen(Screen.MENU))
	return b


## 貓咪大戰爭風格的大按鈕：左側圖示方塊 + 主標題 + 副標題 + 右側箭頭
func _mk_big_button(icon: String, title: String, subtitle: String, accent: Color) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 84)
	b.add_theme_stylebox_override("normal", _mk_big_sb(accent, 0.14))
	b.add_theme_stylebox_override("hover", _mk_big_sb(accent, 0.32))
	b.add_theme_stylebox_override("pressed", _mk_big_sb(accent, 0.48))
	b.add_theme_stylebox_override("disabled", _mk_big_sb(Color(0.35, 0.35, 0.40), 0.08))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var hb := HBoxContainer.new()
	hb.set_anchors_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = 18; hb.offset_right = -18
	hb.add_theme_constant_override("separation", 16)
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(hb)

	var ip := PanelContainer.new()
	ip.custom_minimum_size = Vector2(56, 56)
	ip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ip.add_theme_stylebox_override("panel", _mk_stylebox(Color(accent.r, accent.g, accent.b, 0.85), accent))
	hb.add_child(ip)
	var il := _mk_label(icon, 26, Color(0.04, 0.05, 0.08))
	il.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	il.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ip.add_child(il)

	var tv := VBoxContainer.new()
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tv.add_theme_constant_override("separation", 0)
	tv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(tv)
	var tl := _mk_label(title, 24, Color.WHITE)
	tl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	tl.add_theme_constant_override("outline_size", 5)
	tv.add_child(tl)
	if subtitle != "":
		tv.add_child(_mk_label(subtitle, 12, C_DIM))

	var arrow := _mk_label("▶", 22, accent)
	arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(arrow)
	return b


func _mk_big_sb(accent: Color, alpha: float) -> StyleBoxFlat:
	var sb := _mk_stylebox(Color(accent.r, accent.g, accent.b, alpha), accent)
	sb.border_width_left = 2; sb.border_width_right = 2
	sb.border_width_top = 2; sb.border_width_bottom = 4
	sb.corner_radius_top_left = 10; sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10; sb.corner_radius_bottom_right = 10
	return sb


func _mk_icon_button(glyph: String, tip: String, accent: Color) -> Button:
	var b := _mk_button(glyph, accent)
	b.custom_minimum_size = Vector2(52, 46)
	b.tooltip_text = tip
	b.add_theme_font_size_override("font_size", 20)
	return b


## 陣營選擇器（可在多個畫面各建立一份，refresh 時會一起更新）
func _build_faction_selector() -> Control:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	for team in [TEAM_ATTACKER, TEAM_DEFENDER]:
		var accent: Color = C_ATK if team == TEAM_ATTACKER else C_DEF
		var b := _mk_button(TEAM_NAME[team], accent)
		b.custom_minimum_size = Vector2(0, 52)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): _request_team(team))
		hb.add_child(b)
		_team_btn_list.append({ "team": team, "btn": b })
	return hb


func _build_vtype_selector() -> Control:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	_vtype_boxes.append(hb)
	return hb


## 視覺化商店：左邊是真的 3D 展示台（可預覽機種與塗裝），右邊是購買清單
func _build_screen_shop(parent: Control) -> Control:
	var scr := _mk_screen(parent)

	var sc := ScrollContainer.new()
	sc.set_anchors_preset(Control.PRESET_CENTER_TOP)
	sc.offset_left = -490; sc.offset_right = 490
	sc.offset_top = 8; sc.offset_bottom = 660
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scr.add_child(sc)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.custom_minimum_size = Vector2(960, 0)
	col.add_theme_constant_override("separation", 8)
	sc.add_child(col)

	col.add_child(_mk_screen_title("機　庫", "HANGAR — 3D 預覽並選購／替換飛機與塗裝，升級武器"))
	_shop_credits = _mk_label("", 20, Color(1.0, 0.85, 0.35))
	_shop_credits.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_shop_credits)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	col.add_child(cols)

	# ── 左欄：3D 展示台 + 機種 + 副武裝 ──
	var left := _mk_panel_column(cols, 470)
	left.add_child(_mk_label("▎3D 展示台  PREVIEW", 14, C_DEF))

	_shop_vp = SubViewport.new()
	_shop_vp.size = Vector2i(430, 300)
	_shop_vp.own_world_3d = true            # 自己的 3D 世界，環境不會污染戰場
	_shop_vp.transparent_bg = false
	_shop_vp.msaa_3d = Viewport.MSAA_2X
	_shop_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_shop_stand = load("res://Hangar3D.gd").new()
	_shop_vp.add_child(_shop_stand)

	var vpc := SubViewportContainer.new()
	vpc.stretch = true
	vpc.custom_minimum_size = Vector2(430, 300)
	vpc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vpc.add_child(_shop_vp)
	left.add_child(vpc)
	_shop_stand.build("stand")

	left.add_child(_mk_label("▎機種  AIRCRAFT", 14, C_DEF))
	_shop_plane_row = HBoxContainer.new()
	_shop_plane_row.add_theme_constant_override("separation", 6)
	left.add_child(_shop_plane_row)

	_shop_info = _mk_label("", 12, C_TEXT)
	_shop_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_shop_info.custom_minimum_size = Vector2(0, 78)
	left.add_child(_shop_info)

	# ── 右欄：副武裝、塗裝與升級 ──
	var right := _mk_panel_column(cols, 470)
	right.add_child(_mk_label("▎副武裝  LOADOUT（庫房也可按 Q 切換）", 14, C_DEF))
	right.add_child(_build_weapon_selector())
	right.add_child(_mk_sep())
	right.add_child(_mk_label("▎機身塗裝  SKINS", 14, C_DEF))
	_shop_skins = GridContainer.new()
	_shop_skins.columns = 2
	_shop_skins.add_theme_constant_override("h_separation", 6)
	_shop_skins.add_theme_constant_override("v_separation", 6)
	right.add_child(_shop_skins)

	right.add_child(_mk_sep())
	right.add_child(_mk_label("▎武器升級  UPGRADES", 14, C_DEF))
	_shop_upgrades = VBoxContainer.new()
	_shop_upgrades.add_theme_constant_override("separation", 6)
	right.add_child(_shop_upgrades)

	col.add_child(_mk_spacer(6))
	col.add_child(_mk_back_button())
	return scr


func _refresh_shop() -> void:
	if _shop_credits == null:
		return
	_shop_credits.text = "可用點數：%d" % credits
	_refresh_shop_planes()

	for c in _shop_upgrades.get_children():
		c.queue_free()
	for key in UPGRADES:
		var info: Dictionary = UPGRADES[key]
		var lv := upgrade_level(key)
		var maxed: bool = lv >= int(info["max"])
		var cost := int(info["cost"]) * (lv + 1)      # 越買越貴
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_shop_upgrades.add_child(row)

		var lab := _mk_label("%s　Lv.%d/%d\n%s" % [info["name"], lv, info["max"], info["desc"]],
			13, C_TEXT)
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lab)

		var b := _mk_button("已滿級" if maxed else "升級  %d 點" % cost,
			Color(0.5, 0.5, 0.55) if maxed else Color(0.45, 1.0, 0.6))
		b.custom_minimum_size = Vector2(160, 44)
		b.disabled = maxed or credits < cost
		b.pressed.connect(func():
			if credits < cost:
				return
			credits -= cost
			upgrades[key] = lv + 1
			save_profile()
			add_chat_line("[商店] %s 升級至 Lv.%d" % [info["name"], lv + 1], Color(0.45, 1.0, 0.6))
			_refresh_shop())
		row.add_child(b)

	for c2 in _shop_skins.get_children():
		c2.queue_free()
	for key2 in SKINS:
		var s: Dictionary = SKINS[key2]
		var owned: bool = owned_skins.has(key2)
		var sel: bool = (skin == key2)
		var sb := _mk_button("%s%s\n%s" % ["● " if sel else "", s["name"],
			("裝備中" if sel else "已擁有") if owned else "%d 點" % int(s["cost"])],
			Color(s["col"]).lightened(0.45))
		sb.custom_minimum_size = Vector2(0, 52)
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.disabled = (not owned) and credits < int(s["cost"])
		sb.pressed.connect(func():
			if not owned:
				if credits < int(s["cost"]):
					return
				credits -= int(s["cost"])
				owned_skins.append(key2)
				add_chat_line("[商店] 購買塗裝「%s」。" % s["name"], Color(0.45, 1.0, 0.6))
			skin = key2
			save_profile()
			_refresh_account_lbl()
			refresh_hangar_plane()          # 3D 展示台即時換色
			_refresh_shop())
		_shop_skins.add_child(sb)


#══════════════════════════════════════════════════════════════════════════════
#  機庫：機種選購與 3D 預覽
#══════════════════════════════════════════════════════════════════════════════
var _shop_preview_vt: int = VType.FIGHTER


func _refresh_shop_planes() -> void:
	if _shop_plane_row == null:
		return
	for c in _shop_plane_row.get_children():
		c.queue_free()

	var equipped := int(players[my_id()]["vtype"]) if players.has(my_id()) else VType.FIGHTER
	if not PLANES.has(_shop_preview_vt):
		_shop_preview_vt = equipped

	for vt in PLANES.keys():
		var info: Dictionary = PLANES[vt]
		var cost := int(info["cost"])
		var owned: bool = owns_plane(int(vt))
		var is_eq: bool = (int(vt) == equipped)
		var accent: Color = VSTATS[vt]["color"]
		var state := "裝備中" if is_eq else ("已擁有" if owned else "%d 點" % cost)
		var b := _mk_button("%s%s\n%s" % ["● " if int(vt) == _shop_preview_vt else "",
			VTYPE_NAME[vt], state], Color.WHITE if is_eq else accent)
		b.custom_minimum_size = Vector2(0, 56)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = (not owned) and credits < cost
		b.pressed.connect(func(): _shop_pick_plane(int(vt)))
		_shop_plane_row.add_child(b)

	_refresh_shop_info()
	refresh_hangar_plane()


## 點機種：沒有的先買下來，接著預覽並（若陣營許可）直接裝備
func _shop_pick_plane(vt: int) -> void:
	if not owns_plane(vt):
		var cost := int(PLANES[vt]["cost"])
		if credits < cost:
			return
		credits -= cost
		owned_planes.append(vt)
		save_profile()
		add_chat_line("[機庫] 購入 %s。" % VTYPE_NAME[vt], Color(0.45, 1.0, 0.6))
	_shop_preview_vt = vt
	# 陣營限制：例如轟炸機只有進攻方能開，這種情況只預覽不裝備
	if TEAM_VTYPES[my_team()].has(vt):
		_request_vtype(vt)
	_refresh_account_lbl()
	_refresh_shop()


func _refresh_shop_info() -> void:
	if _shop_info == null:
		return
	var vt := _shop_preview_vt
	var st: Dictionary = VSTATS[vt]
	var teams: Array = []
	for t in [TEAM_ATTACKER, TEAM_DEFENDER]:
		if TEAM_VTYPES[t].has(vt):
			teams.append(String(TEAM_NAME[t]).split(" ")[0])
	var note := ""
	if not TEAM_VTYPES[my_team()].has(vt):
		note = "\n⚠ 目前陣營不能駕駛這個機種（僅供預覽）。"
	_shop_info.text = "%s　［%s］\n%s\nHP %d　最高速 %d m/s　加速 %d　可用陣營：%s%s" % [
		VTYPE_NAME[vt], PLANES[vt]["tag"], PLANES[vt]["desc"],
		int(st["hp"]), int(st["max_speed"]), int(st["accel"]),
		"／".join(teams), note]


func _build_weapon_selector() -> Control:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	_weapon_boxes.append(hb)
	return hb


func _refresh_weapon_buttons() -> void:
	var id := my_id()
	if not players.has(id):
		return
	var vt: int = players[id]["vtype"]
	var cur: int = int(players[id].get("weapon", default_weapon(vt)))
	for box in _weapon_boxes:
		var hb: HBoxContainer = box
		for c in hb.get_children():
			c.queue_free()
		for w in VSTATS[vt]["weapons"]:
			var info: Dictionary = WEAPONS[w]
			var sel: bool = (int(w) == cur)
			var b := _mk_button(("● " if sel else "") + String(info["name"]),
				Color.WHITE if sel else Color(1.0, 0.72, 0.45))
			b.tooltip_text = "%s\n傷害 %d　間隔 %.2fs　備彈 %d　對建築 ×%.1f" % [
				info["desc"], int(info["dmg"]), float(info["rof"]),
				int(info["ammo"]), float(info["struct"])]
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.pressed.connect(func(): _request_weapon(w))
			hb.add_child(b)


func _build_tod_selector() -> Control:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	for t in [TOD_DAY, TOD_DUSK, TOD_NIGHT, TOD_CYCLE]:
		var info: Dictionary = TOD_NAME[t]
		var b := _mk_button(String(info["name"]), Color(0.65, 0.80, 1.00))
		b.custom_minimum_size = Vector2(0, 40)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func():
			time_of_day = t
			_refresh_tod())
		hb.add_child(b)
		_tod_btns.append({ "tod": t, "btn": b })
	return hb


func _build_chat() -> void:
	_chat_panel = PanelContainer.new()
	_chat_panel.name = "ChatBox"
	_chat_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_chat_panel.offset_left = 16
	_chat_panel.offset_top = -230
	_chat_panel.offset_right = 496
	_chat_panel.offset_bottom = -16
	_chat_panel.add_theme_stylebox_override("panel", _mk_stylebox(C_PANE))
	_chat_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_ui.add_child(_chat_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	_chat_panel.add_child(vb)

	var head := HBoxContainer.new()
	vb.add_child(head)
	head.add_child(_mk_label("隊伍通訊 TEAM COMMS", 13, C_DIM))
	_chat_scope_lbl = _mk_label("", 13, C_TEXT)
	_chat_scope_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_scope_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_chat_scope_lbl)

	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_following = true
	_chat_log.fit_content = false
	_chat_log.custom_minimum_size = Vector2(0, 150)
	_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_log.add_theme_font_size_override("normal_font_size", 13)
	vb.add_child(_chat_log)

	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "輸入訊息後按 Enter（Esc 取消）"
	_chat_input.visible = false
	_chat_input.text_submitted.connect(_on_chat_submitted)
	# 點到別的地方就自動收起來，不然欄位會留著把飛行輸入吃光
	_chat_input.focus_exited.connect(_close_chat_input)
	vb.add_child(_chat_input)

	var hint := _mk_label("T 隊伍聊天  ／  1~4 快捷無線電", 11, C_DIM)
	vb.add_child(hint)


# ── UI 小工具 ──
func _mk_label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _mk_button(text: String, accent: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 38)
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", accent)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_stylebox_override("normal", _mk_stylebox(Color(accent.r, accent.g, accent.b, 0.14), accent))
	b.add_theme_stylebox_override("hover", _mk_stylebox(Color(accent.r, accent.g, accent.b, 0.32), accent))
	b.add_theme_stylebox_override("pressed", _mk_stylebox(Color(accent.r, accent.g, accent.b, 0.50), accent))
	b.add_theme_stylebox_override("disabled", _mk_stylebox(Color(0.2, 0.2, 0.25, 0.25), Color(0.3, 0.3, 0.35)))
	return b


func _mk_stylebox(bg: Color, border: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	if border.a > 0.0:
		sb.border_width_left = 1
		sb.border_width_right = 1
		sb.border_width_top = 1
		sb.border_width_bottom = 1
		sb.border_color = border
	return sb


func _mk_sep() -> Control:
	var s := ColorRect.new()
	s.color = Color(1, 1, 1, 0.10)
	s.custom_minimum_size = Vector2(0, 1)
	return s


func _mk_panel_column(parent: Control, width: float) -> VBoxContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(width, 0)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_theme_stylebox_override("panel", _mk_stylebox(C_PANE, Color(1, 1, 1, 0.08)))
	parent.add_child(p)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	p.add_child(vb)
	return vb


func _set_status(msg: String) -> void:
	if _status_lbl:
		_status_lbl.text = msg
	print("[NET] ", msg)


#══════════════════════════════════════════════════════════════════════════════
#  主機 / 加入
#══════════════════════════════════════════════════════════════════════════════
## Godot 4 的 multiplayer_peer 預設是 OfflineMultiplayerPeer（非 null），
## 所以不能用 == null 判斷是否已連線。
func has_net() -> bool:
	var p := multiplayer.multiplayer_peer
	if p == null or p is OfflineMultiplayerPeer:
		return false
	return p.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED


func host_game() -> void:
	if has_net():
		_set_status("已在連線中，請先重新啟動。")
		return

	room_code = _gen_room_code()
	_local_name = _name_edit.text.strip_edges()
	if _pass_edit:
		room_pass = _pass_edit.text.strip_edges()
	is_host = true

	if net_mode == NetMode.WEBRTC:
		_sig_connect({ "cmd": "host", "room": room_code })
	else:
		var peer := ENetMultiplayerPeer.new()
		var err := peer.create_server(_port_from_code(room_code), 16)
		if err != OK:
			_set_status("建立伺服器失敗（錯誤碼 %d）。" % err)
			is_host = false
			return
		multiplayer.multiplayer_peer = peer
		_on_became_host()

	_room_lbl.text = "房號  %s" % room_code


## code 可以是 4 位數房號，也可以是 主機IP 或 主機IP:埠號（ENet 模式）
func join_game(code: String, passcode: String = "") -> void:
	code = code.strip_edges()
	_join_pass = passcode.strip_edges()
	_local_name = _name_edit.text.strip_edges()
	is_host = false

	var host_ip := "127.0.0.1"
	var port := 0
	var pure_code := code.length() == 4 and code.is_valid_int()

	if pure_code:
		room_code = code
		port = _port_from_code(code)
	elif net_mode == NetMode.ENET:
		# 位址模式：ip 或 ip:port，沒寫埠號就用預設 4 位數房號 0000 的埠
		var parts := code.split(":")
		host_ip = String(parts[0]).strip_edges()
		port = int(parts[1]) if parts.size() > 1 and String(parts[1]).is_valid_int() \
			else ENET_BASE_PORT
		room_code = "%04d" % (port - ENET_BASE_PORT) if port > ENET_BASE_PORT else "----"
		if host_ip.is_empty():
			_join_fail("主機位址格式不正確。")
			return
	else:
		_join_fail("WebRTC 模式只能用 4 位數房號加入。")
		return

	if net_mode == NetMode.WEBRTC:
		_sig_connect({ "cmd": "join", "room": room_code })
		_join_status("working", "信令交握　SIGNALING", "連線信令伺服器並交換 SDP…")
	else:
		var peer := ENetMultiplayerPeer.new()
		var err := peer.create_client(host_ip, port)
		if err != OK:
			_join_fail("建立 ENet 客戶端失敗（錯誤碼 %d）。" % err)
			return
		multiplayer.multiplayer_peer = peer
		_set_status("連線中…（ENet %s:%d）" % [host_ip, port])
		_join_status("working", "交握中　HANDSHAKE", "ENet %s:%d ─ 等待房主回應…" % [host_ip, port])

	_show_screen(Screen.ROOM)
	_room_lbl.text = "房號  %s" % room_code


var _join_pass: String = ""


## 把狀態同步到戰術彈窗（彈窗沒開就只寫進狀態列）
func _join_status(kind: String, text: String, detail: String = "") -> void:
	if _join_dlg != null and _join_dlg.visible:
		_join_dlg.set_state(kind, text, detail)
		_join_dlg.log_line("[%s] %s" % [Time.get_time_string_from_system(), detail if detail != "" else text],
			C_DIM)


func _join_fail(msg: String) -> void:
	_set_status(msg)
	if _join_dlg != null and _join_dlg.visible:
		_join_dlg.set_state("fail", "連線失敗　LINK FAILED", msg)
		_join_dlg.log_line("[錯誤] " + msg, Color(1.0, 0.38, 0.34))


func _on_became_host() -> void:
	# 保留玩家在主選單已經選好的陣營與機種
	var prev: Dictionary = players.get(1, {})
	players.clear()
	players[1] = _new_player_entry(_local_name,
		int(prev.get("team", TEAM_ATTACKER)), int(prev.get("vtype", VType.FIGHTER)), false)
	_start_btn.disabled = false
	var pw := "（密碼：%s）" % room_pass if room_pass != "" else "（未設密碼）"
	_set_status("房間已開啟，把房號 %s %s 給隊友。" % [room_code, pw])
	add_chat_line("[系統] 房間 %s 建立完成%s，你是房主。" % [room_code, pw], C_DIM)
	_refresh_roster()
	_refresh_vtype_buttons()


func _gen_room_code() -> String:
	# 自動化測試要固定房號，客戶端才知道要連哪個埠
	var forced := OS.get_environment("NETSMOKE_ROOM").strip_edges()
	if forced.length() == 4 and forced.is_valid_int():
		return forced
	return "%04d" % (randi() % 9000 + 1000)


func _port_from_code(code: String) -> int:
	return ENET_BASE_PORT + int(code)


func _new_player_entry(pname: String, team: int, vtype: int, bot: bool) -> Dictionary:
	return { "name": pname, "team": team, "vtype": vtype, "bot": bot,
		"weapon": default_weapon(vtype), "kills": 0, "deaths": 0 }


func default_weapon(vtype: int) -> int:
	return int(VSTATS[vtype]["weapons"][0])


## 換機種時，若原本的副武裝新機掛不了就換成預設
func _fix_weapon(id: int) -> void:
	if not players.has(id):
		return
	var vt: int = players[id]["vtype"]
	var allowed: Array = VSTATS[vt]["weapons"]
	if not allowed.has(players[id].get("weapon", -1)):
		players[id]["weapon"] = int(allowed[0])


#══════════════════════════════════════════════════════════════════════════════
#  WebRTC 信令（WebSocket）
#══════════════════════════════════════════════════════════════════════════════
## 實際要連的信令位址。優先序：
##   1. 網址參數 `?signal=wss://…`  ─ 網頁版換伺服器不必重新匯出，分享網址時就能帶著走
##   2. 環境變數 `SIGNALING_URL`    ─ 桌面版與自動化測試用
##   3. 常數 SIGNALING_URL          ─ 內建預設
## 網頁是 https 時瀏覽器會擋掉 ws://，所以線上一定要給 wss://。
func signaling_url() -> String:
	if OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge"):
		var js := Engine.get_singleton("JavaScriptBridge")
		var q := str(js.eval(
			"new URLSearchParams(location.search).get('signal') || ''", true)).strip_edges()
		if q != "":
			return q
	var env := OS.get_environment("SIGNALING_URL").strip_edges()
	if env != "":
		return env
	return SIGNALING_URL


func _sig_connect(first_msg: Dictionary) -> void:
	_pending_sig = first_msg
	_ws_open = false
	_conns.clear()
	var url := signaling_url()
	_ws = WebSocketPeer.new()
	var err := _ws.connect_to_url(url)
	if err != OK:
		_set_status("無法連線信令伺服器 %s（錯誤碼 %d）。" % [url, err])
		_ws = null
		return
	_set_status("連線信令伺服器 %s …" % url)


func _poll_signaling() -> void:
	if _ws == null:
		return
	_ws.poll()
	var state := _ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		if not _ws_open:
			_ws_open = true
			_sig_send(_pending_sig)
		while _ws.get_available_packet_count() > 0:
			var txt := _ws.get_packet().get_string_from_utf8()
			var data: Variant = JSON.parse_string(txt)
			if data is Dictionary:
				_on_sig_message(data)
	elif state == WebSocketPeer.STATE_CLOSED:
		_set_status("信令連線關閉（code %d）。" % _ws.get_close_code())
		_ws = null
		_ws_open = false


func _sig_send(msg: Dictionary) -> void:
	if _ws and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(msg))


func _on_sig_message(m: Dictionary) -> void:
	match String(m.get("cmd", "")):
		"error":
			_set_status("信令錯誤：%s" % m.get("msg", ""))

		"welcome":
			var my_id := int(m["id"])
			_rtc = WebRTCMultiplayerPeer.new()
			var err: int
			if is_host:
				err = _rtc.create_server()
			else:
				err = _rtc.create_client(my_id)
			if err != OK:
				_set_status("WebRTCMultiplayerPeer 初始化失敗（%d）。桌面版需安裝 webrtc GDExtension。" % err)
				return
			multiplayer.multiplayer_peer = _rtc
			if is_host:
				_on_became_host()
			else:
				# 客戶端只需與房主 (id 1) 建立連線
				var c := _rtc_make_conn(1)
				if c:
					c.create_offer()
				_set_status("與房主建立 P2P 連線中…")

		"peer_join":
			# 房主收到：等待該客戶端送 offer 過來
			if is_host:
				_rtc_make_conn(int(m["id"]))

		"peer_left":
			var pid := int(m["id"])
			if _conns.has(pid):
				_conns.erase(pid)
			if _rtc:
				_rtc.remove_peer(pid)

		"sdp":
			var from := int(m["from"])
			var conn: WebRTCPeerConnection = _conns.get(from)
			if conn == null:
				conn = _rtc_make_conn(from)
			if conn:
				conn.set_remote_description(String(m["type"]), String(m["sdp"]))

		"ice":
			var f := int(m["from"])
			var cc: WebRTCPeerConnection = _conns.get(f)
			if cc:
				cc.add_ice_candidate(String(m["mid"]), int(m["index"]), String(m["name"]))


func _rtc_make_conn(peer_id: int) -> WebRTCPeerConnection:
	if _conns.has(peer_id):
		return _conns[peer_id]
	var conn := WebRTCPeerConnection.new()
	if conn.initialize(ICE_CONFIG) != OK:
		_set_status("WebRTCPeerConnection 無法初始化（桌面版需 webrtc GDExtension）。")
		return null
	conn.session_description_created.connect(func(type: String, sdp: String):
		conn.set_local_description(type, sdp)
		_sig_send({ "cmd": "sdp", "to": peer_id, "type": type, "sdp": sdp }))
	conn.ice_candidate_created.connect(func(mid: String, index: int, cname: String):
		_sig_send({ "cmd": "ice", "to": peer_id, "mid": mid, "index": index, "name": cname }))
	_rtc.add_peer(conn, peer_id)
	_conns[peer_id] = conn
	return conn


#══════════════════════════════════════════════════════════════════════════════
#  Multiplayer 事件
#══════════════════════════════════════════════════════════════════════════════
func _on_peer_connected(id: int) -> void:
	if is_host:
		_set_status("玩家 %d 已連線。" % id)


func _on_peer_disconnected(id: int) -> void:
	if players.has(id):
		var nm: String = players[id]["name"]
		players.erase(id)
		add_chat_line("[系統] %s 離線。" % nm, C_DIM)
	if is_host:
		_broadcast_players()
	if world and world.has_method("remove_pilot"):
		world.remove_pilot(id)


func _on_connected_ok() -> void:
	_set_status("已連上房主，等待開賽。")
	_join_status("ok", "已連線　LINK ESTABLISHED", "已進入房間，等待房主開賽。")
	rpc_id(1, "srv_register", _local_name, _join_pass)


func _on_connection_failed() -> void:
	_join_fail("連線失敗，請確認房號／位址與伺服器是否正確。")
	multiplayer.multiplayer_peer = null


func _on_server_disconnected() -> void:
	_set_status("與房主斷線。")
	multiplayer.multiplayer_peer = null
	room_code = ""
	_return_to_menu()


#══════════════════════════════════════════════════════════════════════════════
#  玩家註冊 / 陣營 / 機種（RPC）
#══════════════════════════════════════════════════════════════════════════════
@rpc("any_peer", "reliable")
func srv_register(pname: String, passcode: String = "") -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	# 房間密碼由房主驗證：不符就回拒絕訊息並踢掉，不讓對方進名單
	if room_pass != "" and passcode.strip_edges() != room_pass:
		_kick(id, pname, "房間密碼不正確。")
		return
	# 比賽已經開始就不接受中途加入：
	# 對方沒有 GameWorld 節點，房主每秒 20 次的世界狀態 RPC 會全部找不到節點，
	# 兩邊都會被 "Node not found: Main/GameWorld" 洗版（實測 30 秒噴了 800 多個錯誤）。
	if in_match:
		_kick(id, pname, "這一局已經開始了，請等結束後再加入。")
		return
	# 自動平衡：人少的那一隊
	var team := TEAM_ATTACKER if _count_team(TEAM_ATTACKER, true) <= _count_team(TEAM_DEFENDER, true) else TEAM_DEFENDER
	var default_v: int = TEAM_VTYPES[team][0]
	players[id] = _new_player_entry(pname, team, default_v, false)
	_broadcast_players()
	rpc("net_chat", 0, "%s 加入戰場。" % pname, SCOPE_ALL)


## 房主端：拒絕並斷開某個連線
func _kick(id: int, pname: String, reason: String) -> void:
	rpc_id(id, "cli_reject", reason)
	add_chat_line("[系統] 拒絕 %s 的連線：%s" % [pname, reason], C_DIM)
	var peer := multiplayer.multiplayer_peer
	if peer != null and peer is ENetMultiplayerPeer:
		# 延後一個 frame 再踢，讓 cli_reject 有機會送出去
		(peer as ENetMultiplayerPeer).call_deferred("disconnect_peer", id)


## 房主拒絕連線（密碼錯誤或比賽已開始）
@rpc("authority", "reliable")
func cli_reject(reason: String) -> void:
	_join_fail(reason)
	multiplayer.multiplayer_peer = null
	room_code = ""
	add_chat_line("[系統] 連線被拒：%s" % reason, Color(1.0, 0.4, 0.4))


@rpc("any_peer", "reliable")
func srv_set_team(team: int) -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1
	_apply_team(id, team)
	_broadcast_players()


@rpc("any_peer", "reliable")
func srv_set_vtype(vtype: int) -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1
	_apply_vtype(id, vtype)
	_broadcast_players()


func _apply_team(id: int, team: int) -> void:
	if not players.has(id):
		return
	players[id]["team"] = team
	if not TEAM_VTYPES[team].has(players[id]["vtype"]):
		players[id]["vtype"] = TEAM_VTYPES[team][0]
	_fix_weapon(id)


func _apply_vtype(id: int, vtype: int) -> void:
	if not players.has(id):
		return
	var team: int = players[id]["team"]
	if not TEAM_VTYPES[team].has(vtype):
		return
	# 本機玩家沒在機庫買下這台就不能裝備（AI 與其他玩家不受限）
	if id == my_id() and not bool(players[id]["bot"]) and not owns_plane(vtype):
		_set_status("還沒在機庫購入 %s。" % VTYPE_NAME[vtype])
		return
	players[id]["vtype"] = vtype
	_fix_weapon(id)


func _request_team(team: int) -> void:
	if in_match:
		return
	# 未連線（主選單 / 單人設定）時直接改本機資料
	if is_host or not has_net():
		_apply_team(my_id(), team)
		_broadcast_players()
	else:
		rpc_id(1, "srv_set_team", team)


@rpc("any_peer", "reliable")
func srv_set_weapon(w: int) -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1
	_apply_weapon(id, w)
	_broadcast_players()


func _apply_weapon(id: int, w: int) -> void:
	if not players.has(id):
		return
	var vt: int = players[id]["vtype"]
	if Array(VSTATS[vt]["weapons"]).has(w):
		players[id]["weapon"] = w


func _request_weapon(w: int) -> void:
	if is_host or not has_net():
		_apply_weapon(my_id(), w)
		_broadcast_players()
	else:
		rpc_id(1, "srv_set_weapon", w)


func _request_vtype(vtype: int) -> void:
	if in_match:
		return
	if is_host or not has_net():
		_apply_vtype(my_id(), vtype)
		_broadcast_players()
	else:
		rpc_id(1, "srv_set_vtype", vtype)


func _broadcast_players() -> void:
	if has_net():
		rpc("cli_sync_players", players)
	cli_sync_players(players)


@rpc("authority", "reliable")
func cli_sync_players(data: Dictionary) -> void:
	players = data
	_refresh_roster()
	_refresh_vtype_buttons()
	refresh_hangar_plane()      # 停機棚裡展示的就是你現在選的機種


func _count_team(team: int, humans_only: bool) -> int:
	var n := 0
	for id in players:
		if players[id]["team"] != team:
			continue
		if humans_only and players[id]["bot"]:
			continue
		n += 1
	return n


func my_id() -> int:
	if not has_net():
		return 1
	return multiplayer.get_unique_id()


func my_team() -> int:
	var id := my_id()
	return int(players[id]["team"]) if players.has(id) else TEAM_ATTACKER


func _refresh_roster() -> void:
	for team in _roster.keys():
		var vb: VBoxContainer = _roster[team]
		for c in vb.get_children():
			c.queue_free()
		var ids := players.keys()
		ids.sort()
		for id in ids:
			if players[id]["team"] != team:
				continue
			var p: Dictionary = players[id]
			var tag := "  [AI]" if p["bot"] else ("  ★" if int(id) == my_id() else "")
			var l := _mk_label("  %s%s  ─  %s" % [p["name"], tag, VTYPE_NAME[p["vtype"]]], 13,
				C_DIM if p["bot"] else C_TEXT)
			vb.add_child(l)

	for e in _team_btn_list:
		var team: int = e["team"]
		var b: Button = e["btn"]
		var sel := (my_team() == team)
		b.text = "%s%s  (%d)" % ["● " if sel else "", TEAM_NAME[team], _count_team(team, false)]
		b.add_theme_color_override("font_color",
			Color.WHITE if sel else (C_ATK if team == TEAM_ATTACKER else C_DEF))
	_refresh_top_info()


func _refresh_vtype_buttons() -> void:
	var team := my_team()
	var cur: int = int(players[my_id()]["vtype"]) if players.has(my_id()) else -1
	for box in _vtype_boxes:
		var hb: HBoxContainer = box
		for c in hb.get_children():
			c.queue_free()
		for vt in TEAM_VTYPES[team]:
			var accent: Color = VSTATS[vt]["color"]
			var sel: bool = (int(vt) == cur)
			var b := _mk_button(("● " if sel else "") + String(VTYPE_NAME[vt]), Color.WHITE if sel else accent)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.pressed.connect(func(): _request_vtype(vt))
			hb.add_child(b)
	_refresh_weapon_buttons()


func _refresh_difficulty() -> void:
	for e in _diff_btns:
		var b: Button = e["btn"]
		var d: int = e["diff"]
		var info: Dictionary = DIFF[d]
		var sel := (d == difficulty)
		b.text = "%s%s\n%s" % ["● " if sel else "", info["name"], info["en"]]
		b.add_theme_color_override("font_color", Color.WHITE if sel else Color(1.0, 0.85, 0.35))
	_refresh_top_info()


func _refresh_tod() -> void:
	for e in _tod_btns:
		var b: Button = e["btn"]
		var t: int = e["tod"]
		var sel := (t == time_of_day)
		b.text = "%s%s" % ["● " if sel else "", TOD_NAME[t]["name"]]
		b.add_theme_color_override("font_color", Color.WHITE if sel else Color(0.65, 0.80, 1.00))
	_refresh_top_info()


func _refresh_mode_btn() -> void:
	if _mode_check == null:
		return
	var web := (net_mode == NetMode.WEBRTC)
	_mode_check.text = "網路模式：%s" % ("☑ WebRTC（網頁）" if web else "☐ ENet（本機測試）")
	_mode_check.add_theme_color_override("font_color", C_DEF if web else C_DIM)


func _refresh_top_info() -> void:
	if _top_info == null:
		return
	var parts: Array = []
	if _cur_screen == Screen.SOLO or solo_mode:
		parts.append("難度 %s" % DIFF[difficulty]["name"])
	parts.append("時段 %s" % TOD_NAME[time_of_day]["name"])
	if room_code != "":
		parts.append("房號 %s" % room_code)
	parts.append("陣營 %s" % TEAM_NAME[my_team()])
	_top_info.text = "　│　".join(parts)


#══════════════════════════════════════════════════════════════════════════════
#  AI 補齊 & 開賽
#══════════════════════════════════════════════════════════════════════════════
## 檢查兩隊真人數量，不足 MIN_PER_TEAM 就補上 AI 隊友。
## 真人已經滿 MIN_PER_TEAM 的隊伍不會生成任何 AI。
func spawn_bots_if_needed() -> void:
	# 先清掉上一局殘留的 bot
	for id in players.keys():
		if players[id]["bot"]:
			players.erase(id)

	for team in [TEAM_ATTACKER, TEAM_DEFENDER]:
		var humans := _count_team(team, true)
		if humans >= bots_per_team:
			continue
		var need := bots_per_team - humans
		for i in need:
			_next_bot_id -= 1
			var bid := _next_bot_id
			var vt: int = _bot_vtype(team, i)
			players[bid] = _new_player_entry("BOT-%s-%d" % ["ATK" if team == TEAM_ATTACKER else "DEF", i + 1], team, vt, true)
		print("[BOT] %s 補齊 %d 架 AI（真人 %d 名）" % [TEAM_NAME[team], need, humans])


## AI 的機種編成。改成 5v5 之後不能再用「index == 0 就是轟炸機」這種寫法：
## 五架裡只有一架轟炸機，而轟炸機是唯一能有效拆設施的機種，進攻方會完全打不動目標。
## 表格的前三筆刻意跟舊版 3v3 的編成完全一致，人數再往上加就循環取用。
const BOT_LINEUP := {
	TEAM_ATTACKER: [VType.BOMBER, VType.FIGHTER, VType.FIGHTER, VType.BOMBER, VType.FIGHTER],
	TEAM_DEFENDER: [VType.INTERCEPTOR, VType.INTERCEPTOR, VType.HELI, VType.INTERCEPTOR, VType.FIGHTER],
}


func _bot_vtype(team: int, index: int) -> int:
	var lineup: Array = BOT_LINEUP[team]
	return int(lineup[index % lineup.size()])


## 單人打電腦：完全不建立任何網路連線，本機同時扮演房主
func start_solo_game() -> void:
	if in_match:
		return
	solo_mode = true
	is_host = true
	room_code = ""

	# 只留自己一個真人，其餘缺額交給 spawn_bots_if_needed()
	var me := my_id()
	for id in players.keys():
		if int(id) != me:
			players.erase(id)
	if not players.has(me):
		players[me] = _new_player_entry(_local_name, TEAM_ATTACKER, VType.FIGHTER, false)
	players[me]["name"] = _local_name

	add_chat_line("[系統] 單人作戰開始 ─ 難度 %s，敵我雙方缺額由 AI 補齊。"
		% DIFF[difficulty]["name"], C_DIM)
	start_match()


func _return_to_menu() -> void:
	in_match = false
	if world:
		world.queue_free()
		world = null
	# 練習場結束就恢復正常設定
	tutorial_mode = false
	bots_per_team = MIN_PER_TEAM
	if solo_mode:
		solo_mode = false
		is_host = false
		for id in players.keys():
			if players[id]["bot"]:
				players.erase(id)
	_lobby.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_build_hangar()             # 回到主選單就把停機棚蓋回來
	_show_screen(Screen.MENU)
	_refresh_roster()
	_refresh_vtype_buttons()
	_refresh_account_lbl()


func start_match() -> void:
	if not is_host or in_match:
		return
	spawn_bots_if_needed()
	_broadcast_players()

	# 開局抽地圖；每局換一次地形種子，同一張地圖也不會長得一模一樣
	map_id = map_choice if map_choice >= 0 else MAP_INFO.keys()[randi() % MAP_INFO.size()]
	map_seed = randi()
	# 自動化測試要能固定地形，否則每一局的山長得都不一樣，撞山次數沒辦法前後對照
	var forced_seed := OS.get_environment("AUTOPLAY_SEED").strip_edges()
	if forced_seed != "" and forced_seed.is_valid_int():
		map_seed = int(forced_seed)
	weather = weather_choice if weather_choice >= 0 else WX_INFO.keys()[randi() % WX_INFO.size()]

	# 房主的設定要一起送出，否則各端的地形、天空與 AI 強度會不一致
	var settings := {
		"tod": time_of_day, "diff": difficulty,
		"map": map_id, "seed": map_seed, "wx": weather,
	}
	if has_net():
		rpc("cli_start_match", players, settings)
	cli_start_match(players, settings)


@rpc("authority", "reliable")
func cli_start_match(data: Dictionary, settings: Dictionary) -> void:
	players = data
	time_of_day = int(settings.get("tod", TOD_DAY))
	difficulty = int(settings.get("diff", DIFF_NORMAL))
	map_id = int(settings.get("map", MAP_CANYON))
	map_seed = int(settings.get("seed", 20260726))
	weather = int(settings.get("wx", WX_CLEAR))
	in_match = true
	_lobby.visible = false
	# 開賽前把 UI 焦點放掉：留在呼號欄或某顆按鈕上的焦點會把鍵盤事件吃掉，
	# 而且打字會直接跑進那個欄位。
	if _chat_input != null:
		_close_chat_input()
	if _name_edit != null:
		_name_edit.release_focus()
	get_viewport().gui_release_focus()
	if _join_dlg != null:
		_join_dlg.close()
	# 停機棚自帶 WorldEnvironment 與 Camera3D，開賽前一定要整個釋放，
	# 否則會跟戰場的環境與鏡頭互搶。
	_free_hangar()
	if world:
		world.queue_free()
	var world_script := load("res://GameWorld.gd")
	world = world_script.new()
	world.name = "GameWorld"     # 名稱必須一致，RPC 才能對上 NodePath
	add_child(world)
	add_chat_line("[系統] 作戰開始！地圖：%s %s ─ %s"
		% [MAP_INFO[map_id]["name"], MAP_INFO[map_id]["en"], MAP_INFO[map_id]["desc"]],
		Color(0.4, 1.0, 0.6))


func end_match(winner_team: int, reason: String) -> void:
	in_match = false
	# 戰績寫回帳號
	if not account.is_empty():
		account["matches"] = int(account.get("matches", 0)) + 1
		if winner_team == my_team():
			account["wins"] = int(account.get("wins", 0)) + 1
		save_profile()
		_refresh_account_lbl()
	add_chat_line("[系統] %s 獲勝 ─ %s" % [TEAM_NAME[winner_team], reason],
		C_ATK if winner_team == TEAM_ATTACKER else C_DEF)
	await get_tree().create_timer(7.0).timeout
	_return_to_menu()


#══════════════════════════════════════════════════════════════════════════════
#  聊天 & 無線電
#══════════════════════════════════════════════════════════════════════════════
## 聊天框是不是真的在打字（可見「而且」有焦點）。
## 只看 visible 會出事：按了 T 之後點一下遊戲畫面，欄位會留在畫面上但沒有焦點，
## 飛行輸入就被當成「正在打字」全部忽略 ─ 鍵盤等於整個失靈。
func is_typing() -> bool:
	return _chat_input != null and _chat_input.visible and _chat_input.has_focus()


## 鍵盤事件一律用 physical_keycode 判斷：
## InputMap 註冊的是實體鍵位，這裡若改用 keycode，換成非 QWERTY 或中文輸入法時
## T 與 1~4 會對不上。
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key: int = (event as InputEventKey).physical_keycode
	if key == 0:
		key = (event as InputEventKey).keycode

	if _chat_input.visible:
		if key == KEY_ESCAPE:
			_close_chat_input()
			get_viewport().set_input_as_handled()
		return

	if key == KEY_T:
		_open_chat_input()
		get_viewport().set_input_as_handled()
		return

	if not in_match:
		return

	for i in 4:
		if key == KEY_F1 + i:
			send_radio(i)
			get_viewport().set_input_as_handled()
			return


## 視窗失去焦點時把所有按鍵狀態清掉，否則切出去再切回來，
## 引擎會記得「還按著」，飛機會自己一直轉。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		for action in _actions:
			if InputMap.has_action(action):
				Input.action_release(action)
		if _chat_input != null and _chat_input.visible:
			_close_chat_input()


func _open_chat_input() -> void:
	_chat_scope = SCOPE_TEAM
	_chat_scope_lbl.text = "→ %s 頻道" % TEAM_NAME[my_team()]
	_chat_input.visible = true
	_chat_input.text = ""
	_chat_input.grab_focus()


func _close_chat_input() -> void:
	if not _chat_input.visible:
		return                     # 防止 focus_exited 與這裡互相遞迴
	_chat_input.visible = false
	_chat_input.release_focus()
	_chat_scope_lbl.text = ""


## 專屬外掛：在聊天框輸入這組密碼後按 Enter，訊息不會送出去，
## 改成把自機交給電腦駕駛（再輸入一次關掉）。
const CHEAT_AUTOPILOT := "120514"


func _on_chat_submitted(text: String) -> void:
	text = text.strip_edges()
	_close_chat_input()
	if text.is_empty():
		return

	# 完全不留痕跡：不寫聊天紀錄、不跳提示、HUD 也不顯示，
	# 訊息本身當然也不會送出去。旁邊的人看不出來你開了外掛。
	if text == CHEAT_AUTOPILOT:
		if world != null and world.has_method("toggle_autopilot"):
			world.toggle_autopilot()
		return
	var scope := SCOPE_TEAM
	if text.begins_with("/all "):
		scope = SCOPE_ALL
		text = text.substr(5)
	if has_net():
		rpc("net_chat", my_id(), text, scope)
	net_chat(my_id(), text, scope)


## 只有同隊玩家會看到 SCOPE_TEAM 的訊息（在接收端過濾）
@rpc("any_peer", "reliable")
func net_chat(sender_id: int, msg: String, scope: int) -> void:
	var sender_name := "系統"
	var sender_team := -1
	if players.has(sender_id):
		sender_name = players[sender_id]["name"]
		sender_team = players[sender_id]["team"]

	if scope == SCOPE_TEAM and sender_team >= 0 and sender_team != my_team():
		return   # 不同隊 → 直接丟棄，UI 不顯示

	var col := C_TEXT
	var prefix := ""
	if sender_team == TEAM_ATTACKER:
		col = C_ATK
	elif sender_team == TEAM_DEFENDER:
		col = C_DEF
	if scope == SCOPE_ALL:
		prefix = "[全場] "
	elif sender_team >= 0:
		prefix = "[隊伍] "
	add_chat_line("%s%s：%s" % [prefix, sender_name, msg], col)


## 送出快捷無線電（0~3 對應鍵 1~4）
func send_radio(idx: int) -> void:
	if idx < 0 or idx >= RADIO_LINES.size():
		return
	if has_net():
		rpc("net_radio", my_id(), idx)
	net_radio(my_id(), idx)


@rpc("any_peer", "reliable")
func net_radio(sender_id: int, idx: int) -> void:
	if idx < 0 or idx >= RADIO_LINES.size():
		return
	var scope: int = RADIO_SCOPE[idx]
	var sender_team := -1
	var sender_name := "未知"
	if players.has(sender_id):
		sender_team = players[sender_id]["team"]
		sender_name = players[sender_id]["name"]

	# 遊戲世界永遠收到訊號（AI 判斷、3D 標記），UI 才做頻道過濾
	if world and world.has_method("on_radio"):
		world.on_radio(sender_id, sender_team, idx)

	if scope == SCOPE_TEAM and sender_team >= 0 and sender_team != my_team():
		return

	var tag := "[全場廣播]" if scope == SCOPE_ALL else "[無線電]"
	var col := Color(1.0, 0.92, 0.45)
	add_chat_line("%s %s：%s" % [tag, sender_name, RADIO_LINES[idx]], col)


func add_chat_line(text: String, col: Color = C_TEXT) -> void:
	if _chat_log == null:
		print(text)
		return
	_chat_log.append_text("[color=#%s]%s[/color]\n" % [col.to_html(false), text])
	# 保留最近 60 行
	var lines := _chat_log.get_parsed_text().split("\n")
	if lines.size() > 60:
		_chat_log.clear()
