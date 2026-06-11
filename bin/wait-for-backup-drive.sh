#!/usr/bin/env bash

# Send a desktop notification to connect the external backup USB drive to the system.
# Repeat sending the notification every 20 seconds until the device is connected and
# detected
# When the block device shows up, mount it and exit.

# NOTE:
# The script will enter an infinite loop when the device is not connected or
# the device is connected, but does not show up on the expected DISK_PATH.
# When run from the command line it needs to be stopped.
# When run from a systemd service, make sure to set an appropriate timeout (TimeoutStartSec=).

set -euo pipefail

DRIVE_NAME="Seagate BUP BK (0304)"              # Name of the drive used in inotify-send
DISK_PATH="/dev/disk/by-label/BTRBK_ARCHIVE"    # Path to the btrbk archive partition
MOUNT_PATH="/mnt/btrbk_archive"                 # Mountpoint for the btrbk archive partition

# Loop until the external USB is detected by the kernel
while [ ! -b "$DISK_PATH" ]; do
  /usr/local/bin/send-desktop-notification.sh \
    -i drive-harddisk \
    -U normal \
    "Backup Drive Required" \
    "Please connect '$DRIVE_NAME' to resume the Timeshift-btrbk bridge."

  # Check for the disk every second for 20 seconds
  typeset -i i
  i=1                           # Make sure i is set (and option -u does not kill the script)
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
  # NOTE: Added mount options, --source and --target
  mount --types btrfs --options defaults,rw,noatime,compress=zstd:6,discard=async,space_cache=v2,commit=120,autodefrag,subvolid=5 --source "$DISK_PATH" --target "$MOUNT_PATH"
fi

exit 0
