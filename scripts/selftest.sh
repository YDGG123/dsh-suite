#!/usr/bin/env bash
# 反向测试：故意把安装/校验/回滚搞坏，确认它们**真的会红**。
#
# 只跑绿不算证明——这个脚本在临时 HOME 里造沙箱 profile，逐条跑：
#   R1  装错目录（DSH_HOME 不存在）                  → 预检失败，退出码 1
#   R2  仓库不完整（临时藏起网关 lib/index）          → 预检失败，退出码 1
#   R3  半装（复制后删掉一个关键文件）                → 校验失败，退出码 3
#   R4  改一个字节（哈希不符）                        → 校验失败，退出码 3
#   R5  无备份回滚（整份）                            → 拒绝执行，退出码 4
#   R6  无备份单插件回滚                              → 拒绝执行，退出码 4
#   R7  只撤网关：ds-bot 目录逐字节未动、校验仍绿      → 退出码 0（撤错/删多就会红）
#   R8  单插件回滚重复执行                            → 退出码 0 且打印“已处于回滚状态”
#   R9  只撤 ds-bot：网关目录/依赖/配置未动、校验仍绿  → 退出码 0（撤错/删多就会红）
#   R10 整份回滚不受影响                              → package.json / cordis 与备份逐字节一致
#   R11 -OnlyGateway 与 -OnlyDsBot 同时给             → 参数非法，退出码 4
#   R12 用户自己的 - id: mobile-gateway 块             → 必须原样保留（误删就红）
#   R12b 用户块紧跟安装块之后                          → 只撤我们那块，用户块必须留下
#   R13 装两次再只撤网关                              → 上一轮追加的块要撤；目录按 had 保留
#   R14 安装前已有 ds-bot 目录（had:）                 → 只撤登记、目录保留（删了就红）
#   R15 整份回滚遇 had:                               → 目录保留；new: 的插件仍撤掉
#   R16 文档与 IPA/清单一致                            → 一致通过；改坏一个 sha 必须红
#   R17 漏传 --ipa                                     → 参数非法，退出码 2（不许静默沿用旧 sha）
#   R18 相对路径 --gateway                             → 按调用者 cwd 解析并成功同步
#   R19 换新 IPA 后自动改写文档                        → 8 处更新、旧值 0 命中、自检通过
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

ok_line() { printf '  ✓ %-46s %s\n' "$1" "${2:-通过}"; pass=$((pass+1)); }
bad_line() { printf '  ✗ %-46s %s\n' "$1" "${2:-不符}"; failn=$((failn+1)); }

