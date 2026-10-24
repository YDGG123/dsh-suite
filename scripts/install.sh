#!/usr/bin/env bash
# dsh-suite 一键安装（macOS / Linux）。Windows 用 scripts/install.ps1（同一套逻辑）。
#
# 做的事：把仓库里的插件复制进 DeepSeek Harness 的 profile，补齐运行依赖，
#         写 cordis 配置块，然后**逐项校验**；任何一项不过都以非零退出。
#         安装前自动备份，回滚用 scripts/rollback.sh。
#
# 用法：
#   bash scripts/install.sh                 # 两个插件都装（默认）
#   bash scripts/install.sh --only-gateway  # 只装移动网关（最小组合：手机能聊天）
#   bash scripts/install.sh --only-dsbot    # 只装 ds-bot fork（桌面 Bot 团队增强）
#   bash scripts/install.sh --profile desktop
#   bash scripts/install.sh --dsh-home /path/to/.dsh
#   bash scripts/install.sh --verify-only    # 只校验已安装结果（自检/排障用）
#   bash scripts/install.sh --dry-run        # 只打印将要做什么，不落盘
#
# 退出码：0 成功；1 预检失败；2 安装/复制失败；3 校验失败；4 环境不支持
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONLY_GATEWAY=0
ONLY_DSBOT=0
VERIFY_ONLY=0
DRY_RUN=0
PROFILE=""
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"

GATEWAY_NAME="dsh-plugin-mobile-gateway"
DSBOT_NAME="ds-bot"
# 网关的运行依赖闭包（含传递依赖）：
#   qrcode 在模块加载期就要 pngjs / dijkstrajs（配对二维码是 QRCode.toString 生成的，
#   缺包会在“最小组合的最后一步（配对）”崩）；schemastery 要 @standard-schema/spec 与 cosmokit。
#   yargs 不补：只服务 qrcode 的 CLI，插件运行不需要。
GATEWAY_DEPS=("ws" "qrcode" "@deepseek-ai/schemastery" "pngjs" "dijkstrajs" "@standard-schema/spec" "@deepseek-ai/cosmokit")

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { local code="$1"; shift; printf '❌ %s\n' "$*" >&2; exit "$code"; }

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --only-gateway) ONLY_GATEWAY=1; shift;;
    --only-dsbot)   ONLY_DSBOT=1; shift;;
    --verify-only)  VERIFY_ONLY=1; shift;;
    --dry-run)      DRY_RUN=1; shift;;
    --profile)      PROFILE="${2:-}"; shift 2;;
    --dsh-home)     DSH_HOME="${2:-}"; shift 2;;
    -h|--help)      usage; exit 0;;
    *) die 4 "未知参数：$1（用 --help 看用法）";;
  esac
done

if [ "$ONLY_GATEWAY" -eq 1 ] && [ "$ONLY_DSBOT" -eq 1 ]; then
  die 4 "--only-gateway 与 --only-dsbot 不能同时用"
fi
WANT_GATEWAY=1
WANT_DSBOT=1
if [ "$ONLY_GATEWAY" -eq 1 ]; then WANT_DSBOT=0; fi
if [ "$ONLY_DSBOT" -eq 1 ]; then WANT_GATEWAY=0; fi

# ---------- 1. 预检 ----------
say "== 1/5 预检 =="
[ -d "$REPO_ROOT/plugins" ] || die 1 "找不到 plugins/ 目录，请在仓库根目录运行（当前：$REPO_ROOT）"

if [ "$WANT_GATEWAY" -eq 1 ]; then
  [ -f "$REPO_ROOT/plugins/$GATEWAY_NAME/lib/index.mjs" ] \
    || die 1 "仓库缺少 plugins/$GATEWAY_NAME/lib/index.mjs（仓库不完整，请重新 clone）"
fi
if [ "$WANT_DSBOT" -eq 1 ]; then
  [ -f "$REPO_ROOT/plugins/$DSBOT_NAME/index.js" ] \
    || die 1 "仓库缺少 plugins/$DSBOT_NAME/index.js（仓库不完整，请重新 clone）"
fi

[ -d "$DSH_HOME/profiles" ] || die 1 "找不到 DSH 数据目录：$DSH_HOME/profiles。请确认已安装 DeepSeek Harness（≥0.2.1-rc.1），或用 --dsh-home 指定"

