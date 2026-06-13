#!/usr/bin/env bash

# Configuration
typeset -r VERSION="v0.1.1"
typeset -r TAG="timeshift-btrbk-bridge"               # Script TAG
typeset -r ROOT_FILESYSTEM_LABEL="BTRFS_ROOT"         # Label of root Btrfs filesystem
typeset -r BTRFS_ROOT_MOUNTPOINT="/mnt/btrfs_root"    # Mount point for root volume
typeset -r TIMESHIFT_LOCK="/var/lock/timeshift/lock"  # Timeshift lock file
# Ensure the lock directory exists before any other operations
mkdir -p "$(dirname $TIMESHIFT_LOCK)"
# ... rest of your script ...
# Path to timeshift snapshots
typeset -r TIMESHIFT_SNAPSHOTS_DIR="${BTRFS_ROOT_MOUNTPOINT}/timeshift-btrfs/snapshots"
# Path to btrbk snapshots (= btrbk sink)
typeset -r BTRBK_SINK="${BTRFS_ROOT_MOUNTPOINT}/btrbk/snapshots"
typeset -r ARCHIVE_FILESYSTEM_LABEL="BTRBK_ARCHIVE"   # Label of btrbk archive filesystem

# Mount point for USB backup drive containing btrbk archive
typeset -r BTRBK_ARCHIVE_MOUNTPOINT="/mnt/btrbk_archive"
BTRBK_CONFIG_FILE=""                                  # Path to the btrbk config file
typeset -ar TARGET_SUBVOLUMES=("@" "@home")           # Btrfs subvolumes to process
typeset -a BTRBK_OPTIONS=()                           # Indexed array of btrbk options
# Path to logger module
typeset -r LOGGING_MODULE_PATH="/usr/local/lib/bash-logger/logging.sh"
# Logging config file
typeset -r LOGGING_CONFIG="/usr/local/etc/${TAG}/logging.conf"
# Timeshift-btrbk-bridge log file directory - set in LOGGING_CONFIG
# typeset -r LOGGING_DIR="/var/log/${TAG}"
# Timeshift-btrbk-bridge log file
# typeset -r LOGGING_FILE="$LOGGING_DIR/${TAG}.log"

# Check for root permissions
check_for_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

# Helper function to handle running a command vs printing
run() {
  if $DRY_RUN; then
    log_notice "[DRY-RUN]: Executing: $*"
  else
    "$@"
  fi
}

# Function to log critical message and abort the script
fail (){
  log_critical "$*"
  log_critical "Abort."
  exit 1
}

# Function to show extended usage information
# Runs when timeshift-btrbk-bridge is called with command 'help'
show_usage() {
	cat <<HERE;
"$TAG version $VERSION"

Usage: "$TAG" [-n] [-c cfgfile] [-l loglevel] [-p ON|OFF] [-T throttle] command

$TAG creates read-only clones from timeshift read-write
snapshots and renames them for btrbk compatibility.

$TAG comes with ABSOLUTELY NO WARRANTY.  This is free software,
and you are welcome to redistribute it under certain conditions.
See the GNU General Public License for details.

Options:
    -c file          - Specify alternate btrbk config file (-c /path/to/file).
    -l loglevel      - Specify loglevel **for btrbk**.
                       Must be one of error|warn|info|debug|trace.
    -n               - Dry run. Do not modify anything. Just show what would be
                       done when running a command.
    -p preserve      - Specify preserve option for btrbk.
                       Must be one of ON|OFF.
                       If ON, -p is passed as an option to btrbk, meaning
                       btrbk will preserve all snapshots and backups,
                       overriding the configured retention policy.
    -q quiet         - Suppress non-fatal warnings.
    -t throttle      - Specify the maximum nomber of timeshift snapshots to process
                       in one run.
                       For testing purposes, and for catching up with timeshift when
                       starting to use ${TAG}, and not getting overwhelmed
                       with a mass of send / receve snapshots being launched by btrbk.

Commands:
    clone            - Only clone timeshift snapshots. Do not run btrbk.
    btrbk            - Do not clone timeshift snapshots. Only run btrbk.
    run              - Run both clone and btrbk.
    version          - Show version for ${TAG} and btrbk.
    help             - Show this help message.
HERE

}

