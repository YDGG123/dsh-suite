<#
.SYNOPSIS
  dsh-suite 回滚（Windows）：把 profile 恢复到安装前的状态。

.DESCRIPTION
  用法：
    powershell -ExecutionPolicy Bypass -File scripts\rollback.ps1                       # 回滚最近一次备份
    powershell -ExecutionPolicy Bypass -File scripts\rollback.ps1 -Backup <备份目录>    # 回滚指定备份
    powershell -ExecutionPolicy Bypass -File scripts\rollback.ps1 -List                 # 列出可用备份

  备份由 install.ps1/install.sh 在安装前创建：profiles\<profile>\backups\dsh-suite-<时间戳>\
  内含 package.json、cordis.patch.yml 与 state.txt（记录哪些目录是“原来就有/原来没有”）。

  退出码：0 成功；1 预检失败；2 恢复失败；4 无备份可回滚
#>
param(
    [string]$Backup = "",
    [string]$Profile = "",
    [string]$DshHome = "",
    [switch]$List
)

$ErrorActionPreference = 'Stop'

function Say([string]$Text) { Write-Host $Text }
function Ok([string]$Text) { Write-Host "  OK  $Text" }
function Die([int]$Code, [string]$Text) {
    [Console]::Error.WriteLine("ERROR  $Text")
    exit $Code
}

if ([string]::IsNullOrWhiteSpace($DshHome)) {
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $DshHome = Join-Path $homeDir '.dsh'
}

$ProfilesDir = Join-Path $DshHome 'profiles'
if (-not (Test-Path -LiteralPath $ProfilesDir -PathType Container)) { Die 1 "找不到 DSH 数据目录：$ProfilesDir" }

if ([string]::IsNullOrWhiteSpace($Profile)) {
    $desktop = Join-Path $ProfilesDir 'desktop'
    if (Test-Path -LiteralPath $desktop -PathType Container) { $Profile = 'desktop' }
    else {
        $first = Get-ChildItem -LiteralPath $ProfilesDir -Directory | Sort-Object Name | Select-Object -First 1
        if ($first) { $Profile = $first.Name }
    }
}
if ([string]::IsNullOrWhiteSpace($Profile)) { Die 1 '没有可用的 profile' }

$ProfileDir = Join-Path $ProfilesDir $Profile
$Modules = Join-Path $ProfileDir 'node_modules'
$BackupsDir = Join-Path $ProfileDir 'backups'

if ($List) {
    if (-not (Test-Path -LiteralPath $BackupsDir)) { Say "（$Profile 没有备份）"; exit 0 }
    $items = Get-ChildItem -LiteralPath $BackupsDir -Directory -Filter 'dsh-suite-*' | Sort-Object Name -Descending
    if (-not $items) { Say "（$Profile 没有备份）"; exit 0 }
    Say '可用备份（新→旧）：'
    foreach ($item in $items) { Say "  $($item.FullName)" }
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Backup)) {
    $candidates = @()
    if (Test-Path -LiteralPath $BackupsDir) {
        $candidates = Get-ChildItem -LiteralPath $BackupsDir -Directory -Filter 'dsh-suite-*' | Sort-Object Name -Descending
    }
    if ($candidates.Count -eq 0) {
        Die 4 "没有备份可回滚（$BackupsDir 为空）。若是手动安装，请按指南 2.4 反向删除 node_modules 里的插件目录。"
    }
    $Backup = $candidates[0].FullName
}

if (-not (Test-Path -LiteralPath $Backup -PathType Container)) { Die 1 "备份目录不存在：$Backup" }
$stateFile = Join-Path $Backup 'state.txt'
if (-not (Test-Path -LiteralPath $stateFile)) { Die 1 "备份不完整（缺 state.txt）：$Backup。为避免误删，拒绝继续。" }

Say "== 回滚 profile：$Profile =="
Say "  备份：$Backup"

$pkgBackup = Join-Path $Backup 'package.json'
if (Test-Path -LiteralPath $pkgBackup) {
    try { Copy-Item -LiteralPath $pkgBackup -Destination (Join-Path $ProfileDir 'package.json') -Force }
    catch { Die 2 '恢复 package.json 失败' }
    Ok 'package.json 已恢复'
} else {
    Say '  ! 备份里没有 package.json（安装前该文件可能不存在），跳过'
}

$cordisBackup = Join-Path $Backup 'cordis.patch.yml'
if (Test-Path -LiteralPath $cordisBackup) {
    try { Copy-Item -LiteralPath $cordisBackup -Destination (Join-Path $ProfileDir 'cordis.patch.yml') -Force }
    catch { Die 2 '恢复 cordis.patch.yml 失败' }
    Ok 'cordis.patch.yml 已恢复'
} else {
    Say '  ! 备份里没有 cordis.patch.yml，跳过'
}

# state.txt：new:* 表示安装前没有 → 删掉；had:* 表示原来有 → 删当前版本并提示自备旧版
Get-Content -LiteralPath $stateFile -Encoding ASCII | ForEach-Object {
    $line = $_.TrimEnd("`r")
    if ($line -like 'new:*') {
        $name = $line.Substring(4)
        $target = Join-Path $Modules $name
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
            Ok "移除安装时新增的目录：$name"
        }
    } elseif ($line -like 'had:*') {
        $name = $line.Substring(4)
        $target = Join-Path $Modules $name
        Say "  ! $name 安装前就存在：已删除当前版本，如需旧版本请从你自己的备份恢复"
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    } elseif ($line -like 'new-dep:*') {
        $dep = $line.Substring(8)
        $target = Join-Path $Modules $dep
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
            Ok "移除补装的运行依赖：$dep"
        }
    }
}

Say ''
Say '== 完成 =='
Say '  请完全退出 DeepSeek Harness 再重新打开，让插件列表刷新。'
exit 0
