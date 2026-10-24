#!/usr/bin/env bash
# 反向测试：故意把安装/校验/回滚搞坏，确认它们**真的会红**。
#
# 只跑绿不算证明——这个脚本在临时 HOME 里造沙箱 profile，跑 5 种坏情况：
#   R1 装错目录（DSH_HOME 不存在）            → 预检失败，退出码 1
#   R2 仓库不完整（临时藏起网关 lib/index）    → 预检失败，退出码 1
#   R3 半装（复制后删掉一个关键文件）          → 校验失败，退出码 3
#   R4 改一个字节（哈希不符）                  → 校验失败，退出码 3
#   R5 无备份回滚                              → 拒绝执行，退出码 4
#
# 用法：bash scripts/selftest.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/dsh-suite-selftest.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; failn=0
expect_code() {
  local label="$1" want="$2"; shift 2
  "$@" >"$SANDBOX/out.log" 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    printf '  ✓ %-46s 退出码 %s（符合预期）\n' "$label" "$got"; pass=$((pass+1))
  else
    printf '  ✗ %-46s 期望退出码 %s，实际 %s\n' "$label" "$want" "$got"
    sed 's/^/      /' "$SANDBOX/out.log" | tail -6
    failn=$((failn+1))
  fi
}

new_home() {
  local name="$1"
  local home="$SANDBOX/$name"
  mkdir -p "$home/.dsh/profiles/desktop/node_modules"
  printf '{"name":"dsh-profile-desktop","dependencies":{}}\n' > "$home/.dsh/profiles/desktop/package.json"
  printf '# patch\n' > "$home/.dsh/profiles/desktop/cordis.patch.yml"
  printf '%s' "$home"
}

printf '== 反向测试（每条都应“红”）==\n'

# R1：装错目录
( cd "$REPO_ROOT" && DSH_HOME="$SANDBOX/nope" bash scripts/install.sh )
expect_code "R1 装错目录（DSH_HOME 不存在）" 1 env DSH_HOME="$SANDBOX/nope" bash "$REPO_ROOT/scripts/install.sh"

# R2：仓库不完整（用一个只有空 plugins 的假仓库跑）
FAKE_REPO="$SANDBOX/fake-repo"
mkdir -p "$FAKE_REPO/scripts" "$FAKE_REPO/plugins"
cp "$REPO_ROOT/scripts/install.sh" "$FAKE_REPO/scripts/"
HOME2="$(new_home r2)"
expect_code "R2 仓库不完整（缺插件产物）" 1 env DSH_HOME="$HOME2/.dsh" bash "$FAKE_REPO/scripts/install.sh"

# R3：半装
HOME3="$(new_home r3)"
env DSH_HOME="$HOME3/.dsh" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
rm -f "$HOME3/.dsh/profiles/desktop/node_modules/dsh-plugin-mobile-gateway/lib/mobile-v1/card-frames.mjs"
expect_code "R3 半装（删掉关键文件）" 3 env DSH_HOME="$HOME3/.dsh" bash "$REPO_ROOT/scripts/install.sh" --verify-only

# R4：改一个字节
HOME4="$(new_home r4)"
env DSH_HOME="$HOME4/.dsh" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
printf '\n// tampered\n' >> "$HOME4/.dsh/profiles/desktop/node_modules/dsh-plugin-mobile-gateway/lib/index.mjs"
expect_code "R4 哈希不符（改一个字节）" 3 env DSH_HOME="$HOME4/.dsh" bash "$REPO_ROOT/scripts/install.sh" --verify-only

# R5：无备份回滚
HOME5="$(new_home r5)"
expect_code "R5 无备份回滚（应拒绝）" 4 env DSH_HOME="$HOME5/.dsh" bash "$REPO_ROOT/scripts/rollback.sh"

printf '\n== 结果：通过 %d 条，失败 %d 条 ==\n' "$pass" "$failn"
[ "$failn" -eq 0 ] || exit 1
printf '（说明：这 5 条都“红”才说明闸门真实有效；全绿反而说明脚本什么都没检查。）\n'
