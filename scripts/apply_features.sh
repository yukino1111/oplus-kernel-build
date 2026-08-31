#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$DEPS_DIR"

ENABLE_ROOT=${ENABLE_ROOT:-1}
ENABLE_HMBIRD=${ENABLE_HMBIRD:-1}
ENABLE_BBG=${ENABLE_BBG:-1}
ENABLE_NTSYNC=${ENABLE_NTSYNC:-0}
ENABLE_DROIDSPACES=${ENABLE_DROIDSPACES:-0}
ENABLE_NETWORK=${ENABLE_NETWORK:-1}
ENABLE_UNICODE=${ENABLE_UNICODE:-1}

clone_at() {
  local url=$1 sha=$2 dir=$3
  rm -rf "$dir"
  for attempt in 1 2 3; do
    if git init -q "$dir" &&
       git -C "$dir" remote add origin "$url" &&
       git -C "$dir" fetch --depth=1 origin "$sha" &&
       git -C "$dir" checkout -q --detach FETCH_HEAD; then
      [[ $(git -C "$dir" rev-parse HEAD) == "$sha" ]] || return 1
      return 0
    fi
    rm -rf "$dir"
    sleep $((attempt * 5))
  done
  return 1
}

apply_strict() {
  local patch_file=$1 strip=${2:-1}
  echo "Applying $(basename "$patch_file")"
  patch --batch --forward --fuzz=0 -p"$strip" < "$patch_file"
  if find . -name '*.rej' -print -quit | grep -q .; then
    echo "Reject file found after $(basename "$patch_file")" >&2
    find . -name '*.rej' -print >&2
    exit 1
  fi
}

apply_hmbird() {
  local patch_file=$1 rc=0
  echo "Applying device-specific $(basename "$patch_file")"
  patch --batch --forward --fuzz=0 -p1 < "$patch_file" || rc=$?
  [[ $rc == 0 || $rc == 1 ]] || return "$rc"

  # Current OnePlus 6.6.118 adds dmabuf/vendor hooks around two upstream
  # fork.c contexts. Preserve those hooks while applying the exact HMBIRD
  # semantic changes rejected by the upstream patch.
  if [[ -f kernel/fork.c.rej ]]; then
    sed -i '/^[[:space:]]*sched_ext_free(tsk);$/c\#ifdef CONFIG_HMBIRD_SCHED\n\thmbird_free(tsk);\n#endif' kernel/fork.c
    sed -i 's/^bad_fork_core_free:$/bad_fork_cancel_cgroup:/' kernel/fork.c
    awk 'BEGIN { seen=0 }
      /^bad_fork_cancel_cgroup:$/ { seen++; if (seen > 1) next }
      { print }
    ' kernel/fork.c > kernel/fork.c.tmp
    mv kernel/fork.c.tmp kernel/fork.c
    rm kernel/fork.c.rej
  fi

  # MT6991 already carries the newer SCHED_CHANGE_BLOCK form without the
  # obsolete task_group argument. Convert that one function to the final
  # HMBIRD-safe dequeue/change/enqueue sequence when its two upstream hunks
  # reject. This resolution is intentionally MT-only.
  if [[ $DEVICE_ID == ace5ultra-mt6991 && -f kernel/sched/core.c.rej ]]; then
    python3 - <<'PY'
from pathlib import Path
import re

p = Path('kernel/sched/core.c')
s = p.read_text()
pattern = re.compile(
    r'void sched_move_task\(struct task_struct \*tsk\)\n\{.*?\n\}\n\nstatic inline struct task_group \*css_tg',
    re.S,
)
replacement = '''void sched_move_task(struct task_struct *tsk)
{
\tint queued, running, queue_flags =
\t\tDEQUEUE_SAVE | DEQUEUE_MOVE | DEQUEUE_NOCLOCK;
\tstruct rq_flags rf;
\tstruct rq *rq;

\ttrace_android_vh_sched_move_task(tsk);
\trq = task_rq_lock(tsk, &rf);
\tupdate_rq_clock(rq);

\trunning = task_current(rq, tsk);
\tqueued = task_on_rq_queued(tsk);
\tif (queued)
\t\tdequeue_task(rq, tsk, queue_flags);
\tif (running)
\t\tput_prev_task(rq, tsk);

\tsched_change_group(tsk);

\tif (queued)
\t\tenqueue_task(rq, tsk, queue_flags);
\tif (running) {
\t\tset_next_task(rq, tsk);
\t\tresched_curr(rq);
\t}
\ttask_rq_unlock(rq, tsk, &rf);
}

static inline struct task_group *css_tg'''
s, count = pattern.subn(replacement, s, count=1)
if count != 1:
    raise SystemExit(f'expected one sched_move_task replacement, got {count}')
p.write_text(s)
PY
    rm kernel/sched/core.c.rej
  fi

  if find . -name '*.rej' -print -quit | grep -q .; then
    echo "Unexpected HMBIRD reject files" >&2
    find . -name '*.rej' -print >&2
    exit 1
  fi
  grep -q 'hmbird_free(tsk);' kernel/fork.c
  ! grep -q '^[[:space:]]*sched_ext_free(tsk);$' kernel/fork.c
  [[ $(grep -c '^bad_fork_cancel_cgroup:$' kernel/fork.c) == 1 ]]
}

