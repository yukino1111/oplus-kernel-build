#!/usr/bin/env bash
set -euo pipefail

ENABLE_ROOT=${ENABLE_ROOT:-1}
ENABLE_BBG=${ENABLE_BBG:-1}
ENABLE_DROIDSPACES=${ENABLE_DROIDSPACES:-0}
ENABLE_NETWORK=${ENABLE_NETWORK:-1}
ENABLE_NTSYNC=${ENABLE_NTSYNC:-0}

mkdir -p "$OUT_DIR" "$CCACHE_DIR"

ORYON_STATUS=disabled
case "$SOC" in
  SM8750)
    [[ $DEVICE_ID == pad2pro-sm8750 && $USE_ORYON == 1 ]] || { echo "Invalid SM8750 toolchain configuration" >&2; exit 1; }
    [[ $ZYC_VERSION == 19.0.0git-20240723 && -n $ZYC_URL ]] || { echo "Pad 2 Pro requires pinned ZyC 19.0.0git-20240723" >&2; exit 1; }
    zyc_dir="$DEPS_DIR/zyc-clang"
    if [[ ! -x $zyc_dir/bin/clang ]]; then
      mkdir -p "$zyc_dir"
      zyc_archive=$(mktemp /tmp/zyc-clang.XXXXXX.tar.gz)
      trap 'rm -f "$zyc_archive" /tmp/oryon-test.o' EXIT
      aria2c --max-tries=5 --retry-wait=3 --allow-overwrite=true --auto-file-renaming=false -x8 -s8 --dir="$(dirname "$zyc_archive")" --out="$(basename "$zyc_archive")" "$ZYC_URL"
      tar -xzf "$zyc_archive" -C "$zyc_dir"
    fi
    CLANG_BIN="$zyc_dir/bin"
    [[ -x $CLANG_BIN/clang ]] || { echo "Pinned ZyC clang not found after extraction" >&2; exit 1; }
    "$CLANG_BIN/clang" --version | head -n1 | grep -Eq '19\.0\.0|19\.0'
    "$CLANG_BIN/clang" --target=aarch64-linux-gnu -mcpu=oryon-1 -c -x c /dev/null -o /tmp/oryon-test.o
    TOOLCHAIN_NAME="ZyC $ZYC_VERSION"
    ORYON_STATUS=enabled
    ;;
  MT6991)
    [[ $DEVICE_ID == ace5ultra-mt6991 && $USE_ORYON == 0 ]] || { echo "Invalid MT6991 toolchain configuration" >&2; exit 1; }
    official_root="$SRC_DIR/kernel_platform/prebuilts/clang/host/linux-x86"
    official_clang=$(find "$official_root" -maxdepth 3 -type f -name clang -perm -111 | sort -V | tail -n1)
    [[ -x $official_clang ]] || { echo "Official CLO clang not found" >&2; exit 1; }
    CLANG_BIN=$(dirname "$official_clang")
    TOOLCHAIN_NAME="Official OnePlus/CLO Clang"
    ;;
  *) echo "Unsupported SoC: $SOC" >&2; exit 2 ;;
esac

export PATH="$CLANG_BIN:$SRC_DIR/kernel_platform/prebuilts/kernel-build-tools/linux-x86/bin:$SRC_DIR/kernel_platform/prebuilts/kernel-build-tools/linux_musl-x86/bin:/usr/lib/ccache:$PATH"
export ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1
export LD=ld.lld HOSTLD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
export CROSS_COMPILE=aarch64-linux-gnu-
export KBUILD_BUILD_USER=yukino KBUILD_BUILD_HOST=github-actions
export KBUILD_BUILD_TIMESTAMP=$(date -u '+%a %b %d %H:%M:%S UTC %Y')
export SOURCE_DATE_EPOCH=$(git -C "$COMMON_DIR" log -1 --format=%ct)
MAKE_COMPILER_ARGS=(
  CC="ccache clang"
  CXX="ccache clang++"
  HOSTCC="ccache clang"
  HOSTCXX="ccache clang++"
)

ccache --set-config "cache_dir=$CCACHE_DIR"
ccache --set-config "max_size=$CCACHE_MAXSIZE"
ccache --set-config compression=true
ccache --set-config compiler_check=content
ccache --zero-stats

cd "$COMMON_DIR"
rm -rf "$OUT_DIR/kernel"
KOUT="$OUT_DIR/kernel"
mkdir -p "$KOUT"

make "${MAKE_COMPILER_ARGS[@]}" O="$KOUT" gki_defconfig

cfg="$KOUT/.config"
scripts/config --file "$cfg" --set-str LOCALVERSION "-android15-6.6-${DEVICE_ID}"
scripts/config --file "$cfg" -d LOCALVERSION_AUTO
scripts/config --file "$cfg" -e CC_OPTIMIZE_FOR_PERFORMANCE -d CC_OPTIMIZE_FOR_PERFORMANCE_O3
scripts/config --file "$cfg" -e LTO_CLANG -e LTO_CLANG_THIN -d LTO_CLANG_NONE -d LTO_CLANG_FULL

