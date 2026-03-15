# Contributing

## Reporting a different sensor

If you have an Intel Meteor Lake laptop with a different camera sensor (e.g. OV8856,
HM2170, OV2740), open an issue using the
[camera-not-working template](.github/ISSUE_TEMPLATE/camera-not-working.yml).

Include the output of:

```bash
sudo dmesg | grep -E "(ivsc|ipu6|OVTI|INT3472)"
```

and your ACPI HID (visible in `dmesg | grep ivsc` as the firmware filenames it
requests contain the sensor identifier).

The patches in this repo are sensor-agnostic — the VSC firmware filenames are the
only sensor-specific part.  If the 3 patches get you past the build but the camera
still does not appear, the missing firmware file is almost certainly the cause.

## Pull requests

Patch updates, corrections, and tested reports for other RHEL-based distros
(Rocky Linux, CentOS Stream) are welcome.
