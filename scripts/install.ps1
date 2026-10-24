<#
.SYNOPSIS
  dsh-suite 一键安装（Windows）。与 scripts/install.sh 同一套逻辑：备份 → 复制插件 →
  补运行依赖 → 写 cordis 配置块 → 逐项校验；任何一项不过都以非零退出。

.DESCRIPTION
  用法：
    powershell -ExecutionPolicy Bypass -File scripts\install.ps1                  # 两个插件都装（默认）
    powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -OnlyGateway     # 只装移动网关（最小组合：手机能聊天）
    powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -OnlyDsBot       # 只装 ds-bot fork
    powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -Profile desktop
    powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -DshHome C:\Users\me\.dsh
    powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -VerifyOnly      # 只校验已安装结果
    powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -DryRun          # 只打印计划，不落盘

  退出码：0 成功；1 预检失败；2 安装/复制失败；3 校验失败；4 环境不支持
#>
param(
    [switch]$OnlyGateway,
    [switch]$OnlyDsBot,
    [switch]$VerifyOnly,
    [switch]$DryRun,
    [string]$Profile = "",
    [string]$DshHome = ""
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$GatewayName = 'dsh-plugin-mobile-gateway'
$DsBotName = 'ds-bot'
# 运行依赖闭包（含传递依赖）。yargs 不补：只服务 qrcode 的 CLI。
$GatewayDeps = @(
    'ws',
    'qrcode',
    '@deepseek-ai/schemastery',
    'pngjs',
    'dijkstrajs',
    '@standard-schema/spec',
    '@deepseek-ai/cosmokit'
)

function Say([string]$Text) { Write-Host $Text }
function Ok([string]$Text) { Write-Host "  OK  $Text" }
function Warn([string]$Text) { Write-Host "  !   $Text" }
function Die([int]$Code, [string]$Text) {
    [Console]::Error.WriteLine("ERROR  $Text")
    exit $Code
}


# PowerShell 5.1 的 Set-Content -Encoding UTF8 会写 BOM；Node 的 JSON.parse 遇到 BOM 会失败。
# 统一用无 BOM 写入，避免 DSH 读不了 package.json / cordis.patch.yml。
function Write-TextNoBom([string]$Path, [string]$Text) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

if ($OnlyGateway -and $OnlyDsBot) { Die 4 '-OnlyGateway 与 -OnlyDsBot 不能同时用' }

$WantGateway = -not $OnlyDsBot
$WantDsBot = -not $OnlyGateway

if ([string]::IsNullOrWhiteSpace($DshHome)) {
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $DshHome = Join-Path $homeDir '.dsh'
}

$Join = { param($a, $b) Join-Path -Path $a -ChildPath $b }

# ---------- 1. 预检 ----------
Say '== 1/5 预检 =='
$PluginsDir = & $Join $RepoRoot 'plugins'
if (-not (Test-Path -LiteralPath $PluginsDir -PathType Container)) {
    Die 1 "找不到 plugins 目录，请在仓库根目录运行（当前：$RepoRoot）"
}
if ($WantGateway -and -not (Test-Path -LiteralPath (& $Join (& $Join $PluginsDir $GatewayName) 'lib\index.mjs'))) {
    Die 1 "仓库缺少 plugins\$GatewayName\lib\index.mjs（仓库不完整，请重新下载）"
}
if ($WantDsBot -and -not (Test-Path -LiteralPath (& $Join (& $Join $PluginsDir $DsBotName) 'index.js'))) {
    Die 1 "仓库缺少 plugins\$DsBotName\index.js（仓库不完整，请重新下载）"
}

$ProfilesDir = & $Join $DshHome 'profiles'
if (-not (Test-Path -LiteralPath $ProfilesDir -PathType Container)) {
    Die 1 "找不到 DSH 数据目录：$ProfilesDir。请确认已安装 DeepSeek Harness（>=0.2.1-rc.1），或用 -DshHome 指定"
}

if ([string]::IsNullOrWhiteSpace($Profile)) {
    $desktop = & $Join $ProfilesDir 'desktop'
    if (Test-Path -LiteralPath $desktop -PathType Container) {
        $Profile = 'desktop'
    } else {
        $first = Get-ChildItem -LiteralPath $ProfilesDir -Directory | Sort-Object Name | Select-Object -First 1
        if ($first) { $Profile = $first.Name }
    }
}
if ([string]::IsNullOrWhiteSpace($Profile)) { Die 1 "$ProfilesDir 下没有任何 profile，请先在 DeepSeek Harness 里建一个" }

$ProfileDir = & $Join $ProfilesDir $Profile
if (-not (Test-Path -LiteralPath $ProfileDir -PathType Container)) { Die 1 "profile 不存在：$ProfileDir" }
$ProfilePkg = & $Join $ProfileDir 'package.json'
if (-not (Test-Path -LiteralPath $ProfilePkg)) { Die 2 "profile 里没有 package.json：$ProfileDir（这个 profile 可能没初始化过）" }
$Modules = & $Join $ProfileDir 'node_modules'
if (-not (Test-Path -LiteralPath $Modules -PathType Container)) {
    Die 2 "profile 里没有 node_modules：$Modules（请先启动一次 DeepSeek Harness，让它自己初始化）"
}
Ok "DSH 数据目录：$DshHome"
Ok "目标 profile：$Profile（$ProfileDir）"

# ---------- 2. 备份 ----------
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupDir = & $Join (& $Join $ProfileDir 'backups') "dsh-suite-$Stamp"
Say ''
Say '== 2/5 备份 =='
if ($DryRun) {
    Say "  (dry-run) 将备份到：$BackupDir"
} elseif (-not $VerifyOnly) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    foreach ($f in @('package.json', 'cordis.patch.yml')) {
        $src = & $Join $ProfileDir $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (& $Join $BackupDir $f) -Force }
    }
    $state = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($GatewayName, $DsBotName)) {
        if (Test-Path -LiteralPath (& $Join $Modules $name) -PathType Container) { $state.Add("had:$name") } else { $state.Add("new:$name") }
    }
    foreach ($dep in $GatewayDeps) {
        if (Test-Path -LiteralPath (& $Join $Modules $dep) -PathType Container) { $state.Add("had-dep:$dep") } else { $state.Add("new-dep:$dep") }
    }
    Write-TextNoBom (& $Join $BackupDir 'state.txt') (($state -join "`n") + "`n")
    Ok "备份完成：$BackupDir（回滚用 scripts\rollback.ps1）"
}

