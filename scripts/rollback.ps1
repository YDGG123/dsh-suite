<#
.SYNOPSIS
  dsh-suite 回滚（Windows）：把 profile 恢复到安装前的状态。

.DESCRIPTION
  用法：
    powershell -ExecutionPolicy Bypass -File scripts\rollback.ps1                       # 回滚最近一次备份（两个插件都撤）
    powershell -ExecutionPolicy Bypass -File scripts\rollback.ps1 -Backup <备份目录>    # 回滚指定备份（两个插件都撤）
    powershell -ExecutionPolicy Bypass -File scripts\rollback.ps1 -OnlyGateway          # 只撤移动网关，另一个插件原样不动
    powershell -ExecutionPolicy Bypass -File scripts\rollback.ps1 -OnlyDsBot            # 只撤 ds-bot fork，另一个插件原样不动
    powershell -ExecutionPolicy Bypass -File scripts\rollback.ps1 -List                 # 列出可用备份
    powershell -ExecutionPolicy Bypass -File scripts\rollback.ps1 -Profile desktop      # 指定 profile
    powershell -ExecutionPolicy Bypass -File scripts\rollback.ps1 -DshHome C:\Users\me\.dsh
    powershell -ExecutionPolicy Bypass -File scripts\rollback.ps1 -Help                 # 显示这段说明

  备份由 install.ps1/install.sh 在安装前创建：profiles\<profile>\backups\dsh-suite-<时间戳>\
  内含 package.json、cordis.patch.yml 与 state.txt（记录哪些目录是“原来就有/原来没有”）。

  单插件回滚复用同一份备份与 state.txt，并且只读它：只还原该插件在 package.json /
  cordis.patch.yml 里的登记、删它的目录和它补装的运行依赖；另一个插件与它的登记不动。
  撤网关才会撤运行依赖（那 7 个目录只属于网关闭包）；撤 ds-bot 绝不碰依赖。
  重复执行是安全的：已经撤掉的项会被跳过，仍然退出 0。

  退出码：0 成功；1 预检失败；2 恢复失败；4 无备份可回滚 / 参数非法