apply_droidspaces_kabi() {
  local patch_file=$1 rc=0
  echo "Applying $(basename "$patch_file") with OnePlus KABI context handling"
  patch --batch --forward --fuzz=0 -p1 < "$patch_file" || rc=$?
  [[ $rc == 0 || $rc == 1 ]] || return "$rc"

  # OnePlus 6.6.118 consumes ABI slots 1-3 for dma-buf metadata before the
  # unchanged reserve 4-8 block. Keep those vendor additions and place the
  # SYSVIPC fields in slots 6-8 exactly as the pinned Droidspaces patch does.
  if [[ -f include/linux/sched.h.rej ]]; then
    python3 - <<'PY'
from pathlib import Path

p = Path('include/linux/sched.h')
s = p.read_text()
old = '''\tANDROID_KABI_RESERVE(4);
\tANDROID_KABI_RESERVE(5);
\tANDROID_KABI_RESERVE(6);
\tANDROID_KABI_RESERVE(7);
\tANDROID_KABI_RESERVE(8);'''
new = '''\tANDROID_KABI_RESERVE(4);
\tANDROID_KABI_RESERVE(5);

#ifdef CONFIG_SYSVIPC
\tANDROID_KABI_USE(6, struct sysv_sem sysvsem);
\t_ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(7); ANDROID_KABI_RESERVE(8), struct sysv_shm sysvshm);
#else
\tANDROID_KABI_RESERVE(6);
\tANDROID_KABI_RESERVE(7);
\tANDROID_KABI_RESERVE(8);
#endif'''
if s.count(old) != 1:
    raise SystemExit(f'expected one SYSVIPC KABI reserve block, got {s.count(old)}')
p.write_text(s.replace(old, new, 1))
PY
    rm include/linux/sched.h.rej
  fi

  if find . -name '*.rej' -print -quit | grep -q .; then
    echo "Unexpected Droidspaces KABI reject files" >&2
    find . -name '*.rej' -print >&2
    exit 1
  fi
  grep -q 'ANDROID_KABI_USE(6, struct sysv_sem sysvsem);' include/linux/sched.h
  grep -q 'struct sysv_shm sysvshm);' include/linux/sched.h
}

PATCHES_DIR="$DEPS_DIR/kernel_patches"
HMBIRD_DIR="$DEPS_DIR/SCHED_PATCH"
SUSFS_DIR="$DEPS_DIR/susfs4ksu"
KSU_DIR="$SRC_DIR/kernel_platform/KernelSU"
BBG_DIR="$SRC_DIR/kernel_platform/Baseband-guard"
DROIDSPACES_DIR="$DEPS_DIR/Droidspaces-OSS"

[[ $ENABLE_ROOT == 1 ]] && {
  clone_at https://gitlab.com/simonpunk/susfs4ksu.git "$SUSFS_SHA" "$SUSFS_DIR"
  clone_at https://github.com/tiann/KernelSU.git "$KSU_SHA" "$KSU_DIR"
}
[[ $ENABLE_HMBIRD == 1 ]] && {
  clone_at https://github.com/Numbersf/SCHED_PATCH.git "$HMBIRD_SHA" "$HMBIRD_DIR"
}
[[ $ENABLE_BBG == 1 ]] && {
  clone_at https://github.com/vc-teahouse/Baseband-guard.git "$BBG_SHA" "$BBG_DIR"
}
if [[ $ENABLE_ROOT == 1 || $ENABLE_HMBIRD == 1 || $ENABLE_NTSYNC == 1 || $ENABLE_DROIDSPACES == 1 || $ENABLE_UNICODE == 1 ]]; then
  clone_at https://github.com/WildKernels/kernel_patches.git "$PATCHES_SHA" "$PATCHES_DIR"