required=(TMPFS_XATTR TMPFS_POSIX_ACL DEVTMPFS)
if [[ $ENABLE_ROOT == 1 ]]; then
  required+=(KSU KSU_SUSFS)
else
  for option in KSU KSU_SUSFS; do scripts/config --file "$cfg" -d "$option" || true; done
fi
if [[ $ENABLE_BBG == 1 ]]; then
  required+=(BBG)
else
  scripts/config --file "$cfg" -d BBG || true
fi
if [[ $ENABLE_DROIDSPACES == 1 ]]; then
  required+=(SYSVIPC PID_NS POSIX_MQUEUE USER_NS)
else
  for option in SYSVIPC PID_NS POSIX_MQUEUE USER_NS; do scripts/config --file "$cfg" -d "$option" || true; done
fi
if [[ $ENABLE_NETWORK == 1 ]]; then
  required+=(
    NET_SCH_FQ NET_SCH_FQ_CODEL NET_SCH_CAKE NET_SCH_PIE NET_SCH_FQ_PIE
    IP_NF_TARGET_TTL IP6_NF_TARGET_HL IP6_NF_MATCH_HL IP_SET
    IP_SET_BITMAP_IP IP_SET_BITMAP_IPMAC IP_SET_BITMAP_PORT IP_SET_HASH_IP
    IP_SET_HASH_IPMARK IP_SET_HASH_IPPORT IP_SET_HASH_IPPORTIP
    IP_SET_HASH_IPPORTNET IP_SET_HASH_IPMAC IP_SET_HASH_MAC
    IP_SET_HASH_NETPORTNET IP_SET_HASH_NET IP_SET_HASH_NETNET
    IP_SET_HASH_NETPORT IP_SET_HASH_NETIFACE IP_SET_LIST_SET NETFILTER_XT_SET
    IP6_NF_NAT IP6_NF_TARGET_MASQUERADE
  )
else
  for option in NET_SCH_FQ NET_SCH_FQ_CODEL NET_SCH_CAKE NET_SCH_PIE NET_SCH_FQ_PIE IP_NF_TARGET_TTL IP6_NF_TARGET_HL IP6_NF_MATCH_HL IP_SET NETFILTER_XT_SET IP6_NF_NAT IP6_NF_TARGET_MASQUERADE; do
    scripts/config --file "$cfg" -d "$option" || true
  done
fi
for option in "${required[@]}"; do scripts/config --file "$cfg" -e "$option"; done
scripts/config --file "$cfg" --set-val IP_SET_MAX 65534

if [[ $ENABLE_NTSYNC == 1 ]]; then
  scripts/config --file "$cfg" -e NTSYNC
else
  scripts/config --file "$cfg" -d NTSYNC
fi

for option in TCP_CONG_BBR WIREGUARD ZRAM_WRITEBACK SCHED_BORE IOSCHED_ADIOS LRNG; do
  scripts/config --file "$cfg" -d "$option" || true
done

current_lsm=$(sed -n 's/^CONFIG_LSM="\(.*\)"/\1/p' "$cfg")
if [[ $ENABLE_BBG == 1 && ,$current_lsm, != *,baseband_guard,* ]]; then
  scripts/config --file "$cfg" --set-str LSM "${current_lsm:+$current_lsm,}baseband_guard"
