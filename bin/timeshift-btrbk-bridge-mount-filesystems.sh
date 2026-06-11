#!/usr/bin/env bash
# Mount btrfs filesystems used by timeshift-btrbk-bridge.sh
# Check for root permissions
check_for_root() {
  if [[ $EUID -ne 0 ]]; then echo "This script must be run as root."; exit 1; fi
}
set -eu
check_for_root
# Presumes that both filesystems are configured in /etc/fstab
set -euo  pipefail
# To get access to timeshift snapshots and the 'btrbk sink'
mount -L BTRFS_ROOT
# To get access to btrbk archived snapshots
mount -L BTRBK_ARCHIVE
