#!/usr/bin/env bash
# dsh-suite 回滚：把 profile 恢复到安装前的状态。
#
# 用法：
#   bash scripts/rollback.sh                          # 回滚最近一次备份（两个插件都撤）
#   bash scripts/rollback.sh --backup <备份目录>       # 回滚指定备份（两个插件都撤）
#   bash scripts/rollback.sh --only-gateway            # 只撤移动网关，另一个插件原样不动
#   bash scripts/rollback.sh --only-dsbot              # 只撤 ds-bot fork，另一个插件原样不动
#   bash scripts/rollback.sh --list                   # 列出可用备份
#   bash scripts/rollback.sh --profile <名字>          # 指定 profile（默认 desktop）
#   bash scripts/rollback.sh --dsh-home <路径>         # 指定 DSH 数据目录（默认 ~/.dsh）
#
# 备份由 install.sh 在安装前创建：profiles/<profile>/backups/dsh-suite-<时间戳>/
# 内含 package.json、cordis.patch.yml 与 state.txt（记录哪些目录是“原来就有/原来没有”）。
#
# 单插件回滚复用同一份备份与 state.txt，并且**只读**它：只还原该插件在 package.json /
# cordis.patch.yml 里的登记、删它的目录和它补装的运行依赖；另一个插件与它的登记不动。
# 撤网关才会撤运行依赖（那 7 个目录只属于网关闭包）；撤 ds-bot 绝不碰依赖。
# 重复执行是安全的：已经撤掉的项会被跳过，仍然退出 0。
#
# 退出码：0 成功；1 预检失败；2 恢复失败；4 无备份可回滚 / 参数非法
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
PROFILE=""
BACKUP=""
LIST=0
ONLY_GATEWAY=0
ONLY_DSBOT=0

GATEWAY_NAME="dsh-plugin-mobile-gateway"
DSBOT_NAME="ds-bot"
# 只认安装脚本自己写的那行注释：用户自己也可能有 `- id: mobile-gateway` 配置块，
# 没有这行注释的块一律不碰。
GATEWAY_BLOCK_COMMENT="# dsh-suite: 手机连接需要开启"
GATEWAY_HEADER="# dsh-suite: 移动网关配置（手机连接用）"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { local code="$1"; shift; printf '❌ %s\n' "$*" >&2; exit "$code"; }

usage() { sed -n '/^# 用法：/,/^# 退出码/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --backup)       BACKUP="${2:-}"; shift 2;;
    --profile)      PROFILE="${2:-}"; shift 2;;
    --dsh-home)     DSH_HOME="${2:-}"; shift 2;;
    --only-gateway) ONLY_GATEWAY=1; shift;;
    --only-dsbot)   ONLY_DSBOT=1; shift;;
    --list)         LIST=1; shift;;
    -h|--help)      usage; exit 0;;
    *) die 4 "未知参数：$1（用 --help 看用法）";;
  esac
done

if [ "$ONLY_GATEWAY" -eq 1 ] && [ "$ONLY_DSBOT" -eq 1 ]; then
  die 4 "--only-gateway 与 --only-dsbot 不能同时用"
fi
# 不带 --only-* 是整份回滚（老行为）；带上就只撤那一个。
SINGLE=0
WANT_GATEWAY=1
WANT_DSBOT=1
if [ "$ONLY_GATEWAY" -eq 1 ]; then SINGLE=1; WANT_DSBOT=0; fi
if [ "$ONLY_DSBOT" -eq 1 ]; then SINGLE=1; WANT_GATEWAY=0; fi

[ -d "$DSH_HOME/profiles" ] || die 1 "找不到 DSH 数据目录：$DSH_HOME/profiles"

if [ -z "$PROFILE" ]; then
  if [ -d "$DSH_HOME/profiles/desktop" ]; then PROFILE="desktop"
  else PROFILE="$(cd "$DSH_HOME/profiles" && ls -1d */ 2>/dev/null | sed 's#/##' | head -1)"; fi
fi
[ -n "$PROFILE" ] || die 1 "没有可用的 profile"
PROFILE_DIR="$DSH_HOME/profiles/$PROFILE"
MODULES="$PROFILE_DIR/node_modules"
PROFILE_PKG="$PROFILE_DIR/package.json"
PROFILE_CORDIS="$PROFILE_DIR/cordis.patch.yml"

