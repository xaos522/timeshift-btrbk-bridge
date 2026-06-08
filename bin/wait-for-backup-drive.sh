#!/usr/bin/env bash
# set -euo pipefail

DRIVE_NAME="Seagate BUP BK (0304)"
DISK_PATH="/dev/disk/by-label/BTRBK_ARCHIVE"
MOUNT_PATH="/mnt/btrbk_archive"

# Loop until the physical hardware label is detected by the kernel
while [ ! -b "$DISK_PATH" ]; do
  /usr/local/bin/send-desktop-notification.sh \
    -i drive-harddisk \
    -U normal \
    "Backup Drive Required" \
    "Please connect '$DRIVE_NAME' to resume the Timeshift-btrbk bridge."

  # Check for the disk every second for 20 seconds
  for i in {1..20}; do
    if [ -b "$DISK_PATH" ]; then
      break 2
    fi
    sleep 1
  done
done

# Hardware found! Now ensure it is mounted before passing control to the backup engine
if ! mountpoint -q "$MOUNT_PATH"; then
  echo "Drive detected. Mounting to $MOUNT_PATH..."
  mkdir -p "$MOUNT_PATH"
  mount "$DISK_PATH" "$MOUNT_PATH"
fi

exit 0