#>
param(
    [string]$Backup = "",
    [string]$Profile = "",
    [string]$DshHome = "",
    [switch]$List,
    [switch]$OnlyGateway,
    [switch]$OnlyDsBot,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$GatewayName = 'dsh-plugin-mobile-gateway'
$DsBotName = 'ds-bot'
# 只认安装脚本自己写的那行注释：用户自己也可能有 `- id: mobile-gateway` 配置块，
# 没有这行注释的块一律不碰。
$GatewayBlockComment = '# dsh-suite: 手机连接需要开启'

function Say([string]$Text) { Write-Host $Text }
function Ok([string]$Text) { Write-Host "  OK  $Text" }
function Warn([string]$Text) { Write-Host "  !   $Text" }
function Die([int]$Code, [string]$Text) {
    [Console]::Error.WriteLine("ERROR  $Text")
    exit $Code
}

if ($Help) {
    $self = [System.IO.File]::ReadAllText($MyInvocation.MyCommand.Path)
    $from = $self.IndexOf('.DESCRIPTION')
    $to = $self.IndexOf('#>')
    if ($from -ge 0 -and $to -gt $from) {
        $body = $self.Substring($from + '.DESCRIPTION'.Length, $to - $from - '.DESCRIPTION'.Length)
        foreach ($line in ($body -split "`r?`n")) {
            $text = $line.Trim()
            if ($text -ne '') { Write-Host $text }
        }
    }
    exit 0
}

if ($OnlyGateway -and $OnlyDsBot) { Die 4 '-OnlyGateway 与 -OnlyDsBot 不能同时用' }

# 不带 -Only* 是整份回滚（老行为）；带上就只撤那一个。
$Single = $OnlyGateway -or $OnlyDsBot
$WantGateway = -not $OnlyDsBot
$WantDsBot = -not $OnlyGateway

# PowerShell 5.1 的 Set-Content -Encoding UTF8 会写 BOM；Node 的 JSON.parse 遇到 BOM 会失败。
function Write-TextNoBom([string]$Path, [string]$Text) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

if ([string]::IsNullOrWhiteSpace($DshHome)) {
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $DshHome = Join-Path $homeDir '.dsh'
}

$Join = { param($a, $b) Join-Path -Path $a -ChildPath $b }

$ProfilesDir = & $Join $DshHome 'profiles'
if (-not (Test-Path -LiteralPath $ProfilesDir -PathType Container)) { Die 1 "找不到 DSH 数据目录：$ProfilesDir" }

if ([string]::IsNullOrWhiteSpace($Profile)) {
    $desktop = & $Join $ProfilesDir 'desktop'
    if (Test-Path -LiteralPath $desktop -PathType Container) { $Profile = 'desktop' }
    else {
        $first = Get-ChildItem -LiteralPath $ProfilesDir -Directory | Sort-Object Name | Select-Object -First 1
        if ($first) { $Profile = $first.Name }
    }
}
if ([string]::IsNullOrWhiteSpace($Profile)) { Die 1 '没有可用的 profile' }

$ProfileDir = & $Join $ProfilesDir $Profile
$Modules = & $Join $ProfileDir 'node_modules'
$ProfilePkg = & $Join $ProfileDir 'package.json'
$ProfileCordis = & $Join $ProfileDir 'cordis.patch.yml'
$BackupsDir = & $Join $ProfileDir 'backups'

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
$stateFile = & $Join $Backup 'state.txt'
if (-not (Test-Path -LiteralPath $stateFile)) { Die 1 "备份不完整（缺 state.txt）：$Backup。为避免误删，拒绝继续。" }
$backupPkg = & $Join $Backup 'package.json'
$backupCordis = & $Join $Backup 'cordis.patch.yml'

if ($Single) {
    if (-not (Test-Path -LiteralPath $ProfilePkg)) { Die 1 "profile 里没有 package.json：$ProfilePkg（无法还原插件登记）" }
    # 改之前先确认它是合法 JSON：坏文件上动手只会让宿主更难恢复。
    try {
        $null = Get-Content -LiteralPath $ProfilePkg -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Die 1 "package.json 不是合法 JSON，拒绝改动：$ProfilePkg。先把它修好再回滚。"
    }
}

# 把该插件在 package.json 的登记还原成安装前的样子：备份里有旧值就写回旧值，
# 没有（安装时新增）就删掉这一项。别的依赖一个不动。
function Restore-Registration([string]$Name) {
    $data = Get-Content -LiteralPath $ProfilePkg -Raw -Encoding UTF8 | ConvertFrom-Json
    $old = $null
    $hadOld = $false
    if (Test-Path -LiteralPath $backupPkg) {
        try { $before = Get-Content -LiteralPath $backupPkg -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $before = $null }
        if ($null -ne $before -and $before.PSObject.Properties['dependencies'] -and
            $before.dependencies.PSObject.Properties[$Name]) {
            $old = $before.dependencies.$Name
            $hadOld = $true
        }
    }
    if (-not $data.PSObject.Properties['dependencies'] -or $null -eq $data.dependencies) {
        $data | Add-Member -MemberType NoteProperty -Name 'dependencies' -Value ([pscustomobject]@{}) -Force
    }
    $deps = $data.dependencies
    $had = [bool]$deps.PSObject.Properties[$Name]
    if (-not $hadOld) {
        if (-not $had) { Say "  · package.json 无需改动：$Name（已处于回滚状态）"; return }
        $deps.PSObject.Properties.Remove($Name)
        Write-TextNoBom $ProfilePkg (($data | ConvertTo-Json -Depth 100) + "`n")
        Ok "package.json 已撤销登记：$Name"
    } else {
        if ($had -and $deps.$Name -eq $old) { Say "  · package.json 无需改动：$Name（已处于回滚状态）"; return }
        if ($had) { $deps.$Name = $old }
        else { $deps | Add-Member -MemberType NoteProperty -Name $Name -Value $old }
        Write-TextNoBom $ProfilePkg (($data | ConvertTo-Json -Depth 100) + "`n")
        Ok "package.json 已还原登记：$Name（安装前的旧值）"
    }
}

function Test-GatewayBegin([string]$Line) { return $Line.StartsWith($GatewayBlockComment) }
# 去掉安装脚本追加的那一块：从注释行起，跳过空行、缩进子行，以及紧随其后的第一个
# `- id: mobile-gateway`。再出现的 `- id:` 顶格行是用户自己的块，必须留下。
function Remove-GatewayBlock([string]$Text) {
    $result = New-Object System.Collections.Generic.List[string]
    $skip = $false
    $seenId = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($skip) {
            if ($line -eq '') { continue }
            if ($line -match '^\s') { continue }
            if (-not $seenId -and $line -match '^- id: mobile-gateway\s*$') { $seenId = $true; continue }
            $skip = $false
        }
        if (Test-GatewayBegin $line) { $skip = $true; $seenId = $false; continue }
        $result.Add($line)
    }
    while ($result.Count -gt 0 -and $result[$result.Count - 1].Trim() -eq '') { $result.RemoveAt($result.Count - 1) }
    return ($result -join "`n")
}

