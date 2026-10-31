#!/usr/bin/env bash
# 维护者用：从开发仓库同步插件与 App 到本发布仓库，并重建 plugins/manifest.json。
#
# 用法：
#   bash scripts/sync-from-dev.sh \
#     --gateway ~/work/dsh-plugin-mobile-gateway \
#     --dsbot   ~/work/ds-bot/ds-bot \
#     --ipa     ~/work/dsh-mobile/build-output/DshMobile-iOS16-20261025-xxxx.ipa
#   bash scripts/sync-from-dev.sh --dsbot ~/work/ds-bot/ds-bot --no-ipa   # 不发新 IPA（manifest.ipa=null）
#   bash scripts/sync-from-dev.sh --check-docs                            # 只读：文档里的 IPA 名/大小/sha 与实际一致吗
#
# 只复制白名单里的运行时文件（dev/、test/、node_modules/、.git、锁文件一律不带）；先拷到临时名、
# 逐文件校验后再原子替换，任何一步失败都不会动到现有发布树。复制完重建 manifest 并自动改写
# README/INSTALL 里的 IPA 文件名、大小与 sha256，最后自检“旧值 0 命中”。
#
# --ipa 必传，或用 --no-ipa 显式声明本次不发 IPA：不允许静默沿用旧的 sha256。
# 同步前校验源仓库**白名单内**是否有未提交改动：有就打印文件清单并非零退出（manifest 按
# 磁盘内容取哈希，未入库内容会让发布仓 HEAD 与 manifest 对不上）。白名单外的 test/、scripts/ 等不挡。
# 源路径按**调用者当前目录**解析（脚本内部会切到仓库根，但参数的锚点是你敲命令的地方）。
#
# 退出码：0 成功；1 源/复制/校验/文档不一致；2 参数非法；4 缺 node（算 sha256 用）
set -euo pipefail

usage() { sed -n '/^# 用法：/,/^# 退出码/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

say() { printf '%s\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }
die_usage() { printf '❌ %s\n' "$*" >&2; exit 2; }

CALLER_PWD="$PWD"
abs_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_PWD" "$1" ;;
  esac
}

GATEWAY_SRC=""; DSBOT_SRC=""; IPA_SRC=""; NO_IPA=0; CHECK_DOCS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gateway) GATEWAY_SRC="$(abs_path "${2:-}")"; shift 2;;
    --dsbot)   DSBOT_SRC="$(abs_path "${2:-}")"; shift 2;;
    --ipa)     IPA_SRC="$(abs_path "${2:-}")"; shift 2;;
    --no-ipa)  NO_IPA=1; shift;;
    --check-docs) CHECK_DOCS=1; shift;;
    -h|--help) usage; exit 0;;
    *) die_usage "未知参数：$1（用 --help 看用法）";;
  esac
done

if [ "$NO_IPA" -eq 1 ] && [ -n "$IPA_SRC" ]; then
  die_usage "--ipa 与 --no-ipa 不能同时用"
fi
if [ "$CHECK_DOCS" -eq 0 ]; then
  if [ -z "$IPA_SRC" ] && [ "$NO_IPA" -eq 0 ]; then
    die_usage "--ipa 必传；本次不发 IPA 请显式加 --no-ipa（不许静默沿用旧 sha256）"
  fi
  if [ -z "$GATEWAY_SRC" ] && [ -z "$DSBOT_SRC" ] && [ -z "$IPA_SRC" ]; then
    die_usage "除 --no-ipa 外没有同步动作：至少给 --gateway / --dsbot / --ipa 之一"
  fi
fi

command -v node >/dev/null 2>&1 || { printf '❌ 需要 node 来计算 sha256（维护者机器应已具备）\n' >&2; exit 4; }

cd "$(dirname "${BASH_SOURCE[0]}")/.." || die "进不到仓库根目录"
REPO_ROOT="$PWD"
[ -f "$REPO_ROOT/plugins/manifest.json" ] || say '  ! 还没有 plugins/manifest.json（首次同步会新建）'

