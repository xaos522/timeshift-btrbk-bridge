#!/usr/bin/env bash

# Send a desktop notification to connect the external backup USB drive to the system.
# Repeat sending the notification every 20 seconds until the device is connected and
# detected
# When the block device shows up, mount it and exit.

# NOTE:
# The script will enter an infinite loop when the device is not connected or
# when the device is connected, but does not show up on the expected DISK_PATH.
# NOTE: timeout issue
# TimeoutStartSec was set to 60s. However, for TYPE=Oneshot services,
# the service is never considered fully "started" until the main
# ExecStart script exits with a success code.
# Therefore, TimeoutStartSec is now set to infinity, to allow scripts to finish
# without timeouts, AND
# We MUST set our own timeout to exit with error code 1 within a reasonable time interval

set -euo pipefail

typeset -r DRIVE_NAME="Seagate BUP BK (0304)"            # Name of the drive used in inotify-send
typeset -r DISK_PATH="/dev/disk/by-label/BTRBK_ARCHIVE"  # Path to the btrbk archive partition
typeset -r MOUNT_PATH="/mnt/btrbk_archive"               # Mountpoint for the btrbk archive partition
typeset -i -r TIMEOUT=300                                # Timeout seconds to wait for the drive

typeset -i START_SECONDS
START_SECONDS=$(date +%s)

# Loop until the external USB is detected by the kernel or timeout is reached
typeset -i i
i=1 # Make sure i is set (and option -u does not kill the script)
while [[ ! -b "$DISK_PATH" ]]; do
  /usr/local/bin/send-desktop-notification.sh \
    -i drive-harddisk \
    -U normal \
    "Backup Drive Required" \
    "Please connect '$DRIVE_NAME' to resume the Timeshift-btrbk bridge."

  # Check for the disk every second.
  # Send the notification every 30s.
  # Abort the script when timeout is exceeded
  for i in {1..60}; do
    if [ -b "$DISK_PATH" ]; then
      break 2
    elif (( $(date +%s) - START_SECONDS >= TIMEOUT )); then
      # Timeout exceeded
      echo "Timeout waiting for $DRIVE_NAME exceeded. Abort."
      exit 1
    else
      sleep 1
    fi
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
