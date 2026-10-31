# 安装指南（Windows + iPhone iOS 16 / TrollStore 巨魔）

> **给 AI 助手的说明**：按本文**编号顺序**执行，每步都有「命令」「预期输出」「失败怎么办」。
> **不要执行本文之外的操作**——不需要 `npm install`、不需要构建、TrollStore 路径**不需要签名**、
> 不需要 Apple ID。任何一步的预期输出对不上，先看该步的失败处理，不要跳过继续。

> **给用户的说明**：本套**不需要** Apple ID、签名工具、Node/npm 或任何构建步骤。
> 桌面装两个插件、手机用巨魔装一个 App、扫一次码，结束。

---

## 0. 先选组合（决定你要走到第几步）

| 你想要什么 | 要装什么 | 不装会怎样 |
|---|---|---|
| 手机上**聊天 / 会话 / 工作区** | **网关插件 + App**（最小组合） | — |
| 手机上看 **Bot 团队页**（名册 / 实时状态 / 头像） | 网关插件 + **ds-bot fork** + App | 团队页显示**降级名册**（无实时状态） |
| **群聊卡片**（提问卡 / 展示卡 / 密钥卡） | 网关插件 + **ds-bot fork** + App | 手机看不到卡片；**桌面群里也不弹卡** |
| **只要桌面 Bot 团队**（不要手机） | 只装 **ds-bot fork** | 手机相关功能与你无关 |