# 只撤安装脚本追加的块：当前文件里有我们写的那行注释才动。用户自己的 mobile-gateway 块
# 没有这行注释，绝不触碰；备份里有没有都不影响判断（重装后回滚时，上一轮追加的块也是我们写的）。
function Remove-Cordis {
    if (-not (Test-Path -LiteralPath $ProfileCordis)) { Say '  · cordis.patch.yml 不存在（无需撤除）'; return }
    $current = [System.IO.File]::ReadAllText($ProfileCordis)
    if (-not $current.Contains($GatewayBlockComment)) {
        Say '  · cordis.patch.yml 里没有本安装追加的配置块（保留你的设置）'
        return
    }
    # 升级场景：安装前这份备份里已经有我们追加的块，说明它本来就该在 → 保留。
    if ((Test-Path -LiteralPath $backupCordis) -and
        ([System.IO.File]::ReadAllText($backupCordis)).Contains($GatewayBlockComment)) {
        Say '  · 安装前就有该配置块：保留（回到安装前的样子）'
        return
    }
    $clean = Remove-GatewayBlock $current
    # 安装时新建的文件：撤完只剩我们自己的表头/空白就整份删掉，回到“本来没有”。
    $meaningful = @($clean -split "`n" | Where-Object { $_.Trim() -ne '' -and -not $_.StartsWith('# dsh-suite:') })
    if (-not (Test-Path -LiteralPath $backupCordis) -and $meaningful.Count -eq 0) {
        try { Remove-Item -LiteralPath $ProfileCordis -Force } catch { Die 2 '移除 cordis.patch.yml 失败' }
        Ok 'cordis.patch.yml 是安装时新建的，已移除（安装前没有这个文件）'
        return
    }
    $next = if ($clean -eq '') { '' } else { $clean + "`n" }
    if ($next -eq $current) { Say '  · cordis.patch.yml 无需改动（已处于回滚状态）'; return }
    try { Write-TextNoBom $ProfileCordis $next } catch { Die 2 "写回 cordis.patch.yml 失败：$ProfileCordis" }
    Ok 'cordis.patch.yml 已撤除本安装追加的移动网关配置块'
}

function Test-PluginHad([string]$Name) {
    return (@(Get-Content -LiteralPath $stateFile -Encoding ASCII) -contains "had:$Name")
}