# 只复制运行时需要的文件。dev/（901MB 的 harness 树）、test/、node_modules/、.git、
# 各种锁文件都不在名单里，白名单之外的东西一个字节都不会进发布树。
GATEWAY_WHITELIST='^(lib/|bin/|helper/|docs/|package\.json$|README\.md$|LICENSE$|PROTOCOL\.md$|cordis\.patch\.yml$)'
DSBOT_WHITELIST='^(src/(host|shared|client)/|index\.js$|client\.js$|web-search\.js$|package\.json$|README\.md$|LICENSE$|cordis\.patch\.yml$)'

# 「源仓库有未提交改动 = 还没定稿」：白名单内的脏文件一旦被同步，manifest 按磁盘内容取哈希，
# 而发布仓 HEAD 里没有这些内容，出包时逐条比对必然对不上。2026-10-31 踩过：网关 0.11.1
# 未入库的 16 个文件把 manifest 从 66 条变成 72 条，ReleaseBot 推送前才发现。
# 只校验**真正会被复制**的路径（白名单内）；白名单外的 test/、scripts/、锁文件脏了不挡。
dirty_sync_paths() {
  local src="$1" whitelist="$2" prefix path entry
  # src 可能是仓库的子目录（如 ds-bot/ 仓库下的 ds-bot/ 子目录）：`git status` 一律按仓库根
  # report（`ds-bot/README.md`），必须剥掉 show-prefix 才能和白名单（相对 src）对上。
  prefix="$(git -C "$src" rev-parse --show-prefix 2>/dev/null || true)"
  # -z：NUL 分隔。中文/空格路径不被转义；rename 的「源路径」记录没有状态前缀，
  # 去前缀的展开不会改动它，原样参与白名单匹配。
  while IFS= read -r -d '' entry; do
    path="${entry#[ MADRCU?!][ MADRCU?!] }"
    [ -n "$path" ] || continue
    path="${path#"$prefix"}"
    if printf '%s\n' "$path" | grep -qE "$whitelist"; then printf '%s\n' "$path"; fi
  done < <(git -C "$src" -c core.quotePath=false status --porcelain=v1 -z --untracked-files=all -- .)
  return 0
}

require_clean_source() {
  local name="$1" src="$2" whitelist="$3" found
  if ! git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    say "  ! $name 源不是 git 仓库：跳过「未提交改动」检查"
    return 0
  fi
  found="$(dirty_sync_paths "$src" "$whitelist" || true)"
  if [ -n "$found" ]; then
    printf '❌ %s 有未提交的改动（这些文件会被同步进发布树）：\n' "$name" >&2
    printf '%s\n' "$found" | sed 's/^/     /' >&2
    printf '   先提交或 stash 再同步。原因：manifest 按磁盘内容取哈希，未入库的内容会让\n' >&2
    printf '   发布仓 HEAD 与 manifest 对不上（出包闸门会拒）。\n' >&2
    exit 1
  fi
}

# 先拷临时名 → 逐文件比对 → 再原子替换；失败时旧发布树原封不动。
copy_plugin() {
  local name="$1" src="$2" whitelist="$3"
  require_clean_source "$name" "$src" "$whitelist"
  local tmp="plugins/.tmp-$name.$$" list count
  list="$(mktemp "${TMPDIR:-/tmp}/dsh-suite-list.XXXXXX")"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  if ! ( cd "$src" && find . \( -type f -o -type l \) -print | sed 's|^\./||' | grep -E "$whitelist" | sort > "$list" ); then
    rm -rf "$tmp" "$list"
    die "列文件失败：$src"
  fi
  if [ ! -s "$list" ]; then
    rm -rf "$tmp" "$list"
    die "白名单没匹配到任何文件：$src（源目录不对？）"
  fi
  if ! ( cd "$src" && tar -cf - -T "$list" ) | ( cd "$tmp" && tar -xf - ); then
    rm -rf "$tmp" "$list"
    die "复制失败：$name"
  fi
  # 完整性闸门：白名单内每个文件都必须逐一字节一致。
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if ! cmp -s "$src/$rel" "$tmp/$rel"; then
      rm -rf "$tmp" "$list"
      die "复制不完整（内容不一致）：$name/$rel"
    fi
  done < "$list"
  # 不该带的东西必须不在。
  for junk in dev test tests node_modules .git package-lock.json pnpm-lock.yaml .DS_Store; do
    if [ -e "$tmp/$junk" ]; then
      rm -rf "$tmp" "$list"
      die "sanitize 漏了 $name/$junk"
    fi
  done
  count="$(find "$tmp" -type f | wc -l | tr -d ' ')"
  rm -f "$list"
  rm -rf "plugins/$name"
  mv "$tmp" "plugins/$name"
  say "→ 已同步 $name（$count 个文件）"
}