if [ -z "$PROFILE" ]; then
  if [ -d "$DSH_HOME/profiles/desktop" ]; then
    PROFILE="desktop"
  else
    PROFILE="$(cd "$DSH_HOME/profiles" && ls -1d */ 2>/dev/null | sed 's#/##' | head -1)"
  fi
fi
[ -n "$PROFILE" ] || die 1 "$DSH_HOME/profiles 下没有任何 profile，请先在 DeepSeek Harness 里建一个"
PROFILE_DIR="$DSH_HOME/profiles/$PROFILE"
[ -d "$PROFILE_DIR" ] || die 1 "profile 不存在：$PROFILE_DIR"
[ -f "$PROFILE_DIR/package.json" ] || die 2 "profile 里没有 package.json：$PROFILE_DIR（这个 profile 可能没初始化过）"
MODULES="$PROFILE_DIR/node_modules"
[ -d "$MODULES" ] || die 2 "profile 里没有 node_modules：$MODULES（请先启动一次 DeepSeek Harness，让它自己初始化）"
ok "DSH 数据目录：$DSH_HOME"
ok "目标 profile：$PROFILE（$PROFILE_DIR）"

have_json_editor=0
command -v node >/dev/null 2>&1 && have_json_editor=1
command -v python3 >/dev/null 2>&1 && have_json_editor=1

# ---------- 2. 备份 ----------
STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_DIR="$PROFILE_DIR/backups/dsh-suite-$STAMP"
say
say "== 2/5 备份 =="
if [ "$DRY_RUN" -eq 1 ]; then
  say "  (dry-run) 将备份到：$BACKUP_DIR"
elif [ "$VERIFY_ONLY" -eq 0 ]; then
  mkdir -p "$BACKUP_DIR" || die 2 "无法创建备份目录：$BACKUP_DIR"
  for f in package.json cordis.patch.yml; do
    [ -f "$PROFILE_DIR/$f" ] && cp -p "$PROFILE_DIR/$f" "$BACKUP_DIR/$f"
  done
  {
    for name in "$GATEWAY_NAME" "$DSBOT_NAME"; do
      if [ -d "$MODULES/$name" ]; then echo "had:$name"; else echo "new:$name"; fi
    done
    for dep in "${GATEWAY_DEPS[@]}"; do
      if [ -d "$MODULES/$dep" ]; then echo "had-dep:$dep"; else echo "new-dep:$dep"; fi
    done
  } > "$BACKUP_DIR/state.txt"
  ok "备份完成：$BACKUP_DIR（回滚用 scripts/rollback.sh）"
  # 机器可读锚点：AI/文档按这一行取备份路径（别依赖中文措辞）
  say "backup: $BACKUP_DIR"
fi

# ---------- 3. 安装 ----------
say
say "== 3/5 安装插件 =="
install_plugin() {
  local name="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  (dry-run) 复制 plugins/$name → $MODULES/$name"
    return 0
  fi
  rm -rf "$MODULES/$name" || die 2 "无法删除旧目录：$MODULES/$name（是否被 DeepSeek Harness 占用？先退出宿主再试）"
  cp -R "$REPO_ROOT/plugins/$name" "$MODULES/$name" || die 2 "复制失败：$name"
  ok "$name 已复制到 node_modules"
}

install_deps() {
  local dep
  for dep in "${GATEWAY_DEPS[@]}"; do
    if [ -f "$MODULES/$dep/package.json" ]; then
      ok "运行依赖已在位：$dep"
      continue
    fi
    [ -d "$REPO_ROOT/plugins/_runtime-deps/$dep" ] || die 2 "仓库缺少 plugins/_runtime-deps/$dep（网关需要它）"
    if [ "$DRY_RUN" -eq 1 ]; then
      say "  (dry-run) 补运行依赖：$dep"
      continue
    fi
    mkdir -p "$(dirname "$MODULES/$dep")"
    cp -R "$REPO_ROOT/plugins/_runtime-deps/$dep" "$MODULES/$dep" || die 2 "复制运行依赖失败：$dep"
    ok "补上运行依赖：$dep"
  done
}