if [ "$LIST" -eq 1 ]; then
  shopt -s nullglob
  backups=("$PROFILE_DIR"/backups/dsh-suite-*)
  if [ ${#backups[@]} -eq 0 ]; then say "（$PROFILE 没有备份）"; exit 0; fi
  say "可用备份（新→旧）："
  for b in $(printf '%s\n' "${backups[@]}" | sort -r); do
    say "  $b"
  done
  exit 0
fi

if [ -z "$BACKUP" ]; then
  shopt -s nullglob
  candidates=("$PROFILE_DIR"/backups/dsh-suite-*)
  [ ${#candidates[@]} -gt 0 ] || die 4 "没有备份可回滚（$PROFILE_DIR/backups 为空）。若是手动安装，请按指南 2.4 反向删除 node_modules 里的插件目录。"
  BACKUP="$(printf '%s\n' "${candidates[@]}" | sort -r | head -1)"
fi
[ -d "$BACKUP" ] || die 1 "备份目录不存在：$BACKUP"
[ -f "$BACKUP/state.txt" ] || die 1 "备份不完整（缺 state.txt）：$BACKUP。为避免误删，拒绝继续。"

# 单插件回滚要改 package.json，必须先确认有能把 JSON 改对且改完仍合法的工具。
# 整份回滚是整文件覆盖，不需要（老路径不引入新前置）。
HAVE_NODE=0
HAVE_PY=0
if [ "$SINGLE" -eq 1 ]; then
  command -v node >/dev/null 2>&1 && HAVE_NODE=1
  command -v python3 >/dev/null 2>&1 && HAVE_PY=1
  [ "$HAVE_NODE" -eq 1 ] || [ "$HAVE_PY" -eq 1 ] \
    || die 1 "单插件回滚要改 package.json，但本机既没有 node 也没有 python3。请先装其一，或手动删掉 package.json 里该插件的依赖项后再跑。"
  [ -f "$PROFILE_PKG" ] || die 1 "profile 里没有 package.json：$PROFILE_PKG（无法还原插件登记）"
  # 改之前先确认它是合法 JSON：坏文件上动手只会让宿主更难恢复。
  if [ "$HAVE_NODE" -eq 1 ]; then
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$PROFILE_PKG" 2>/dev/null \
      || die 1 "package.json 不是合法 JSON，拒绝改动：$PROFILE_PKG。先把它修好再回滚。"
  else
    python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$PROFILE_PKG" 2>/dev/null \
      || die 1 "package.json 不是合法 JSON，拒绝改动：$PROFILE_PKG。先把它修好再回滚。"
  fi
fi

# 把该插件在 package.json 的登记还原成安装前的样子：备份里有旧值就写回旧值，
# 没有（安装时新增）就删掉这一项。别的依赖一个不动。输出 restored/removed/unchanged。
restore_registration() {
  local name="$1" out
  if [ "$HAVE_NODE" -eq 1 ]; then
    out="$(node -e '
const fs = require("fs");
const [file, backup, name] = process.argv.slice(1);
const read = (path) => {
  try { return JSON.parse(fs.readFileSync(path, "utf8")); } catch { return undefined; }
};
const data = read(file);
if (data === undefined || data === null || typeof data !== "object") process.exit(1);
const before = read(backup);
const old = before && before.dependencies && Object.prototype.hasOwnProperty.call(before.dependencies, name)
  ? before.dependencies[name]
  : undefined;
data.dependencies = data.dependencies || {};
const had = Object.prototype.hasOwnProperty.call(data.dependencies, name);
if (old === undefined) {
  if (!had) { process.stdout.write("unchanged\n"); process.exit(0); }
  delete data.dependencies[name];
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
  process.stdout.write("removed\n");
} else {
  if (had && data.dependencies[name] === old) { process.stdout.write("unchanged\n"); process.exit(0); }
  data.dependencies[name] = old;
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
  process.stdout.write("restored\n");
}
' "$PROFILE_PKG" "$BACKUP/package.json" "$name")" || die 2 "改写 package.json 失败：$name"
  else
    out="$(python3 - "$PROFILE_PKG" "$BACKUP/package.json" "$name" <<'PY'
import json, sys
file, backup, name = sys.argv[1:4]
def read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None
data = read(file)
if not isinstance(data, dict):
    sys.exit(1)
before = read(backup)
old = None
has_old = isinstance(before, dict) and isinstance(before.get("dependencies"), dict) and name in before["dependencies"]
if has_old:
    old = before["dependencies"][name]
deps = data.get("dependencies")
if not isinstance(deps, dict):
    deps = {}
    data["dependencies"] = deps
had = name in deps
if old is None:
    if not had:
        print("unchanged")
        sys.exit(0)
    del deps[name]
else:
    if had and deps[name] == old:
        print("unchanged")
        sys.exit(0)
    deps[name] = old
with open(file, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
print("removed" if old is None else "restored")
PY
)" || die 2 "改写 package.json 失败：$name"
  fi
  case "$out" in
    removed)   ok "package.json 已撤销登记：$name";;
    restored)  ok "package.json 已还原登记：$name（安装前的旧值）";;
    unchanged) say "  · package.json 无需改动：$name（已处于回滚状态）";;
    *)         die 2 "改写 package.json 失败：$name（输出：$out）";;
  esac
}