fi
if [[ $DEVICE_ID == pad2pro-sm8750 && $ENABLE_DROIDSPACES == 1 ]]; then
  [[ -n $DROIDSPACES_SHA ]] || { echo "Droidspaces SHA is required for Pad 2 Pro" >&2; exit 1; }
  clone_at https://github.com/ravindu644/Droidspaces-OSS.git "$DROIDSPACES_SHA" "$DROIDSPACES_DIR"
fi

if [[ $ENABLE_ROOT == 1 ]]; then
  # Official KernelSU dev integration, pinned before any source modification.
  ln -sfn "$(realpath --relative-to="$COMMON_DIR/drivers" "$KSU_DIR/kernel")" "$COMMON_DIR/drivers/kernelsu"
  grep -q 'CONFIG_KSU.*kernelsu' "$COMMON_DIR/drivers/Makefile" || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$COMMON_DIR/drivers/Makefile"
  grep -q 'drivers/kernelsu/Kconfig' "$COMMON_DIR/drivers/Kconfig" || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$COMMON_DIR/drivers/Kconfig"
fi

if [[ $ENABLE_ROOT == 1 ]]; then
  # SuSFS: patch KernelSU first, then the Android 15 / Linux 6.6 common tree.
  cd "$KSU_DIR"
  apply_strict "$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"

  cp "$SUSFS_DIR/kernel_patches/fs/"* "$COMMON_DIR/fs/"
  cp "$SUSFS_DIR/kernel_patches/include/linux/"* "$COMMON_DIR/include/linux/"
  SUSFS_VERSION=$(awk -F'"' '/#define SUSFS_VERSION/ {print $2; exit}' "$COMMON_DIR/include/linux/susfs.h")
  [[ -n $SUSFS_VERSION ]] || { echo "Unable to read SuSFS version" >&2; exit 1; }
  printf 'SUSFS_VERSION=%s\n' "$SUSFS_VERSION" >> "$GITHUB_ENV"
else
  printf 'SUSFS_VERSION=disabled\n' >> "$GITHUB_ENV"
fi

cd "$COMMON_DIR"
if [[ $ENABLE_ROOT == 1 ]] && ! grep -qxF '#include <trace/hooks/fs.h>' fs/namespace.c; then
  sed -i '/#include <trace\/hooks\/blk.h>/a #include <trace/hooks/fs.h>' fs/namespace.c
fi
if [[ $ENABLE_ROOT == 1 && -f include/linux/page_size_compat.h ]] && ! grep -q '__fold_filemap_fixup_entry' include/linux/page_size_compat.h; then
  apply_strict "$PATCHES_DIR/common/backports/fold_fixup_entries.patch"
fi

# The upstream A15-6.6 SuSFS patch expects Google's page-size migration locals.
# Temporarily add only the expected declarations, apply strictly, then remove
# unused compatibility declarations after patching.
susfs_compat=0
if [[ $ENABLE_ROOT == 1 ]] && ! grep -q 'unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;' fs/proc/task_mmu.c; then
  sed -i '/int ret = 0, copied = 0;/a \\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;\n\\tpagemap_entry_t *res = NULL;' fs/proc/task_mmu.c
  susfs_compat=1
fi
if [[ $ENABLE_ROOT == 1 ]]; then
  apply_strict "$SUSFS_DIR/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch"
fi
if [[ $ENABLE_ROOT == 1 && $susfs_compat == 1 ]]; then
  sed -i '/unsigned int nr_subpages = __PAGE_SIZE \/ PAGE_SIZE;/d; /pagemap_entry_t \*res = NULL;/d' fs/proc/task_mmu.c
fi

if [[ $ENABLE_HMBIRD == 1 ]]; then
  # Device-specific Android 16 Fengchi/HMBIRD. Never share patches across SoCs.
  apply_hmbird "$HMBIRD_DIR/$HMBIRD_PATCH"
  apply_strict "$PATCHES_DIR/oneplus/hmbird/overwriter.patch"
  apply_strict "$PATCHES_DIR/oneplus/hmbird/hmbird_config.patch"
  [[ ! -f drivers/of/overwriter/overwrite_configs/convert_configs.sh ]] || chmod +x drivers/of/overwriter/overwrite_configs/convert_configs.sh
fi

if [[ $ENABLE_BBG == 1 ]]; then
  # Baseband Guard stable compatibility line, integrated into the LSM build.
  (cd "$SRC_DIR/kernel_platform" && bash ./Baseband-guard/setup.sh "$BBG_SHA")
fi

if [[ $ENABLE_NTSYNC == 1 ]]; then
  apply_strict "$PATCHES_DIR/common/ntsync/ntsync_compat_android15-6.6.patch"
  apply_strict "$PATCHES_DIR/common/ntsync/ntsync_base.patch"
