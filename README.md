# dsh-suite · DeepSeek Harness 移动端全家桶（交钥匙包）

一个仓库装齐全套：**手机 App（iOS）+ 两个桌面插件**。照着 [安装指南](docs/INSTALL.md) 走，从 clone 到手机连上桌面端，一次完成。

## 这套东西是什么

- **Whaleness 手机 App**（iOS 16+）：在手机上访问 DeepSeek Harness 的会话、工作区、Agent 轨迹；**Bot 团队页**（名册/实时状态/头像，对齐桌面端）；群聊卡片（提问卡/展示卡/密钥卡）；实时活动（iOS 16.2+）
- **dsh-plugin-mobile-gateway**（桌面插件）：手机与桌面之间的通道——设备配对、实时帧、团队名册/卡片投影、局域网与公网隧道
- **ds-bot**（桌面插件，fork 版）：Bot 团队本体——群聊卡片、名册发布、密钥卡。**基于上游 [Fei2411/DeepSeek-Bot](https://github.com/Fei2411/DeepSeek-Bot) v0.2.0，含我们的自研功能**

## 快速开始（三步）

1. **桌面装插件**：电脑上进入本仓库，跑 `scripts/install.ps1`（Windows）或 `bash scripts/install.sh`（macOS）
2. **手机装 App**：用 [Sideloadly](https://sideloadly.io/) 把 `app/DshMobile-iOS16-v1.7.8-29.unsigned.ipa` 自签安装（详见 [安装指南](docs/INSTALL.md)）
3. **配对**：桌面 DSH 里开移动网关、生成配对码 → 手机扫码

完整步骤、验收清单、常见问题：**[docs/INSTALL.md](docs/INSTALL.md)**

## 目录

```
app/                          # 未签名 IPA（自签后安装）
  DshMobile-iOS16-v1.7.8-29.unsigned.ipa   (10,441,930 B)
  sha256: 5f8ae6a7e46dc0020eb00baca635ee42428897ac828e55a994095535124dd39f
plugins/
  dsh-plugin-mobile-gateway/  # 网关插件（含构建产物，装完即用）
  ds-bot/                     # ds-bot fork（含 client.js 构建产物）
scripts/
  install.ps1                 # Windows 一键装插件（含备份+校验）
  install.sh                  # macOS/Linux 同款
  rollback.ps1 / rollback.sh  # 一键回滚
  sync-from-dev.sh            # 维护者：从开发仓库同步新版本到本仓库
docs/
  INSTALL.md                  # 安装指南（Windows + iPhone iOS 16 为主）
```

## 要求

| 项 | 要求 |
|---|---|
| 桌面 | Windows / macOS，已安装 **DeepSeek Harness ≥ 0.2.1-rc.1** |
| 手机 | iPhone，**iOS 16.0+**（实时活动需 16.2+） |
| 签名 | 任一 Apple ID（免费即可，7 天重签一次；详见指南） |

## 上游与致谢

- App：基于 [Clarklevis1995/dsh-mobile](https://github.com/Clarklevis1995/dsh-mobile)（iOS 16 适配与团队功能为本套增强）
- 网关插件：[YDGG123/dsh-plugin-mobile-gateway](https://github.com/YDGG123/dsh-plugin-mobile-gateway)
- ds-bot：fork 自 [Fei2411/DeepSeek-Bot](https://github.com/Fei2411/DeepSeek-Bot) v0.2.0（Apache-2.0）

各组件许可证见其目录内 LICENSE/NOTICE。
