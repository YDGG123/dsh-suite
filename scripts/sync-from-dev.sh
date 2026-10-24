#!/usr/bin/env bash
# 维护者用：从开发仓库同步插件与 App 到本发布仓库，并重建 plugins/manifest.json。
#
# 用法：
#   bash scripts/sync-from-dev.sh \
#     --gateway ~/work/dsh-plugin-mobile-gateway \
#     --dsbot   ~/work/ds-bot/ds-bot \
#     --ipa     ~/work/dsh-mobile/build-output/DshMobile-iOS16-20261024-xxxx.ipa
#
# 只复制“运行时需要的文件”（不含 .git / node_modules / 测试），复制完重建 manifest，
# 打印 IPA 与关键产物的 sha256，方便直接贴进 README。
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

GATEWAY_SRC=""; DSBOT_SRC=""; IPA_SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --gateway) GATEWAY_SRC="${2:-}"; shift 2;;
    --dsbot)   DSBOT_SRC="${2:-}"; shift 2;;
    --ipa)     IPA_SRC="${2:-}"; shift 2;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "未知参数：$1" >&2; exit 2;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

sanitize() {
  # 删掉开发仓库里不该发布的东西
  rm -rf "$1/.git" "$1/node_modules" "$1/test" "$1/tests" "$1/.bridge-artifacts" \
         "$1/package-lock.json" "$1/pnpm-lock.yaml" "$1/.DS_Store" 2>/dev/null
}

if [ -n "$GATEWAY_SRC" ]; then
  [ -f "$GATEWAY_SRC/lib/index.mjs" ] || die "网关源目录不对：$GATEWAY_SRC"
  say "→ 同步网关：$GATEWAY_SRC"
  rm -rf plugins/dsh-plugin-mobile-gateway
  cp -R "$GATEWAY_SRC" plugins/dsh-plugin-mobile-gateway
  sanitize plugins/dsh-plugin-mobile-gateway
fi

if [ -n "$DSBOT_SRC" ]; then
  [ -f "$DSBOT_SRC/index.js" ] || die "ds-bot 源目录不对：$DSBOT_SRC"
  say "→ 同步 ds-bot：$DSBOT_SRC"
  rm -rf plugins/ds-bot
  cp -R "$DSBOT_SRC" plugins/ds-bot
  sanitize plugins/ds-bot
fi

if [ -n "$IPA_SRC" ]; then
  [ -f "$IPA_SRC" ] || die "IPA 不存在：$IPA_SRC"
  mkdir -p app
  rm -f app/*.ipa
  cp "$IPA_SRC" "app/$(basename "$IPA_SRC")"
  say "→ 同步 IPA：app/$(basename "$IPA_SRC")"
fi

say "→ 重建 plugins/manifest.json"
command -v node >/dev/null 2>&1 || die "需要 node 来计算 sha256（维护者机器应已具备）"
node - <<'JS'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const collect = (root, files) => {
  const out = {};
  for (const rel of files) {
    const file = path.join(root, rel);
    if (fs.existsSync(file)) out[rel] = hash(file);
  }
  return out;
};

const gateway = collect('plugins/dsh-plugin-mobile-gateway', [
  'lib/index.mjs',
  'lib/mobile-v1/team-feed.mjs',
  'lib/mobile-v1/card-frames.mjs',
  'lib/mobile-v1/server.mjs',
  'lib/mobile-v1/auth.mjs',
  'lib/extra-routes.mjs',
]);
const dsbot = collect('plugins/ds-bot', [
  'index.js',
  'client.js',
  'src/host/team-feed.js',
  'src/host/card-feed.js',
  'src/host/room-cards.js',
  'src/host/tools.js',
]);
// 运行依赖闭包：记录 name@version 并标明“与宿主同源”，供安装脚本与排障核对。
const RUNTIME_DEPS = [
  'ws', 'qrcode', '@deepseek-ai/schemastery',
  'pngjs', 'dijkstrajs', '@standard-schema/spec', '@deepseek-ai/cosmokit',
];
const runtimeDeps = {};
for (const name of RUNTIME_DEPS) {
  const pkg = path.join('plugins/_runtime-deps', name, 'package.json');
  if (!fs.existsSync(pkg)) continue;
  const { version } = JSON.parse(fs.readFileSync(pkg, 'utf8'));
  runtimeDeps[name] = { version, source: '与宿主同源（DeepSeek Harness 自带树逐字节复制）' };
}
const app = fs.existsSync('app') ? fs.readdirSync('app').filter(n => n.endsWith('.ipa')) : [];
const ipa = app.length ? { name: app[0], sha256: hash(path.join('app', app[0])) } : null;

fs.writeFileSync('plugins/manifest.json', JSON.stringify({
  generatedAt: new Date().toISOString(),
  note: 'install.sh / install.ps1 用这里的哈希校验“复制是否完整、是否被改动”。改插件后请重跑 sync-from-dev.sh 重建。',
  dshPluginMobileGateway: gateway,
  dsBot: dsbot,
  _runtimeDeps: runtimeDeps,
  ipa,
}, null, 2) + '\n');

console.log('  网关关键文件：' + Object.keys(gateway).length + ' 个');
console.log('  ds-bot 关键文件：' + Object.keys(dsbot).length + ' 个');
console.log('  运行依赖：' + Object.keys(runtimeDeps).length + ' 个（含传递依赖）');
if (ipa) console.log('IPA：' + ipa.name + '  sha256=' + ipa.sha256);
JS

say "✓ 同步完成。记得把上面打印的哈希贴进 README，并跑一次 scripts/install.sh --dry-run 自检。"