# 只移除安装脚本追加的那一块：它以 GATEWAY_BLOCK_COMMENT 开头，下面跟 `- id: mobile-gateway`
# 与缩进子行。用户自己的 mobile-gateway 块没有这行注释，绝不触碰；备份里有没有都不影响判断
# （重装后回滚时，上一轮追加的块也是我们写的，删掉才对——否则会留一个指向空目录的配置）。
remove_gateway_block() {
  local file="$PROFILE_CORDIS"
  local backup="$BACKUP/cordis.patch.yml"
  [ -f "$file" ] || { say "  · cordis.patch.yml 不存在（无需撤除）"; return 0; }
  if ! grep -qF "$GATEWAY_BLOCK_COMMENT" "$file"; then
    say "  · cordis.patch.yml 里没有本安装追加的配置块（保留你的设置）"
    return 0
  fi
  # 升级场景：安装前这份备份里已经有我们追加的块，说明它本来就该在 → 保留。
  if [ -f "$backup" ] && grep -qF "$GATEWAY_BLOCK_COMMENT" "$backup"; then
    say "  · 安装前就有该配置块：保留（回到安装前的样子）"
    return 0
  fi
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/dsh-suite-cordis.XXXXXX")" || die 2 "无法创建临时文件"
  awk -v mark="$GATEWAY_BLOCK_COMMENT" '
    { line = $0 }
    skip == 1 {
      if (line == "") next
      if (line ~ /^[[:space:]]/) next
      # 安装块的块首 `- id: mobile-gateway` 只认一次；之后再出现顶格行（例如用户自己
      # 紧跟其后的 `- id: mobile-gateway` 块）就结束跳过，把它原样留下。
      if (seenid == 0 && line ~ /^- id: mobile-gateway[[:space:]]*$/) { seenid = 1; next }
      skip = 0
    }
    index(line, mark) == 1 { skip = 1; seenid = 0; next }
    { lines[++count] = line }
    END { for (i = 1; i <= count; i++) print lines[i] }
  ' "$file" > "$tmp" || { rm -f "$tmp"; die 2 "处理 cordis.patch.yml 失败"; }
  # 安装时新建的文件：撤完只剩注释/空白就整份删掉，回到“本来没有”。
  if [ ! -f "$backup" ] && ! grep -qvE '^([[:space:]]*|# dsh-suite:.*)$' "$tmp"; then
    rm -f "$tmp" "$file" || die 2 "移除 cordis.patch.yml 失败"
    ok "cordis.patch.yml 是安装时新建的，已移除（安装前没有这个文件）"
    return 0
  fi
  if cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
    say "  · cordis.patch.yml 无需改动（已处于回滚状态）"
    return 0
  fi
  mv "$tmp" "$file" || { rm -f "$tmp"; die 2 "写回 cordis.patch.yml 失败：$file"; }
  ok "cordis.patch.yml 已撤除本安装追加的移动网关配置块"
}

plugin_had() { grep -qx "had:$1" "$BACKUP/state.txt" 2>/dev/null; }