function Remove-PluginDir([string]$Name) {
    $target = & $Join $Modules $Name
    if (Test-PluginHad $Name) {
        # 安装前就有这个目录：备份里没有旧版本可还原，删掉只会让用户两边都没有。
        Warn "$Name 安装前就存在：备份里没有旧版本，保留当前目录（不删除）；如需旧版请从你自己的备份恢复"
        return
    }
    if (Test-Path -LiteralPath $target) {
        try { Remove-Item -LiteralPath $target -Recurse -Force }
        catch { Die 2 "删除插件目录失败：$target（是否被 DeepSeek Harness 占用？先退出宿主再试）" }
        Ok "移除安装时新增的目录：$Name"
    } else {
        Say "  · $Name 目录不在（已处于回滚状态）"
    }
}

function Remove-NewDeps {
    $removed = $false
    foreach ($line in (Get-Content -LiteralPath $stateFile -Encoding ASCII)) {
        if (-not $line.StartsWith('new-dep:')) { continue }
        $dep = $line.Substring(8)
        $target = & $Join $Modules $dep
        if (Test-Path -LiteralPath $target) {
            try { Remove-Item -LiteralPath $target -Recurse -Force }
            catch { Die 2 "删除运行依赖失败：$target（是否被 DeepSeek Harness 占用？先退出宿主再试）" }
            Ok "移除补装的运行依赖：$dep"
            $removed = $true
        }
    }
    if (-not $removed) { Say '  · 补装的运行依赖已不在（已处于回滚状态）' }
}

Say "== 回滚 profile：$Profile =="
Say "  备份：$Backup"
if ($Single) {
    $what = if ($WantGateway) { '移动网关' } else { 'ds-bot fork' }
    Say "  范围：只撤 $what（另一个插件原样不动）"
} else {
    Say '  范围：整份快照（两个插件都撤）'
}

if ($Single) {
    # 先还原登记、再删目录：万一登记写不进去，插件目录还在，宿主不会停在“登记在、文件没了”。
    if ($WantGateway) { Restore-Registration $GatewayName }
    if ($WantDsBot) { Restore-Registration $DsBotName }
    if ($WantGateway) { Remove-Cordis }
    if ($WantGateway) {
        Remove-PluginDir $GatewayName
        # 网关安装前就有（升级）→ 目录保留，它补装的运行依赖也保留，否则保留的目录跑不起来。
        if (-not (Test-PluginHad $GatewayName)) { Remove-NewDeps }
    }
    if ($WantDsBot) { Remove-PluginDir $DsBotName }
} else {
    if (Test-Path -LiteralPath $backupPkg) {
        try { Copy-Item -LiteralPath $backupPkg -Destination $ProfilePkg -Force }
        catch { Die 2 '恢复 package.json 失败' }
        Ok 'package.json 已恢复'
    } else {
        Say '  ! 备份里没有 package.json（安装前该文件可能不存在），跳过'
    }

    if (Test-Path -LiteralPath $backupCordis) {
        try { Copy-Item -LiteralPath $backupCordis -Destination $ProfileCordis -Force }
        catch { Die 2 '恢复 cordis.patch.yml 失败' }
        Ok 'cordis.patch.yml 已恢复'
    } else {
        Say '  ! 备份里没有 cordis.patch.yml，跳过'
    }

    # state.txt：new:* 表示安装前没有 → 删掉；had:* 表示原来有 → 保留当前目录并提示自备旧版
    foreach ($line in (Get-Content -LiteralPath $stateFile -Encoding ASCII)) {
        $line = $line.TrimEnd("`r")
        if ($line -like 'new:*') {
            $name = $line.Substring(4)
            $target = & $Join $Modules $name
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force
                Ok "移除安装时新增的目录：$name"
            }
        } elseif ($line -like 'had:*') {
            $name = $line.Substring(4)
            Say "  ! $name 安装前就存在：备份里没有旧版本，保留当前目录（不删除）；如需旧版请从你自己的备份恢复"
        } elseif ($line -like 'new-dep:*') {
            $dep = $line.Substring(8)
            $target = & $Join $Modules $dep
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force
                Ok "移除补装的运行依赖：$dep"
            }
        }
    }
}

Say ''
Say '== 完成 =='
Say '  请完全退出 DeepSeek Harness 再重新打开，让插件列表刷新。'
exit 0