> **最小可用组合 = 网关插件 + App。** 装完第 4 步就能聊天；ds-bot 是增强项。
>
> **⚠️ 先记住这一条**：团队页显示"降级名册 / 实时状态暂不可用"、群里不弹卡片，
> **都不是坏了**，是没装增强插件（ds-bot）。完整对照见 [第 6 节](#6-降级表现对照看起来像坏了其实正常)。

**三个问题决定走到哪：**

1. 只想在手机看会话 → **基础组合**：第 1 → 2.1 → 3 → 4 步，然后做[基础验收](#5-验收清单装完照这个勾)
2. 还要手机看团队 / 群聊卡片 → **增强组合**：第 1 → 2.1+2.2 → 3 → 4 步，再做[增强验收](#5-验收清单装完照这个勾)
3. 只要桌面 Bot 团队、不要手机 → **只装 ds-bot**：第 1 → 2.2 步，结束（跳过第 3、4 步）

---

## 1. 环境自检（四条都过再往下）

### 1.0 先把本仓库弄到电脑上（二选一）

**方式 A · 网页下载 ZIP（电脑上没有 git 时用这个，最简单）**

1. 浏览器打开 https://github.com/YDGG123/dsh-suite
2. 绿色 **Code** 按钮 → **Download ZIP**
3. 右键 ZIP → 全部解压到任意目录（如 `D:\dsh-suite`）
4. 之后所有"在仓库根目录执行"= 在解压出的 `dsh-suite-main` 目录里执行

**方式 B · git clone（电脑上有 git 时）**

```powershell
git clone https://github.com/YDGG123/dsh-suite.git
```

- **预期**：得到 `dsh-suite` 目录，里面有 `README.md`、`app`、`plugins`、`scripts`
- **失败**：下载慢/失败 → 挂代理重试，或用方式 A

### 1.1 桌面 DeepSeek Harness 版本 ≥ 0.2.1-rc.1

打开 DeepSeek Harness →（左下角/设置）**关于** → 看版本号。
  （AI 可执行核验：在 PowerShell 里跑 `Get-Content "$env:LOCALAPPDATA\Programs\DeepSeek Harness\resources\app.asar.unpacked\dsh\package.json" | Select-String version`；装在别处以应用内"关于"显示为准。）

- **预期**：`0.2.1-rc.1` 或更高
- **失败**：版本低于此 → 先升级 DSH 再回来；版本不够插件不会加载。
  - **DSH 从哪获取/升级**：DeepSeek Harness 官方发布页 https://github.com/deepseek-ai/deepseek-harness/releases （下载对应系统的安装包覆盖安装；Mac 也可在应用内检查更新）。装的是正式版也没关系，只要 ≥ 0.2.1-rc.1。

### 1.2 打开 PowerShell（Windows）

在仓库根目录按住 `Shift` + 右键空白处 → **在此处打开 PowerShell 窗口**。

- **预期**：提示符路径就是本仓库根目录（能看到 `README.md`、`app`、`plugins`）
- **失败**：没有"在此处打开 PowerShell" → 手动打开 PowerShell 后 `cd` 到仓库目录

### 1.3 确认 iPhone 是 iOS 16 且巨魔（TrollStore）可用

手机 → 设置 → 通用 → 关于本机 → 看**版本**。

- **预期**：`16.x`，且手机上能打开 **TrollStore**（巨魔）
- **失败**：没有巨魔 → 走 [3.5 备选：无巨魔时自签安装](#35-备选无巨魔时自签安装sideloadly)

### 1.4 手机与电脑在同一 Wi-Fi

- **预期**：手机 Wi-Fi 名与电脑相同，且不是"访客网络"
- **失败**：公司/学校 Wi-Fi 常隔离设备 → 换手机热点验证（热点也能用）

---

## 2. 桌面装插件

> 脚本会**先备份再安装**，备份路径会打印在输出里，**记下来**（回滚要用）。
> 只装一个用 `-OnlyGateway` / `-OnlyDsBot`；不写参数 = 两个都装。
> 想先干跑不落盘：加 `-DryRun`（macOS `--dry-run`）；只想校验已装结果：`-VerifyOnly`（macOS `--verify-only`）。

### 2.1 基础组合：装移动网关

**命令**（PowerShell，仓库根目录）：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1 -OnlyGateway
```

macOS：`bash scripts/install.sh --only-gateway`

- **预期输出**：**退出码 0**，输出里有 `1/5 预检` … `5/5 完成`，末尾是 `下一步：` 三段。逐字骨架见 [2.4](#24-装完自证ai-必读退出码--预期输出骨架)
- **失败**：
  - 提示"禁止运行脚本" → 就用上面这行（`-ExecutionPolicy Bypass` 只对本次生效）
  - 提示找不到文件 → 确认当前目录是仓库根目录（`dir` 能看到 `scripts`）
  - 其它报错 → 记下原文，用 [2.5 手动兜底](#25-失败兜底手动安装脚本不可用时) 重试

### 2.2 进阶段：装 ds-bot（**不需要 Bot 功能可跳过整节**）

**只有**你要"手机团队页 / 群聊卡片"时才做这一步。它只为一件事服务：**把 Bot 团队的数据交给手机**——
名册本身由网关提供，但**实时状态 / 头像形状与颜色 / 群聊卡片**必须由 ds-bot 发布。

**命令**：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1 -OnlyDsBot
```

macOS：`bash scripts/install.sh --only-dsbot`

- **预期输出**：出现 `ds-bot` 的"已安装/已启用"，**没有红色报错**
- 想一次装两个：`powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1`（不带参数 = 全装）
- **失败**：同上，见 [2.5](#25-失败兜底手动安装脚本不可用时)

> **装了 npm 上的原版 ds-bot 等于没装**：它与本套不冲突，但**没有**群聊卡片、名册发布这些自研功能 →
> 手机端表现和"没装 ds-bot"一样。要用这些功能，请装本仓库 `plugins/ds-bot/`（fork 版）。

### 2.3 重启 DSH 并确认插件已加载

关掉 DeepSeek Harness 再打开 → 打开插件/扩展列表。

- **预期**：
  - 基础组合：列表里有 `dsh-plugin-mobile-gateway`
  - 增强组合：**额外**有 `ds-bot`
  - 两者都没有"加载失败/错误"标记
- **失败**：列表里没有 → 回看 1.1 版本、2.1/2.2 的输出；仍不出现 → [2.5](#25-失败兜底手动安装脚本不可用时)

### 2.4 装完自证（AI 必读：退出码 + 预期输出骨架）

**先看退出码——这是最硬的判据，别靠"看起来没报错"：**

| 退出码 | 含义 | 该做什么 |
|---|---|---|
| `0` | 成功 | 进下一步（§2.3 重启） |
| `1` | 预检失败（目录/版本/工具缺失） | 按输出提示补齐，**一个文件都没动**，可修好直接重跑 |
| `2` | 安装/复制失败 | 跑 `rollback`（§7）后重试 |
| `3` | **校验失败**（文件不全/哈希不符/依赖缺失） | 跑 `rollback` 后重试；仍失败 → 反馈 |
| `4` | 环境不支持 | 停止，反馈（不要手改文件绕过） |

Windows 取退出码：`echo $LASTEXITCODE`；macOS：`echo $?`。

**真装时的输出骨架**（macOS 实测于 2026-10-25；Windows 文字一致）：

```
== 1/5 预检 ==
  ✓ DSH 数据目录：<你的 .dsh 路径>
  ✓ 目标 profile：desktop（<…>/profiles/desktop）
== 2/5 备份 ==
  backup: <…>/profiles/<profile>/backups/dsh-suite-<YYYYMMDD-HHMMSS>   ← 记下这一行，回滚要用
== 3/5 安装插件 ==
== 4/5 校验 ==
  ✓ 网关：文件齐全、哈希与仓库一致、运行依赖在位
  ✓ ds-bot：文件齐全、哈希与仓库一致、含 dsBotCards
CHECK gateway: PASS
CHECK dsbot: PASS
RESULT: PASS
== 5/5 完成 ==
  已安装：移动网关 ds-bot
  下一步：
    1) 完全退出 DeepSeek Harness 再重新打开（插件在启动时加载）
    2) 设置 → 插件，确认上面这两个插件出现且已启用
    3) 设置 → 移动网关：按 docs/INSTALL.md 第 4 步生成配对码，手机扫码
```

> 只装了网关（`-OnlyGateway`）时，`4/5 校验` 里**只有网关那一行**，`CHECK` 也只有 `CHECK gateway: PASS`，
> `已安装：` 里只有「移动网关」——**这是正常的**，不是漏装。
>
> **四个机器可读锚点**（脚本/文档/AI 都以它们为准，不靠中文描述猜）：`backup: <备份目录>`、
> `CHECK gateway: PASS|FAIL`、`CHECK dsbot: PASS|FAIL`、`RESULT: PASS|FAIL`。校验失败时先打
> `CHECK <插件>: FAIL`（哪个插件红）再打 `RESULT: FAIL` 并退出码 3。
>
> **回滚用的备份路径直接取 `backup:` 那一行**，不要从“== 2/5 备份 ==”旁边的中文描述里手抄。

**一条命令自证"到底装好了没有"**（我实测：退出码 0 + 两行 `✓`）：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1 -VerifyOnly
```
```bash
bash scripts/install.sh --verify-only
```

> **Windows 用户先干跑一次**：`install.ps1` 的参数与逻辑与 macOS 同源，但**尚未在真实 Windows 环境执行过**（作者自述）。所以：
> 1. 先 `-DryRun`（`--dry-run`）——输出每行以 `(dry-run)` 开头，最后一行是 `5/5 完成（未改动任何文件）`，**不落盘**；
> 2. 计划符合预期再真跑（去掉 `-DryRun`）；
> 3. 出问题把完整输出发回（§9 反馈）。

### 2.5 失败兜底：手动安装（脚本不可用时）

两个插件目录都是**装完即用**的完整包（含 `lib/` 或 `client.js` 构建产物），**不依赖联网、不需要构建**：

1. 打开 DSH 的插件目录：DSH 数据目录下 `profiles/<你的 profile>/node_modules/`（Windows 一般在 `%USERPROFILE%\.dsh\profiles\`）
2. 把 `plugins/dsh-plugin-mobile-gateway/` 整个目录复制进去；（增强组合）再把 `plugins/ds-bot/` 复制进去
3. 重启 DeepSeek Harness，回到 2.3 的预期确认

---

## 3. 第二步：手机装 App

> ⚠️ **本步需要人手操作**（传文件到手机、在 TrollStore 里点安装）——AI 助手执行到此处应把操作交回用户，等用户确认后再继续校验。（TrollStore 主线）

> 巨魔安装 = **免签名、永久有效**，不会 7 天过期。**不需要 Apple ID。**

### 3.1 拿到 IPA

仓库里就有：`app/Orcarness-iOS16-20261031-0941.ipa`

建议执行（这是自动可查的完整性检查，AI 助手请执行）：在仓库根目录

```powershell
Get-FileHash app\Orcarness-iOS16-20261031-0941.ipa -Algorithm SHA256
```

- **预期**：`5A017C5D353CD1ECE27A434ADA03812DA52EFEF874D56EB1E172EB471E5E31D2`，大小 `15,455,788` 字节
- **对不上** → 重新下载本仓库，别用这个文件

### 3.2 把 IPA 传到手机

任选一种（挑你顺手的）：

- **iCloud 云盘**：Windows 装 iCloud → 把 IPA 拖进 iCloud Drive → 手机「文件」App 里能看到
- **聊天工具**：微信/QQ 的"文件传输助手"发给自己 → 手机上"保存到文件"
- **Mac**：AirDrop 直接发给手机

- **预期**：手机「文件」App 里能找到这个 `.ipa`
- **失败**：手机上找不到 → 确认是存进了「文件」（不是只留在聊天记录里）

### 3.3 用 TrollStore 安装

手机上：在「文件」里**长按该 IPA → 共享 → TrollStore**（或先打开 TrollStore，用它的安装入口选文件）。

- **预期**：TrollStore 显示安装进度，结束后桌面出现 **Whaleness** 图标
- **失败**：
  - 共享菜单里没有 TrollStore → 先打开一次 TrollStore，再重复长按共享
  - 提示"不支持/无法安装" → 巨魔与系统版本不匹配 → 走 [3.5 备选](#35-备选无巨魔时自签安装sideloadly)
  - 巨魔各版本菜单叫法略有差异，**以你手机上看到的按钮为准**，目标只有一个：让它装这个 IPA

### 3.4 打开 App 确认

桌面点开 **Whaleness**。

- **预期**：App 正常打开出现主界面（此时还没配对，会话列表为空是正常的）
- **失败**：闪退/白屏 → 删除后按 3.3 重装；仍不行 → 先排查这一步再谈配对

### 3.5 备选：无巨魔时自签安装（Sideloadly）

> **只有 1.3 发现手机没有巨魔时才用这节。** 代价：**要 Apple ID、7 天过期需重签**。

1. 电脑装 [Sideloadly](https://sideloadly.io/)，数据线连 iPhone
2. 把 `app/Orcarness-iOS16-20261031-0941.ipa` 拖进 Sideloadly，填 Apple ID → Start
3. 手机上信任证书：设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任
4. **7 天到期**后 App 打不开 → 同样方式重签一次；**配对信息不会丢**

---

## 4. 第三步：配对（手机 ↔ 桌面）

> ⚠️ **本步需要人手操作**（手机扫码、桌面点批准）——AI 助手执行到此处应把操作交回用户。

1. 桌面 DeepSeek Harness 里打开**移动网关**，确认是开启状态（能看到本机地址与端口）
2. 在网关上**生成配对码 / 二维码**
3. 手机 Whaleness → 扫码（或手动输入"地址 + 配对码"）

- **预期**：手机上**出现会话列表**（配对成功、通道打通）
- **失败**：
  - 一直"连接断开/正在重连" → 回看 1.4（同一 Wi-Fi）、电脑防火墙弹窗是否选了**允许**
  - 配对码过期 → 重新生成再扫（配对码一次性）
  - 扫不动 → 手动输入地址与配对码

---

## 5. 验收清单（装完照这个勾）

### 基础组合（网关 + App）

- [ ] 桌面插件列表有 `dsh-plugin-mobile-gateway`，无加载报错
- [ ] 移动网关面板能打开、能生成配对码
- [ ] 手机 App 能打开，扫码后**会话列表出现**
- [ ] 点进一个会话能看到历史，发一条消息能拿到回复
- [ ] 工作区/文件列表能打开

### 增强组合（+ ds-bot）

- [ ] 桌面插件列表**额外**有 `ds-bot`
- [ ] 手机「团队」页看得到 Bot 名册，**头像有形状/颜色**（不是清一色首字母）
- [ ] 有 Bot 在干活时，团队页能看到**实时状态**（在做 / 等审批）
- [ ] 群里触发一次卡片（例如让 Bot 问你一个问题）→ **手机和桌面都看到卡片**

---

## 6. 降级表现对照（"看起来像坏了，其实正常"）

| 你看到的 | 真正的原因 | 是不是故障 | 怎么办 |
|---|---|---|---|
| 团队页显示"**降级名册**" / "实时状态暂不可用" | **没装 ds-bot**，或 ds-bot 未启用/未运行 | ❌ 不是 | 按 2.2 装/启用 ds-bot |
| 团队页**整页空**（或只剩一张说明卡） | 最小组合（只装了网关），名册还没同步上来 | ❌ 不是 | 稍等刷新；想要团队页就装 ds-bot |
| 群里发消息**没有任何卡片** | 卡片是 ds-bot 的能力，没装就不弹 | ❌ 不是 | 按 2.2 装 ds-bot（桌面群同样需要它） |
| 手机**看不到卡片**，桌面群里有 | 同上（或网关版本旧） | ❌ 不是 | 装 ds-bot，并确认网关是 0.10.4 |
| 团队页**头像都是首字母** | 旧版数据/旧宿主（没发布解析后的头像） | ❌ 不是 | 两端都用本包版本 |
| 切了语言，界面还是中文 | iOS 只在**启动时**读语言设置 | ❌ 不是 | 按 App 内提示**退出再打开** |
| 实时活动不出现 | iOS < 16.2，或没允许通知/实时活动 | ❌ 不是 | 升到 16.2+，检查通知设置 |
| 手机一直"正在重连" | 网关没开、不同网段、配对过期、防火墙拦 | ✅ 是 | 看[第 4 步失败处理](#4-第三步配对手机--桌面) 与 [FAQ](#8-常见问题) |
| App 打不开/闪退 | 巨魔安装不完整，或（自签路径）**7 天到期** | ✅ 是 | 重装（自签则重签），配对不丢 |
| 桌面 DSH 重启后插件"消失" | DSH 升级覆盖了插件目录 | ✅ 是 | 重跑 2.1/2.2（脚本会校验已装项） |

> **一句话客服口径**：*"团队页空 / 群里不弹卡 = 没装 ds-bot，不是坏了；装上 ds-bot 重启 DSH 就好。"*

---

## 7. 升级 / 回滚 / 卸载

### 升级

1. 重新拉取本仓库（或下载新版压缩包）
2. 重跑 `install.ps1`（不带参数 = 两个都升；只升一个用 `-OnlyGateway` / `-OnlyDsBot`）
3. 重启 DeepSeek Harness
4. 有新 IPA 时按第 3 步重装覆盖（**配对信息保留**）

### 回滚（整份快照，或只撤一个插件）

| 目的 | Windows | macOS |
|---|---|---|
| 回滚到最近一次备份（两个插件都撤） | `.\scripts\rollback.ps1` | `bash scripts/rollback.sh` |
| 只撤移动网关（ds-bot 原样不动） | `.\scripts\rollback.ps1 -OnlyGateway` | `bash scripts/rollback.sh --only-gateway` |
| 只撤 ds-bot fork（网关原样不动） | `.\scripts\rollback.ps1 -OnlyDsBot` | `bash scripts/rollback.sh --only-dsbot` |
| 列出可用备份 | `.\scripts\rollback.ps1 -List` | `bash scripts/rollback.sh --list` |
| 回滚到指定备份 | `.\scripts\rollback.ps1 -Backup <目录>` | `bash scripts/rollback.sh --backup <目录>` |

参数以脚本自己的帮助输出为准：`bash scripts/rollback.sh --help`、`powershell -File scripts\rollback.ps1 -Help`。

- **整份回滚**：安装脚本每次安装前都会备份一次，回滚会把那次安装新增的插件目录
  与补装的运行依赖一起移除，并还原 `package.json` / `cordis.patch.yml`
- **单插件回滚**（`-OnlyGateway` / `-OnlyDsBot`）：只动你点名的那个插件——还原它在 `package.json`
  的登记（安装前有旧值就写回旧值，没有就删掉这一项）、撤它在 `cordis.patch.yml` 的配置块（只有网关有）、
  删它的 `node_modules` 目录与它补装的运行依赖；**另一个插件的目录与登记一个字节都不动**（有反向用例钉住）
  - 运行依赖只随**网关**撤（那 7 个目录属于网关的依赖闭包）；撤 ds-bot **不碰**依赖
  - 单插件回滚复用同一份备份里的 `state.txt`，**只读不写**：重复执行是安全的，已撤掉的项会被跳过，退出码仍为 0
  - macOS/Linux 上改 `package.json` 需要 `node` 或 `python3`；两个都没有时**预检直接拒绝（退出码 1）**，一个文件都不动。
    Windows 走 PowerShell 原生处理，无需额外工具
  - `package.json` 会被按标准两空格缩进重写（依赖内容不变）；`cordis.patch.yml` 只撤**本安装追加的那一块**
    （认安装脚本写的那行 `# dsh-suite: 手机连接需要开启…` 注释），**你自己写的 `- id: mobile-gateway` 配置块原样保留**，
    即使它就紧跟在安装块后面；安装前没有这个文件的，撤完会把文件删掉
  - **安装前就存在同名插件目录**（`state.txt` 记 `had:`，例如把 npm 原版换成本套）：备份里不保存旧版本文件，
    回滚**保留当前目录**（不删除），只把 `package.json` 的登记还原成安装前的值；网关升级还会保留它原有的
    `cordis` 配置块与已补装的运行依赖。输出会明确提示"保留当前目录，如需旧版请自备恢复"，
    不会让用户"新版本和旧版本都没有"。整份回滚与单插件回滚同口径
- 回滚从**安装时自动做的备份**恢复：备份路径取安装输出里的 `backup: <目录>` 那一行（机器可读锚点）
- **只撤 ds-bot 后**：手机仍能聊天，团队页回到降级名册、群里不弹卡 → 预期表现，不是故障
- **只撤网关后**：手机连不上，重新配对或重装网关即可；桌面 Bot 团队不受影响

### 卸载

- **只装过本包**：先 `rollback`（只想去掉一个插件就用 `-OnlyGateway` / `-OnlyDsBot`），再到 DSH 插件列表里移除对应插件
- **App**：手机上长按 **Whaleness** 删除即可（巨魔装的应用与普通应用一样删）

---

## 8. 常见问题

**1. 手机连不上，一直"正在重连"**
确认桌面移动网关**开着**、地址端口没变；确认手机与电脑**同一 Wi-Fi**（热点也可以）；关掉代理/VPN；
公司 Wi-Fi 常有客户端隔离 → 换热点验证。

**2. 配对码过期 / 扫码没反应**
配对码一次性，**重新生成**再扫；扫码时允许相机权限；已配对的设备不需要重复配对。

**3. 插件装了但 DSH 里看不到**
查 1.1 版本是否 ≥ 0.2.1-rc.1 → 重启 DSH → 看安装输出有没有被拦的报错 → 用 [2.5 手动兜底](#25-失败兜底手动安装脚本不可用时)。

**4. 我装的是 npm 上的 ds-bot，团队页还是降级**
原版没有本套的自研发布逻辑 → 换成本仓库 `plugins/ds-bot/`（fork 版）。

**5. 想在外面（不同网络）用手机连桌面**
网关支持公网隧道；开启后用隧道地址配对。**注意**：暴露公网请保留配对鉴权，别在公共机器上长期开着。

**6. 换电脑 / 换端口后手机连不上**
手机上删掉旧设备记录（或在网关面板里删设备）重新配对；配对与端口绑定。

**7. 团队页有名册但永远没实时状态**
ds-bot 没在运行或没启用（只有 Bot 干活时才有状态帧）；只看名册是网关的能力，不需要 ds-bot。

**8. 语言换成 English 后还是中文**
iOS 只在启动时读语言设置：按 App 内提示**退出再打开**（设置里语言行会标"需重启后生效"）。

**9. 巨魔安装时提示"不支持/无法安装"**
系统版本与巨魔不匹配 → 走 [3.5 自签备选](#35-备选无巨魔时自签安装sideloadly)。

---

## 附录：本包内容与校验

```
app/
  Orcarness-iOS16-20261031-0941.ipa   15,455,788 B
  sha256 5a017c5d353cd1ece27a434ada03812da52efef874d56eb1e172eb471e5e31d2
plugins/
  dsh-plugin-mobile-gateway/   0.10.4   （含 lib/ 产物，装完即用）
  ds-bot/                      0.2.0    （含 client.js 产物）
scripts/
  install.ps1 / install.sh     # 安装（默认全装；-OnlyGateway / -OnlyDsBot 选装）
  rollback.ps1 / rollback.sh   # 回滚（同样按插件粒度）
  sync-from-dev.sh             # 维护者：同步版本（白名单复制、原子替换、重建 manifest、自动改写本文档的 IPA 名/大小/sha）
docs/
  INSTALL.md                   # 本文
```

- App：`com.lichaofan.dshmobile`，显示名 **Whaleness**，最低 **iOS 16.0**（实时活动 16.2+）
- 许可证：各组件见其目录内 `LICENSE` / `NOTICE`（ds-bot fork 自上游 v0.2.0，Apache-2.0）
