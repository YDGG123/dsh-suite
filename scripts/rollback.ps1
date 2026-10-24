<#
.SYNOPSIS
  dsh-suite 回滚：把 profile 恢复到安装前的状态。

.DESCRIPTION
  备份由 scripts/install.ps1 在安装前创建：profiles\<profile>\backups\dsh-suite-<时间戳>\
  内含 package.json、cordis.patch.yml 与 state.txt（记录哪些目录是“原来就有 / 原来没有”）。

.PARAMETER Backup
  指定备份目录；省略则回滚最近一次。

.PARAMETER Profile
  DSH profile 名，默认 desktop（不存在则取第一个）。

.PARAMETER DshHome
  DSH 数据目录，默认 %USERPROFILE%\.dsh。

.PARAMETER List
  只列出可用备份。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\rollback.ps1 -List

.NOTES
  退出码：0 成功；1 预检失败；2 恢复失败；4 无备份可回滚。
#>
param(
  [string]$Backup = "",
  [string]$Profile = "",
  [string]$DshHome = "",
  [switch]$List
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Say($msg) { Write-Host $msg }
function Ok($msg) { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Warn2($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Die($code, $msg) { Write-Host "❌ $msg" -ForegroundColor Red; exit $code }

if ([string]::IsNullOrWhiteSpace($DshHome)) {
  $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }
}
if (-not (Test-Path "$DshHome\profiles")) { Die 1 "找不到 DSH 数据目录：$DshHome\profiles" }

if ([string]::IsNullOrWhiteSpace($Profile)) {
  if (Test-Path "$DshHome\profiles\desktop") { $Profile = "desktop" }
  else {
    $first = Get-ChildItem "$DshHome\profiles" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($first) { $Profile = $first.Name }
  }
}
if ([string]::IsNullOrWhiteSpace($Profile)) { Die 1 "没有可用的 profile" }

$ProfileDir = Join-Path $DshHome "profiles/$Profile"
$Modules = Join-Path $ProfileDir "node_modules"
$BackupRoot = Join-Path $ProfileDir "backups"

if ($List) {
  $items = Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "dsh-suite-*" } | Sort-Object Name -Descending
  if (-not $items) { Say "（$Profile 没有备份）"; exit 0 }
  Say "可用备份（新→旧）："
  foreach ($i in $items) { Say "  $($i.FullName)" }
  exit 0
}

if ([string]::IsNullOrWhiteSpace($Backup)) {
  $latest = Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "dsh-suite-*" } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $latest) { Die 4 "没有备份可回滚（$BackupRoot 为空）。若是手动安装，请按指南 2.4 反向删除 node_modules 里的插件目录。" }
  $Backup = $latest.FullName
}
if (-not (Test-Path $Backup)) { Die 1 "备份目录不存在：$Backup" }
if (-not (Test-Path (Join-Path $Backup "state.txt"))) { Die 1 "备份不完整（缺 state.txt）：$Backup。为避免误删，拒绝继续。" }

Say "== 回滚 profile：$Profile =="
Say "  备份：$Backup"

if (Test-Path (Join-Path $Backup "package.json")) {
  Copy-Item (Join-Path $Backup "package.json") (Join-Path $ProfileDir "package.json") -Force
  Ok "package.json 已恢复"
} else { Warn2 "备份里没有 package.json，跳过" }

if (Test-Path (Join-Path $Backup "cordis.patch.yml")) {
  Copy-Item (Join-Path $Backup "cordis.patch.yml") (Join-Path $ProfileDir "cordis.patch.yml") -Force
  Ok "cordis.patch.yml 已恢复"
} else { Warn2 "备份里没有 cordis.patch.yml，跳过" }

foreach ($line in Get-Content (Join-Path $Backup "state.txt")) {
  if (-not $line) { continue }
  if ($line.StartsWith("new:")) {
    $name = $line.Substring(4)
    $target = Join-Path $Modules $name
    if (Test-Path $target) { Remove-Item $target -Recurse -Force; Ok "移除安装时新增的目录：$name" }
  } elseif ($line.StartsWith("had:")) {
    $name = $line.Substring(4)
    $target = Join-Path $Modules $name
    if (Test-Path $target) { Remove-Item $target -Recurse -Force }
    Warn2 "$name 安装前就存在：已删除当前版本，如需旧版本请从你自己的备份恢复"
  } elseif ($line.StartsWith("new-dep:")) {
    $dep = $line.Substring(8)
    $target = Join-Path $Modules $dep
    if (Test-Path $target) { Remove-Item $target -Recurse -Force; Ok "移除补装的运行依赖：$dep" }
  }
}

Say ""
Say "== 完成 =="
Say "  请完全退出 DeepSeek Harness 再重新打开，让插件列表刷新。"
exit 0
