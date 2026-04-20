#!/bin/bash

# Configuration
VERSION="v0.1.0"
SYSTEM_DEVICE_LABEL="BTRFS_ROOT"
BTRFS_ROOT_MOUNTPOINT="/mnt/btrfs_root"
TIMESHIFT_LOCK="/var/lock/timeshift/lock"
TIMESHIFT_SNAPSHOTS_DIR="${BTRFS_ROOT_MOUNTPOINT}/timeshift-btrfs/snapshots"
BTRBK_SINK="${BTRFS_ROOT_MOUNTPOINT}/btrbk/snapshots"
BTRBK_ARCHIVE_LABEL="BTRBK_ARCHIVE"
BTRBK_ARCHIVE_MOUNTPOINT="/mnt/btrbk_archive"
BTRBK_ARCHIVE_SNAPSHOTS="$BTRBK_ARCHIVE_MOUNTPOINT/snapshots/"
BTRBK_CONFIG_FILE=""
typeset -a TARGET_SUBVOLUMES=("@" "@home")
typeset -a BTRBK_OPTIONS=()

# Check for root permissions
check_for_root() {
  if [[ $EUID -ne 0 ]]; then fail "This script must be run as root."; fi
}

# Helper function to handle execution vs printing
run() {
  if $DRY_RUN; then
    echo "[DRY-RUN]: Executing: $*" >&2
  else
    "$@"
  fi
}

fail (){ echo "[ERROR]: $1" >&2 && exit 1; }

warn (){
  if [[ $QUIET == "false" ]]; then
    echo "[WARNING]: $1" >&2
  fi
}

info (){
  if [[ $QUIET == "false" ]]; then
    echo "[INFO]   : $1" >&2
  fi
}


# extended usage information
# runs when timeshift-btrbk-bridge is called with -h as an option
# exits 0
show_usage() {
	cat <<HERE;
timeshift-btrbk-bridge $VERSION
Usage: timeshift-btrbk-bridge [-hn] [-c cfgfile] [-l loglevel] [-p ON|OFF] [-T throttle]

timeshift-btrbk-bridge creates read-only clones from timeshift read-write
snapshots and renames them for btrbk compatibility.

timeshift-btrbk-bridge comes with ABSOLUTELY NO WARRANTY.  This is free software,
and you are welcome to redistribute it under certain conditions.
See the GNU General Public License for details.

Options:
    -c file          - Specify alternate btrbk config file (-c /path/to/file).
    -l loglevel      - Specify loglevel for btrbk.
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
                       starting to use timeshift-btrbk-bridge, and not getting overwhelmed
                       with a mass of send / receve snapshots being launched by btrbk.

Commands:
    clone            - Only clone timeshift snapshots. Do not run btrbk.
    btrbk            - Do not clone timeshift snapshots. Only run btrbk.
    run              - Run both clone and btrbk.
    version          - Show the version number for timeshift-btrbk-bridge and btrbk.
    help             - Show this help message.
HERE

	exit 0
}