# 目录内容指纹：同样的文件与内容 → 同样的值（用来证明“另一个插件没被动过”）。
tree_hash() { ( cd "$1" && find . -type f -exec shasum -a 256 {} + | sort | shasum -a 256 | awk '{print $1}' ); }
assert_same() { local label="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then ok_line "$label" "一致"; else bad_line "$label" "期望 $want 实际 $got"; fi; }
assert_absent() { local label="$1" path="$2"; if [ ! -e "$path" ] && [ ! -L "$path" ]; then ok_line "$label" "已撤除"; else bad_line "$label" "仍然存在：$path"; fi; }
assert_present() { local label="$1" path="$2"; if [ -e "$path" ]; then ok_line "$label" "仍在"; else bad_line "$label" "不见了：$path"; fi; }
assert_text() { local label="$1" file="$2" needle="$3"; if grep -qF -- "$needle" "$file" 2>/dev/null; then ok_line "$label" "命中"; else bad_line "$label" "没找到：$needle"; fi; }
assert_no_text() { local label="$1" file="$2" needle="$3"; if grep -qF -- "$needle" "$file" 2>/dev/null; then bad_line "$label" "不该出现：$needle"; else ok_line "$label" "干净"; fi; }
assert_bytes_same() { local label="$1" a="$2" b="$3"; if cmp -s "$a" "$b"; then ok_line "$label" "逐字节一致"; else bad_line "$label" "内容不同"; fi; }

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

printf '\n== 单插件粒度回滚 ==\n'

# R6：无备份的单插件回滚同样必须拒绝
expect_code "R6 无备份单插件回滚（应拒绝）" 4 env DSH_HOME="$HOME5/.dsh" bash "$REPO_ROOT/scripts/rollback.sh" --only-gateway

# R11：两个 -Only 互斥
expect_code "R11 -Only 互斥（应拒绝）" 4 env DSH_HOME="$HOME5/.dsh" bash "$REPO_ROOT/scripts/rollback.sh" --only-gateway --only-dsbot

# R7 + R8：装两个 → 只撤网关 → ds-bot 原样、校验仍绿；再撤一次必须幂等
HOME7="$(new_home r7)"
P7="$HOME7/.dsh/profiles/desktop"
env DSH_HOME="$HOME7/.dsh" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
DSBOT_BEFORE="$(tree_hash "$P7/node_modules/ds-bot")"
expect_code "R7 只撤网关（应成功）" 0 env DSH_HOME="$HOME7/.dsh" bash "$REPO_ROOT/scripts/rollback.sh" --only-gateway
assert_absent  "R7 网关目录已撤" "$P7/node_modules/dsh-plugin-mobile-gateway"
assert_absent  "R7 网关运行依赖已撤" "$P7/node_modules/ws"
assert_present "R7 ds-bot 目录仍在" "$P7/node_modules/ds-bot"
assert_same    "R7 ds-bot 目录逐字节未动" "$DSBOT_BEFORE" "$(tree_hash "$P7/node_modules/ds-bot")"
assert_no_text "R7 package.json 已撤销网关登记" "$P7/package.json" "dsh-plugin-mobile-gateway"
assert_text    "R7 package.json 保留 ds-bot 登记" "$P7/package.json" '"ds-bot"'
assert_no_text "R7 cordis 已撤网关配置块" "$P7/cordis.patch.yml" "- id: mobile-gateway"
expect_code "R7 只撤网关后 ds-bot 校验仍绿" 0 env DSH_HOME="$HOME7/.dsh" bash "$REPO_ROOT/scripts/install.sh" --only-dsbot --verify-only

env DSH_HOME="$HOME7/.dsh" bash "$REPO_ROOT/scripts/rollback.sh" --only-gateway >"$SANDBOX/r8.log" 2>&1
assert_same "R8 重复执行退出码" 0 "$?"
assert_text "R8 打印“已处于回滚状态”" "$SANDBOX/r8.log" "已处于回滚状态"
assert_present "R8 ds-bot 没有被误删" "$P7/node_modules/ds-bot"
expect_code "R8 重复执行后 ds-bot 校验仍绿" 0 env DSH_HOME="$HOME7/.dsh" bash "$REPO_ROOT/scripts/install.sh" --only-dsbot --verify-only

# R9：装两个 → 只撤 ds-bot → 网关的目录/依赖/配置都还在、校验仍绿
HOME9="$(new_home r9)"
P9="$HOME9/.dsh/profiles/desktop"
env DSH_HOME="$HOME9/.dsh" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
GATEWAY_BEFORE="$(tree_hash "$P9/node_modules/dsh-plugin-mobile-gateway")"
expect_code "R9 只撤 ds-bot（应成功）" 0 env DSH_HOME="$HOME9/.dsh" bash "$REPO_ROOT/scripts/rollback.sh" --only-dsbot
assert_absent  "R9 ds-bot 目录已撤" "$P9/node_modules/ds-bot"
assert_present "R9 网关目录仍在" "$P9/node_modules/dsh-plugin-mobile-gateway"
assert_same    "R9 网关目录逐字节未动" "$GATEWAY_BEFORE" "$(tree_hash "$P9/node_modules/dsh-plugin-mobile-gateway")"
assert_present "R9 网关运行依赖仍在" "$P9/node_modules/ws"
assert_no_text "R9 package.json 已撤销 ds-bot 登记" "$P9/package.json" '"ds-bot"'
assert_text    "R9 package.json 保留网关登记" "$P9/package.json" '"dsh-plugin-mobile-gateway"'
assert_text    "R9 cordis 配置块未被动" "$P9/cordis.patch.yml" "- id: mobile-gateway"
expect_code "R9 只撤 ds-bot 后网关校验仍绿" 0 env DSH_HOME="$HOME9/.dsh" bash "$REPO_ROOT/scripts/install.sh" --only-gateway --verify-only

# R10：整份回滚仍是逐字节还原，不受单插件路径影响
HOME10="$(new_home r10)"
P10="$HOME10/.dsh/profiles/desktop"
env DSH_HOME="$HOME10/.dsh" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
BACKUP10="$(ls -1d "$P10"/backups/dsh-suite-* | tail -1)"
expect_code "R10 整份回滚（应成功）" 0 env DSH_HOME="$HOME10/.dsh" bash "$REPO_ROOT/scripts/rollback.sh"
assert_bytes_same "R10 package.json == 备份" "$P10/package.json" "$BACKUP10/package.json"
assert_bytes_same "R10 cordis == 备份" "$P10/cordis.patch.yml" "$BACKUP10/cordis.patch.yml"
assert_absent "R10 网关目录已撤" "$P10/node_modules/dsh-plugin-mobile-gateway"
assert_absent "R10 ds-bot 目录已撤" "$P10/node_modules/ds-bot"

# R12：用户自己写的 `- id: mobile-gateway` 块（没有我们那行注释）绝不能被单插件回滚误删
HOME12="$(new_home r12)"
P12="$HOME12/.dsh/profiles/desktop"
cat > "$P12/cordis.patch.yml" <<'YML'
# patch
# 用户自己维护的网关配置：没有 dsh-suite 的注释行
- id: mobile-gateway
  name: dsh-plugin-mobile-gateway
  config:
    gatewayEnabled: true
YML
cp "$P12/cordis.patch.yml" "$SANDBOX/r12.cordis.before"
env DSH_HOME="$HOME12/.dsh" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
expect_code "R12 只撤网关（应成功）" 0 env DSH_HOME="$HOME12/.dsh" bash "$REPO_ROOT/scripts/rollback.sh" --only-gateway
assert_bytes_same "R12 用户自己的配置块逐字节保留" "$P12/cordis.patch.yml" "$SANDBOX/r12.cordis.before"
assert_text "R12 用户自己的块仍在" "$P12/cordis.patch.yml" "- id: mobile-gateway"
assert_absent "R12 网关目录已撤" "$P12/node_modules/dsh-plugin-mobile-gateway"

# R13：装两次再单撤网关 —— 上一轮也是我们追加的块，必须一起撤掉（不能留指向空目录的配置）
HOME13="$(new_home r13)"
P13="$HOME13/.dsh/profiles/desktop"
env DSH_HOME="$HOME13/.dsh" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
env DSH_HOME="$HOME13/.dsh" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
expect_code "R13 重装后只撤网关（应成功）" 0 env DSH_HOME="$HOME13/.dsh" bash "$REPO_ROOT/scripts/rollback.sh" --only-gateway
# 第二次安装时网关已在（state 记 had:）：保留目录、依赖与它原有的配置块，
# 这才是“第二次安装之前”的样子（上一轮的安装结果）。
assert_present "R13 网关目录按 had 保留" "$P13/node_modules/dsh-plugin-mobile-gateway"
assert_present "R13 运行依赖也保留" "$P13/node_modules/ws"
assert_text    "R13 安装前就有的配置块保留" "$P13/cordis.patch.yml" "# dsh-suite: 手机连接需要开启"
assert_text    "R13 提示保留而非删除" "$SANDBOX/out.log" "保留当前目录"


# R12b：用户自己的块**紧跟**在安装块之后 —— 只撤我们的块，用户块必须原样留下。
#        （跳过区间若把第二个 "- id: mobile-gateway" 也当成自己的，这条会红。）
HOME12B="$(new_home r12b)"
P12B="$HOME12B/.dsh/profiles/desktop"
env DSH_HOME="$HOME12B/.dsh" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
cat >> "$P12B/cordis.patch.yml" <<'YML'
- id: mobile-gateway
  name: dsh-plugin-mobile-gateway
  config:
    gatewayEnabled: true
    lanPort: 3999
YML
expect_code "R12b 只撤网关（用户块紧随其后）" 0 env DSH_HOME="$HOME12B/.dsh" bash "$REPO_ROOT/scripts/rollback.sh" --only-gateway
assert_no_text "R12b 安装块注释已撤" "$P12B/cordis.patch.yml" "# dsh-suite: 手机连接需要开启"
assert_text   "R12b 用户块仍在" "$P12B/cordis.patch.yml" "lanPort: 3999"
assert_same   "R12b 只剩用户那一块" "1" "$(grep -c '^- id: mobile-gateway$' "$P12B/cordis.patch.yml")"
assert_absent "R12b 网关目录已撤" "$P12B/node_modules/dsh-plugin-mobile-gateway"

# R14：安装前就有 ds-bot 目录（state 记 had:）→ 回滚只撤登记、**保留目录**。
#        （旧行为会删掉它，让用户"新版本和旧版本都没有"，这条锁死新口径。）
HOME14="$(new_home r14)"
P14="$HOME14/.dsh/profiles/desktop"
mkdir -p "$P14/node_modules/ds-bot"
printf 'old version marker\n' > "$P14/node_modules/ds-bot/OLD.txt"
printf '{"name":"dsh-profile-desktop","dependencies":{"ds-bot":"0.2.0"}}\n' > "$P14/package.json"
env DSH_HOME="$HOME14/.dsh" bash "$REPO_ROOT/scripts/install.sh" --only-dsbot >/dev/null 2>&1
expect_code "R14 只撤 ds-bot（had 场景）" 0 env DSH_HOME="$HOME14/.dsh" bash "$REPO_ROOT/scripts/rollback.sh" --only-dsbot
assert_present "R14 安装前就有的目录被保留" "$P14/node_modules/ds-bot"
assert_text    "R14 明确提示保留当前目录" "$SANDBOX/out.log" "保留当前目录"
assert_text    "R14 登记还原为安装前的值" "$P14/package.json" '"ds-bot": "0.2.0"'
assert_no_text "R14 不再是本安装的 file: 登记" "$P14/package.json" '"ds-bot": "file:'

# R15：整份回滚同样遵守 had: 保留目录（new: 的另一个插件仍撤掉）。
HOME15="$(new_home r15)"
P15="$HOME15/.dsh/profiles/desktop"
mkdir -p "$P15/node_modules/dsh-plugin-mobile-gateway"
printf 'old gateway\n' > "$P15/node_modules/dsh-plugin-mobile-gateway/OLD.txt"
env DSH_HOME="$HOME15/.dsh" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
expect_code "R15 整份回滚（had 场景）" 0 env DSH_HOME="$HOME15/.dsh" bash "$REPO_ROOT/scripts/rollback.sh"
assert_present "R15 安装前就有的网关目录被保留" "$P15/node_modules/dsh-plugin-mobile-gateway"
assert_present "R15 它的运行依赖也保留" "$P15/node_modules/ws"
assert_absent  "R15 ds-bot（new:）仍被撤掉" "$P15/node_modules/ds-bot"

# R16–R19：维护者同步脚本（sync-from-dev.sh）的闸门。全部在临时副本里跑，不碰本仓库。
fake_repo() {
  local dst="$1"
  mkdir -p "$dst/scripts" "$dst/docs" "$dst/app" "$dst/plugins"
  cp "$REPO_ROOT/scripts/sync-from-dev.sh" "$dst/scripts/"
  cp "$REPO_ROOT/README.md" "$dst/README.md"
  cp "$REPO_ROOT/docs/INSTALL.md" "$dst/docs/INSTALL.md"
  cp "$REPO_ROOT/plugins/manifest.json" "$dst/plugins/manifest.json"
  cp "$REPO_ROOT"/app/*.ipa "$dst/app/"
}

# R16：文档里的 IPA 名/大小/sha 必须与实际 app/ + manifest 一致（--check-docs，只读）。
FAKE16="$SANDBOX/repo16"
fake_repo "$FAKE16"
expect_code "R16 文档与 IPA/清单一致（应通过）" 0 bash "$FAKE16/scripts/sync-from-dev.sh" --check-docs
node -e 'const fs=require("fs");const p=process.argv[1];fs.writeFileSync(p,fs.readFileSync(p,"utf8").replace(/sha256: [0-9a-f]{64}/,"sha256: "+"0".repeat(64)))' "$FAKE16/README.md"
expect_code "R16 文档被改坏（应红）" 1 bash "$FAKE16/scripts/sync-from-dev.sh" --check-docs

# R17：漏传 --ipa 也必须红——不许静默沿用旧 sha256（参数校验在触碰任何文件之前）。
expect_code "R17 缺 --ipa 必须红" 2 bash "$FAKE16/scripts/sync-from-dev.sh" --dsbot "$FAKE16"

# R18：相对路径按调用者 cwd 解析（脚本内部会 cd 到仓库根，锚点不能漂）。
FAKE18="$SANDBOX/repo18"
fake_repo "$FAKE18"
mkdir -p "$SANDBOX/gwsrc/lib" "$SANDBOX/gwsrc/dev/harness" "$SANDBOX/gwsrc/test"
printf 'export const ok=1\n' > "$SANDBOX/gwsrc/lib/index.mjs"
printf '{"name":"dsh-plugin-mobile-gateway"}\n' > "$SANDBOX/gwsrc/package.json"
printf 'must not ship\n' > "$SANDBOX/gwsrc/dev/harness/x.bin"
printf 'must not ship\n' > "$SANDBOX/gwsrc/test/x.js"
expect_code "R18 相对路径按调用者 cwd 解析" 0 bash -c 'cd "$1" && bash "$2" --gateway gwsrc --no-ipa' _ "$SANDBOX" "$FAKE18/scripts/sync-from-dev.sh"
assert_text "R18 网关确实被同步" "$FAKE18/plugins/dsh-plugin-mobile-gateway/lib/index.mjs" "export const ok=1"
assert_absent "R18 dev/ 没被带进发布树" "$FAKE18/plugins/dsh-plugin-mobile-gateway/dev"
assert_absent "R18 test/ 没被带进发布树" "$FAKE18/plugins/dsh-plugin-mobile-gateway/test"

# R19：换一个新 IPA 同步后，README/INSTALL 的 8 处必须自动改写，旧值 0 命中。
FAKE19="$SANDBOX/repo19"
fake_repo "$FAKE19"
NEWIPA="$SANDBOX/DshMobile-iOS16-20261025-999999.ipa"
head -c 4096 /dev/urandom > "$NEWIPA"
expect_code "R19 带新 IPA 同步（应成功）" 0 bash "$FAKE19/scripts/sync-from-dev.sh" --gateway "$SANDBOX/gwsrc" --ipa "$NEWIPA"
assert_text    "R19 README 已改名" "$FAKE19/README.md" "$(basename "$NEWIPA")"
assert_text    "R19 INSTALL 已改名" "$FAKE19/docs/INSTALL.md" "app/$(basename "$NEWIPA")"
assert_no_text "R19 旧名 0 命中" "$FAKE19/README.md" "DshMobile-iOS16-v1.7.8-29.unsigned.ipa"
assert_no_text "R19 旧 sha 0 命中" "$FAKE19/docs/INSTALL.md" "5f8ae6a7e46dc0020eb00baca635ee42428897ac828e55a994095535124dd39f"
expect_code "R19 改完后文档自检通过" 0 bash "$FAKE19/scripts/sync-from-dev.sh" --check-docs

# R20b：--no-ipa 之后 manifest.ipa 是 null，文档仍描述 app 里的旧包。下一轮带新 IPA 时，
#       旧名/旧 sha/旧大小必须从 app 里那个旧包推出来，文档照样改对（否则会留着旧信息）。
#       独立目录（repo20b）：与上一段共用会把 app/ 拷成双包，撞“只能一个 IPA”的保护。
FAKE20B="$SANDBOX/repo20b"
fake_repo "$FAKE20B"
expect_code "R20 --no-ipa 同步（应成功）" 0 bash "$FAKE20B/scripts/sync-from-dev.sh" --gateway "$SANDBOX/gwsrc" --no-ipa
assert_text "R20 manifest.ipa 已置 null" "$FAKE20B/plugins/manifest.json" '"ipa": null'
NEWIPA20="$SANDBOX/DshMobile-iOS16-20261025-888888.ipa"
head -c 5000 /dev/urandom > "$NEWIPA20"
expect_code "R20 随后换新 IPA（应成功）" 0 bash "$FAKE20B/scripts/sync-from-dev.sh" --gateway "$SANDBOX/gwsrc" --ipa "$NEWIPA20"
assert_text    "R20 README 用了新名" "$FAKE20B/README.md" "$(basename "$NEWIPA20")"
assert_no_text "R20 旧名 0 命中" "$FAKE20B/README.md" "DshMobile-iOS16-v1.7.8-29.unsigned.ipa"
expect_code "R20 改完后文档自检通过" 0 bash "$FAKE20B/scripts/sync-from-dev.sh" --check-docs

# R21：INSTALL §2.4 的四个机器可读锚点必须存在，且脚本真的会打印（文档不说假话）。
for anchor in 'backup: ' 'CHECK gateway: PASS' 'CHECK dsbot: PASS' 'RESULT: PASS'; do
  assert_text "R21 文档含锚点 [$anchor]" "$REPO_ROOT/docs/INSTALL.md" "$anchor"
done
assert_text "R21 install.sh 打印 backup 锚点" "$REPO_ROOT/scripts/install.sh" 'say "backup: '
assert_text "R21 install.ps1 打印 RESULT 锚点" "$REPO_ROOT/scripts/install.ps1" "'RESULT: PASS'"

printf '\n== 结果：通过 %d 条，失败 %d 条 ==\n' "$pass" "$failn"
[ "$failn" -eq 0 ] || exit 1
printf '（说明：R1–R6、R11 必须“红”，R7–R21 撤错/删多/误删用户配置/非幂等就会“红”；全绿反而说明闸门什么都没检查。）\n'
