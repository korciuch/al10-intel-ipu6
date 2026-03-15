# Intel MTL SOF Audio on AlmaLinux 10.1

> Fix for audio not working on Intel Meteor Lake laptops running AlmaLinux 10.1 / RHEL 10 / kernel 6.12.

**Device:** `0000:00:1f.3` — Intel Meteor Lake-P HD Audio Controller
**Status:** Working as of 2026-03-15

## Quick Start

```bash
sudo bash audio/setup.sh
```

## What Breaks and Why

`alsa-sof-firmware` from the AlmaLinux 10 repos only ships firmware up to
Raptor Lake (RPL) — no MTL firmware is included. Upstream `sof-bin` has it
but it is not yet packaged for RHEL/AlmaLinux 10.

MTL also uses the IPC4 firmware interface, so the firmware path is
`intel/sof-ipc4/` (not the older `intel/sof/` used for IPC3 platforms).

dmesg symptom:
```
sof-audio-pci-intel-mtl 0000:00:1f.3: Check if you have 'sof-firmware' package installed.
sof-audio-pci-intel-mtl 0000:00:1f.3: error: sof_probe_work failed err: -2
```

Error `-2` = `ENOENT` — firmware binary simply not present.

## What setup.sh Does

1. Downloads `sof-bin-v2025.12.2.tar.gz` from the SOF project releases
2. Installs `sof-mtl.ri` → `/lib/firmware/intel/sof-ipc4/`
3. Installs all `sof-mtl-*.tplg` topology files → `/lib/firmware/intel/sof-ipc4-tplg/`
4. Reloads `snd_sof_pci_intel_mtl`
5. Verifies ALSA devices appear

Both the firmware (`.ri`) **and** topology (`.tplg`) files are required —
the driver fails silently if topology is missing.

## Notes

- `alsa-sof-firmware` from dnf is still worth installing for non-MTL
  platform compatibility — `setup.sh` installs it automatically
- The topology file is selected automatically by the driver based on
  detected codec (SoundWire/I2C device IDs)
- To check which topology was loaded: `sudo dmesg | grep -i tplg`
- Firmware files in `/lib/firmware/` persist across reboots; no extra
  configuration needed

## Compatibility

| Item | Version |
|------|---------|
| Hardware | Dell XPS 16 9640 |
| OS | AlmaLinux 10.1 (Heliotrope Lion) |
| Kernel | 6.12.0-124.43.1.el10_1.x86_64 |
| sof-bin | v2025.12.2 |
| alsa-sof-firmware | from AlmaLinux 10 repos |
