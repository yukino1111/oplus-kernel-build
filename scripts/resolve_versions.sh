#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE=${1:?usage: resolve_versions.sh configs/device.env}
# shellcheck disable=SC1090
source "$CONFIG_FILE"

ENABLE_ROOT=${ENABLE_ROOT:-1}
ENABLE_HMBIRD=${ENABLE_HMBIRD:-1}
ENABLE_BBG=${ENABLE_BBG:-1}
ENABLE_NTSYNC=${ENABLE_NTSYNC:-0}
ENABLE_DROIDSPACES=${ENABLE_DROIDSPACES:-0}
ENABLE_NETWORK=${ENABLE_NETWORK:-1}
ENABLE_UNICODE=${ENABLE_UNICODE:-1}

ls_remote() {
  local url=$1 ref=$2 sha= attempt
  for attempt in 1 2 3 4 5; do
    sha=$(git ls-remote "$url" "$ref" | awk 'NR == 1 {print $1}')
    if [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
      printf '%s\n' "$sha"
      return 0
    fi
    sleep $((attempt * 3))
  done
  echo "Unable to resolve $url $ref" >&2
  return 1
}

case "$DEVICE_ID" in
  pad2pro-sm8750)
    COMMON_URL=https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8750.git
    MODULES_URL=https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8750.git
    ;;
  ace5ultra-mt6991)
    COMMON_URL=https://github.com/OnePlusOSS/android_kernel_oneplus_mt6991.git
    MODULES_URL=https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_mt6991.git
    ;;
  *) echo "Unsupported device: $DEVICE_ID" >&2; exit 2 ;;
esac

if [[ -n ${PIN_ONEPLUS_COMMON_SHA:-} || -n ${PIN_ONEPLUS_MODULES_SHA:-} ]]; then
  [[ ${PIN_ONEPLUS_COMMON_SHA:-} =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid pinned OnePlus common SHA" >&2; exit 2; }
  [[ ${PIN_ONEPLUS_MODULES_SHA:-} =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid pinned OnePlus modules SHA" >&2; exit 2; }
  ONEPLUS_COMMON_SHA=$PIN_ONEPLUS_COMMON_SHA
  ONEPLUS_MODULES_SHA=$PIN_ONEPLUS_MODULES_SHA
else
  ONEPLUS_COMMON_SHA=$(ls_remote "$COMMON_URL" "refs/heads/$OS_BRANCH")
  ONEPLUS_MODULES_SHA=$(ls_remote "$MODULES_URL" "refs/heads/$OS_BRANCH")
fi

# KernelSU and SuSFS are intentionally pinned as a tested pair. Never resolve
# their moving branches independently: an otherwise harmless SuSFS update can
# stop applying to the selected KernelSU tree.
if [[ -n ${KSU_SHA:-} ]]; then
  [[ $KSU_SHA =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid pinned KernelSU SHA" >&2; exit 2; }
else
  KSU_SHA=$(ls_remote https://github.com/tiann/KernelSU.git refs/heads/dev)
fi
if [[ -n ${SUSFS_SHA:-} ]]; then
  [[ $SUSFS_SHA =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid pinned SuSFS SHA" >&2; exit 2; }
else
  SUSFS_SHA=$(ls_remote https://gitlab.com/simonpunk/susfs4ksu.git refs/heads/gki-android15-6.6)
fi
if [[ $ENABLE_ROOT == 1 || $ENABLE_HMBIRD == 1 || $ENABLE_NTSYNC == 1 || $ENABLE_DROIDSPACES == 1 || $ENABLE_UNICODE == 1 ]]; then
  PATCHES_SHA=$(ls_remote https://github.com/WildKernels/kernel_patches.git refs/heads/main)
else
  PATCHES_SHA=
fi
if [[ $ENABLE_HMBIRD == 1 ]]; then
  HMBIRD_SHA=$(ls_remote https://github.com/Numbersf/SCHED_PATCH.git "refs/heads/$HMBIRD_BRANCH")
else
  HMBIRD_SHA=
fi
DROIDSPACES_SHA=
if [[ $DEVICE_ID == pad2pro-sm8750 && $ENABLE_DROIDSPACES == 1 ]]; then
  DROIDSPACES_SHA=$(ls_remote https://github.com/ravindu644/Droidspaces-OSS.git refs/heads/main)
fi

# release-1.0 is the newest BBG line explicitly maintained for pre-6.18 kernels.
# Later main commits only advance CI to Android 17 / Linux 6.18.
BBG_BRANCH=release-1.0
if [[ $ENABLE_BBG == 1 ]]; then
  BBG_SHA=$(ls_remote https://github.com/vc-teahouse/Baseband-guard.git "refs/heads/$BBG_BRANCH")
else
  BBG_SHA=
fi
# ZyC and AnyKernel3 are intentionally fixed rather than resolved here.
ANYKERNEL_SHA=af770f7b16cf8f8eb7c68614b2a693b3b361c90c

RESOLVED_FILE="$GITHUB_WORKSPACE/resolved-${DEVICE_ID}.env"
{
  for name in DEVICE_ID DEVICE_NAME SOC OS_BRANCH ANDROID_GENERATION KERNEL_SERIES MANIFEST COMMON_PROJECT HMBIRD_BRANCH HMBIRD_PATCH EXPECTED_PLATFORM EXPECTED_DEVICE USE_ORYON ZYC_VERSION ZYC_URL BUILD_TOOLS_SHA COMMON_URL MODULES_URL ONEPLUS_COMMON_SHA ONEPLUS_MODULES_SHA KSU_SHA SUSFS_SHA PATCHES_SHA HMBIRD_SHA DROIDSPACES_SHA BBG_SHA BBG_BRANCH ANYKERNEL_SHA; do
    printf '%s=%s\n' "$name" "${!name}"
  done
} | tee "$RESOLVED_FILE" >> "$GITHUB_ENV"

echo "Locked OnePlus common: $ONEPLUS_COMMON_SHA"
echo "Locked OnePlus modules: $ONEPLUS_MODULES_SHA"
echo "Locked KernelSU dev: $KSU_SHA"
echo "Locked SuSFS: $SUSFS_SHA"
echo "Locked WildKernels patches: $PATCHES_SHA"
echo "Locked HMBIRD: $HMBIRD_SHA"
echo "Locked Baseband Guard: $BBG_SHA"
if [[ -n $DROIDSPACES_SHA ]]; then
  echo "Locked Droidspaces: $DROIDSPACES_SHA"
fi
