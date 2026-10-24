# 运行依赖（`_runtime-deps/`）说明

这些目录**不是**本仓库开发的代码，而是 **DeepSeek Harness 宿主自带的 npm 包**，
逐字节复制过来，用于「宿主缺包时安装脚本能补齐」这一种兜底场景。

| 包 | 版本 | 许可证 | 上游 |
| --- | --- | --- | --- |
| `ws` | 8.22.0 | MIT | https://github.com/websockets/ws |
| `qrcode` | 1.5.4 | MIT | https://github.com/soldair/node-qrcode |
| `@deepseek-ai/schemastery` | 3.18.5 | MIT | https://github.com/deepseek-ai/deepseek-harness |
| `pngjs` | 5.0.0 | MIT | https://github.com/lukeapage/pngjs |
| `dijkstrajs` | 1.0.3 | MIT | https://github.com/tcort/dijkstrajs |
| `@standard-schema/spec` | 1.1.0 | MIT | https://github.com/standard-schema/standard-schema |
| `@deepseek-ai/cosmokit` | 1.8.6 | MIT | https://github.com/deepseek-ai/deepseek-harness |

## 为什么需要传递依赖

`qrcode` 在**模块加载期**就会 `require('pngjs')` 与 `require('dijkstrajs')`，
`schemastery` 加载期需要 `@standard-schema/spec` 与 `@deepseek-ai/cosmokit`。
只带直接依赖时，缺包会在**最小组合的最后一步（生成配对二维码）**才崩——
兜底生效的唯一场景正好是最关键步骤，所以必须是完整闭包。

`yargs` 不在此列：它只服务 `qrcode` 的命令行工具，插件运行路径不需要。

## 维护规则

- 版本与内容必须与宿主树**逐字节一致**（`cp -R` 复制，不做改写/压缩/二次打包）。
- 升级宿主后如这些包版本变化，重新从宿主树复制并重跑 `scripts/sync-from-dev.sh`
  重建 `plugins/manifest.json`（`_runtimeDeps` 段会记录 name@version）。
- 许可证与 NOTICE 义务：以上均为 MIT，随包保留各自的 `LICENSE` 文件；
  本文件即汇总声明，再分发时请一并保留。
