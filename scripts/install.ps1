<#
.SYNOPSIS
  dsh-suite 一键安装（Windows PowerShell）。macOS/Linux 用 scripts/install.sh（同一套逻辑）。

.DESCRIPTION
  把仓库里的插件复制进 DeepSeek Harness 的 profile，补齐运行依赖，写 cordis 配置块，
  然后逐项校验；任何一项不过都以非零码退出。安装前自动备份，回滚用 scripts/rollback.ps1。

.PARAMETER OnlyGateway
  只装移动网关（最小组合：手机能聊天/看会话）。

.PARAMETER OnlyDsBot
  只装 ds-bot fork（桌面 Bot 团队增强：团队实时状态、群聊卡片）。

.PARAMETER VerifyOnly
  只校验已安装结果，不改任何文件（排障用）。

.PARAMETER DryRun
  只打印将要做什么，不落盘。

.PARAMETER Profile
  DSH profile 名，默认 desktop（不存在则取第一个）。

.PARAMETER DshHome
  DSH 数据目录，默认 %USERPROFILE%\.dsh。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1 -OnlyGateway

.NOTES
  退出码：0 成功；1 预检失败；2 安装/复制失败；3 校验失败；4 环境/参数不支持。
#>
param(
  [switch]$OnlyGateway,
  [switch]$OnlyDsBot,
  [switch]$VerifyOnly,
  [switch]$DryRun,
  [string]$Profile = "",
  [string]$DshHome = "",
  [switch]$Help
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$GatewayName = "dsh-plugin-mobile-gateway"
$DsBotName = "ds-bot"
$GatewayDeps = @("ws", "qrcode", "@deepseek-ai/schemastery")

function Say($msg) { Write-Host $msg }
function Ok($msg) { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Warn2($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Die($code, $msg) { Write-Host "❌ $msg" -ForegroundColor Red; exit $code }

if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }
if ($OnlyGateway -and $OnlyDsBot) { Die 4 "-OnlyGateway 与 -OnlyDsBot 不能同时用" }

$WantGateway = -not $OnlyDsBot
$WantDsBot = -not $OnlyGateway

if ([string]::IsNullOrWhiteSpace($DshHome)) {
  $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }
}

# ---------- 1. 预检 ----------
Say "== 1/5 预检 =="
if (-not (Test-Path "$RepoRoot\plugins")) { Die 1 "找不到 plugins 目录，请在仓库根目录运行（当前：$RepoRoot）" }

if ($WantGateway -and -not (Test-Path "$RepoRoot\plugins\$GatewayName\lib\index.mjs")) {
  Die 1 "仓库缺少 plugins\$GatewayName\lib\index.mjs（仓库不完整，请重新 clone）"
}
if ($WantDsBot -and -not (Test-Path "$RepoRoot\plugins\$DsBotName\index.js")) {
  Die 1 "仓库缺少 plugins\$DsBotName\index.js（仓库不完整，请重新 clone）"
}
if (-not (Test-Path "$DshHome\profiles")) {
  Die 1 "找不到 DSH 数据目录：$DshHome\profiles。请确认已安装 DeepSeek Harness（≥0.2.1-rc.1），或用 -DshHome 指定"
}

if ([string]::IsNullOrWhiteSpace($Profile)) {
  if (Test-Path "$DshHome\profiles\desktop") { $Profile = "desktop" }
  else {
    $first = Get-ChildItem "$DshHome\profiles" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($first) { $Profile = $first.Name }
  }
}
if ([string]::IsNullOrWhiteSpace($Profile)) { Die 1 "$DshHome\profiles 下没有任何 profile，请先在 DeepSeek Harness 里建一个" }

$ProfileDir = Join-Path $DshHome "profiles/$Profile"
if (-not (Test-Path $ProfileDir)) { Die 1 "profile 不存在：$ProfileDir" }
if (-not (Test-Path "$ProfileDir\package.json")) { Die 2 "profile 里没有 package.json：$ProfileDir（这个 profile 可能没初始化过）" }
$Modules = Join-Path $ProfileDir "node_modules"
if (-not (Test-Path $Modules)) { Die 2 "profile 里没有 node_modules：$Modules（请先启动一次 DeepSeek Harness，让它自己初始化）" }
Ok "DSH 数据目录：$DshHome"
Ok "目标 profile：$Profile（$ProfileDir）"

# ---------- 2. 备份 ----------
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupDir = Join-Path $ProfileDir "backups/dsh-suite-$Stamp"
Say ""
Say "== 2/5 备份 =="
if ($DryRun) {
  Say "  (dry-run) 将备份到：$BackupDir"
} elseif (-not $VerifyOnly) {
  New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
  foreach ($f in @("package.json", "cordis.patch.yml")) {
    if (Test-Path "$ProfileDir\$f") { Copy-Item "$ProfileDir\$f" (Join-Path $BackupDir $f) -Force }
  }
  $state = New-Object System.Collections.Generic.List[string]
  foreach ($n in @($GatewayName, $DsBotName)) {
    if (Test-Path (Join-Path $Modules $n)) { $state.Add("had:$n") } else { $state.Add("new:$n") }
  }
  foreach ($d in $GatewayDeps) {
    if (Test-Path (Join-Path $Modules $d)) { $state.Add("had-dep:$d") } else { $state.Add("new-dep:$d") }
  }
  [System.IO.File]::WriteAllLines((Join-Path $BackupDir "state.txt"), $state)
  Ok "备份完成：$BackupDir（回滚用 scripts\rollback.ps1）"
}

# ---------- 3. 安装 ----------
Say ""
Say "== 3/5 安装插件 =="

function Install-Plugin([string]$name) {
  if ($DryRun) { Say "  (dry-run) 复制 plugins\$name → $Modules\$name"; return }
  $target = Join-Path $Modules $name
  if (Test-Path $target) { Remove-Item $target -Recurse -Force }
  Copy-Item (Join-Path $RepoRoot "plugins\$name") $target -Recurse -Force
  Ok "$name 已复制到 node_modules"
}

function Install-Deps {
  foreach ($dep in $GatewayDeps) {
    if (Test-Path (Join-Path $Modules "$dep\package.json")) { Ok "运行依赖已在位：$dep"; continue }
    $src = Join-Path $RepoRoot "plugins\_runtime-deps\$dep"
    if (-not (Test-Path $src)) { Die 2 "仓库缺少 plugins\_runtime-deps\$dep（网关需要它）" }
    if ($DryRun) { Say "  (dry-run) 补运行依赖：$dep"; continue }
    $dst = Join-Path $Modules $dep
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item $src $dst -Recurse -Force
    Ok "补上运行依赖：$dep"
  }
}

function Record-Dependency([string]$name) {
  $file = Join-Path $ProfileDir "package.json"
  $json = Get-Content $file -Raw | ConvertFrom-Json
  if (-not $json.PSObject.Properties.Name.Contains("dependencies") -or $null -eq $json.dependencies) {
    $json | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $value = "file:" + (Join-Path $RepoRoot "plugins\$name")
  $json.dependencies | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
  [System.IO.File]::WriteAllText($file, ($json | ConvertTo-Json -Depth 12) + "`n")
  Ok "package.json 已登记：$name → $value"
}

function Ensure-CordisBlock {
  $file = Join-Path $ProfileDir "cordis.patch.yml"
  if (-not (Test-Path $file)) {
    if ($DryRun) { Say "  (dry-run) 将新建 cordis.patch.yml"; return }
    [System.IO.File]::WriteAllText($file, "# dsh-suite: 移动网关配置（手机连接用）`n")
  }
  if ((Get-Content $file -Raw) -match "dsh-plugin-mobile-gateway") {
    Ok "cordis.patch.yml 里已有移动网关配置块（保留你的设置，不覆盖）"
    return
  }
  if ($DryRun) { Say "  (dry-run) 将追加移动网关配置块"; return }
  $block = @"

# dsh-suite: 手机连接需要开启 mobile-v1 通道（配对/团队帧都在这个前缀下）
- id: mobile-gateway
  name: dsh-plugin-mobile-gateway
  config:
    gatewayEnabled: false
    mobileV1Enabled: true
    gatewayWaitTimeoutMs: 300000
"@
  $existing = [System.IO.File]::ReadAllText($file)
  [System.IO.File]::WriteAllText($file, $existing + $block + "`n")
  Ok "cordis.patch.yml 已追加移动网关配置块"
}

if (-not $VerifyOnly) {
  if ($WantGateway) { Install-Plugin $GatewayName; Install-Deps }
  if ($WantDsBot) { Install-Plugin $DsBotName }
  if (-not $DryRun) {
    if ($WantGateway) { Record-Dependency $GatewayName }
    if ($WantDsBot) { Record-Dependency $DsBotName }
  }
  if ($WantGateway) { Ensure-CordisBlock }
}

# ---------- 4. 校验 ----------
Say ""
Say "== 4/5 校验 =="
if ($DryRun) { Say "  (dry-run) 跳过校验（未落盘）"; Say ""; Say "== 5/5 完成（未改动任何文件）=="; exit 0 }

$VerifyFail = 0
function Fail($msg) { Write-Host "  ✗ $msg" -ForegroundColor Red; $script:VerifyFail = 1 }

function Check-Hash([string]$file, [string]$expect, [string]$label) {
  if (-not (Test-Path $file)) { Fail "$label 缺失：$file"; return }
  $actual = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
  if ($actual -ne $expect.ToLower()) { Fail "$label 哈希不符（期望 $($expect.Substring(0,12))…，实际 $($actual.Substring(0,12))…）" }
}

$manifestPath = Join-Path $RepoRoot "plugins\manifest.json"
$manifest = if (Test-Path $manifestPath) { Get-Content $manifestPath -Raw | ConvertFrom-Json } else { $null }

if ($WantGateway) {
  $G = Join-Path $Modules $GatewayName
  foreach ($f in @("lib\index.mjs", "lib\mobile-v1\team-feed.mjs", "lib\mobile-v1\card-frames.mjs", "lib\mobile-v1\server.mjs")) {
    if (-not (Test-Path (Join-Path $G $f))) { Fail "网关缺文件：$f" }
  }
  if ($manifest -and $manifest.dshPluginMobileGateway) {
    foreach ($p in $manifest.dshPluginMobileGateway.PSObject.Properties) {
      Check-Hash (Join-Path $G ($p.Name -replace '/', '\')) $p.Value "网关 $($p.Name)"
    }
  }
  foreach ($dep in $GatewayDeps) {
    if (-not (Test-Path (Join-Path $Modules "$dep\package.json"))) { Fail "网关运行依赖缺失：$dep" }
  }
  if ($VerifyFail -eq 0) { Ok "网关：文件齐全、哈希与仓库一致、运行依赖在位" }
}

if ($WantDsBot) {
  $D = Join-Path $Modules $DsBotName
  foreach ($f in @("index.js", "client.js", "src\host\team-feed.js", "src\host\card-feed.js", "src\host\room-cards.js")) {
    if (-not (Test-Path (Join-Path $D $f))) { Fail "ds-bot 缺文件：$f（可能装成了上游原版）" }
  }
  $hostDir = Join-Path $D "src\host"
  if (Test-Path $hostDir) {
    $cards = (Select-String -Path (Join-Path $hostDir "*.js") -Pattern "dsBotCards" -SimpleMatch -List | Measure-Object).Count
    if ($cards -lt 1) { Fail "ds-bot 没有 dsBotCards 服务（装成了上游原版？手机团队页/卡片会缺失）" }
    $roster = (Select-String -Path (Join-Path $hostDir "*.js") -Pattern "teamFeed" -SimpleMatch -List | Measure-Object).Count
    if ($roster -lt 1) { Fail "ds-bot 没有 teamFeed（名册发布缺失，手机团队页只会是降级名册）" }
  }
  if ($manifest -and $manifest.dsBot) {
    foreach ($p in $manifest.dsBot.PSObject.Properties) {
      Check-Hash (Join-Path $D ($p.Name -replace '/', '\')) $p.Value "ds-bot $($p.Name)"
    }
  }
  if ($VerifyFail -eq 0) { Ok "ds-bot：文件齐全、哈希与仓库一致、含 dsBotCards" }
}

if ($WantGateway) {
  $cordis = Join-Path $ProfileDir "cordis.patch.yml"
  if (-not (Test-Path $cordis) -or -not ((Get-Content $cordis -Raw) -match "dsh-plugin-mobile-gateway")) {
    Fail "cordis.patch.yml 里没有移动网关配置块"
  }
}
if (-not $VerifyOnly -and -not $DryRun) {
  $pkg = Get-Content (Join-Path $ProfileDir "package.json") -Raw
  if ($WantGateway -and $pkg -notmatch [regex]::Escape($GatewayName)) { Fail "package.json 里没有登记 $GatewayName" }
  if ($WantDsBot -and $pkg -notmatch [regex]::Escape($DsBotName)) { Fail "package.json 里没有登记 $DsBotName" }
}

if ($VerifyFail -ne 0) { Die 3 "校验未通过（看上面 ✗ 的项）。可用 scripts\rollback.ps1 还原" }

# ---------- 5. 完成 ----------
Say ""
Say "== 5/5 完成 =="
$installedNames = New-Object System.Collections.Generic.List[string]
if ($WantGateway) { $installedNames.Add("移动网关") }
if ($WantDsBot) { $installedNames.Add("ds-bot") }
Say ("  已安装：" + ($installedNames -join " "))
Say "  下一步："
Say "    1) 完全退出 DeepSeek Harness 再重新打开（插件在启动时加载）"
Say "    2) 设置 → 插件，确认上面这两个插件出现且已启用"
Say "    3) 设置 → 移动网关：按 docs/INSTALL.md 第 4 步生成配对码，手机扫码"
if (-not $VerifyOnly -and -not $DryRun) {
  Say "  备份：$BackupDir（回滚：powershell -ExecutionPolicy Bypass -File .\scripts\rollback.ps1 -Backup `"$BackupDir`"）"
}
exit 0