remove_plugin_dir() {
  local name="$1"
  if plugin_had "$name"; then
    # 安装前就有这个目录：备份里没有旧版本可还原，删掉只会让用户两边都没有。
    warn "$name 安装前就存在：备份里没有旧版本，保留当前目录（不删除）；如需旧版请从你自己的备份恢复"
    return 0
  fi
  if [ -e "$MODULES/$name" ] || [ -L "$MODULES/$name" ]; then
    rm -rf "$MODULES/$name" || die 2 "删除插件目录失败：$MODULES/$name（是否被 DeepSeek Harness 占用？先退出宿主再试）"
    ok "移除安装时新增的目录：$name"
  else
    say "  · $name 目录不在（已处于回滚状态）"
  fi
}

remove_new_deps() {
  local line dep removed=0
  while IFS= read -r line; do
    case "$line" in
      new-dep:*)
        dep="${line#new-dep:}"
        if [ -e "$MODULES/$dep" ] || [ -L "$MODULES/$dep" ]; then
          rm -rf "$MODULES/$dep" || die 2 "删除运行依赖失败：$MODULES/$dep（是否被 DeepSeek Harness 占用？先退出宿主再试）"
          ok "移除补装的运行依赖：$dep"
          removed=1
        fi;;
    esac
  done < "$BACKUP/state.txt"
  [ "$removed" -eq 1 ] || say "  · 补装的运行依赖已不在（已处于回滚状态）"
}

say "== 回滚 profile：$PROFILE =="
say "  备份：$BACKUP"
if [ "$SINGLE" -eq 1 ]; then
  say "  范围：只撤 $( [ "$WANT_GATEWAY" -eq 1 ] && printf '移动网关' ; [ "$WANT_DSBOT" -eq 1 ] && printf 'ds-bot fork' )（另一个插件原样不动）"
else
  say "  范围：整份快照（两个插件都撤）"
fi

if [ "$SINGLE" -eq 1 ]; then
  # 先还原登记、再删目录：万一登记写不进去，插件目录还在，宿主不会停在“登记在、文件没了”。
  [ "$WANT_GATEWAY" -eq 1 ] && restore_registration "$GATEWAY_NAME"
  [ "$WANT_DSBOT" -eq 1 ]   && restore_registration "$DSBOT_NAME"
  [ "$WANT_GATEWAY" -eq 1 ] && remove_gateway_block
  if [ "$WANT_GATEWAY" -eq 1 ]; then
    remove_plugin_dir "$GATEWAY_NAME"
    # 网关安装前就有（升级）→ 目录保留，它补装的运行依赖也跟着保留，否则保留的目录跑不起来。
    plugin_had "$GATEWAY_NAME" || remove_new_deps
  fi
  [ "$WANT_DSBOT" -eq 1 ] && remove_plugin_dir "$DSBOT_NAME"
else
  if [ -f "$BACKUP/package.json" ]; then
    cp -p "$BACKUP/package.json" "$PROFILE_PKG" || die 2 "恢复 package.json 失败"
    ok "package.json 已恢复"
  else
    say "  ! 备份里没有 package.json（安装前该文件可能不存在），跳过"
  fi

  if [ -f "$BACKUP/cordis.patch.yml" ]; then
    cp -p "$BACKUP/cordis.patch.yml" "$PROFILE_CORDIS" || die 2 "恢复 cordis.patch.yml 失败"
    ok "cordis.patch.yml 已恢复"
  else
    say "  ! 备份里没有 cordis.patch.yml，跳过"
  fi

  # state.txt 里 `new:` 表示安装前没有这个目录 → 回滚时删掉；`had:` 表示原来有 → 保留当前目录并提示
  while IFS= read -r line; do
    case "$line" in
      new:*) name="${line#new:}"; rm -rf "$MODULES/$name" && ok "移除安装时新增的目录：$name";;
      had:*) name="${line#had:}"; warn "$name 安装前就存在：备份里没有旧版本，保留当前目录（不删除）；如需旧版请从你自己的备份恢复";;
      new-dep:*) dep="${line#new-dep:}"; rm -rf "$MODULES/$dep" && ok "移除补装的运行依赖：$dep";;
      had-dep:*) : ;;
    esac
  done < "$BACKUP/state.txt"
fi

say
say "== 完成 =="
say "  请完全退出 DeepSeek Harness 再重新打开，让插件列表刷新。"
exit 0