# ---------- 3. 安装 ----------
Say ''
Say '== 3/5 安装插件 =='

function Install-Plugin([string]$Name) {
    $dst = & $Join $Modules $Name
    if ($DryRun) { Say "  (dry-run) 复制 plugins\$Name -> $dst"; return }
    if (Test-Path -LiteralPath $dst) {
        try { Remove-Item -LiteralPath $dst -Recurse -Force } catch {
            Die 2 "无法删除旧目录：$dst（是否被 DeepSeek Harness 占用？先退出宿主再试）"
        }
    }
    try { Copy-Item -LiteralPath (Join-Path $PluginsDir $Name) -Destination $dst -Recurse -Force } catch {
        Die 2 "复制失败：$Name（$($_.Exception.Message)）"
    }
    Ok "$Name 已复制到 node_modules"
}

function Install-Deps {
    foreach ($dep in $GatewayDeps) {
        $dst = & $Join $Modules $dep
        if (Test-Path -LiteralPath (& $Join $dst 'package.json')) { Ok "运行依赖已在位：$dep"; continue }
        $src = & $Join (& $Join $PluginsDir '_runtime-deps') $dep
        if (-not (Test-Path -LiteralPath $src -PathType Container)) { Die 2 "仓库缺少 plugins\_runtime-deps\$dep（网关需要它）" }
        if ($DryRun) { Say "  (dry-run) 补运行依赖：$dep"; continue }
        $parent = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        try { Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force } catch { Die 2 "复制运行依赖失败：$dep" }
        Ok "补上运行依赖：$dep"
    }
}

