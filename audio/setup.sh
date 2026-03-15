#!/usr/bin/env bash
# install-sof-mtl-firmware.sh
# Installs Intel Meteor Lake SOF IPC4 firmware from upstream sof-bin.
# Required on AlmaLinux 10.1 where alsa-sof-firmware does not include MTL.
#
# Usage: sudo ./install-sof-mtl-firmware.sh [sof-bin-version]
#   e.g. sudo ./install-sof-mtl-firmware.sh v2025.12.2  (default)

set -euo pipefail

SOF_VERSION="${1:-v2025.12.2}"
SOF_TAG="${SOF_VERSION#v}"  # strip leading 'v' for tarball name
TARBALL="sof-bin-${SOF_TAG}.tar.gz"
DOWNLOAD_URL="https://github.com/thesofproject/sof-bin/releases/download/${SOF_VERSION}/${TARBALL}"
WORKDIR="$(mktemp -d)"

FW_DEST="/lib/firmware/intel/sof-ipc4"
TPLG_DEST="/lib/firmware/intel/sof-ipc4-tplg"

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { echo "[sof-mtl] $*"; }
die()  { echo "[sof-mtl] ERROR: $*" >&2; exit 1; }

# ── checks ───────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root (sudo $0)"

for cmd in curl tar modprobe; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

# ── download ─────────────────────────────────────────────────────────────────
log "Downloading sof-bin ${SOF_VERSION} ..."
curl -fL --progress-bar -o "${WORKDIR}/${TARBALL}" "${DOWNLOAD_URL}" \
    || die "Download failed: ${DOWNLOAD_URL}"

log "Extracting ..."
tar -xzf "${WORKDIR}/${TARBALL}" -C "${WORKDIR}"
SOF_DIR="${WORKDIR}/sof-bin-${SOF_TAG}"

[[ -f "${SOF_DIR}/sof-ipc4/mtl/intel-signed/sof-mtl.ri" ]] \
    || die "sof-mtl.ri not found in tarball — unexpected layout"

# ── install firmware ─────────────────────────────────────────────────────────
log "Installing firmware to ${FW_DEST} ..."
mkdir -p "${FW_DEST}"
install -m 0644 "${SOF_DIR}/sof-ipc4/mtl/intel-signed/sof-mtl.ri" "${FW_DEST}/"

log "Installing topology files to ${TPLG_DEST} ..."
mkdir -p "${TPLG_DEST}"
install -m 0644 "${SOF_DIR}"/sof-ipc4-tplg/sof-mtl-*.tplg "${TPLG_DEST}/"

TPLG_COUNT=$(ls "${TPLG_DEST}"/sof-mtl-*.tplg 2>/dev/null | wc -l)
log "Installed sof-mtl.ri + ${TPLG_COUNT} topology files."

# ── reload driver ─────────────────────────────────────────────────────────────
log "Reloading SOF driver ..."
modprobe -r snd_sof_pci_intel_mtl snd_sof_intel_hda_common snd_sof 2>/dev/null || true
modprobe snd_sof_pci_intel_mtl

# Give it a moment to probe
sleep 2

# ── verify ────────────────────────────────────────────────────────────────────
log "Driver probe result:"
dmesg | grep -i sof | tail -10

if aplay -l 2>/dev/null | grep -q card; then
    log "SUCCESS — ALSA audio devices found:"
    aplay -l
else
    log "WARNING — no ALSA devices visible yet. Check: dmesg | grep -i sof"
fi

# ── cleanup ───────────────────────────────────────────────────────────────────
rm -rf "${WORKDIR}"
log "Done."