# Parse arguments for commands that do not require elevated privileges to run
parse_arguments_early() {
  if (( $# > 0 )); then
    typeset option
    for option in "$@"; do
      case "$option" in
        help )
          show_usage
          exit 0
          ;;
        version )
          echo "timeshift-btrbk-bridge version $VERSION"
          btrbk --version
          exit 0
          ;;
      esac
    done
  else
    echo "Missing required argument"
    show_usage
    exit 1
  fi
}

# Parse arguments that require elevated privileges to run
# Called AFTER check_for_root and configure_logging
parse_arguments() {
  typeset -g    DRY_RUN=false
  typeset -i -g THROTTLE=1000         # no throttling by default
  typeset -g    PRESERVE="ON"         # retention policy is ON by default
  typeset -g    LOGLEVEL=""           # default is info
  typeset -g    QUIET=false
  typeset -g    COMMAND="* Not set *" # Show this when COMMAND has not been set
  typeset -a    INFO_MSGS=()          # Collect INFO messages
  typeset -a    WARNING_MSGS=()       # Collect WARNING messages

  # NOTE:
  # One or more arguments is guaranteed after the call to parse_arguments_early
  # 1. Handle Options
  while getopts ":c:l:np:qt:" opt; do # Go through the options
    case $opt in
      # Keep the DRY-RUN option first, to list it as first when set.
      n )
        DRY_RUN=true
        WARNING_MSGS+=( "--- DRY RUN MODE ACTIVE (No changes will be made) ---" )
        ;;
      c )
        if [[ ! -r $OPTARG ]]; then
          fail "btrbk configuration file $OPTARG is not readable"
        else
          BTRBK_CONFIG_FILE=$OPTARG
          BTRBK_OPTIONS+=( "-c $OPTARG")
        fi
        ;;
      l )
        # NOTE:
        # LOGLEVEL is the log level for the btrbk invocation.
        # General log levels are set in configure_logging.
        if [[ $OPTARG =~ error|warn|info|debug|trace ]]; then
          LOGLEVEL=$OPTARG
          BTRBK_OPTIONS+=( "--loglevel=$LOGLEVEL" )
          INFO_MSGS+=( "--- BTRBK LOG LEVEL is set to $LOGLEVEL ---" )
        else
          WARNING_MSGS+=( "invalid option -$opt argument $OPTARG" )
        fi
        ;;
      p )
        if [[ $OPTARG =~ ON|OFF ]]; then
          PRESERVE=$OPTARG
          if [[ $PRESERVE == ON ]]; then
            INFO_MSGS+=( "--- PRESERVE MODE is $PRESERVE ---")
            BTRBK_OPTIONS+=( "-p")
          fi
        else
          WARNING_MSGS+=( "invalid option -$opt argument $OPTARG" )
        fi
        ;;
      q )
        QUIET=true
        ;;
      t )
        if [[ $OPTARG =~ [1-9][0-9]* ]]; then
          THROTTLE=$OPTARG
          INFO_MSGS+=( "--- THROTTLE is set to $THROTTLE ---" )
        else
          WARNING_MSGS+=( "invalid option -$opt argument $OPTARG" )
        fi
        ;;
      ? ) # Invalid option
        fail "invalid option: -${OPTARG}"
        ;;

    esac
  done

  # Show WARNING and INFO messages.
  # Do it here, after all options have been parsed (including QUIET).
  # So that we can honour the QUIET option, if set.
  for msg in "${WARNING_MSGS[@]}"; do
    log_warn "$msg"
  done
  for msg in "${INFO_MSGS[@]}"; do
    log_info "$msg"
  done

  # 2. Handle Command
  shift $((OPTIND -1))
  if [[ $# -eq 0 ]]; then
    fail "Must specify one command (clone|btrbk|run|version|help)."
  else
    COMMAND=$1
    shift 1
    if [[ $# -gt 0 ]]; then
      log_warn "Ignore excess arguments $*."
    fi
  fi

  # 3. Early Help Exit
  if [[ $COMMAND == "help" ]]; then
    show_usage
  fi
}

# retry a command with arguments max(retries) | delay | fatal | command + arguments
with_retries() {
  typeset -i max=$1
  typeset -i delay=$2
  typeset fatal=$3
  shift 3
  typeset -i count=1
  while true; do
    if ! run "$@"; then
      if (( count < max)); then
        log_warn "Command $* failed. Attempt $count/$max"
        ((count++))
        sleep $delay
      else
        typeset msg="Command $* has failed after $count attempts."
        if $fatal; then fail "$msg"; else log_warn "$msg"; fi
      fi
      else
        break
    fi
  done
}

# Mount device with given label
# NOTE: Presumes filesystem is declared in /etc/fstab with LABEL=
#       Mount with options and mountpoint declared in /etc/fstab
mount_by_label () {
  typeset LABEL=$1
  typeset MOUNTPOINT

  # Extract mountpoint from /etc/fstab:
  # 1. Look for lines starting with LABEL= (ignoring comments)
  # 2. Use awk to grab the second column reliably
  MOUNTPOINT=$(grep "^LABEL=${LABEL}[[:space:]]" /etc/fstab | awk '{print $2}')

  if [[ -n "$MOUNTPOINT" ]]; then

    if [[ ! -d $MOUNTPOINT ]]; then
      mkdir -p "$MOUNTPOINT" 2>/dev/null || { fail "failed to create mountpoint $MOUNTPOINT"; }
    fi

    # NOTE: issue
    # mount LABEL=BTRBK_ARCHIVE returns 0 when the USB device is not mounted
    # because the entry in /etc/fstab had 'nofail' in the mount options.
    # removing 'nofail' solved the issue.
    if ! mountpoint -q "$MOUNTPOINT"; then
      # Attempt the mount
      mount LABEL="$LABEL" &>/dev/null
      rc=$?

      if [[ $rc -gt 0 ]]; then
        fail "mount LABEL=$LABEL returned $rc."
      else
        mounted_by_this_script+=("$MOUNTPOINT")
      fi
    fi
  fi
}

# Create ro snapshot: source=timeshift snapshot; destination=btrbk sink.
# ONLY when the snapshot is not older than the latest archived snapshot
# AND the ro snapshot is not already in the btrbk sink.
process_snapshot() {
    typeset snapshot_path="$1"  # This should be the full absolute path

    # Validation: Ensure the path is absolute and exists
    if [[ ! "$snapshot_path" =~ ^/ ]]; then
        # If it's just a folder name, prepend the snapshots directory
        snapshot_path="${TIMESHIFT_SNAPSHOTS_DIR}/${snapshot_path}"
    fi

    if [[ ! -d "$snapshot_path" ]]; then
        fail "Source snapshot directory not found: $snapshot_path"
    fi

    typeset timeshift_snapshot_name
    timeshift_snapshot_name=$(basename "$snapshot_path")

    # Convert YYYY-MM-DD_HH-MM-SS to YYYYMMDDTHHMM
    typeset btrbk_snapshot_name
    btrbk_snapshot_name=$(echo "$timeshift_snapshot_name" | sed 's/-//g; s/_/T/' | cut -c 1-13)

    for subvol in "${TARGET_SUBVOLUMES[@]}"; do
        typeset src_subvol="${snapshot_path}/${subvol}"
        typeset dest_subvol="${BTRBK_SINK}/${subvol}.${btrbk_snapshot_name}"

        # 1. Check if source subvolume exists (e.g., does @home exist in this snapshot?)
        if [[ ! -d "$src_subvol" ]]; then
            log_warn "Subvolume $subvol not present in $timeshift_snapshot_name, skipping."
            continue
        fi

        # 2. Check if snapshot is older than the latest archived snapshot for this subvolume
        log_debug "Comparing ${subvol}.${btrbk_snapshot_name} to ${LATEST_SNAPSHOTS[$subvol]}"
        if ! [[ "${subvol}.${btrbk_snapshot_name}" > "${LATEST_SNAPSHOTS[$subvol]}" ]]; then
          log_debug "Snapshot $btrbk_snapshot_name has already been archived. Skipping..."
          continue
        fi

        # 3. Check if the destination already exists in the sink
        if [[ ! -d "$dest_subvol" ]]; then
            log_info "Creating read-only snapshot ${subvol}.${btrbk_snapshot_name} in the btrbk sink."

            # Use absolute paths for both source and destination
            run btrfs subvolume snapshot -r "$src_subvol" "$dest_subvol"

            rc=$?
            if [[ $rc -gt 0 ]]; then
                fail "Failed to create read-only snapshot for $src_subvol (return code $rc)"
            fi
        else
            log_info "Snapshot ${subvol}.${btrbk_snapshot_name} already exists in btrbk sink."
        fi
    done
}

acquire_timeshift_lock(){
  if [[ ! -f $TIMESHIFT_LOCK ]]; then
    echo "$$;" > $TIMESHIFT_LOCK
    # cat $TIMESHIFT_LOCK
  else return 1
  fi
}

relinquish_timeshift_lock(){
  if [[ ! -f $TIMESHIFT_LOCK ]]; then
    fail "trying to relinquish non existant lock."
  else
    run rm $TIMESHIFT_LOCK
  fi
}

# exit handler
cleanup () {
  set +e
  typeset exit_code=$?
  typeset mp
  trap - EXIT

  if [[ -f $TIMESHIFT_LOCK ]]; then
    # check if it is the lock we created
    if grep -F "$$;" $TIMESHIFT_LOCK; then
      rm $TIMESHIFT_LOCK
      rc=$?
      log_info "Error removing the timeshift lock (return code $rc)."
      set +e
      send_desktop_notification "critical" "timeshift btrbk bridge" "Could not remove the timeshift lock.. All timeshift commands will fail until the lock (file /run/timeshift/lock/timeshift) is removed. Please investigate."
      set -e
    fi
  fi

  # unmount filesystems mounted by this script
  for mp in "${mounted_by_this_script[@]}"; do
    umount "$mp" &>/dev/null
    rc=$?
    if [[ 0 -ne $rc ]]; then log_critical "umount $mp returned $rc."; fi
  done

  if [[ $exit_code -gt 0 ]] && [[ -n "$PHASE" ]]; then
    log_critical "A command in phase $PHASE returned $exit_code."
    send_desktop_notification "critical" "timeshift btrbk bridge" "timeshift-btrbk-bridge returned $exit_code in phase $PHASE. Please investigate."
  fi

  exit $exit_code
}

have_command() { command -v "$1" >/dev/null; }

send_desktop_notification() {

  function get_active_gui_user() {
    typeset -n nr_gui_user=$1
    typeset -n nr_gui_user_id=$2
    typeset whereami="get_active_gui_user"

    # have loginctl?
    if ! have_command loginctl; then
      log_warn "${whereami}: command loginctl not found"
      return 1
    fi

    typeset -a LOGINCTL_USERS
    set +m
    shopt -s lastpipe
    loginctl --no-legend list-users 2>/dev/null | mapfile -t LOGINCTL_USERS
    rc=${PIPESTATUS[0]}
    [[ $rc -eq 0 ]] || {
      log_warn "${whereami}: loginctl rc=$rc"
      return $rc
    }
    typeset item
    typeset pattern="^[[:space:]]*([0-9]+)[[:space:]]*([^[:space:]]+)[[:space:]]+[^[:space:]]+[[:space:]]+([^[:space:]]+)[[:space:]]*$"
    for item in "${LOGINCTL_USERS[@]}"; do
      if [[ "$item" =~ $pattern ]]; then
        active="${BASH_REMATCH[3]}"
        nr_gui_user_id="${BASH_REMATCH[1]}"
        { [[ "$active" != active ]] || [[ "$user_id" == 0 ]]; }  && continue
        nr_gui_user="${BASH_REMATCH[2]}"
        break
      else
        log_warn "${whereami}: ($item) does not match pattern"
      fi
    done
  }

  function get_active_gui_user_fallback() {
    # Find the GUI user for X11 setup (usually the one logged into display :0)
    typeset -n nr_gui_user=$1
    typeset -n nr_gui_user_id=$2
    typeset whereami="get_active_gui_user_fallback"

    # have w?
    if ! have_command w >/dev/null; then
      log_warn "${whereami}: command w not found"
      return 1
    fi

    typeset -a W
    set +m
    shopt -s lastpipe
    w --no-header 2>/dev/null | mapfile -t W
    rc=${PIPESTATUS[0]}
    [[ $rc -eq 0 ]] || {
      log_warn "${whereami}: command w failed rc=$rc"
      return $rc
    }
    typeset item
    typeset pattern="^[[:space:]]*([^[:space:]]+).*$"
    for item in "${W[@]}"; do
      if [[ "$item" =~ $pattern ]]; then
        nr_gui_user="${BASH_REMATCH[1]}"
        [[ "$nr_gui_user" == root ]] && continue
        break
      else
        log_warn "${whereami}: ($item) does not match pattern"
      fi
    done
    nr_gui_user_id=""
    if [[ -n "$nr_gui_user" ]]; then
      # Get the user's ID to access their DBUS session
      nr_gui_user_id=$(id -u "$gui_user")
    fi
  }

  typeset whereami="send_desktop_notification"
  typeset urgency="$1"   # low, normal, critical
  typeset summary="$2"
  typeset body="$3"
  typeset -i rc

  # have notify-send?
  if ! have_command notify-send; then
    log_warn "${whereami}: command notify-send not found"
    return 1
  fi

  typeset gui_user=""
  typeset user_id=""

  get_active_gui_user gui_user user_id

  if [[ -z "${gui_user}" ]]; then
    get_active_gui_user_fallback gui_user user_id
  fi

  # still no gui_user? give up
  if [[ -z "${gui_user}" ]]; then
    log_warn "${whereami}: failed to get gui_user"
    return 1
  fi

  # Execute as the user, pointing to their specific D-Bus bus
  # This works for both X11 and Wayland
  sudo -u "$gui_user" \
       DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/"$user_id"/bus \
       notify-send -u "$urgency" -i "timeshift" "$summary" "$body" \
       -t 10000
  rc=$?
  [[ "$rc" -eq 0 ]] || log_warn "$whereami: notify-send rc=$rc"
  return $rc

} # End of send_desktop_notification

clone_timeshift_snapshots() {
  # NOTE: Get latest archived snapshot per subvolume.
  # This REQUIRES the USB drive containing btrbk archive to be mounted.
  # Used to decide which timeshift snapshots we want to select and process:
  # Only snapshots younger than the latest snapshot are processed,
  # other snapshots have already been archived and can be skipped.
  # 1. Get latest archived snapshot per subvolume
  PHASE="Get latest archived snapshot per subvolume"
  log_notice "Start ${PHASE,,}"

  if ! mountpoint -q "$BTRBK_ARCHIVE_MOUNTPOINT"; then
    fail "Filesystem with label $ARCHIVE_FILESYSTEM_LABEL is not mounted."
  fi

  typeset -A LATEST_SNAPSHOTS
  get_latest_snapshots

  # 2. Find all timeshift snapshots
  PHASE="Find all timeshift snapshots"
  log_notice "Start ${PHASE,,}"

  # NOTE: Acquire the timeshift lock
  # Prevent timeshift to create/delete snapshots while we are processing them.
  with_retries 3 2 true acquire_timeshift_lock

  # We hold the timeshift lock
  typeset -a timeshift_snapshots
  # Enable nullglob so it returns an empty array if no snapshots exist
  shopt -s nullglob
  # Populate array directly with absolute paths
  timeshift_snapshots=( "$TIMESHIFT_SNAPSHOTS_DIR"/* )
  # Remove trailing slash
  # timeshift_snapshots=( "${timeshift_snapshots[@]%/}" )
  shopt -u nullglob
  # printf '%s\n' "${timeshift_snapshots[@]}"

  # 3. Select and process snapshots
  PHASE="Clone selected timeshift snapshots into the btrbk sink"
  log_notice "Start ${PHASE,,}"

  typeset -i count=0            # start from zero, as does timeshift
  # Process snapshots
  log_info "Processing snapshots"
  # NOTE: take THROTTLE into account
  # Limit number of processed snapshots to configured snapshots per run.
  for snapshot in "${timeshift_snapshots[@]:0:${THROTTLE}}"; do
    log_info "snapshot #$count - $snapshot ..."
    process_snapshot "$snapshot"
    # ?? Ignore return code 1 (snapshot does not exist any more)
    (( ++count ))
  done

  # Relinquish the timeshift lock.
  run relinquish_timeshift_lock
}

archive_snapshots() {
  # 4. Run btrbk send / receive
  PHASE="Btrbk send/receive"
  log_notice "Start ${PHASE,,}"
  # NOTE:Can be removed
  # We mount BTRBK_ARCHIVE here for test purposes.
  # In production this script will run automatically using a systemd timer, and
  # BTRBK_ARCHIVE will be mounted using a mount unit.
  # mount_by_label BTRBK_ARCHIVE $BTRBK_ARCHIVE_MOUNTPOINT

  # if dry run, do not just show the btrbk command, but run it with dryrun
  if $DRY_RUN; then
    /usr/bin/btrbk "${BTRBK_OPTIONS[@]}" dryrun
  else
    run /usr/bin/btrbk "${BTRBK_OPTIONS[@]}" run
  fi

  rc=$?

  # NOTE:
  # btrbk return code 10 means "Completed with warnings"
  # (often due to stray subvolumes or skipped snapshots)
  # Should not happen because we guard against re-introduced snapshots
  if [[ $rc -eq 10 ]]; then
    # Log as an error, but continue.
    log_error "btrbk completed with warnings (RC 10). Please investigate."
  elif [[ $rc -gt 0 ]]; then
    fail "btrbk returned a fatal error: $rc."
  fi
}

# Function to get the latest snapshots on BTRBK_ARCHIVE for subvolumes @ and @home
get_latest_snapshots () {
  # Capture output of 'btrbk --format=raw list latest'
  mapfile -t btrbk_list_latest < <(btrbk --format=raw list latest)
  typeset format type source_url source_host source_port source_subvolume snapshot_subvolume \
          snapshot_name status target_url target_host target_port target_subvolume target_type \
          source_rsh target_rsh
  typeset entry key value

  for entry in "${btrbk_list_latest[@]}"; do
    eval "$entry"
    # printf '%s\n' "$snapshot_name"
    # printf '%s\n' "$snapshot_subvolume"
    key="$snapshot_name"
    value="$(basename "$snapshot_subvolume")"
    # printf '%s\n' "key = $key"
    # printf '%s\n' "value = $value"
    log_notice "Latest archived snapshot for $key is $value"
    LATEST_SNAPSHOTS["$key"]="$value"
  done
}

# Function to check if logger command is available
# check_logger_availability() {
#   if command -v logger &>/dev/null; then
#     echo "✓ 'logger' command is available for journal logging"
#     LOGGER_AVAILABLE=true
#   else
#     echo "✗ 'logger' command is not available. Journal logging features will be skipped."
#     LOGGER_AVAILABLE=false
#   fi
# }

# Configure logging
configure_logging () {
  # Check if logging module exists
  if [[ ! -f "$LOGGING_MODULE_PATH" ]]; then
    echo "Error: Logger module not found at $LOGGING_MODULE_PATH" >&2
    exit 1
  fi

  # Create log directory
  # mkdir -p "$LOGGING_DIR"

  # echo "Log file: $LOGGING_FILE"

  # Source the logger module
  echo "Sourcing logger from: $LOGGING_MODULE_PATH"
  # shellcheck source=/dev/null
  source "$LOGGING_MODULE_PATH"
  # Check if logger command is available
  # check_logger_availability

  # Initialize logger using LOGGING_CONFIG
  echo "========== Initializing logger using config file =========="
  init_logger --config "${LOGGING_CONFIG}" || {
    echo "Failed to initialize logger" >&2
    exit 1
  }
}

# ----- start Main -----

# NOTE
# Uncomment next line when bash-logger bug is solved
set -euo pipefail

# Check for commands that do not require elevated privileges
parse_arguments_early "$@"

check_for_root

configure_logging

parse_arguments "$@"

log_notice "Running $0 $*"

# Mount BTRFS_ROOT
# and keep track of mountpoints mounted by this script
typeset -a mounted_by_this_script=()
mount_by_label "$ROOT_FILESYSTEM_LABEL"
# ROOT_UUID=$(grep -E '^[^#].+/\s+btrfs' /etc/fstab | cut -d " " -f 1 | cut -d '=' -f 2)
# ROOT_FS_OPTIONS=$(grep -E '^[^#].+/\s+btrfs' /etc/fstab | cut -d ' ' -f 4)
# # replace 'subvol=@' by 'subvolid=0'
# ROOT_FS_OPTIONS=${ROOT_FS_OPTIONS/subvol=\/@/subvolid=5,subvol=/}
# # mount by UUID using ROOT_FS_OPTIONS and mountpoint BTRFS_ROOT_MOUNTPOINT
# mount UUID=$ROOT_UUID -o $ROOT_FS_OPTIONS $BTRFS_ROOT_MOUNTPOINT
# mounted_by_this_script+=($BTRFS_ROOT_MOUNTPOINT)
# findmnt -t btrfs

# Mount btrbk_archive here - 'btrbk list latest' REQUIRES BTRBK_ARCHIVE mounted
#
mount_by_label "$ARCHIVE_FILESYSTEM_LABEL"

# 'EXIT' catches any termination of the script
trap cleanup EXIT

case $COMMAND in
  clone )
    # clone only
    clone_timeshift_snapshots
    ;;
  btrbk )
    # btrbk only
    archive_snapshots
    ;;
  run )
    # clone AND btrbk
    clone_timeshift_snapshots
    archive_snapshots
    ;;
  * )
    fail "invalid command $COMMAND."
    ;;
esac
