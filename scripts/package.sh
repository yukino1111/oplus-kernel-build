#!/usr/bin/env bash
set -euo pipefail

rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"
AK3_DIR="$DEPS_DIR/AnyKernel3"
KSU_DIR="$SRC_DIR/kernel_platform/KernelSU"
ENABLE_ROOT=${ENABLE_ROOT:-1}
ENABLE_HMBIRD=${ENABLE_HMBIRD:-1}
ENABLE_BBG=${ENABLE_BBG:-1}
ENABLE_NTSYNC=${ENABLE_NTSYNC:-0}
ENABLE_DROIDSPACES=${ENABLE_DROIDSPACES:-0}
ENABLE_NETWORK=${ENABLE_NETWORK:-1}
ENABLE_UNICODE=${ENABLE_UNICODE:-1}

# KernelSU's Kbuild unshallows its pinned repository before compiling and
# derives the embedded version from the full commit count. Recompute the same
# value here so the ZIP name and build-info match the actual kernel binary.
if [[ $ENABLE_ROOT == 1 ]]; then
  KSU_GIT_COUNT=$(git -C "$KSU_DIR" rev-list --count HEAD)
  (( KSU_GIT_COUNT > 1 )) || { echo "KernelSU history is still shallow" >&2; exit 1; }
  KSU_VERSION=$((30000 + KSU_GIT_COUNT))
  grep -q -- "-DKSU_VERSION=$KSU_VERSION" "$OUT_DIR/build.log" || {
    echo "KernelSU metadata version does not match the compiled Image" >&2
    exit 1
  }
else
  KSU_VERSION=disabled
fi

rm -rf "$AK3_DIR"
git init -q "$AK3_DIR"
git -C "$AK3_DIR" remote add origin https://github.com/osm0sis/AnyKernel3.git
git -C "$AK3_DIR" fetch --depth=1 origin "$ANYKERNEL_SHA"
git -C "$AK3_DIR" checkout -q --detach FETCH_HEAD

MAGISK_VERSION=30.7
MAGISK_APK_SHA256=e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5
MAGISK_APK="$DEPS_DIR/Magisk-v$MAGISK_VERSION.apk"
curl --fail --location --retry 5 \
  "https://github.com/topjohnwu/Magisk/releases/download/v$MAGISK_VERSION/Magisk-v$MAGISK_VERSION.apk" \
  -o "$MAGISK_APK"
printf '%s  %s\n' "$MAGISK_APK_SHA256" "$MAGISK_APK" | sha256sum -c -

unzip -p "$MAGISK_APK" lib/arm64-v8a/libbusybox.so > "$AK3_DIR/tools/busybox"
unzip -p "$MAGISK_APK" lib/arm64-v8a/libmagiskboot.so > "$AK3_DIR/tools/magiskboot"
chmod 0755 "$AK3_DIR/tools/busybox" "$AK3_DIR/tools/magiskboot"
rm -f \
  "$AK3_DIR/tools/fec" \
  "$AK3_DIR/tools/httools_static" \
  "$AK3_DIR/tools/lptools_static" \
  "$AK3_DIR/tools/magiskpolicy" \
  "$AK3_DIR/tools/snapshotupdater_static"

for tool in busybox magiskboot; do
  readelf -h "$AK3_DIR/tools/$tool" | grep -q 'Class:.*ELF64' || {
    echo "AnyKernel3 $tool is not ELF64" >&2
    exit 1
  }
  readelf -h "$AK3_DIR/tools/$tool" | grep -q 'Machine:.*AArch64' || {
    echo "AnyKernel3 $tool is not AArch64" >&2
    exit 1
  }
done

cp "$IMAGE" "$ARTIFACT_DIR/Image"
cp "$IMAGE" "$AK3_DIR/Image"

cat > "$AK3_DIR/anykernel.sh" <<'AK3'
### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

