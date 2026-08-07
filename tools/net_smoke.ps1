# ─────────────────────────────────────────────────────────────────────────────
#  連線煙霧測試驅動腳本
#
#  開兩個 headless Godot 實例（房主 + 客戶端），跑 NetSmoke.gd 裡的情境並比對結果。
#  兩邊給不同的 APPDATA，user:// 才會分開，帳號檔不會互相蓋掉。
#
#    powershell -File tools\net_smoke.ps1                    # 跑全部三個情境
#    powershell -File tools\net_smoke.ps1 -Scenario happy    # 只跑一個
#    powershell -File tools\net_smoke.ps1 -Godot "D:\Godot_v4.7-stable_win64_console.exe"
#
#  離開碼：0 = 全部通過，1 = 有情境失敗。
# ─────────────────────────────────────────────────────────────────────────────
param(
	[ValidateSet('all', 'happy', 'powers', 'kick', 'badpass', 'latejoin')]
	[string]$Scenario = 'all',

	[string]$Godot = "$env:USERPROFILE\Desktop\Godot_v4.7-stable_win64_console.exe",

	# 單一情境的上限秒數，超過就強制砍掉並判失敗。
	# happy 會一路等到戰鬥階段（簡報 42s + 部署 30s）才數機體，所以要留夠。
	[int]$TimeoutSec = 240,

	# 客戶端延後幾秒才加入，讓房主先把 ENet 伺服器開起來
	[int]$JoinDelay = 4
)

$ErrorActionPreference = 'Stop'
# Godot 印中文；不設這個 console 會吐亂碼
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ProjectDir = Split-Path -Parent $PSScriptRoot
$OutDir     = Join-Path $ProjectDir 'tools\.smoke'

