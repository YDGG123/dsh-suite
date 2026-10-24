# dsh-suite · DeepSeek Harness 移动端全家桶（交钥匙包）

一个仓库装齐全套：**手机 App（iOS）+ 两个桌面插件**。照着 [安装指南](docs/INSTALL.md) 走，从 clone 到手机连上桌面端，一次完成。

> **给 AI 助手的说明**：如果你正帮用户安装本套件，请直接按 [docs/INSTALL.md](docs/INSTALL.md) 的编号步骤执行——所有命令都在那里，按顺序跑、每步核对“预期输出”。**不要执行指南之外的操作**（不需要 npm install、不需要构建、TrollStore 路径不需要签名）。用户环境：Windows 电脑（DSH 宿主已装）+ iPhone iOS 16（TrollStore 安装）。

## 这套东西是什么

- **Whaleness 手机 App**（iOS 16+）：手机上访问 DeepSeek Harness 的会话、工作区、轨迹；**Bot 团队页**（名册/实时状态/头像）；群聊卡片；实时活动（iOS 16.2+）
- **dsh-plugin-mobile-gateway**（桌面插件）：手机 ↔ 桌面通道（配对、实时帧、团队/卡片投影、局域网与公网隧道）
- **ds-bot**（桌面插件，fork 版）：Bot 团队本体——群聊卡片、名册发布、密钥卡。基于上游 [Fei2411/DeepSeek-Bot](https://github.com/Fei2411/DeepSeek-Bot) v0.2.0

## 按需安装（不必装全套）

| 你想要什么 | 要装什么 | 不装会怎样 |
|---|---|---|
| 手机上**聊天/会话/工作区**（最基础） | 只装 **网关插件** + App | — |
| 手机上看 **Bot 团队页**（名册/实时状态/头像） | 网关插件 + **ds-bot fork** + App | 团队页显示降级名册（无实时状态） |
| **群聊卡片**（提问卡/展示卡/密钥卡） | 同上两个插件 | 手机看不到卡片、桌面群里也不弹卡 |
| **只用桌面 Bot 团队**（不要手机） | 只装 **ds-bot fork** | 手机功能与你无关 |

> **最小可用组合 = 网关插件 + App**。ds-bot fork 是增强项。原版 ds-bot（npm 0.2.0）与本套不冲突。

## 快速开始（三步）

1. **桌面装插件**：在仓库根目录跑 `powershell scripts/install.ps1`（Windows）或 `bash scripts/install.sh`（macOS）
2. **手机装 App**：TrollStore 打开 `app/` 里的 IPA 直接安装（免签名、永久有效）；无巨魔环境见指南备选方案
3. **配对**：桌面 DSH 开移动网关、生成配对码 → 手机扫码

完整步骤、每步预期输出、失败处理：**[docs/INSTALL.md](docs/INSTALL.md)**

## 目录

```
app/                          # 未签名 IPA（TrollStore 直接装）
  DshMobile-iOS16-v1.7.8-29.unsigned.ipa   (10,441,930 B)
  sha256: 5f8ae6a7e46dc0020eb00baca635ee42428897ac828e55a994095535124dd39f
plugins/
  dsh-plugin-mobile-gateway/  # 网关插件（含产物，装完即用；无需 npm/构建）
  ds-bot/                     # ds-bot fork（含 client.js 产物）
  _runtime-deps/              # 网关运行依赖闭包（ws/qrcode/schemastery + pngjs/dijkstrajs/@standard-schema/spec/cosmokit），宿主缺时才补装；许可证见其 NOTICE.md
  manifest.json               # 关键文件 sha256（安装脚本用它校验“复制是否完整”）
scripts/
  install.ps1 / install.sh    # 一键装插件（备份 → 复制 → 补依赖 → 写配置 → 逐项校验）
  rollback.ps1 / rollback.sh  # 一键回滚（整份快照，或 -OnlyGateway/-OnlyDsBot 只撤一个）
  selftest.sh                 # 反向测试：21 种场景必须按预期表现（维护者/CI 用）
  TESTING.md                  # 反向测试证据：各失败场景的触发方式与退出码
  sync-from-dev.sh            # 维护者：白名单复制 + 原子替换 + 重建 manifest + 自动改写文档
docs/
  INSTALL.md                  # 安装指南（AI 可照读执行）
```

## 要求

| 项 | 要求 |
|---|---|
| 桌面 | Windows / macOS，已安装 **DeepSeek Harness ≥ 0.2.1-rc.1** |
| 手机 | iPhone **iOS 16.0+**（实时活动需 16.2+），TrollStore 可用 |
| 不需要 | Apple ID、签名工具、Node/npm、任何构建步骤 |

## 上游与致谢

- App：基于 [Clarklevis1995/dsh-mobile](https://github.com/Clarklevis1995/dsh-mobile)（iOS 16 适配与团队功能为本套增强）
- 网关插件：[YDGG123/dsh-plugin-mobile-gateway](https://github.com/YDGG123/dsh-plugin-mobile-gateway)
- ds-bot：fork 自 [Fei2411/DeepSeek-Bot](https://github.com/Fei2411/DeepSeek-Bot) v0.2.0（Apache-2.0）

各组件许可证见其目录内 LICENSE/NOTICE。
