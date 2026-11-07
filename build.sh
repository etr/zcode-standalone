#!/usr/bin/env bash
# Works under bash and zsh.
# build.sh — build our own ZCode engine (unmodified upstream + our patch layer)
# and assemble it at ~/.zcode/local/engine — fully outside the ZCode.app bundle,
# so desktop app updates never touch it.
#
# Usage: build.sh [tag]        # default: tag matching the installed app version
#        build.sh --no-app-tag v3.17.2   # build an explicit tag even if != app
#
# Stages: fetch source → apply patches → verify compliance → install → build
#         engine bundle + TUI → assemble engine dir → re-verify + record.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
ENGINE="${ZCODE_STANDALONE_ENGINE:-$HOME/.zcode/local/engine}"
BASELINE="$ROOT/fingerprint-baseline.json"

TAG_ARG="${1:-}"
if [[ -n "$TAG_ARG" && "$TAG_ARG" != "--no-app-tag" ]]; then
  TAG="$TAG_ARG"
elif [[ "$TAG_ARG" == "--no-app-tag" && -n "${2:-}" ]]; then
  TAG="$2"
else
  # Default tag: match the installed app. macOS: Info.plist. Linux: version in
  # the AppImage filename (ZCode-<ver>-linux-*.AppImage) under common paths.
  APP_VER=""
  if command -v defaults >/dev/null 2>&1 && [[ -d /Applications/ZCode.app ]]; then
    APP_VER=$(defaults read /Applications/ZCode.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || true)
  else
    for candidate in "$HOME"/Applications/ZCode-*.AppImage "$HOME"/Downloads/ZCode-*.AppImage "$HOME"/ZCode-*.AppImage /opt/ZCode-*.AppImage /usr/local/bin/ZCode-*.AppImage; do
      if [[ -f "$candidate" ]]; then
        APP_VER=$(basename "$candidate" | sed -nE 's/^ZCode-([0-9]+\.[0-9]+\.[0-9]+)-linux-.*/\1/p')
        [[ -n "$APP_VER" ]] && break
      fi
    done
  fi
  if [[ -z "$APP_VER" ]]; then
    echo "Could not detect an installed ZCode version. Pass a tag explicitly: ./build.sh v3.17.2"
    exit 1
  fi
  TAG="v$APP_VER"
fi
echo "==> Building ZCode engine from tag: $TAG"

# ---------------------------------------------------------------- 1. source
if [[ ! -d "$SRC/.git" ]]; then
  echo "==> Cloning ZCode (first run)"
  git clone https://github.com/zai-org/ZCode.git "$SRC"
fi
cd "$SRC"
git fetch --tags --force origin
git checkout --force "$TAG"
git reset --hard "$TAG"
git clean -fdq   # remove untracked non-ignored files (previous patch artifacts)

# ---------------------------------------------------------------- 2. patches
# null-glob semantics in both shells: an empty patches/ dir yields zero iterations
if [ -n "${ZSH_VERSION:-}" ]; then setopt NULL_GLOB; fi
if [ -n "${BASH_VERSION:-}" ]; then shopt -s nullglob; fi
patch_files=("$ROOT"/patches/*.patch)
if [ "${#patch_files[@]}" -gt 0 ]; then
  # check+apply per patch: later patches may context-depend on earlier ones
  # (e.g. 0007 builds on 0001's added lines), so each check must see the
  # partially-patched tree.
  for p in "${patch_files[@]}"; do
    if ! git apply --check "$p"; then
      echo "PATCH CONFLICT: $(basename "$p") does not apply to $TAG."
      echo "Rebase the patch onto this tag (see README) and retry."
      exit 1
    fi
    git apply "$p"
    echo "    applied $(basename "$p")"
  done
else
  echo "==> No patches — clean upstream build"
fi
if [ -n "${BASH_VERSION:-}" ]; then shopt -u nullglob; fi

# ---------------------------------------------------------------- 3. compliance (pre-build)
"$ROOT/verify-compliance.sh" "$SRC" "$TAG" "$BASELINE"

# ---------------------------------------------------------------- 4. install + build
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export ZCODE_ENV=production   # stage config/provider/zcode-builtin.json (prod rules)
command -v pnpm >/dev/null 2>&1 || corepack enable

echo "==> pnpm install (root workspace; vendor patches in patches/ are load-bearing)"
if [ "${#patch_files[@]}" -gt 0 ]; then
  # Our patches may add workspace deps; their lockfile delta ships inside the patch.
  pnpm install --no-frozen-lockfile
else
  pnpm install --frozen-lockfile
fi

echo "==> Building engine bundle (tsc chain + esbuild + plugin runtimes + glm staging)"
node scripts/build-desktop-agent-cli.mjs

echo "==> Full glm staging (official plugins, bundled skills, npm runtime, sharp/koffi)"
node packages/desktop/scripts/prepare-agent-node-bundle.mjs

echo "==> Building TUI + workspace deps"
pnpm --filter @zcode/contracts --filter @zcode/i18n --filter @zcode/shared run build
pnpm --filter @zcode/tui run build

echo "==> Deploying self-contained TUI node_modules closure"
python3 - <<'PY'
import json
p = "package.json"
d = json.load(open(p))
d.get("pnpm", {}).pop("patchedDependencies", None)  # filtered deploy fails patch validation
json.dump(d, open(p, "w"), indent=2)
PY
rm -rf "$ROOT/tui-deploy"
pnpm deploy --filter=@zcode/tui --prod --legacy "$ROOT/tui-deploy"
git checkout -- package.json   # restore real manifest (patches intact for next time)

# ---------------------------------------------------------------- 5. assemble engine
PLATFORM_KEY="$(node -e 'console.log(`${process.platform}-${process.arch}`)')"
GLM_STAGED="packages/desktop/bundled-agents/$PLATFORM_KEY/glm"
[[ -f "$GLM_STAGED/zcode.cjs" ]] || { echo "staged bundle missing: $GLM_STAGED/zcode.cjs"; exit 1; }

echo "==> Assembling engine at $ENGINE"
rm -rf "$ENGINE"
mkdir -p "$ENGINE"
cp -R "$GLM_STAGED/." "$ENGINE/"
mkdir -p "$ENGINE/provider"
cp apps/zcode-cli/packages/cli/dist/provider/zcode-builtin.json "$ENGINE/provider/zcode-builtin.json"
cp -R "$ROOT/tui-deploy/node_modules" "$ENGINE/node_modules/"
mkdir -p "$ENGINE/node_modules/@zcode/tui"
cp "$ROOT/tui-deploy/package.json" "$ENGINE/node_modules/@zcode/tui/package.json"
cp -R "$ROOT/tui-deploy/dist" "$ENGINE/node_modules/@zcode/tui/dist"
chmod +x "$ENGINE/zcode.cjs"

echo "==> Bundling @zcode/services as engine ESM module"
node "$ROOT/build-services.mjs" "$SRC" "$ENGINE"

# ---------------------------------------------------------------- 6. report
ENGINE_TAG_VERSION=$(node "$ENGINE/zcode.cjs" --version 2>/dev/null || true)
echo "==> Done."
echo "    tag:            $TAG"
echo "    engine:         $ENGINE"
echo "    engine version: ${ENGINE_TAG_VERSION:-unknown}"
echo "    launch:         zcode-tui   (wrapper uses this engine)"