function Register-Dependency([string]$Name) {
    $target = Join-Path $PluginsDir $Name
    try {
        $data = Get-Content -LiteralPath $ProfilePkg -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Warn 'package.json 不是合法 JSON，跳过依赖登记（插件仍已复制，重启后应可见）'
        return
    }
    if (-not $data.PSObject.Properties['dependencies']) {
        $data | Add-Member -MemberType NoteProperty -Name 'dependencies' -Value ([pscustomobject]@{})
    }
    $deps = $data.dependencies
    if ($deps.PSObject.Properties[$Name]) { $deps.$Name = "file:$target" }
    else { $deps | Add-Member -MemberType NoteProperty -Name $Name -Value "file:$target" }
    Write-TextNoBom $ProfilePkg (($data | ConvertTo-Json -Depth 100) + "`n")
    Ok "package.json 已登记：$Name -> file:$target"
}

function Ensure-CordisBlock {
    $cordis = & $Join $ProfileDir 'cordis.patch.yml'
    if (-not (Test-Path -LiteralPath $cordis)) {
        if ($DryRun) { Say '  (dry-run) 将新建 cordis.patch.yml'; return }
        Write-TextNoBom $cordis "# dsh-suite: 移动网关配置（手机连接用）`n"
    }
    if (Select-String -LiteralPath $cordis -SimpleMatch 'dsh-plugin-mobile-gateway' -Quiet) {
        Ok 'cordis.patch.yml 里已有移动网关配置块（保留你的设置，不覆盖）'
        return
    }
    if ($DryRun) { Say '  (dry-run) 将追加移动网关配置块'; return }
    $block = @'

# dsh-suite: 手机连接需要开启 mobile-v1 通道（配对/团队帧都在这个前缀下）
- id: mobile-gateway
  name: dsh-plugin-mobile-gateway
  config:
    gatewayEnabled: false
    mobileV1Enabled: true
    gatewayWaitTimeoutMs: 300000
'@
    $existing = if (Test-Path -LiteralPath $cordis) { [System.IO.File]::ReadAllText($cordis) } else { '' }
    Write-TextNoBom $cordis ($existing + $block)
    Ok 'cordis.patch.yml 已追加移动网关配置块'
}

if (-not $VerifyOnly) {
    if ($WantGateway) { Install-Plugin $GatewayName; Install-Deps }
    if ($WantDsBot) { Install-Plugin $DsBotName }
    if (-not $DryRun) {
        if ($WantGateway) { Register-Dependency $GatewayName }
        if ($WantDsBot) { Register-Dependency $DsBotName }
    }
    if ($WantGateway) { Ensure-CordisBlock }
}

# ---------- 4. 校验 ----------
Say ''
Say '== 4/5 校验 =='
if ($DryRun) {
    Say '  (dry-run) 跳过校验（未落盘）'
    Say ''
    Say '== 5/5 完成（未改动任何文件）=='
    exit 0
}

$VerifyFail = $false
function Fail([string]$Text) { Write-Host "  X   $Text"; $script:VerifyFail = $true }

$ManifestPath = & $Join $PluginsDir 'manifest.json'
$Manifest = $null
if (Test-Path -LiteralPath $ManifestPath) {
    try { $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $Manifest = $null }
}

function Check-Hash([string]$File, [string]$Expect, [string]$Label) {
    if (-not (Test-Path -LiteralPath $File)) { Fail "$Label 缺失：$File"; return }
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Expect.ToLower()) {
        Fail ("$Label 哈希不符（期望 {0}...，实际 {1}...）" -f $Expect.Substring(0, [Math]::Min(12, $Expect.Length)), $actual.Substring(0, [Math]::Min(12, $actual.Length)))
    }
}

