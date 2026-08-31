#!/usr/bin/env bash
set -euo pipefail

rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
cd "$SRC_DIR"

git config --global feature.manyFiles true
git config --global core.fsmonitor false

reference_dir="$BUILD_TOOLS_CACHE_DIR"
if [[ -n ${SOURCE_OBJECT_CACHE_DIR:-} && -d $SOURCE_OBJECT_CACHE_DIR/.repo/project-objects ]]; then
  reference_dir="$SOURCE_OBJECT_CACHE_DIR"
else
  # Keep the fixed CLO build-tools objects outside SRC_DIR so the first sync
  # can reuse them and Actions can cache them for later source-cache misses.
  build_tools_mirror="$BUILD_TOOLS_CACHE_DIR/kernel/prebuilts/build-tools.git"
  mkdir -p "$(dirname "$build_tools_mirror")"
  if ! git --git-dir="$build_tools_mirror" rev-parse --is-bare-repository >/dev/null 2>&1; then
    rm -rf "$build_tools_mirror"
    git init -q --bare "$build_tools_mirror"
    git --git-dir="$build_tools_mirror" remote add origin https://git.codelinaro.org/clo/la/kernel/prebuilts/build-tools.git
  fi
  git --git-dir="$build_tools_mirror" fetch --depth=1 origin "$BUILD_TOOLS_SHA"
  git --git-dir="$build_tools_mirror" cat-file -e "$BUILD_TOOLS_SHA^{commit}"
fi

repo init \
  -u https://github.com/yukino1111/oplus-kernel-build.git \
  -b main \
  -m "manifests/$MANIFEST" \
  --reference="$reference_dir" \
  --depth=1 \
  --no-repo-verify

for attempt in 1 2 3; do
  if repo sync -c --no-tags --prune --force-sync --optimized-fetch -j4; then
    break
  fi
  [[ $attempt -lt 3 ]] || exit 1
  sleep $((attempt * 10))
done

COMMON_DIR=$(readlink -f "$SRC_DIR/kernel_platform/common")
[[ -f "$COMMON_DIR/Makefile" ]] || { echo "Common kernel tree missing" >&2; exit 1; }

# Build the SHAs produced by the resolve job even if an upstream branch moves
# between resolution and repo sync.
git -C "$COMMON_DIR" fetch --depth=1 "$COMMON_URL" "$ONEPLUS_COMMON_SHA"
git -C "$COMMON_DIR" checkout -q --detach FETCH_HEAD
git -C "$SRC_DIR" fetch --depth=1 "$MODULES_URL" "$ONEPLUS_MODULES_SHA"
git -C "$SRC_DIR" checkout -q --detach FETCH_HEAD

actual_common=$(git -C "$COMMON_DIR" rev-parse HEAD)
actual_modules=$(git -C "$SRC_DIR" rev-parse HEAD)
[[ $actual_common == "$ONEPLUS_COMMON_SHA" ]] || { echo "Failed to lock OnePlus common SHA" >&2; exit 1; }
[[ $actual_modules == "$ONEPLUS_MODULES_SHA" ]] || { echo "Failed to lock OnePlus modules SHA" >&2; exit 1; }

# Persist only repo Git objects, never the expanded source tree. A new Actions
# cache key is created when the source fingerprint changes.
if [[ -n ${SOURCE_OBJECT_CACHE_DIR:-} && -d .repo/project-objects ]]; then
  rm -rf "$SOURCE_OBJECT_CACHE_DIR/.repo/project-objects"
  mkdir -p "$SOURCE_OBJECT_CACHE_DIR/.repo"
  rsync -a --delete .repo/project-objects/ "$SOURCE_OBJECT_CACHE_DIR/.repo/project-objects/"
fi

printf 'COMMON_DIR=%s\n' "$COMMON_DIR" >> "$GITHUB_ENV"
echo "Synced official source at $actual_common"