fi
if [[ $ENABLE_UNICODE == 1 ]]; then
  apply_strict "$PATCHES_DIR/common/unicode_bypass_fix_6.1+.patch"
fi

if [[ $ENABLE_DROIDSPACES == 1 ]]; then
  # DroidSpaces KABI and the OnePlus MIDAS compatibility fix.
  if [[ $DEVICE_ID == pad2pro-sm8750 ]]; then
    apply_droidspaces_kabi "$DROIDSPACES_DIR/Documentation/resources/kernel-patches/GKI/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch"
  else
    apply_droidspaces_kabi "$PATCHES_DIR/common/droidspaces/fix_sysvipc_kabi_6_7_8.patch"
  fi
  apply_strict "$PATCHES_DIR/common/droidspaces/0001-Return-ghost-task-if-task-is-null-and-is-requested-b.patch"
  for symbol in oplus_bsp_midas ghost_task 'init_ghost_task()'; do
    grep -Fq "$symbol" kernel/pid.c || { echo "MIDAS semantic check failed: $symbol missing from kernel/pid.c" >&2; exit 1; }
  done
fi

if [[ $ENABLE_ROOT == 1 ]]; then
cat >> arch/arm64/configs/gki_defconfig <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
# CONFIG_KSU_SUSFS_SUS_OVERLAYFS is not set
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
# CONFIG_KSU_SUSFS_SUS_SU is not set
EOF
fi

if [[ $ENABLE_BBG == 1 ]]; then
  printf 'CONFIG_BBG=y\n' >> arch/arm64/configs/gki_defconfig
fi

cat >> arch/arm64/configs/gki_defconfig <<'EOF'
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_DEVTMPFS=y
EOF

if [[ $ENABLE_DROIDSPACES == 1 ]]; then
cat >> arch/arm64/configs/gki_defconfig <<'EOF'
CONFIG_SYSVIPC=y
CONFIG_PID_NS=y
CONFIG_POSIX_MQUEUE=y
CONFIG_USER_NS=y
EOF
fi

if [[ $ENABLE_NETWORK == 1 ]]; then
cat >> arch/arm64/configs/gki_defconfig <<'EOF'
CONFIG_NET_SCH_FQ=y
CONFIG_NET_SCH_FQ_CODEL=y
CONFIG_NET_SCH_CAKE=y
CONFIG_NET_SCH_PIE=y
CONFIG_NET_SCH_FQ_PIE=y
CONFIG_IP_NF_TARGET_TTL=y
CONFIG_IP6_NF_TARGET_HL=y
CONFIG_IP6_NF_MATCH_HL=y
CONFIG_IP_SET=y
CONFIG_IP_SET_MAX=65534
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_BITMAP_IPMAC=y
CONFIG_IP_SET_BITMAP_PORT=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPMARK=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_IPMAC=y
CONFIG_IP_SET_HASH_MAC=y
CONFIG_IP_SET_HASH_NETPORTNET=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETNET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
EOF
fi

cat >> arch/arm64/configs/gki_defconfig <<'EOF'
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y
# CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3 is not set
CONFIG_LTO_CLANG=y
CONFIG_LTO_CLANG_THIN=y
# CONFIG_LTO_CLANG_NONE is not set
# CONFIG_LTO_CLANG_FULL is not set
# CONFIG_TCP_CONG_BBR is not set
# CONFIG_WIREGUARD is not set
# CONFIG_ZRAM_WRITEBACK is not set
# CONFIG_SCHED_BORE is not set
# CONFIG_IOSCHED_ADIOS is not set
# CONFIG_LRNG is not set
EOF

if [[ $ENABLE_NTSYNC == 1 ]]; then
  printf 'CONFIG_NTSYNC=y\n' >> arch/arm64/configs/gki_defconfig
fi

if find "$COMMON_DIR" -name '*.rej' -print -quit | grep -q .; then
  echo "Patch reject files exist" >&2
  find "$COMMON_DIR" -name '*.rej' -print >&2
  exit 1
fi

if [[ $ENABLE_ROOT == 1 ]]; then
  KSU_VERSION=$((30000 + $(git -C "$KSU_DIR" rev-list --count HEAD)))
  printf 'KSU_VERSION=%s\n' "$KSU_VERSION" >> "$GITHUB_ENV"
else
  printf 'KSU_VERSION=disabled\n' >> "$GITHUB_ENV"
fi

git -C "$COMMON_DIR" status --short
