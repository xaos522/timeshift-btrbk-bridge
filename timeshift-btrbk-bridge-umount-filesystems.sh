#!/usr/bin/env bash
# Unmount btrfs filesystems used by timeshift-btrbk-bridge.sh
set -eu

# Check for root permissions
check_for_root() {
  if [[ $EUID -ne 0 ]]; then echo "This script must be run as root."; exit 1; fi
}
check_for_root
umount /mnt/btrfs_root
umount /mnt/btrbk_archive