elif [[ $ENABLE_BBG != 1 && ,$current_lsm, == *,baseband_guard,* ]]; then
  current_lsm=${current_lsm//,baseband_guard/}
  current_lsm=${current_lsm//baseband_guard,/}
  current_lsm=${current_lsm//baseband_guard/}
  scripts/config --file "$cfg" --set-str LSM "$current_lsm"
fi

make "${MAKE_COMPILER_ARGS[@]}" O="$KOUT" olddefconfig
cp "$cfg" "$OUT_DIR/final.config"

KCFLAGS="-O2 -Wno-error -pipe -fdebug-prefix-map=$GITHUB_WORKSPACE=. -fmacro-prefix-map=$GITHUB_WORKSPACE=. -ffile-prefix-map=$GITHUB_WORKSPACE=."
if [[ $USE_ORYON == 1 ]]; then
  KCFLAGS="-mcpu=oryon-1 $KCFLAGS"
else
  [[ $KCFLAGS != *oryon-1* ]] || { echo "Oryon flag leaked into MT6991 build" >&2; exit 1; }
fi

CLANG_VERSION=$(clang --version | head -n1)
printf 'CLANG_VERSION=%s\nTOOLCHAIN_NAME=%s\nORYON_STATUS=%s\n' "$CLANG_VERSION" "$TOOLCHAIN_NAME" "$ORYON_STATUS" >> "$GITHUB_ENV"
echo "Compiler: $CLANG_VERSION"
echo "Toolchain: $TOOLCHAIN_NAME"
echo "KCFLAGS: $KCFLAGS"

set -o pipefail
make -j"$(nproc --all)" "${MAKE_COMPILER_ARGS[@]}" O="$KOUT" V=1 KCFLAGS="$KCFLAGS" Image 2>&1 | tee "$OUT_DIR/build.log"

IMAGE="$KOUT/arch/arm64/boot/Image"
[[ -f $IMAGE ]] || { echo "Kernel Image missing" >&2; exit 1; }
file "$IMAGE" | grep -qi 'ARM64' || { file "$IMAGE"; exit 1; }
(( $(stat -c %s "$IMAGE") >= 6000000 )) || { echo "Kernel Image is implausibly small" >&2; exit 1; }

if [[ $ENABLE_ROOT == 1 ]]; then
  for option in KSU KSU_SUSFS; do
    grep -qx "CONFIG_${option}=y" "$cfg" || { echo "CONFIG_${option}=y missing" >&2; exit 1; }
  done
else
  ! grep -qx 'CONFIG_KSU=y' "$cfg" || { echo 'CONFIG_KSU unexpectedly enabled' >&2; exit 1; }
  ! grep -qx 'CONFIG_KSU_SUSFS=y' "$cfg" || { echo 'CONFIG_KSU_SUSFS unexpectedly enabled' >&2; exit 1; }
fi
if [[ $ENABLE_BBG == 1 ]]; then
  grep -qx 'CONFIG_BBG=y' "$cfg" || { echo 'CONFIG_BBG=y missing' >&2; exit 1; }
else
  ! grep -qx 'CONFIG_BBG=y' "$cfg" || { echo 'CONFIG_BBG unexpectedly enabled' >&2; exit 1; }
fi
if [[ $ENABLE_NETWORK == 1 ]]; then
  grep -qx 'CONFIG_NET_SCH_CAKE=y' "$cfg" || { echo 'CONFIG_NET_SCH_CAKE=y missing' >&2; exit 1; }
  grep -qx 'CONFIG_IP_SET=y' "$cfg" || { echo 'CONFIG_IP_SET=y missing' >&2; exit 1; }
else
  ! grep -qx 'CONFIG_NET_SCH_CAKE=y' "$cfg" || { echo 'CONFIG_NET_SCH_CAKE unexpectedly enabled' >&2; exit 1; }
  ! grep -qx 'CONFIG_IP_SET=y' "$cfg" || { echo 'CONFIG_IP_SET unexpectedly enabled' >&2; exit 1; }
fi
if [[ $ENABLE_NTSYNC == 1 ]]; then
  grep -qx 'CONFIG_NTSYNC=y' "$cfg" || { echo "CONFIG_NTSYNC=y missing from requested build" >&2; exit 1; }
else
  ! grep -qx 'CONFIG_NTSYNC=y' "$cfg" || { echo "CONFIG_NTSYNC=y unexpectedly enabled" >&2; exit 1; }
fi
if [[ $ENABLE_BBG == 1 ]]; then
  grep -q '^CONFIG_LSM=.*baseband_guard' "$cfg" || { echo "baseband_guard missing from CONFIG_LSM" >&2; exit 1; }
else
  ! grep -q '^CONFIG_LSM=.*baseband_guard' "$cfg" || { echo "baseband_guard unexpectedly present in CONFIG_LSM" >&2; exit 1; }
fi
grep -qx 'CONFIG_LTO_CLANG_THIN=y' "$cfg"
grep -qx 'CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y' "$cfg"

for forbidden in TCP_CONG_BBR WIREGUARD ZRAM_WRITEBACK SCHED_BORE IOSCHED_ADIOS LRNG; do
  ! grep -qx "CONFIG_${forbidden}=y" "$cfg" || { echo "Forbidden CONFIG_${forbidden}=y" >&2; exit 1; }
done
[[ ! -e kernel/module/module_overlay && ! -e kernel/module_overlay ]] || { echo "Module Overlay present" >&2; exit 1; }
! find "$COMMON_DIR" -name '*.rej' -print -quit | grep -q . || { echo "Patch reject exists" >&2; exit 1; }

if [[ $USE_ORYON == 1 ]]; then
  grep -q -- '-mcpu=oryon-1' "$OUT_DIR/build.log" || { echo "Oryon flag absent from SM8750 log" >&2; exit 1; }
else
  ! grep -q -- '-mcpu=oryon-1' "$OUT_DIR/build.log" || { echo "Oryon flag present in MT6991 build" >&2; exit 1; }
fi
grep -q -- 'ccache clang .* -c ' "$OUT_DIR/build.log" || { echo "Kernel compilation bypassed ccache" >&2; exit 1; }

KERNEL_FULL_VERSION=$(make -s "${MAKE_COMPILER_ARGS[@]}" kernelrelease O="$KOUT")
printf 'IMAGE=%s\nKERNEL_FULL_VERSION=%s\n' "$IMAGE" "$KERNEL_FULL_VERSION" >> "$GITHUB_ENV"
ccache --show-stats