properties() { '
kernel.string=Yukino Android 16 kernel
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
do.check_boot_version=1
supported.versions=16
supported.patchlevels=
supported.vendorpatchlevels=
'; }

BLOCK=boot
IS_SLOT_DEVICE=auto
RAMDISK_COMPRESSION=auto
PATCH_VBMETA_FLAG=auto
NO_MAGISK_CHECK=1

. tools/ak3-core.sh

platform=$(getprop ro.board.platform 2>/dev/null)
device=$(getprop ro.product.device 2>/dev/null)
model=$(getprop ro.product.model 2>/dev/null)
ui_print "Target: __DEVICE_NAME__ (__EXPECTED_DEVICE__, __EXPECTED_PLATFORM__)"
ui_print "Detected: device=${device:-unknown}, model=${model:-unknown}, platform=${platform:-unknown}"
[ "$platform" = "__EXPECTED_PLATFORM__" ] || abort "Wrong SoC/platform; refusing to flash this device-specific kernel."

kernel_version=$(awk '{print $3}' /proc/version)
case "$kernel_version" in
  6.6*) ;;
  *) abort "This package requires a Linux 6.6 GKI device." ;;
esac

split_boot
if [ -f "$SPLITIMG/ramdisk.cpio" ]; then
  unpack_ramdisk
  write_boot
else
  flash_boot
fi
AK3

sed -i \
  -e "s/__EXPECTED_DEVICE__/$EXPECTED_DEVICE/g" \
  -e "s/__EXPECTED_PLATFORM__/$EXPECTED_PLATFORM/g" \
  -e "s/__DEVICE_NAME__/$DEVICE_NAME/g" \
  "$AK3_DIR/anykernel.sh"

grep -qx 'BLOCK=boot' "$AK3_DIR/anykernel.sh"
grep -qx 'IS_SLOT_DEVICE=auto' "$AK3_DIR/anykernel.sh"
grep -qx 'RAMDISK_COMPRESSION=auto' "$AK3_DIR/anykernel.sh"
grep -qx 'PATCH_VBMETA_FLAG=auto' "$AK3_DIR/anykernel.sh"
grep -qx 'NO_MAGISK_CHECK=1' "$AK3_DIR/anykernel.sh"
grep -qx 'do.devicecheck=0' "$AK3_DIR/anykernel.sh"
! grep -q '^device\.name' "$AK3_DIR/anykernel.sh" || {
  echo "AnyKernel3 device aliases are intentionally disabled; use the explicit platform gate" >&2
  exit 1
}
if grep -Eq '^(block|is_slot_device|ramdisk_compression|patch_vbmeta_flag|no_magisk_check)=' "$AK3_DIR/anykernel.sh"; then
  echo "AnyKernel3 variables must use canonical uppercase names" >&2
  exit 1
fi

if [[ $ENABLE_ROOT == 1 ]]; then
  ROOT_TAG="KSU-${KSU_VERSION}-SuSFS-${SUSFS_VERSION}"
else
  ROOT_TAG="no-root"
fi
ZIP_NAME="${DEVICE_ID}-A16-${KERNEL_FULL_VERSION}-${ROOT_TAG}-run${GITHUB_RUN_ID}.zip"
(cd "$AK3_DIR" && zip -r9 "$ARTIFACT_DIR/$ZIP_NAME" . -x '.git/*' '.github/*' 'README.md' '*.zip')

unzip -t "$ARTIFACT_DIR/$ZIP_NAME"
ZIP_ENTRIES=$(unzip -Z1 "$ARTIFACT_DIR/$ZIP_NAME")
grep -qx 'Image' <<< "$ZIP_ENTRIES"
grep -qx 'anykernel.sh' <<< "$ZIP_ENTRIES"
grep -qx 'tools/busybox' <<< "$ZIP_ENTRIES"
grep -qx 'tools/magiskboot' <<< "$ZIP_ENTRIES"
! grep -q '^\.github/' <<< "$ZIP_ENTRIES" || {
  echo "Repository-only .github files leaked into the flashable package" >&2
  exit 1
}
[[ $ZIP_NAME == *"-run${GITHUB_RUN_ID}.zip" ]] || {
  echo "Flashable ZIP name does not identify its Actions run" >&2
  exit 1
}
for unused_tool in fec httools_static lptools_static magiskpolicy snapshotupdater_static; do
  ! grep -qx "tools/$unused_tool" <<< "$ZIP_ENTRIES" || {
    echo "Unused 32-bit tool is present in package: $unused_tool" >&2
    exit 1
  }
