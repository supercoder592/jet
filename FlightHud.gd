extends Control
#══════════════════════════════════════════════════════════════════════════════
#  FlightHud.gd ─ 飛行視覺回饋層（純繪製，不吃輸入）
#
#  轉向一律用鍵盤（W/S 俯仰、A/D 偏航、Z/C 滾轉），這一層只負責畫：
#    ‧ 後燃器加速時的放射狀速度線
#    ‧ 畫面上緣的滾轉刻度尺與指標
#    ‧ 準星周圍的鎖定進度環
#    ‧ 加速時畫面邊緣的熱暈
#
#  註：刻意不宣告 class_name，由 GameWorld 以 load() 動態載入。
#══════════════════════════════════════════════════════════════════════════════

var enabled: bool = true
var boost: float = 0.0        # 0~1 加速強度
var boost_fuel: float = 1.0
var speed_norm: float = 0.0   # 目前速度 / 最高速
var roll_angle: float = 0.0   # 機體滾轉角（弧度）
var locked: bool = false      # 是否已完成鎖定
var lock_progress: float = 0.0
var _t: float = 0.0


func setup() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 由 GameWorld 每個 physics frame 呼叫，推進動畫時間
func tick(delta: float) -> void:
	_t += delta


func _draw() -> void:
	if not enabled:
		return
	var vp := size
	var c := vp * 0.5

	# ── 速度線：加速時從畫面邊緣往中心刷過 ──
	var intensity: float = clampf(boost + maxf(0.0, speed_norm - 0.72) * 1.6, 0.0, 1.6)
	if intensity > 0.02:
		var n := 44
		var r_out: float = vp.length() * 0.55
		for i in n:
			# 角度固定（由 index 決定），長度隨時間變化 → 看起來是往後刷
			var a := TAU * (float(i) / float(n)) + float(i % 7) * 0.11
			var phase := fmod(_t * 2.6 + float(i) * 0.37, 1.0)
			var near: float = lerpf(r_out * 0.22, r_out * 0.72, phase)
			var far: float = near + r_out * (0.16 + 0.22 * intensity)
			var dir := Vector2(cos(a), sin(a))
			var alpha: float = (1.0 - phase) * 0.55 * minf(1.0, intensity)
			draw_line(c + dir * near, c + dir * far,
				Color(0.75, 0.90, 1.0, alpha), 1.0 + 1.6 * intensity)

	# ── 鎖定進度環：畫在準星外圈 ──
	if lock_progress > 0.02 and not locked:
		draw_arc(c, 34.0, -PI * 0.5, -PI * 0.5 + TAU * lock_progress, 32,
			Color(1.0, 0.82, 0.30, 0.9), 3.0)
	elif locked:
		draw_arc(c, 34.0, 0, TAU, 32, Color(1.0, 0.35, 0.35, 0.8), 2.0)
		draw_arc(c, 40.0, 0, TAU, 32, Color(1.0, 0.35, 0.35, 0.35), 1.0)

	# ── 滾轉刻度尺：放在計時器與基地血條下面，不要跟它們疊在一起 ──
	var top := Vector2(c.x, 196.0)
	var rr := 74.0
	draw_arc(top, rr, PI * 1.18, PI * 1.82, 40, Color(0.55, 0.85, 1.0, 0.30), 1.5)
	for deg in [-60, -45, -30, -15, 0, 15, 30, 45, 60]:
		var a2 := -PI * 0.5 + deg_to_rad(float(deg))
		var d2 := Vector2(sin(a2), -cos(a2))
		var len_t: float = 10.0 if deg % 30 == 0 else 5.0
		draw_line(top + d2 * rr, top + d2 * (rr + len_t), Color(0.55, 0.85, 1.0, 0.45), 1.5)
	# 目前滾轉的指標三角
	var ra: float = clampf(-roll_angle, -PI * 0.55, PI * 0.55)
	var rd := Vector2(sin(ra), -cos(ra))
	var tip := top + rd * (rr - 4.0)
	var perp := Vector2(-rd.y, rd.x)
	draw_colored_polygon(PackedVector2Array([
		tip, tip - rd * 11.0 + perp * 6.0, tip - rd * 11.0 - perp * 6.0]),
		Color(1.0, 0.85, 0.35, 0.9))

	# ── 加速中的畫面邊緣熱暈 ──
	if boost > 0.05:
		var a3: float = boost * 0.13
		var band := 46.0
		draw_rect(Rect2(Vector2.ZERO, Vector2(vp.x, band)), Color(1.0, 0.55, 0.2, a3))
		draw_rect(Rect2(Vector2(0, vp.y - band), Vector2(vp.x, band)), Color(1.0, 0.55, 0.2, a3))
		draw_rect(Rect2(Vector2.ZERO, Vector2(band, vp.y)), Color(1.0, 0.55, 0.2, a3))
		draw_rect(Rect2(Vector2(vp.x - band, 0), Vector2(band, vp.y)), Color(1.0, 0.55, 0.2, a3))