record_dependency() {
  local name="$1"
  [ "$have_json_editor" -eq 1 ] || { warn "本机没有 node/python3，跳过 package.json 依赖登记（插件仍已复制，重启后应可见）"; return 0; }
  local file="$PROFILE_DIR/package.json"
  local target="$REPO_ROOT/plugins/$name"
  if command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const [file, name, target] = process.argv.slice(1);
const data = JSON.parse(fs.readFileSync(file, "utf8"));
data.dependencies = data.dependencies || {};
data.dependencies[name] = "file:" + target;
fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
' "$file" "$name" "$target" || die 2 "写入 package.json 失败"
  else
    python3 - "$file" "$name" "$target" <<'PY' || die 2 "写入 package.json 失败"
import json, sys
file, name, target = sys.argv[1:4]
with open(file, encoding="utf-8") as fh:
    data = json.load(fh)
data.setdefault("dependencies", {})[name] = "file:" + target
with open(file, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
  fi
  ok "package.json 已登记：$name → file:$target"
}

ensure_cordis_block() {
  local file="$PROFILE_DIR/cordis.patch.yml"
  if [ ! -f "$file" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then say "  (dry-run) 将新建 cordis.patch.yml"; return 0; fi
    printf '# dsh-suite: 移动网关配置（手机连接用）\n' > "$file"
  fi
  if grep -q "dsh-plugin-mobile-gateway" "$file"; then
    ok "cordis.patch.yml 里已有移动网关配置块（保留你的设置，不覆盖）"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then say "  (dry-run) 将追加移动网关配置块"; return 0; fi
  [ -n "$(tail -c 1 "$file")" ] && printf '\n' >> "$file"
  cat >> "$file" <<'YAML'

# dsh-suite: 手机连接需要开启 mobile-v1 通道（配对/团队帧都在这个前缀下）
- id: mobile-gateway
  name: dsh-plugin-mobile-gateway
  config:
    gatewayEnabled: false
    mobileV1Enabled: true
    gatewayWaitTimeoutMs: 300000
YAML
  ok "cordis.patch.yml 已追加移动网关配置块"
}

if [ "$VERIFY_ONLY" -eq 0 ]; then
  [ "$WANT_GATEWAY" -eq 1 ] && { install_plugin "$GATEWAY_NAME"; install_deps; }
  [ "$WANT_DSBOT" -eq 1 ]   && install_plugin "$DSBOT_NAME"
  if [ "$DRY_RUN" -eq 0 ]; then
    [ "$WANT_GATEWAY" -eq 1 ] && record_dependency "$GATEWAY_NAME"
    [ "$WANT_DSBOT" -eq 1 ]   && record_dependency "$DSBOT_NAME"
  fi
  [ "$WANT_GATEWAY" -eq 1 ] && ensure_cordis_block
fi

# ---------- 4. 校验 ----------
say
say "== 4/5 校验 =="
if [ "$DRY_RUN" -eq 1 ]; then
  say "  (dry-run) 跳过校验（未落盘）"
  say
  say "== 5/5 完成（未改动任何文件）=="
  exit 0
fi
verify_fail=0
fail() { printf '  ✗ %s\n' "$*"; verify_fail=1; }

sha_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

check_hash() {
  local file="$1" expect="$2" label="$3"
  [ -f "$file" ] || { fail "$label 缺失：$file"; return; }
  local actual; actual="$(sha_of "$file")"
  [ "$actual" = "$expect" ] || fail "$label 哈希不符（期望 ${expect:0:12}…，实际 ${actual:0:12}…）"
}

if [ "$WANT_GATEWAY" -eq 1 ]; then
  G="$MODULES/$GATEWAY_NAME"
  for f in lib/index.mjs lib/mobile-v1/team-feed.mjs lib/mobile-v1/card-frames.mjs lib/mobile-v1/server.mjs; do
    [ -f "$G/$f" ] || fail "网关缺文件：$f"
  done
  # 关键产物哈希取自仓库内 manifest（与仓库一致 = 复制完整）
  if [ -f "$REPO_ROOT/plugins/manifest.json" ] && command -v node >/dev/null 2>&1; then
    while IFS=$'\t' read -r rel expect; do
      [ -n "$rel" ] || continue
      check_hash "$G/$rel" "$expect" "网关 $rel"
    done < <(node -e '
const m = require(process.argv[1]);
for (const [k, v] of Object.entries(m.dshPluginMobileGateway || {})) console.log(k + "\t" + v);
' "$REPO_ROOT/plugins/manifest.json")
  fi
  for dep in "${GATEWAY_DEPS[@]}"; do
    [ -f "$MODULES/$dep/package.json" ] || fail "网关运行依赖缺失：$dep"
  done
  if [ "$verify_fail" -eq 0 ]; then ok "网关：文件齐全、哈希与仓库一致、运行依赖在位"; else printf 'CHECK gateway: FAIL\n'; fi
fi

if [ "$WANT_DSBOT" -eq 1 ]; then
  D="$MODULES/$DSBOT_NAME"
  for f in index.js client.js src/host/team-feed.js src/host/card-feed.js src/host/room-cards.js; do
    [ -f "$D/$f" ] || fail "ds-bot 缺文件：$f（可能装成了上游原版）"
  done
  # 自研能力的存在性判据：dsBotCards（卡片帧发布）与 teamFeed（名册发布）
  cards=$(grep -rl "dsBotCards" "$D/src/host" 2>/dev/null | wc -l | tr -d ' ')
  [ "${cards:-0}" -ge 1 ] || fail "ds-bot 没有 dsBotCards 服务（装成了上游原版？手机团队页/卡片会缺失）"
  roster=$(grep -rl "teamFeed" "$D/src/host" 2>/dev/null | wc -l | tr -d ' ')
  [ "${roster:-0}" -ge 1 ] || fail "ds-bot 没有 teamFeed（名册发布缺失，手机团队页只会是降级名册）"
  if [ -f "$REPO_ROOT/plugins/manifest.json" ] && command -v node >/dev/null 2>&1; then
    while IFS=$'\t' read -r rel expect; do
      [ -n "$rel" ] || continue
      check_hash "$D/$rel" "$expect" "ds-bot $rel"
    done < <(node -e '
const m = require(process.argv[1]);
for (const [k, v] of Object.entries(m.dsBot || {})) console.log(k + "\t" + v);
' "$REPO_ROOT/plugins/manifest.json")
  fi
  if [ "$verify_fail" -eq 0 ]; then ok "ds-bot：文件齐全、哈希与仓库一致、含 dsBotCards"; else printf 'CHECK dsbot: FAIL\n'; fi
fi

if [ -f "$PROFILE_DIR/cordis.patch.yml" ] && [ "$WANT_GATEWAY" -eq 1 ]; then
  grep -q "dsh-plugin-mobile-gateway" "$PROFILE_DIR/cordis.patch.yml" \
    || fail "cordis.patch.yml 里没有移动网关配置块"
fi
if [ "$have_json_editor" -eq 1 ] && [ "$VERIFY_ONLY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  for pair in "$WANT_GATEWAY:$GATEWAY_NAME" "$WANT_DSBOT:$DSBOT_NAME"; do
    want="${pair%%:*}"; name="${pair##*:}"
    [ "$want" -eq 1 ] || continue
    grep -q "\"$name\"" "$PROFILE_DIR/package.json" || fail "package.json 里没有登记 $name"
  done
fi

if [ "$verify_fail" -ne 0 ]; then
  printf 'RESULT: FAIL\n'
  die 3 "校验未通过（看上面 ✗ 的项）。可用 scripts/rollback.sh 还原"
fi
[ "$WANT_GATEWAY" -eq 1 ] && printf 'CHECK gateway: PASS\n'
[ "$WANT_DSBOT" -eq 1 ] && printf 'CHECK dsbot: PASS\n'
printf 'RESULT: PASS\n'

# ---------- 5. 完成 ----------
say
say "== 5/5 完成 =="
say "  已安装：$( [ "$WANT_GATEWAY" -eq 1 ] && printf '移动网关 ' ; [ "$WANT_DSBOT" -eq 1 ] && printf 'ds-bot ' )"
say "  下一步："
say "    1) 完全退出 DeepSeek Harness 再重新打开（插件在启动时加载）"
say "    2) 设置 → 插件，确认上面这两个插件出现且已启用"
say "    3) 设置 → 移动网关：按 docs/INSTALL.md 第 4 步生成配对码，手机扫码"
if [ "$VERIFY_ONLY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  say "  备份：$BACKUP_DIR（回滚：bash scripts/rollback.sh --backup \"$BACKUP_DIR\"）"
fi
exit 0
