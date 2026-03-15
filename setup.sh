#!/usr/bin/env bash
# setup.sh — Install Intel IPU6 camera support on AlmaLinux 10.1 / RHEL 10 / kernel 6.12
# Usage: sudo bash setup.sh [OPTIONS]
#
# Options:
#   --dry-run          Print all steps without executing anything
#   --drivers-dir DIR  Use existing ipu6-drivers clone at DIR (skip git clone)
#   --bins-dir DIR     Use existing ipu6-camera-bins clone at DIR (skip git clone)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
DRIVERS_DIR=""
BINS_DIR=""
WORK_DIR="/tmp/ipu6-setup-$$"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     DRY_RUN=1; shift ;;
        --drivers-dir) DRIVERS_DIR="$2"; shift 2 ;;
        --bins-dir)    BINS_DIR="$2"; shift 2 ;;
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

# ── Setup work directory ──────────────────────────────────────────────────────
if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p "$WORK_DIR"
    trap 'rm -rf "$WORK_DIR"' EXIT
fi

# ── Step 1: Clone / locate ipu6-drivers ──────────────────────────────────────
info "Step 1: Locate ipu6-drivers"
if [[ -n "$DRIVERS_DIR" ]]; then
    [[ -d "$DRIVERS_DIR" ]] || die "--drivers-dir '$DRIVERS_DIR' does not exist"
    info "  Using existing clone: $DRIVERS_DIR"
    DRIVERS_CLONE="$DRIVERS_DIR"
else
    DRIVERS_CLONE="${WORK_DIR}/ipu6-drivers"
    info "  Cloning intel/ipu6-drivers..."
    run git clone https://github.com/intel/ipu6-drivers.git "$DRIVERS_CLONE"
fi

# ── Step 2: Apply patches ─────────────────────────────────────────────────────
info "Step 2: Apply AlmaLinux compatibility patches"
PATCHES_DIR="$SCRIPT_DIR/patches"
[[ -d "$PATCHES_DIR" ]] || die "patches/ directory not found at $PATCHES_DIR"

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
if [[ -n "$BINS_DIR" ]]; then
    [[ -d "$BINS_DIR" ]] || die "--bins-dir '$BINS_DIR' does not exist"
    BINS_CLONE="$BINS_DIR"
    info "  Using existing clone: $BINS_CLONE"
else
    BINS_CLONE="${WORK_DIR}/ipu6-camera-bins"
    info "  Cloning intel/ipu6-camera-bins..."
    run git clone https://github.com/intel/ipu6-camera-bins.git "$BINS_CLONE"
fi

FW_SRC="$BINS_CLONE/firmware/ipu6epmtl_fw.bin"
FW_DEST="/lib/firmware/intel/ipu/ipu6epmtl_fw.bin"
if [[ $DRY_RUN -eq 0 && ! -f "$FW_SRC" ]]; then
    die "Firmware binary not found: $FW_SRC"
fi
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