done
(( $(stat -c %s "$ARTIFACT_DIR/$ZIP_NAME") >= 6000000 ))

IMAGE_SHA256=$(sha256sum "$ARTIFACT_DIR/Image" | awk '{print $1}')
ZIP_SHA256=$(sha256sum "$ARTIFACT_DIR/$ZIP_NAME" | awk '{print $1}')

if [[ $ENABLE_NTSYNC == 1 ]]; then
  NTSYNC_STATUS=enabled
else
  NTSYNC_STATUS=disabled
fi
if [[ $ENABLE_DROIDSPACES == 1 ]]; then
  DROIDSPACES_STATUS=enabled
  if [[ $DEVICE_ID == pad2pro-sm8750 ]]; then
    DROIDSPACES_SOURCE="https://github.com/ravindu644/Droidspaces-OSS@$DROIDSPACES_SHA"
  else
    DROIDSPACES_SOURCE="WildKernels compatibility patches@$PATCHES_SHA"
  fi
else
  DROIDSPACES_STATUS=disabled
  DROIDSPACES_SOURCE="not used"
fi
ROOT_FEATURE=""
ROOT_DISABLED=""
if [[ $ENABLE_ROOT == 1 ]]; then ROOT_FEATURE="KernelSU official dev, SuSFS"; else ROOT_DISABLED=", KernelSU, SuSFS"; fi
HMBIRD_FEATURE=""
HMBIRD_DISABLED=""
if [[ $ENABLE_HMBIRD == 1 ]]; then HMBIRD_FEATURE=", Fengchi/HMBIRD"; else HMBIRD_DISABLED=", Fengchi/HMBIRD"; fi
BBG_FEATURE=""
BBG_DISABLED=""
if [[ $ENABLE_BBG == 1 ]]; then BBG_FEATURE=", Baseband Guard"; else BBG_DISABLED=", Baseband Guard"; fi
NETWORK_FEATURE=""
NETWORK_DISABLED=""
if [[ $ENABLE_NETWORK == 1 ]]; then NETWORK_FEATURE=", CAKE, PIE, FQ_PIE, FQ_CODEL, FQ, IP_SET, IPv6 NAT/TTL"; else NETWORK_DISABLED=", network extensions"; fi
UNICODE_FEATURE=""
UNICODE_DISABLED=""
if [[ $ENABLE_UNICODE == 1 ]]; then UNICODE_FEATURE=", Unicode bypass fix"; else UNICODE_DISABLED=", Unicode bypass fix"; fi
DEVICE_FEATURES=""
[[ $ENABLE_DROIDSPACES == 1 ]] && DEVICE_FEATURES+=", Droidspaces kernel support"
[[ $ENABLE_NTSYNC == 1 ]] && DEVICE_FEATURES+=", NTSync"
DEVICE_DISABLED="$ROOT_DISABLED$HMBIRD_DISABLED$BBG_DISABLED$NETWORK_DISABLED$UNICODE_DISABLED"
[[ $ENABLE_DROIDSPACES == 1 ]] || DEVICE_DISABLED+=", Droidspaces kernel support"
[[ $ENABLE_NTSYNC == 1 ]] || DEVICE_DISABLED+=", NTSync"

cat > "$ARTIFACT_DIR/build-info.txt" <<EOF
Device: $DEVICE_NAME
Device ID: $DEVICE_ID
SoC: $SOC
OS branch: $OS_BRANCH
Android generation: $ANDROID_GENERATION
Kernel base: $KERNEL_SERIES
Kernel full version: $KERNEL_FULL_VERSION

