# timeshift-btrbk-bridge

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

A bridge tool that combines [Timeshift](https://github.com/teejee2008/timeshift) (for short-term snapshots) and [Btrbk](https://github.com/digint/btrbk) (for long-term backups) into an integrated snapshot management workflow.

## Overview

`timeshift-btrbk-bridge` automates the creation of read-only Btrfs snapshots from Timeshift snapshots and prepares them for Btrbk backup management. This allows you to:

- **Short-term protection**: Use Timeshift for frequent, system-level snapshots
- **Long-term backups**: Leverage Btrbk for efficient incremental backups to external storage
- **Automated workflow**: Run as a systemd service or manual command-line tool
- **No manual intervention**: Automatically clones and renames Timeshift snapshots for Btrbk compatibility

## Features

- ✅ Converts Timeshift snapshots to read-only Btrbk-compatible snapshots
- ✅ Automatically mounts/unmounts required Btrfs volumes
- ✅ Timeshift lock management to prevent concurrent snapshot operations
- ✅ Desktop notifications for success/failure events
- ✅ Dry-run mode for testing
- ✅ Throttling support for gradual catch-up processing
- ✅ Configurable log levels and btrbk options
- ✅ Systemd integration with automatic restart on failure
- ✅ Root-only execution (safety check)

## Requirements

- **Linux system** with Btrfs filesystem
- **Btrfs utilities**: `btrfs` command-line tools
- **Timeshift**: Installed and configured for snapshot creation
- **Btrbk**: Installed and configured for backup management
- **systemd**: For service and timer management (optional but recommended)
- **notify-send**: For desktop notifications (optional)
- **Root privileges**: Required to execute the script

### Supported Btrfs Configuration

The script assumes:
- Root filesystem (BTRFS_ROOT) mounted at `/mnt/btrfs_root` with label `BTRFS_ROOT`
- Timeshift snapshots in `@/.snapshots/` or similar Btrfs subvolumes
- Target subvolumes: `@` (root) and `@home` (home directory)
- Btrbk archive on external storage with label `BTRBK_ARCHIVE`

## Installation

1. **Clone the repository**:
   ```bash
   git clone https://github.com/xaos522/timeshift-btrbk-bridge.git
   cd timeshift-btrbk-bridge
   ```

2. **Install the main script**:
   ```bash
   sudo cp timeshift-btrbk-bridge.sh /usr/local/bin/
   sudo chmod +x /usr/local/bin/timeshift-btrbk-bridge.sh
   ```

3. **Install the systemd service** (optional):
   ```bash
   sudo cp timeshift-btrbk-bridge.service /etc/systemd/system/
   sudo systemctl daemon-reload
   ```

4. **Configure your system** (see Configuration section below)

## Configuration

### Filesystem Labels

Ensure your Btrfs filesystems are labeled in `/etc/fstab`:

```bash
# Root Btrfs volume
LABEL=BTRFS_ROOT  /mnt/btrfs_root  btrfs  defaults,subvol=@  0  0

# Btrbk archive (external storage)
LABEL=BTRBK_ARCHIVE  /mnt/btrbk_archive  btrfs  defaults  0  0
```

To set labels:
```bash
sudo btrfs filesystem label /dev/sdX1 BTRFS_ROOT
sudo btrfs filesystem label /dev/sdY1 BTRBK_ARCHIVE
```

### Script Configuration

Edit the top of `timeshift-btrbk-bridge.sh` to customize:

```bash
SYSTEM_DEVICE_LABEL="BTRFS_ROOT"           # Label of root Btrfs filesystem
BTRFS_ROOT_MOUNTPOINT="/mnt/btrfs_root"    # Mount point for root volume
TIMESHIFT_LOCK="/var/lock/timeshift/lock"  # Timeshift lock file
TIMESHIFT_SNAPSHOTS_DIR="..."              # Path to Timeshift snapshots
BTRBK_SINK="..."                           # Path to btrbk snapshots
BTRBK_ARCHIVE_LABEL="BTRBK_ARCHIVE"        # Label of backup archive
TARGET_SUBVOLUMES=("@" "@home")            # Btrfs subvolumes to process
```

### Btrbk Configuration

Create/update your Btrbk configuration file (e.g., `/etc/btrbk/btrbk.conf`):

```ini
# Volume and subvolume to be backed up
volume /mnt/btrfs_root
  subvolume @
  subvolume @home
  
  target send-receive /mnt/btrbk_archive

# Retention policy
snapshot_preserve_min all
snapshot_preserve_days 0
target_preserve_min all
target_preserve_days 0
```

## Usage

### Command Line

```bash
timeshift-btrbk-bridge [OPTIONS] COMMAND
```

#### Commands

| Command | Description |
|---------|-------------|
| `clone` | Only clone Timeshift snapshots to btrbk sink |
| `btrbk` | Only run btrbk send/receive |
| `run` | Run both clone and btrbk (full cycle) |
| `version` | Show version information |
| `help` | Display help message |

#### Options

```
-c file          Specify alternate btrbk config file
-l loglevel      Set btrbk log level (error|warn|info|debug|trace)
-n               Dry run (no changes made)
-p ON|OFF        Preserve snapshots/backups (override retention policy)
-q               Quiet mode (suppress warnings)
-t number        Throttle: process max N timeshift snapshots per run
-h               Show help message
```

### Examples

**Run full cycle with info logging**:
```bash
sudo timeshift-btrbk-bridge -l info run
```

**Dry run to preview changes**:
```bash
sudo timeshift-btrbk-bridge -n run
```

**Process only 5 snapshots (catch-up mode)**:
```bash
sudo timeshift-btrbk-bridge -t 5 run
```

**Use custom btrbk config**:
```bash
sudo timeshift-btrbk-bridge -c /path/to/custom/btrbk.conf run
```

**Clone only (skip btrbk)**:
```bash
sudo timeshift-btrbk-bridge clone
```

### Systemd Integration

#### Manual Execution

```bash
sudo systemctl start timeshift-btrbk-bridge.service
```

#### View Logs

```bash
sudo journalctl -u timeshift-btrbk-bridge.service -f
```

#### With Systemd Timer

Create `/etc/systemd/system/timeshift-btrbk-bridge.timer`:

```ini
[Unit]
Description=Run timeshift-btrbk-bridge daily
Requires=timeshift-btrbk-bridge.service

[Timer]
OnBootSec=30min
OnUnitActiveSec=24h
AccuracySec=1m

[Install]
WantedBy=timers.target
```

Enable the timer:
```bash
sudo systemctl enable --now timeshift-btrbk-bridge.timer
```

## How It Works

### Snapshot Processing Pipeline

1. **Lock Acquisition**: Acquires Timeshift lock to prevent concurrent snapshot operations
2. **Snapshot Discovery**: Lists all Timeshift snapshots
3. **Snapshot Cloning**: 
   - Converts Timeshift timestamp format (YYYY-MM-DD_HH-MM-SS) to Btrbk format (YYYYMMDDTHHMM)
   - Creates read-only Btrfs snapshots in the btrbk sink
   - Skips existing snapshots (idempotent)
4. **Lock Release**: Relinquishes the Timeshift lock
5. **Archive Mount**: Automatically mounts external Btrbk archive if available
6. **Btrbk Execution**: Runs btrbk to send/receive snapshots to archive
7. **Notifications**: Sends desktop notifications on success/failure

### File Structure

```
Timeshift Snapshots:
/mnt/btrfs_root/timeshift-btrfs/snapshots/
├── 2024-01-15_10-30-45/
│   ├── @/
│   └── @home/
└── 2024-01-16_14-22-10/
    ├── @/
    └── @home/

Btrbk Sink:
/mnt/btrfs_root/btrbk/snapshots/
├── @.20240115T1030
├── @home.20240115T1030
├── @.20240116T1422
└── @home.20240116T1422

Btrbk Archive:
/mnt/btrbk_archive/
└── snapshots/
    ├── @.20240115T1030
    ├── @home.20240115T1030
    ├── @.20240116T1422
    └── @home.20240116T1422
```

## Troubleshooting

### Timeshift Lock Issue

If the script crashes, the Timeshift lock may persist:
```bash
sudo rm /var/lock/timeshift/lock
```

### Mount Failures

Verify Btrfs volumes are properly configured:
```bash
# Check filesystem labels
sudo btrfs filesystem show

# Check fstab entries
grep LABEL= /etc/fstab

# Manual mount test
sudo mount LABEL=BTRFS_ROOT /mnt/btrfs_root
```

### Snapshot Not Found

Verify Timeshift paths and snapshot locations:
```bash
ls -la /mnt/btrfs_root/timeshift-btrfs/snapshots/
```

### Btrbk Errors

Check btrbk configuration and logs:
```bash
sudo btrbk -c /etc/btrbk/btrbk.conf dryrun
sudo journalctl -u timeshift-btrbk-bridge.service -n 100
```

## Performance Considerations

- **Throttling**: Use `-t` option to limit snapshots per run (useful for initial catch-up)
- **I/O Priority**: The service uses `ionice -c 3` (idle I/O priority)
- **Incremental Backups**: Btrbk only transfers changed blocks, minimizing bandwidth
- **Schedule**: Run during off-peak hours to minimize system impact

## Desktop Notifications

The script sends notifications via `notify-send`:
- ✅ Success: "timeshift-btrbk-bridge completed successfully"
- ❌ Failure: Details of the phase that failed

Note: Requires an active GUI session and `notify-send` command.

## Limitations

- Requires Btrfs filesystem (cannot be used with LVM/ext4/other filesystems)
- Assumes specific Btrfs subvolume structure (`@`, `@home`, etc.)
- Requires root privileges to execute
- Desktop notifications require active GUI session

## Contributing

Contributions are welcome! Please:
1. Test thoroughly before submitting PRs
2. Follow existing code style
3. Update documentation as needed
4. Test on multiple systems if possible

## License

This project is licensed under the GNU General Public License v3.0 - see LICENSE file for details.

**DISCLAIMER**: This tool modifies your filesystem snapshots. Use with caution and maintain regular backups. The author provides absolutely no warranty.

## See Also

- [Timeshift](https://github.com/teejee2008/timeshift) - System snapshot tool
- [Btrbk](https://github.com/digint/btrbk) - Btrfs incremental backup tool
- [Btrfs Wiki](https://btrfs.wiki.kernel.org/) - Btrfs documentation
- [systemd.service](https://www.freedesktop.org/software/systemd/man/systemd.service.html) - Systemd service documentation

## Support

For issues, feature requests, or questions:
1. Check existing issues in the repository
2. Review the Troubleshooting section above
3. Open a new GitHub issue with detailed information
