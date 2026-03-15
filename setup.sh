#!/usr/bin/env bash
# setup.sh — Install Intel IPU6 camera support on AlmaLinux 10.1 / RHEL 10 / kernel 6.12
# Usage: sudo bash setup.sh [OPTIONS]
#
# This script uses the submodules bundled in this repo:
#   ipu6-drivers/      — intel/ipu6-drivers @ da921f7 (2026-03-15)
#   ipu6-camera-bins/  — intel/ipu6-camera-bins @ 30e8766 (2026-03-15)
#
# Options:
#   --dry-run  Print all steps without executing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

info()  { echo "==> $*"; }
warn()  { echo "WARN: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
    die "This script must be run as root (sudo bash setup.sh)"
fi

# ── Kernel version check ──────────────────────────────────────────────────────
KVER="$(uname -r)"
info "Running on kernel $KVER"
if [[ "$KVER" != 6.12.* ]]; then
    warn "This script was tested on kernel 6.12.x; you are running $KVER"
    warn "Proceeding anyway — review patches manually if the build fails."
fi

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in git dkms dracut curl; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

# ── Submodule check ───────────────────────────────────────────────────────────
DRIVERS_DIR="$SCRIPT_DIR/ipu6-drivers"
BINS_DIR="$SCRIPT_DIR/ipu6-camera-bins"

if [[ ! -f "$DRIVERS_DIR/dkms.conf" || ! -f "$BINS_DIR/firmware/ipu6epmtl_fw.bin" ]]; then
    die "Submodules are not initialized. Run:
    git submodule update --init --recursive"
fi

# ── Step 1: Prepare a working copy of ipu6-drivers ───────────────────────────
# We copy to a temp dir so we can apply patches without dirtying the submodule.
info "Step 1: Prepare ipu6-drivers working copy"
WORK_DIR="/tmp/ipu6-setup-$$"
if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p "$WORK_DIR"
    trap 'rm -rf "$WORK_DIR"' EXIT
fi
DRIVERS_CLONE="$WORK_DIR/ipu6-drivers"
run cp -r "$DRIVERS_DIR" "$DRIVERS_CLONE"

# ── Step 2: Apply patches ─────────────────────────────────────────────────────
info "Step 2: Apply AlmaLinux compatibility patches"
PATCHES_DIR="$SCRIPT_DIR/patches"

for patch in \
    "0001-dkms-conf-fix-module-array-gaps.patch" \
    "0002-makefile-guard-ov05c10-v4l2-cci.patch" \
    "0003-psys-module-import-ns-rhel-compat.patch"
do
    pfile="$PATCHES_DIR/$patch"
    [[ -f "$pfile" ]] || die "Patch not found: $pfile"
    info "  Applying $patch"
    run git -C "$DRIVERS_CLONE" apply "$pfile"
done

# ── Step 3: Install via DKMS ──────────────────────────────────────────────────
info "Step 3: Install ipu6-drivers via DKMS"
DKMS_SRC="/usr/src/ipu6-drivers-1.0"
run mkdir -p "$DKMS_SRC"
run cp -r "$DRIVERS_CLONE/." "$DKMS_SRC/"
run dkms add ipu6-drivers/1.0
run dkms build ipu6-drivers/1.0
run dkms install ipu6-drivers/1.0

# ── Step 4: Install IPU6 EP MTL firmware ──────────────────────────────────────
info "Step 4: Install IPU6 EP MTL firmware"
FW_SRC="$BINS_DIR/firmware/ipu6epmtl_fw.bin"
FW_DEST="/lib/firmware/intel/ipu/ipu6epmtl_fw.bin"
run mkdir -p /lib/firmware/intel/ipu
run cp "$FW_SRC" "$FW_DEST"
info "  Installed: $FW_DEST"

# ── Step 5: Install missing VSC firmware ──────────────────────────────────────
info "Step 5: Install VSC firmware (missing from AlmaLinux linux-firmware)"
run mkdir -p /lib/firmware/intel/vsc

VSC_BASE="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/vsc"

info "  Downloading ivsc_fw.bin (Stage 1 — main VSC firmware)..."
run curl -fsSL "${VSC_BASE}/ivsc_fw.bin" \
    -o /lib/firmware/intel/vsc/ivsc_fw.bin

info "  Downloading ivsc_skucfg_ovti02c1_0_1.bin (Stage 3 — SKU config)..."
run curl -fsSL "${VSC_BASE}/ivsc_skucfg_ovti02c1_0_1.bin" \
    -o /lib/firmware/intel/vsc/ivsc_skucfg_ovti02c1_0_1.bin

info "  Note: ivsc_pkg_ovti02c1_0.bin (Stage 2) should already be present"
info "  in the AlmaLinux linux-firmware package."
if [[ $DRY_RUN -eq 0 && ! -f /lib/firmware/intel/vsc/ivsc_pkg_ovti02c1_0.bin ]]; then
    warn "Stage 2 firmware not found: /lib/firmware/intel/vsc/ivsc_pkg_ovti02c1_0.bin"
    warn "Install the linux-firmware package or download it manually."
fi

# ── Step 6: Rebuild initramfs ──────────────────────────────────────────────────
info "Step 6: Rebuild initramfs"
run dracut --force
info "  initramfs rebuilt."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo " Setup complete!  Verify after reboot with:"
echo ""
echo "   sudo dmesg | grep -E '(intel_vsc|ivsc|ipu6|ipu_bridge|OVTI|ov02c10)' \\"
echo "     | grep -v 'bridge window'"
echo ""
echo "   ls /dev/video* /dev/media*"
echo ""
echo " A working system shows /dev/media0 and ~48 /dev/video* nodes."
echo "========================================================"
echo ""

if [[ $DRY_RUN -eq 0 ]]; then
    read -r -p "Reboot now? [y/N] " _ans
    if [[ "${_ans,,}" == "y" ]]; then
        reboot
    else
        echo "Remember to reboot before testing the camera."
    fi
fi