if ($WantGateway) {
    $G = & $Join $Modules $GatewayName
    foreach ($rel in @('lib\index.mjs', 'lib\mobile-v1\team-feed.mjs', 'lib\mobile-v1\card-frames.mjs', 'lib\mobile-v1\server.mjs')) {
        if (-not (Test-Path -LiteralPath (& $Join $G $rel))) { Fail "网关缺文件：$rel" }
    }
    if ($Manifest -and $Manifest.dshPluginMobileGateway) {
        foreach ($prop in $Manifest.dshPluginMobileGateway.PSObject.Properties) {
            Check-Hash (& $Join $G $prop.Name) $prop.Value "网关 $($prop.Name)"
        }
    }
    foreach ($dep in $GatewayDeps) {
        if (-not (Test-Path -LiteralPath (& $Join (& $Join $Modules $dep) 'package.json'))) { Fail "网关运行依赖缺失：$dep" }
    }
    if (-not $VerifyFail) { Ok '网关：文件齐全、哈希与仓库一致、运行依赖在位' }
}

if ($WantDsBot) {
    $D = & $Join $Modules $DsBotName
    foreach ($rel in @('index.js', 'client.js', 'src\host\team-feed.js', 'src\host\card-feed.js', 'src\host\room-cards.js')) {
        if (-not (Test-Path -LiteralPath (& $Join $D $rel))) { Fail "ds-bot 缺文件：$rel（可能装成了上游原版）" }
    }
    $hostDir = & $Join $D 'src\host'
    if (Test-Path -LiteralPath $hostDir) {
        $cards = @(Get-ChildItem -LiteralPath $hostDir -Recurse -File | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'dsBotCards' }).Count
        if ($cards -lt 1) { Fail 'ds-bot 没有 dsBotCards 服务（装成了上游原版？手机团队页/卡片会缺失）' }
        $roster = @(Get-ChildItem -LiteralPath $hostDir -Recurse -File | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'teamFeed' }).Count
        if ($roster -lt 1) { Fail 'ds-bot 没有 teamFeed（名册发布缺失，手机团队页只会是降级名册）' }
    } else {
        Fail 'ds-bot 缺 src\host 目录（可能装成了上游原版）'
    }
    if ($Manifest -and $Manifest.dsBot) {
        foreach ($prop in $Manifest.dsBot.PSObject.Properties) {
            Check-Hash (& $Join $D $prop.Name) $prop.Value "ds-bot $($prop.Name)"
        }
    }
    if (-not $VerifyFail) { Ok 'ds-bot：文件齐全、哈希与仓库一致、含 dsBotCards' }
}

$cordisFile = & $Join $ProfileDir 'cordis.patch.yml'
if ($WantGateway -and (Test-Path -LiteralPath $cordisFile)) {
    if (-not (Select-String -LiteralPath $cordisFile -SimpleMatch 'dsh-plugin-mobile-gateway' -Quiet)) {
        Fail 'cordis.patch.yml 里没有移动网关配置块'
    }
}
if (-not $VerifyOnly) {
    $pkgText = Get-Content -LiteralPath $ProfilePkg -Raw -Encoding UTF8
    if ($WantGateway -and ($pkgText -notmatch [regex]::Escape('"' + $GatewayName + '"'))) { Fail "package.json 里没有登记 $GatewayName" }
    if ($WantDsBot -and ($pkgText -notmatch [regex]::Escape('"' + $DsBotName + '"'))) { Fail "package.json 里没有登记 $DsBotName" }
}

if ($VerifyFail) { Die 3 '校验未通过（看上面 X 的项）。可用 scripts\rollback.ps1 还原' }

# ---------- 5. 完成 ----------
Say ''
Say '== 5/5 完成 =='
$installed = @()
if ($WantGateway) { $installed += '移动网关' }
if ($WantDsBot) { $installed += 'ds-bot' }
Say "  已安装：$($installed -join ' ')"
Say '  下一步：'
Say '    1) 完全退出 DeepSeek Harness 再重新打开（插件在启动时加载）'
Say '    2) 设置 -> 插件，确认上面这两个插件出现且已启用'
Say '    3) 设置 -> 移动网关：按 docs/INSTALL.md 第 4 步生成配对码，手机扫码'
if (-not $VerifyOnly) {
    Say "  备份：$BackupDir（回滚：powershell -ExecutionPolicy Bypass -File scripts\rollback.ps1 -Backup `"$BackupDir`"）"
}
exit 0