sync_ipa() {
  local src="$1" base tmp a b
  if [ ! -f "$src" ]; then die "IPA 不存在：$src"; fi
  base="$(basename "$src")"
  case "$base" in
    *.ipa) : ;;
    *) die "不是 .ipa 文件：$base" ;;
  esac
  # 兼容两种前缀：DshMobile 是历史/回滚包名，Orcarness 是 v1.7.10(35) 改名后的现名。
  # 过渡期两种都会出现，两个都放行；其它名字仍警告（不拦，仅提示）。
  case "$base" in
    DshMobile-iOS16-*|Orcarness-iOS16-*) : ;;
    *) say "  ! 警告：IPA 名字不符合 DshMobile-iOS16-* / Orcarness-iOS16-* 约定：$base" ;;
  esac
  mkdir -p app
  tmp="app/.tmp-$base.$$"
  if ! cp "$src" "$tmp"; then rm -f "$tmp"; die "复制 IPA 失败：$src"; fi
  a="$(shasum -a 256 "$src" | awk '{print $1}')"
  b="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [ "$a" != "$b" ]; then rm -f "$tmp"; die "IPA 复制不完整（sha256 不符）：$base"; fi
  rm -f app/*.ipa
  mv "$tmp" "app/$base"
  say "→ 已同步 IPA：app/$base（sha256=$a）"
}

# 旧值要在替换前抓：manifest 里的 IPA 名/sha 与 app 里旧文件的大小，供文档改写与自检用。
read_old_ipa() {
  node - <<'JS'
const fs = require('fs');
let ipa = null;
try {
  const m = JSON.parse(fs.readFileSync('plugins/manifest.json', 'utf8'));
  ipa = m.ipa || null;
} catch {
  ipa = null;
}
// manifest 没声明 IPA（上一次 --no-ipa）时，文档里描述的仍是 app/ 里那个旧包：
// 从文件本身推出旧名/旧 sha/旧大小，下一次换包才改得动文档。
let size = null;
let files = [];
try { files = fs.readdirSync('app').filter(n => n.endsWith('.ipa')); } catch { files = []; }
if (!ipa && files.length === 1) {
  const file = 'app/' + files[0];
  const crypto = require('crypto');
  ipa = { name: files[0], sha256: crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex') };
}
if (ipa && ipa.name && fs.existsSync('app/' + ipa.name)) size = fs.statSync('app/' + ipa.name).size;
console.log(JSON.stringify({ name: ipa ? ipa.name : null, sha256: ipa ? ipa.sha256 : null, size }));
JS
}

if [ -n "$GATEWAY_SRC" ] && [ ! -f "$GATEWAY_SRC/lib/index.mjs" ]; then die "网关源目录不对：$GATEWAY_SRC"; fi
if [ -n "$DSBOT_SRC" ] && [ ! -f "$DSBOT_SRC/index.js" ]; then die "ds-bot 源目录不对：$DSBOT_SRC"; fi

if [ "$CHECK_DOCS" -eq 1 ]; then
  node - <<'JS'
const fs = require('fs');
const crypto = require('crypto');
const fail = (msg) => { console.error('❌ ' + msg); process.exit(1); };
const note = (msg) => console.log('  ' + msg);
const manifestPath = 'plugins/manifest.json';
if (!fs.existsSync(manifestPath)) fail('缺少 plugins/manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
if (!manifest.ipa) fail('manifest.ipa 为 null（未声明 IPA），文档检查无意义');
const ipas = fs.existsSync('app') ? fs.readdirSync('app').filter(n => n.endsWith('.ipa')) : [];
if (ipas.length !== 1) fail('app/ 里应当恰好一个 .ipa，实际 ' + ipas.length + ' 个');
const file = 'app/' + ipas[0];
const sha = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const size = fs.statSync(file).size;
if (manifest.ipa.name !== ipas[0]) fail(`manifest 里的文件名（${manifest.ipa.name}）与实际（${ipas[0]}）不一致`);
if (manifest.ipa.sha256 !== sha) fail('manifest 里的 sha256 与实际文件不一致');
const comma = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
const need = [
  [ipas[0], 'IPA 文件名'],
  [sha, 'sha256（小写）'],
  [comma(size), '大小（带千分位）'],
];
for (const path of ['README.md', 'docs/INSTALL.md']) {
  const text = fs.readFileSync(path, 'utf8');
  for (const [value, label] of need) {
    if (!text.includes(value)) fail(`${path} 里找不到 ${label}：${value}`);
  }
  // 大写 sha 只出现在 INSTALL 的“预期”行，README 只要求小写。
  if (path === 'docs/INSTALL.md' && !text.includes(sha.toUpperCase())) {
    fail(`docs/INSTALL.md 里找不到 sha256（大写）：${sha.toUpperCase()}`);
  }
}
note(`文档与实际一致：${ipas[0]}  ${comma(size)} B  sha256=${sha.slice(0, 12)}…`);
JS
  exit 0
fi

OLD_IPA="$(read_old_ipa)"
if [ -n "$GATEWAY_SRC" ]; then copy_plugin "dsh-plugin-mobile-gateway" "$GATEWAY_SRC" "$GATEWAY_WHITELIST"; fi
if [ -n "$DSBOT_SRC" ]; then copy_plugin "ds-bot" "$DSBOT_SRC" "$DSBOT_WHITELIST"; fi

if [ "$NO_IPA" -eq 1 ]; then
  say "  ⚠ 本次不发 IPA（--no-ipa）：manifest.ipa 置为 null。"
  say "    README/INSTALL 仍描述 app/ 里的旧包；下次带 --ipa 同步会自动改写它们。"
elif [ -n "$IPA_SRC" ]; then
  sync_ipa "$IPA_SRC"
fi

say "→ 重建 plugins/manifest.json"
node - "$OLD_IPA" "$NO_IPA" <<'JS'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const [oldRaw, noIpa] = process.argv.slice(2);
const old = JSON.parse(oldRaw);
const comma = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');

const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const walk = (root) => {
  const out = {};
  const visit = (dir, prefix) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (entry.name.startsWith('.tmp-')) continue;
      const rel = prefix ? prefix + '/' + entry.name : entry.name;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) visit(full, rel);
      else if (entry.isFile()) out[rel] = hash(full);
    }
  };
  if (fs.existsSync(root)) visit(root, '');
  return out;
};

// 整棵发布树都进清单：安装时的“复制是否完整”就是逐文件核对，不再靠几个人手挑的关键文件。
const gateway = walk('plugins/dsh-plugin-mobile-gateway');
const dsbot = walk('plugins/ds-bot');

// 运行依赖从目录推导（不再硬编码 7 项）：网关新增依赖会自动进清单。
const runtimeDeps = {};
const depsRoot = 'plugins/_runtime-deps';
if (fs.existsSync(depsRoot)) {
  const names = [];
  for (const entry of fs.readdirSync(depsRoot, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    if (entry.name.startsWith('@')) {
      for (const sub of fs.readdirSync(path.join(depsRoot, entry.name), { withFileTypes: true })) {
        if (sub.isDirectory()) names.push(entry.name + '/' + sub.name);
      }
    } else {
      names.push(entry.name);
    }
  }
  for (const name of names.sort()) {
    const pkg = path.join(depsRoot, name, 'package.json');
    if (!fs.existsSync(pkg)) continue;
    const { version } = JSON.parse(fs.readFileSync(pkg, 'utf8'));
    runtimeDeps[name] = { version, source: '与宿主同源（DeepSeek Harness 自带树逐字节复制）' };
  }
}

const ipas = fs.existsSync('app') ? fs.readdirSync('app').filter(n => n.endsWith('.ipa')) : [];
if (ipas.length > 1) { console.error('❌ app/ 里有多个 .ipa：' + ipas.join(', ')); process.exit(1); }
const ipa = (noIpa === '1' || ipas.length === 0)
  ? null
  : { name: ipas[0], sha256: hash(path.join('app', ipas[0])) };

fs.writeFileSync('plugins/manifest.json', JSON.stringify({
  generatedAt: new Date().toISOString(),
  note: 'install.sh / install.ps1 用这里的哈希校验“复制是否完整、是否被改动”。改插件后请重跑 sync-from-dev.sh 重建。',
  dshPluginMobileGateway: gateway,
  dsBot: dsbot,
  _runtimeDeps: runtimeDeps,
  ipa,
}, null, 2) + '\n');

console.log('  网关文件：' + Object.keys(gateway).length + ' 个');
console.log('  ds-bot 文件：' + Object.keys(dsbot).length + ' 个');
console.log('  运行依赖：' + Object.keys(runtimeDeps).length + ' 个（含传递依赖）');

if (ipa) {
  const size = fs.statSync(path.join('app', ipa.name)).size;
  const newShaUpper = ipa.sha256.toUpperCase();
  const files = ['README.md', 'docs/INSTALL.md'];
  for (const file of files) {
    let text = fs.readFileSync(file, 'utf8');
    if (old.name && old.name !== ipa.name) text = text.split(old.name).join(ipa.name);
    if (old.sha256 && old.sha256 !== ipa.sha256) {
      text = text.replace(new RegExp(old.sha256, 'gi'), (m) => (m === m.toUpperCase() ? newShaUpper : ipa.sha256));
    }
    if (old.size !== null && old.size !== size) {
      text = text.replace(/\b\d{1,3}(?:,\d{3})+\b|\b\d{7,}\b/g, (m) => {
        const value = Number(m.replace(/,/g, ''));
        if (value !== old.size) return m;
        return m.includes(',') ? comma(size) : String(size);
      });
    }
    fs.writeFileSync(file, text);
  }
  // 自检：旧值必须 0 命中，新值必须出现。
  for (const file of files) {
    const text = fs.readFileSync(file, 'utf8');
    if (old.name && old.name !== ipa.name && text.includes(old.name)) {
      console.error(`❌ ${file} 里仍残留旧 IPA 名：${old.name}`);
      process.exit(1);
    }
    if (old.sha256 && old.sha256 !== ipa.sha256 && text.toLowerCase().includes(old.sha256.toLowerCase())) {
      console.error(`❌ ${file} 里仍残留旧 sha256`);
      process.exit(1);
    }
    if (!text.includes(ipa.name)) {
      console.error(`❌ ${file} 里没有新 IPA 名：${ipa.name}`);
      process.exit(1);
    }
    if (!text.includes(ipa.sha256) && !text.includes(newShaUpper)) {
      console.error(`❌ ${file} 里没有新 sha256`);
      process.exit(1);
    }
  }
  console.log('  IPA：' + ipa.name + '  ' + comma(size) + ' B  sha256=' + ipa.sha256);
  console.log('  文档：README.md / docs/INSTALL.md 已按新 IPA 改写（旧值自检 0 命中）');
} else {
  console.log('  IPA：manifest.ipa = null（--no-ipa；文档未改，README 里的旧包信息保持原样）');
}
JS

say "✓ 同步完成。建议再跑：bash scripts/sync-from-dev.sh --check-docs && bash scripts/install.sh --dry-run"