OnePlus kernel source: $COMMON_URL
OnePlus kernel source SHA: $ONEPLUS_COMMON_SHA
OnePlus modules source: $MODULES_URL
OnePlus modules source SHA: $ONEPLUS_MODULES_SHA

KernelSU branch: dev (pinned tested pair)
KernelSU full SHA: $KSU_SHA
KernelSU version: $KSU_VERSION

SuSFS source: https://gitlab.com/simonpunk/susfs4ksu
SuSFS branch: gki-android15-6.6
SuSFS full SHA: $SUSFS_SHA
SuSFS version: $SUSFS_VERSION

Baseband Guard source: https://github.com/vc-teahouse/Baseband-guard
Baseband Guard branch: $BBG_BRANCH (latest compatible pre-6.18 line)
Baseband Guard SHA: $BBG_SHA
Fengchi/HMBIRD source: https://github.com/Numbersf/SCHED_PATCH
Fengchi/HMBIRD branch: $HMBIRD_BRANCH
Fengchi/HMBIRD patch: $HMBIRD_PATCH
Fengchi/HMBIRD SHA: $HMBIRD_SHA
Droidspaces status: $DROIDSPACES_STATUS
Droidspaces source: $DROIDSPACES_SOURCE
NTSync status: $NTSYNC_STATUS
NTSync patch source: https://github.com/WildKernels/kernel_patches@$PATCHES_SHA/common/ntsync ($NTSYNC_STATUS)
Unicode patch source: https://github.com/WildKernels/kernel_patches@$PATCHES_SHA/common/unicode_bypass_fix_6.1+.patch
AnyKernel3 source: https://github.com/osm0sis/AnyKernel3@$ANYKERNEL_SHA
AnyKernel3 arm64 tools: Magisk v$MAGISK_VERSION (official BusyBox and magiskboot)
Magisk APK SHA256: $MAGISK_APK_SHA256

Toolchain: $TOOLCHAIN_NAME
Compiler version: $CLANG_VERSION
Optimization: -O2
ThinLTO status: enabled
Oryon target status: $ORYON_STATUS

Enabled features: $ROOT_FEATURE$BBG_FEATURE$UNICODE_FEATURE$HMBIRD_FEATURE, ThinLTO, TMPFS XATTR, TMPFS POSIX ACL$NETWORK_FEATURE$DEVICE_FEATURES
Intentionally disabled/not applied: BBR, BBRv3, WireGuard, ADIOS, BORE, LRNG, Wakelock Blocker, Module Overlay, vendor module blacklist/debloat, fake config, Wild 25-patch optimisation bundle, force_tcp_nodelay, cache-pressure tuning, ZRAM writeback tuning, LZ4KD, custom memory tuning, F2FS magic patches, EXT4 commit-age hacks, scheduler optimisation bundles$DEVICE_DISABLED

GitHub Actions run ID: $GITHUB_RUN_ID
GitHub Actions run attempt: $GITHUB_RUN_ATTEMPT
Build timestamp: $(date -u --iso-8601=seconds)
Artifact name: kernel-$DEVICE_ID-$GITHUB_RUN_ID
Kernel ZIP: $ZIP_NAME
Image SHA256: $IMAGE_SHA256
ZIP SHA256: $ZIP_SHA256
EOF

(cd "$ARTIFACT_DIR" && sha256sum Image "$ZIP_NAME" build-info.txt > SHA256SUMS)
(cd "$ARTIFACT_DIR" && sha256sum -c SHA256SUMS)

cat "$ARTIFACT_DIR/build-info.txt"
printf 'ZIP_NAME=%s\nIMAGE_SHA256=%s\nZIP_SHA256=%s\n' "$ZIP_NAME" "$IMAGE_SHA256" "$ZIP_SHA256" >> "$GITHUB_ENV"