if (-not (Test-Path $Godot)) {
	Write-Host "找不到 Godot 執行檔：$Godot" -ForegroundColor Red
	Write-Host "用 -Godot 指定路徑，例如 -Godot 'C:\Godot\Godot_v4.7-stable_win64_console.exe'"
	exit 1
}
if (-not (Test-Path (Join-Path $ProjectDir 'NetSmoke.gd'))) {
	Write-Host "$ProjectDir 裡找不到 NetSmoke.gd" -ForegroundColor Red
	exit 1
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# 每個情境用不同房號，埠號 = 10000 + 房號，避免前一輪殘留的 socket 打架
$Rooms = @{ happy = '4242'; badpass = '4343'; latejoin = '4444'; powers = '4545'; kick = '4646' }

$OrigAppData = $env:APPDATA


function Start-Instance {
	param(
		[string]$Role,
		[string]$Name,
		[hashtable]$EnvVars,
		[string]$LogPath
	)

	# user:// 走 APPDATA，兩個實例必須分開
	$userDir = Join-Path $OutDir "userdata-$Name"
	New-Item -ItemType Directory -Force -Path $userDir | Out-Null
	$env:APPDATA = $userDir

	foreach ($k in $EnvVars.Keys) {
		Set-Item -Path "env:$k" -Value $EnvVars[$k]
	}

	$gargs = @('--headless', '--path', "`"$ProjectDir`"")
	$p = Start-Process -FilePath $Godot -ArgumentList $gargs -PassThru -NoNewWindow `
		-RedirectStandardOutput $LogPath -RedirectStandardError "$LogPath.err"

	# 先碰一下 Handle，.NET 才會保留 process handle；
	# 少了這行，之後讀 $p.ExitCode 會是空的（Start-Process -PassThru 的老問題）。
	$null = $p.Handle

	# 清掉，免得洩漏到下一個實例
	foreach ($k in $EnvVars.Keys) { Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue }
	$env:APPDATA = $OrigAppData

	return $p
}


function Stop-IfAlive {
	param($Proc)
	if ($Proc -ne $null -and -not $Proc.HasExited) {
		try { $Proc.Kill() } catch {}
	}
}


# Godot 的 log 是 UTF-8；PowerShell 5.1 的 Get-Content 預設用 ANSI，中文會變亂碼
function Read-Utf8 {
	param([string]$Path)
	if (-not (Test-Path $Path)) { return @() }
	$enc = New-Object System.Text.UTF8Encoding($false)
	return [System.IO.File]::ReadAllLines($Path, $enc)
}


function Show-SmokeLines {
	param([string]$Label, [string]$LogPath, [string]$ErrPath)

	Write-Host ""
	Write-Host "── $Label " -ForegroundColor Cyan -NoNewline
	Write-Host ("─" * [Math]::Max(1, 60 - $Label.Length)) -ForegroundColor DarkGray

	if (Test-Path $LogPath) {
		foreach ($line in (Read-Utf8 $LogPath)) {
			if ($line -like '*[SMOKE]*') {
				$color = 'Gray'
				if ($line -like '*PASS*')   { $color = 'Green' }
				if ($line -like '*FAIL*')   { $color = 'Red' }
				if ($line -like '*RESULT*') { $color = 'Yellow' }
				Write-Host "   $line" -ForegroundColor $color
			}
		}
	}

	# 引擎錯誤：連線改壞最常見的症狀就是 RPC 找不到節點
	$engineErrors = @()
	foreach ($f in @($LogPath, $ErrPath)) {
		$engineErrors += Read-Utf8 $f | Where-Object {
			$_ -match 'Node not found' -or $_ -match 'SCRIPT ERROR' -or $_ -match 'ERROR:'
		}
	}
	if ($engineErrors.Count -gt 0) {
		Write-Host "   引擎錯誤 $($engineErrors.Count) 行（前 5 行）：" -ForegroundColor Red
		foreach ($e in ($engineErrors | Select-Object -First 5)) {
			Write-Host "     $e" -ForegroundColor DarkRed
		}
	}
	return $engineErrors.Count
}


function Get-SettingsLine {
	param([string]$LogPath)
	if (-not (Test-Path $LogPath)) { return '' }
	$m = Read-Utf8 $LogPath | Where-Object { $_ -like '*[SMOKE]*SETTINGS*' } | Select-Object -First 1
	if ($null -eq $m) { return '' }
	# 只留 "map=... seed=..." 那一段，兩端拿來對拍
	$idx = $m.IndexOf('SETTINGS')
	return $m.Substring($idx)
}


function Invoke-Scenario {
	param([string]$Name)

	$room = $Rooms[$Name]
	$pass = 'ALPHA7'
	$joinPass = $pass
	if ($Name -eq 'badpass') { $joinPass = 'WRONG9' }

	Write-Host ""
	Write-Host "══ 情境 $Name（房號 $room / 埠 $((10000 + [int]$room))）" -ForegroundColor White

	$hostLog = Join-Path $OutDir "$Name-host.log"
	$cliLog  = Join-Path $OutDir "$Name-client.log"
	foreach ($f in @($hostLog, "$hostLog.err", $cliLog, "$cliLog.err")) {
		if (Test-Path $f) { Remove-Item $f -Force }
	}

	$hostProc = $null
	$cliProc  = $null
	$ok = $false

	try {
		$hostProc = Start-Instance -Role 'host' -Name "$Name-host" -LogPath $hostLog -EnvVars @{
			NETSMOKE          = 'host'
			NETSMOKE_SCENARIO = $Name
			NETSMOKE_ROOM     = $room
			NETSMOKE_PASS     = $pass
			NETSMOKE_DELAY    = "$JoinDelay"
		}

		$cliProc = Start-Instance -Role 'client' -Name "$Name-client" -LogPath $cliLog -EnvVars @{
			NETSMOKE          = 'client'
			NETSMOKE_SCENARIO = $Name
			NETSMOKE_ROOM     = $room
			NETSMOKE_JOINPASS = $joinPass
			NETSMOKE_DELAY    = "$JoinDelay"
		}

		$deadline = $TimeoutSec * 1000
		$hostDone = $hostProc.WaitForExit($deadline)
		$cliDone  = $cliProc.WaitForExit($deadline)

		if (-not $hostDone) { Write-Host "   房主逾時（>$TimeoutSec 秒）未結束" -ForegroundColor Red }
		if (-not $cliDone)  { Write-Host "   客戶端逾時（>$TimeoutSec 秒）未結束" -ForegroundColor Red }

		Stop-IfAlive $hostProc
		Stop-IfAlive $cliProc

		$hostErrs = Show-SmokeLines -Label "$Name / HOST"   -LogPath $hostLog -ErrPath "$hostLog.err"
		$cliErrs  = Show-SmokeLines -Label "$Name / CLIENT" -LogPath $cliLog  -ErrPath "$cliLog.err"

		$hostCode = if ($hostDone) { $hostProc.ExitCode } else { 999 }
		$cliCode  = if ($cliDone)  { $cliProc.ExitCode }  else { 999 }

		Write-Host ""
		Write-Host "   exit code：host=$hostCode client=$cliCode　引擎錯誤：host=$hostErrs client=$cliErrs" -ForegroundColor DarkGray

		$ok = ($hostCode -eq 0) -and ($cliCode -eq 0) -and ($hostErrs -eq 0) -and ($cliErrs -eq 0)

		# 有開賽的情境要額外對拍：兩端的地圖／種子／天氣必須一模一樣，否則地形會長不一樣
		if ($Name -eq 'happy' -or $Name -eq 'powers') {
			$hs = Get-SettingsLine $hostLog
			$cs = Get-SettingsLine $cliLog
			Write-Host ""
			if ($hs -ne '' -and $hs -eq $cs) {
				Write-Host "   PASS  兩端開賽設定一致：$hs" -ForegroundColor Green
			} else {
				Write-Host "   FAIL  兩端開賽設定不一致" -ForegroundColor Red
				Write-Host "         host  : $hs" -ForegroundColor DarkRed
				Write-Host "         client: $cs" -ForegroundColor DarkRed
				$ok = $false
			}
		}
	}
	finally {
		Stop-IfAlive $hostProc
		Stop-IfAlive $cliProc
		$env:APPDATA = $OrigAppData
	}

	return $ok
}


# ── 主流程 ────────────────────────────────────────────────────────────────────
$targets = @()
if ($Scenario -eq 'all') { $targets = @('happy', 'powers', 'kick', 'badpass', 'latejoin') }
else { $targets = @($Scenario) }

Write-Host "Godot   : $Godot"
Write-Host "專案    : $ProjectDir"
Write-Host "log 輸出: $OutDir"

$results = @{}
foreach ($s in $targets) {
	$results[$s] = Invoke-Scenario -Name $s
}

Write-Host ""
Write-Host "══════════ 總結 ══════════" -ForegroundColor White
$allOk = $true
foreach ($s in $targets) {
	if ($results[$s]) {
		Write-Host ("  {0,-10} PASS" -f $s) -ForegroundColor Green
	} else {
		Write-Host ("  {0,-10} FAIL" -f $s) -ForegroundColor Red
		$allOk = $false
	}
}
Write-Host ""

if ($allOk) { exit 0 } else { exit 1 }
