# ─────────────────────────────────────────────────────────────────────────────
#  航母進場航道淨空檢查
#
#  每張地圖各開一個 headless 實例，掃描高度圖上航母與護航艦會經過的那條航道。
#  只要掃到地形就代表航母／艦群會穿山，該地圖判 FAIL。
#
#    powershell -File tools\check_lane.ps1
# ─────────────────────────────────────────────────────────────────────────────
param(
	[string]$Godot = "$env:USERPROFILE\Desktop\Godot_v4.7-stable_win64_console.exe",
	[int]$TimeoutSec = 90
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ProjectDir = Split-Path -Parent $PSScriptRoot
$OutDir     = Join-Path $ProjectDir 'tools\.lane'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$MAPS = @(
	@{ id = 0; name = '峽谷' }, @{ id = 1; name = '平原' },
	@{ id = 2; name = '高原' }, @{ id = 3; name = '橫斷山脈' },
	@{ id = 4; name = '高山' }, @{ id = 5; name = '黃土丘陵' },
	@{ id = 6; name = '大堤頓峽谷' }, @{ id = 7; name = '濱海都會' }
)

function Read-Utf8 {
	param([string]$Path)
	if (-not (Test-Path $Path)) { return @() }
	$enc = New-Object System.Text.UTF8Encoding($false)
	return [System.IO.File]::ReadAllLines($Path, $enc)
}

$OrigAppData = $env:APPDATA
$userDir = Join-Path $OutDir 'userdata'
New-Item -ItemType Directory -Force -Path $userDir | Out-Null

$fails = @()
foreach ($m in $MAPS) {
	$log = Join-Path $OutDir ("map{0}.log" -f $m.id)
	if (Test-Path $log) { Remove-Item $log -Force }

	$env:APPDATA        = $userDir
	$env:AUTOPLAY       = '1'
	$env:AUTOPLAY_CHECK = 'lane'
	$env:AUTOPLAY_MAP   = "$($m.id)"
	$env:AUTOPLAY_SHOTS = ''

	$p = Start-Process -FilePath $Godot `
		-ArgumentList @('--headless', '--path', "`"$ProjectDir`"") `
		-PassThru -NoNewWindow -RedirectStandardOutput $log -RedirectStandardError "$log.err"
	$null = $p.Handle

	Remove-Item env:AUTOPLAY, env:AUTOPLAY_CHECK, env:AUTOPLAY_MAP, env:AUTOPLAY_SHOTS -ErrorAction SilentlyContinue
	$env:APPDATA = $OrigAppData

	$done = $p.WaitForExit($TimeoutSec * 1000)
	if (-not $done) { try { $p.Kill() } catch {} }

	$line = Read-Utf8 $log | Where-Object { $_ -like '*航道掃描*' } | Select-Object -First 1
	$ok = ($done -and $p.ExitCode -eq 0)
	if ($ok) {
		Write-Host ("  {0,-12} PASS  {1}" -f $m.name, $line) -ForegroundColor Green
	} else {
		Write-Host ("  {0,-12} FAIL  {1}" -f $m.name, $line) -ForegroundColor Red
		$fails += $m.name
	}
}

Write-Host ""
if ($fails.Count -eq 0) {
	Write-Host "全部地圖的航母進場航道都是淨空的。" -ForegroundColor Green
	exit 0
}
Write-Host ("這些地圖的航道被地形擋住：" + ($fails -join '、')) -ForegroundColor Red
exit 1
