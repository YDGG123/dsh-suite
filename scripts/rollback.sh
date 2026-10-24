#!/usr/bin/env bash
# dsh-suite 回滚：把 profile 恢复到安装前的状态。
#
# 用法：
#   bash scripts/rollback.sh                       # 回滚最近一次备份
#   bash scripts/rollback.sh --backup <备份目录>    # 回滚指定备份
#   bash scripts/rollback.sh --list                # 列出可用备份
#
# 备份由 install.sh 在安装前创建：profiles/<profile>/backups/dsh-suite-<时间戳>/
# 内含 package.json、cordis.patch.yml 与 state.txt（记录哪些目录是“原来就有/原来没有”）。
#
# 退出码：0 成功；1 预检失败；2 恢复失败；4 无备份可回滚
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
PROFILE=""
BACKUP=""
LIST=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
die()  { local code="$1"; shift; printf '❌ %s\n' "$*" >&2; exit "$code"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --backup)  BACKUP="${2:-}"; shift 2;;
    --profile) PROFILE="${2:-}"; shift 2;;
    --dsh-home) DSH_HOME="${2:-}"; shift 2;;
    --list)    LIST=1; shift;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die 4 "未知参数：$1";;
  esac
done

[ -d "$DSH_HOME/profiles" ] || die 1 "找不到 DSH 数据目录：$DSH_HOME/profiles"

if [ -z "$PROFILE" ]; then
  if [ -d "$DSH_HOME/profiles/desktop" ]; then PROFILE="desktop"
  else PROFILE="$(cd "$DSH_HOME/profiles" && ls -1d */ 2>/dev/null | sed 's#/##' | head -1)"; fi
fi
[ -n "$PROFILE" ] || die 1 "没有可用的 profile"
PROFILE_DIR="$DSH_HOME/profiles/$PROFILE"
MODULES="$PROFILE_DIR/node_modules"

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

say "== 回滚 profile：$PROFILE =="
say "  备份：$BACKUP"

if [ -f "$BACKUP/package.json" ]; then
  cp -p "$BACKUP/package.json" "$PROFILE_DIR/package.json" || die 2 "恢复 package.json 失败"
  ok "package.json 已恢复"
else
  say "  ! 备份里没有 package.json（安装前该文件可能不存在），跳过"
fi

if [ -f "$BACKUP/cordis.patch.yml" ]; then
  cp -p "$BACKUP/cordis.patch.yml" "$PROFILE_DIR/cordis.patch.yml" || die 2 "恢复 cordis.patch.yml 失败"
  ok "cordis.patch.yml 已恢复"
else
  say "  ! 备份里没有 cordis.patch.yml，跳过"
fi

# state.txt 里 `new:` 表示安装前没有这个目录 → 回滚时删掉；`had:` 表示原来有 → 提示手动恢复
while IFS= read -r line; do
  case "$line" in
    new:*) name="${line#new:}"; rm -rf "$MODULES/$name" && ok "移除安装时新增的目录：$name";;
    had:*) name="${line#had:}"; say "  ! $name 安装前就存在：已删除当前版本，如需旧版本请从你自己的备份恢复"; rm -rf "$MODULES/$name";;
    new-dep:*) dep="${line#new-dep:}"; rm -rf "$MODULES/$dep" && ok "移除补装的运行依赖：$dep";;
    had-dep:*) : ;;
  esac
done < "$BACKUP/state.txt"

say
say "== 完成 =="
say "  请完全退出 DeepSeek Harness 再重新打开，让插件列表刷新。"
exit 0