parse_input() {
  typeset -g    DRY_RUN=false
  typeset -i -g THROTTLE=1000         # no throttling by default
  typeset -g    PRESERVE="ON"         # retention policy is ON by default
  typeset -g    LOGLEVEL=""           # default is info
  typeset -g    QUIET=false
  typeset -g    COMMAND="* Not set *" # Show this when COMMAND has not been set
  typeset -a    INFO_MSGS=()          # Collect INFO messages
  typeset -a    WARNING_MSGS=()       # Collect WARNING messages

  if (( $# > 0 )); then               # If options provided then
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
          if [[ $OPTARG =~ error|warn|info|debug|trace ]]; then
            LOGLEVEL=$OPTARG
            BTRBK_OPTIONS+=( "--loglevel=$LOGLEVEL" )
            INFO_MSGS+=( "--- LOG LEVEL is set to $LOGLEVEL ---" )
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
      warn "$msg"
    done
    for msg in "${INFO_MSGS[@]}"; do
      info "$msg"
    done

    # 2. Handle Command
    shift $((OPTIND -1))
    if [[ $# -eq 0 ]]; then
      fail "Must specify one command (clone|btrbk|run|version|help)."
    else
      COMMAND=$1
      shift 1
      if [[ $# -gt 0 ]]; then
        warn "Ignore excess arguments $@."
      fi
    fi

    # 3. Early Help Exit
    if [[ $COMMAND == "help" ]]; then
      show_usage
    fi
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
    run "$@" && break || {
        if (( count < max)); then
          warn "Command $@ failed. Attempt $count/$max"
          ((count++))
          sleep $delay
        else
           typeset msg="Command $@ has failed after $count attempts."
          if fatal; then fail "$msg"; else warn "$msg"; fi
        fi
      }
  done
}

# automount device with given label
# NOTE: Presumes filesystem is declared in /etc/fstab with LABEL=
#       Mount with options and mountpoint declared in /etc/fstab
automount_by_label () {
  typeset LABEL=$1
  typeset MOUNTPOINT

  # Extract mountpoint from /etc/fstab:
  # 1. Look for lines starting with LABEL= (ignoring comments)
  # 2. Use awk to grab the second column reliably
  MOUNTPOINT=$(grep "^LABEL=${LABEL}[[:space:]]" /etc/fstab | awk '{print $2}')

  if [[ -n "$MOUNTPOINT" ]]; then

    if [[ ! -d $MOUNTPOINT ]]; then
      mkdir -p $MOUNTPOINT 2>/dev/null || fail "failed to create mountpoint $MOUNTPOINT"
    fi

    if ! mountpoint -q $MOUNTPOINT; then

      # Attempt the mount
      mount LABEL="$LABEL"
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
# ONLY when the ro snapshot is not already in the btrbk sink.
process_snapshot() {
    typeset selected_snapshot_path="$1"  # This should be the full absolute path

    # Validation: Ensure the path is absolute and exists
    if [[ ! "$selected_snapshot_path" =~ ^/ ]]; then
        # If it's just a folder name, prepend the snapshots directory
        selected_snapshot_path="${TIMESHIFT_SNAPSHOTS_DIR}/${selected_snapshot_path}"
    fi

    if [[ ! -d "$selected_snapshot_path" ]]; then
        warn "Source snapshot directory not found: $selected_snapshot_path"
        return 1
    fi

    typeset timeshift_snapshot_name=$(basename "$selected_snapshot_path")

    # Convert YYYY-MM-DD_HH-MM-SS to YYYYMMDDTHHMM
    typeset btrbk_snapshot_name=$(echo "$timeshift_snapshot_name" | sed 's/-//g; s/_/T/' | cut -c 1-13)

    for subvol in "${TARGET_SUBVOLUMES[@]}"; do
        typeset src_subvol="${selected_snapshot_path}/${subvol}"
        typeset dest_subvol="${BTRBK_SINK}/${subvol}.${btrbk_snapshot_name}"

        # 1. Check if source subvolume exists (e.g., does @home exist in this snapshot?)
        if [[ ! -d "$src_subvol" ]]; then
            warn "Subvolume $subvol not found in $timeshift_snapshot_name, skipping."
            continue
        fi

        # 2. Check if the destination already exists in the sink
        if [[ ! -d "$dest_subvol" ]]; then
            info "Creating read-only snapshot ${subvol}.${btrbk_snapshot_name} in the btrbk sink."

            # Use absolute paths for both source and destination
            run btrfs subvolume snapshot -r "$src_subvol" "$dest_subvol"

            rc=$?
            if [[ $rc -gt 0 ]]; then
                fail "Failed to create read-only snapshot for $src_subvol (return code $rc)"
            fi
        else
            info "Snapshot ${subvol}.${btrbk_snapshot_name} already exists in btrbk sink."
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
  typeset exit_code=$?
  typeset mp
  trap - EXIT

  if [[ -f $TIMESHIFT_LOCK ]]; then
    # check if it is the lock we created
    if grep -F "$$;" $TIMESHIFT_LOCK; then
      rm $TIMESHIFT_LOCK
      rc=$?
      info "Error removing the timeshift lock (return code $rc)."
      send_desktop_notification "critical" "timeshift btrbk bridge" "Could not remove the timeshift lock.. All timeshift commands will fail until the lock (file /run/timeshift/lock/timeshift) is removed. Please investigate."
    fi
  fi

  # unmount filesystems mounted by this script
  for mp in "${mounted_by_this_script[@]}"; do
    umount $mp
    rc=$?
    if [[ 0 -ne $rc ]]; then fail "umount $mp returned $rc."; fi
  done

  if [[ $exit_code > 0 ]] && [[ -n "$PHASE" ]]; then
    info "A command in phase $PHASE returned $exit_code."
    send_desktop_notification "critical" "timeshift btrbk bridge" "timeshift-btrbk-bridge returned $exit_code in phase $PHASE. Please investigate."
  fi

  exit $exit_code
}

have_command() { command -v $1 >/dev/null; }

send_desktop_notification() {

  function get_active_gui_user() {
    typeset -n nr_gui_user=$1
    typeset -n nr_gui_user_id=$2
    typeset whereami="get_active_gui_user"

    # have loginctl?
    if ! have_command loginctl; then
      warn "${whereami}: command loginctl not found"
      return 1
    fi

    typeset -a LOGINCTL_USERS
    set +m
    shopt -s lastpipe
    loginctl --no-legend list-users 2>/dev/null | mapfile -t LOGINCTL_USERS
    rc=${PIPESTATUS[0]}
    [[ $rc -eq 0 ]] || {
      warn "${whereami}: loginctl rc=$rc"
      return $rc
    }
    typeset item
    typeset pattern="^[[:space:]]*([0-9]+)[[:space:]]*([^[:space:]]+)[[:space:]]+[^[:space:]]+[[:space:]]+([^[:space:]]+)[[:space:]]*$"
    for item in "${LOGINCTL_USERS[@]}"; do
      if [[ "$item" =~ $pattern ]]; then
        active="${BASH_REMATCH[3]}"
        nr_gui_user_id="${BASH_REMATCH[1]}"
        ( [[ "$active" != active ]] || [[ "$user_id" == 0 ]] ) && continue
        nr_gui_user="${BASH_REMATCH[2]}"
        break
      else
        warn "${whereami}: ($item) does not match pattern"
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
      warn "${whereami}: command w not found"
      return 1
    fi

    typeset -a W
    set +m
    shopt -s lastpipe
    w --no-header 2>/dev/null | mapfile -t W
    rc=${PIPESTATUS[0]}
    [[ $rc -eq 0 ]] || {
      warn "${whereami}: command w failed rc=$rc"
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
        warn "${whereami}: ($item) does not match pattern"
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
    fail "${whereami}: command notify-send not found"
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
    warn "${whereami}: failed to get gui_user"
    return 1
  fi

  # Execute as the user, pointing to their specific D-Bus bus
  # This works for both X11 and Wayland
  sudo -u "$gui_user" \
       DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/"$user_id"/bus \
       notify-send -u "$urgency" -i "timeshift" "$summary" "$body" \
       -t 10000
  rc=$?
  [[ "$rc" -eq 0 ]] || warn "$whereami: notify-send rc=$rc"
  return $rc

} # End of send_desktop_notification

do_clone() {
  # 1. Selection phase
  PHASE="Clone"

  # NOTE: Acquire the timeshift lock
  # Prevent timeshift to create/delete snapshots while we are processing them.
  with_retries 3 2 true acquire_timeshift_lock
  # We hold the timeshift lock
  typeset -a timeshift_snapshots=( $(ls -1 $TIMESHIFT_SNAPSHOTS_DIR) )
  # printf '%s\n' "${timeshift_snapshots[@]}"

  # 2. Fill btrbk sink
  PHASE="Fill btrbk sink"
  # Throttle the transfer to btrbk sink. Limit to 5 snapshots per run.
  typeset -i count=0            # start from zero, as does timeshift
  # Process snapshots
  # NOTE: take THROTTLE into account
  info "Processing snapshots"
  for snapshot_name in "${timeshift_snapshots[@]:0:${THROTTLE}}"; do
    info "snapshot #$count - $snapshot_name ..."
    # Construct absolute path here for clarity
    full_path="${TIMESHIFT_SNAPSHOTS_DIR}/${snapshot_name}"
    process_snapshot "$full_path"
    # Ignore return code 1 (snapshot does not exist any more)
    # Fatal errors are caught and stop the script.
    (( count++ ))
  done
  unset count

  # Relinquish the timeshift lock.
  run relinquish_timeshift_lock
}

do_btrbk() {

  # 3. Run btrbk send / receive
  PHASE="Btrbk send/receive"
  # We mount BTRBK_ARCHIVE here for test purposes.
  # In production this script will run automatically using a systemd timer, and
  # BTRBK_ARCHIVE will be mounted using a mount unit.
  automount_by_label BTRBK_ARCHIVE $BTRBK_ARCHIVE_MOUNTPOINT

  # if dry run, do not just show the btrbk command, but run it with dryrun
  if $DRY_RUN; then
    /usr/bin/btrbk "${BTRBK_OPTIONS[@]}" dryrun
  else
    run /usr/bin/btrbk "${BTRBK_OPTIONS[@]}" run
  fi

  rc=$?

  # btrbk return code 10 means "Completed with warnings"
  # (often due to stray subvolumes or skipped snapshots)
  if [[ $rc -eq 10 ]]; then
    warn "btrbk completed with warnings (RC 10). This is likely due to re-introduced snapshots."
  elif [[ $rc -gt 0 ]]; then
    fail "btrbk returned a fatal error: $rc."
  fi
}

# ----- start Main -----

info "Running $0 $*"

check_for_root

parse_input "$@"

# Mount BTRFS_ROOT
# and keep track of mountpoints mounted by this script
typeset -a mounted_by_this_script=()
automount_by_label BTRFS_ROOT
# ROOT_UUID=$(grep -E '^[^#].+/\s+btrfs' /etc/fstab | cut -d " " -f 1 | cut -d '=' -f 2)
# ROOT_FS_OPTIONS=$(grep -E '^[^#].+/\s+btrfs' /etc/fstab | cut -d ' ' -f 4)
# # replace 'subvol=@' by 'subvolid=0'
# ROOT_FS_OPTIONS=${ROOT_FS_OPTIONS/subvol=\/@/subvolid=5,subvol=/}
# # mount by UUID using ROOT_FS_OPTIONS and mountpoint BTRFS_ROOT_MOUNTPOINT
# mount UUID=$ROOT_UUID -o $ROOT_FS_OPTIONS $BTRFS_ROOT_MOUNTPOINT
# mounted_by_this_script+=($BTRFS_ROOT_MOUNTPOINT)
# findmnt -t btrfs

# 'EXIT' catches any termination of the script
trap cleanup EXIT

case $COMMAND in
  clone )
    # clone only
    do_clone
    ;;

  btrbk )
    # btrbk only
    do_btrbk
    ;;

  run )
    do_clone
    do_btrbk
    # clone AND btrbk
    ;;

  version )
    # show version
    info "timeshift-btrbk-bridge version=$VERSION"
    btrbk --version
    exit 0
    ;;

  * )
    # invalid command
    fail "invalid command $COMMAND."
    ;;

esac
