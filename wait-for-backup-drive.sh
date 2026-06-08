#!/usr/bin/env bash
set -euo pipefail

SYSTEMD_DEV_UNIT="dev-disk-by\x2dlabel-BTRBK_ARCHIVE.device"
DRIVE_NAME="Seagate BUP BK (0304)"

# Check if the device is already active in systemd
if ! systemctl is-active --quiet "$SYSTEMD_DEV_UNIT"; then
    # Drive is missing, send the alert
    /usr/local/bin/send-desktop-notification.sh \
        -i drive-harddisk \
        -U normal \
        "Backup Drive Required" \
        "Please connect '$DRIVE_NAME' to resume the Timeshift-btrbk bridge."

    # Block natively inside systemd until the drive is connected.
    # --timeout=0 ensures it will wait indefinitely without failing.
    systemctl start --timeout=300 "$SYSTEMD_DEV_UNIT"
fi
