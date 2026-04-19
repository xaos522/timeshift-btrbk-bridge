#!/bin/bash

# Configuration
SYSTEM_DEVICE_LABEL="BTRFS_ROOT"
BTRFS_ROOT_MOUNTPOINT="/mnt/btrfs_root"
TIMESHIFT_LOCK="/var/lock/timeshift/lock"
TIMESHIFT_SNAPSHOTS_DIR="${BTRFS_ROOT_MOUNTPOINT}/timeshift-btrfs/snapshots"
BTRBK_SINK="${BTRFS_ROOT_MOUNTPOINT}/btrbk/snapshots"
BTRBK_ARCHIVE_LABEL="BTRBK_ARCHIVE"
BTRBK_ARCHIVE_MOUNTPOINT="/mnt/btrbk_archive"
BTRBK_ARCHIVE_SNAPSHOTS="$BTRBK_ARCHIVE_MOUNTPOINT/snapshots/"
typeset -a TARGET_SUBVOLUMES=("@" "@home")

# Check for root permissions
check_for_root() {
  if [[ $EUID -ne 0 ]]; then fail "This script must be run as root."; fi
}

# Helper function to handle execution vs printing
run() { $DRY_RUN && echo "[DRY-RUN] Executing: $*" || "$@"; }

fail (){ echo "[ERROR]: $1" >&2 && exit 1; }

warn (){ echo "[WARNING]: $1" >&2; }

info (){ echo "[INFO]: $1" >&2; }

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

# select timeshift snapshot to transfer to btrbk sink.
select_snapshot () {
  typeset path=$1
  typeset -a snapshots=($(ls -1 "$path" 2>/dev/null))
  if [[ ${#snapshots[@]} -eq 0 ]]; then return 1; fi

  echo "Available snapshots in $path:" >&2
  for i in "${!snapshots[@]}"; do echo "$i) ${snapshots[$i]}" >&2; done

  read -p "Select a snapshot (number) or press enter to skip: " choice >&2
  if [[ -n "$choice" ]] && [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -lt "${#snapshots[@]}" ]; then echo "${path}/${snapshots[$choice]}"; else echo ""; fi
}

# Create ro snapshot: source timeshift_snapshot destination btrbk sink.
# ONLY when the ro snapshot is not already in the btrbk sink.
process_snapshot() {
  typeset selected_snapshot="$1"
  typeset timeshift_snapshot_name=$(basename "$selected_snapshot")
  # Format name for btrbk (Converting YYYY-MM-DD_HH-MM-SS to YYYYMMDDTHHMM)
  typeset btrbk_snapshot_name=$(echo "$timeshift_snapshot_name" | sed 's/-//g; s/_/T/' | cut -c 1-13)
  for subvol in "${TARGET_SUBVOLUMES[@]}"; do
    if [[ ! -d "$BTRBK_SINK/${subvol}.$btrbk_snapshot_name" ]]; then
      # create new ro snapshot in btrbk sink.
      run  btrfs subvolume snapshot -r "${selected_snapshot}/${subvol}" "${BTRBK_SINK}/${subvol}.$btrbk_snapshot_name"
      rc=$?
      if [[ $rc -gt 0 ]]; then
        fail "failed to create read only snapshot from ${selected_snapshot}/${subvol}"
      fi
    else
      info "snapshot ${selected_snapshot}/${subvol} is already in the btrbk sink"
    fi
  done
}

get_snapshot_age() {
  typeset SNAPSHOT="$1"
  typeset TIMESTAMP
  typeset -i SNAPSHOT_EPOCH
  typeset -i NOW_EPOCH
  # Convert YYYY-MM-DD_HH-MM-SS to YYYY-MM-DD HH:MM:SS
  TIMESTAMP="${SNAPSHOT/_/ }"
  TIMESTAMP="${TIMESTAMP:0:10} ${TIMESTAMP:11:2}:${TIMESTAMP:14:2}:${TIMESTAMP:17:2}"
  typeset -i SNAPSHOT_EPOCH=$(date -u -d "$TIMESTAMP" +%s)
  typeset -i NOW_EPOCH=$(date -u +%s)
  echo $(( NOW_EPOCH - SNAPSHOT_EPOCH ))
}

get_options() {
  DRY_RUN=false
  # By default select ALL scheduled snapshots (monthly + weekly + daily)
  SELECTION=all
  # Default minimum TIMESHIFT snapshot age to become eligable for deleteion
  typeset -i -g DELETE_MIN_AGE=365 # in days
  if [[ ! 0 == $# ]] # If options provided then
  then
    while getopts ":d:s:n" opt; do # Go through the options
      case $opt in
        n )
          DRY_RUN=true
          warn "--- DRY RUN MODE ACTIVE (No changes will be made) ---"
          ;;
        s )
          SELECTION=$OPTARG
          if [[ ! $SELECTION =~ one|monthly|weekly|daily ]]; then
            fail "invalid option -$opt argument ${SELECTION}"; fi
          ;;
        d )
          if [[ $OPTARG =~ [1-9][0-9]* ]]; then
            DELETE_MIN_AGE=$OPTARG
          else
            warn "invalid option -$opt argument $OPTARG"
          fi
          ;;
        ? ) # Invalid option
          fail "invalid option: -${OPTARG}"
          ;;
      esac
    done
    shift $((OPTIND-1))
  fi
}

acquire_timeshift_lock(){
  if [[ ! -f $TIMESHIFT_LOCK ]]; then
    echo "$$;" > $TIMESHIFT_LOCK
    cat $TIMESHIFT_LOCK
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
  set -x
  if [[ -f $TIMESHIFT_LOCK ]]; then
    # check if it is the lock we created
    if grep -F "$$;" $TIMESHIFT_LOCK; then
      rm $TIMESHIFT_LOCK
    fi
  fi
  # unmount filesystems mounted by this script
  for mp in "${mounted_by_this_script[@]}"; do
    umount $mp
    rc=$?
    if [[ 0 -ne $rc ]]; then fail "umount $mp returned $rc."; fi
  done
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

# ----- start Main -----

check_for_root

get_options "$@"

# 1. Selection phase
phase="Selection"
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

typeset -a selected_snapshots=()
typeset -a final_selection=()
have_monthly=false; have_weekly=false; have_daily=false;
case $SELECTION in
  one )
    # Select One Timeshift snapshot - consider all snapshots
    snapshot=$(select_snapshot "${TIMESHIFT_SNAPSHOTS_DIR}")
    if [[ -z "$snapshot" ]]; then warn "no snapshot selected." >&2; exit 0;
    else
      final_selection+=($snapshot)
    fi
    ;;
  * )
    # NOTE: Acquire the timeshift lock
    # We use the links timeshift creates for scheduled snapshots.
    # These links are removed and rebuilt when timeshift creates/deletes snapshots.
    # We want to protect ourselves against changes while selecting snapshots.
    # Why use the links? To exclude 'boot' and 'hourly' snapshot from selection,
    # unless they have been tagged 'D', 'W' or 'M'.
    with_retries 3 2 true acquire_timeshift_lock
    # we have acquired the lock
    case $SELECTION in
      monthly )
        monthly_snapshots_path="${TIMESHIFT_SNAPSHOTS_DIR}/../snapshots-monthly"
        if [[ -d "${monthly_snapshots_path}" ]]; then
          typeset -a snapshots_monthly
          snapshots_monthly=($(ls -1 "${monthly_snapshots_path}"))
          if [[ "${#snapshots_monthly[@]}" -gt 0 ]]; then have_monthly=true; fi
        fi
        ;;

      weekly )
        weekly_snapshots_path="${TIMESHIFT_SNAPSHOTS_DIR}/../snapshots-weekly"
        if [[ -d "${weekly_snapshots_path}" ]]; then
          typeset -a snapshots_weekly
          snapshots_weekly=($(ls -1 "${weekly_snapshots_path}"))
          if [[ "${#snapshots_weekly[@]}" -gt 0 ]]; then have_weekly=true; fi
        fi
        ;;

      daily )
        daily_snapshots_path="${TIMESHIFT_SNAPSHOTS_DIR}/../snapshots-daily"
        if [[ -d "${daily_snapshots_path}" ]]; then
          typeset -a snapshots_daily
          snapshots_daily=($(ls -1 "${daily_snapshots_path}"))
          printf '%s\n' "${snapshots_daily[@]}"
          if [[ "${#snapshots_daily[@]}" -gt 0 ]]; then have_daily=true; fi
        fi
        ;;

      all )  # default select option: consider monthly + weekly + daily snapshots
        monthly_snapshots_path="${TIMESHIFT_SNAPSHOTS_DIR}/../snapshots-monthly"
        if [[ -d "${monthly_snapshots_path}" ]]; then
          typeset -a snapshots_monthly
          snapshots_monthly=($(ls -1 "${monthly_snapshots_path}"))
          if [[ "${#snapshots_monthly[@]}" -gt 0 ]]; then have_monthly=true; fi
        fi

        weekly_snapshots_path="${TIMESHIFT_SNAPSHOTS_DIR}/../snapshots-weekly"
        if [[ -d "${weekly_snapshots_path}" ]]; then
          typeset -a snapshots_weekly
          snapshots_weekly=($(ls -1 "${weekly_snapshots_path}"))
          if [[ "${#snapshots_weekly[@]}" -gt 0 ]]; then have_weekly=true; fi
        fi

        daily_snapshots_path="${TIMESHIFT_SNAPSHOTS_DIR}/../snapshots-daily"
        if [[ -d "${daily_snapshots_path}" ]]; then
          typeset -a snapshots_daily
          snapshots_daily=($(ls -1 "${daily_snapshots_path}"))
          if [[ "${#snapshots_daily[@]}" -gt 0 ]]; then have_daily=true; fi
        fi
        ;;
    esac

    # Done with the selection. Relinquish the timeshift lock.
    run relinquish_timeshift_lock

    # collect ALL selected snapshots
    selected_snapshots=( "${snapshots_monthly[@]}" "${snapshots_weekly[@]}" "${snapshots_daily[@]}" )
    if ($have_monthly || $have_weekly); then
      # we MAY have duplicates, which is NOT a problem. Duplicates will NOT be transferred to the btrbk sink.
      # We MAY have selected snapshots OUT OF CHRONOLOGICAL ORDER.
      # That is unacceptable: we want to reduce DELTA's between
      # snapshots in the btrbk sink to a minimum.
      # dailies are guaranteed to be in chronological order.
      mapfile -t final_selection < <(printf '%s\n' "${selected_snapshots[@]}" | sort -u)
    else
      final_selection=("${selected_snapshots[@]}")
    fi
esac

# 2. Fill btrbk sink
phase="Fill btrbk sink"
# Throttle the transfer to btrbk sink. Limit to 5 snapshots per run.
typeset -i max_count=5
typeset -i count=1
# Process snapshots
# NOTE: take throttling into account
for snapshot in "${final_selection[@]:0:${max_count}}"; do
  echo "#$count processing $snapshot ..."
  process_snapshot "$snapshot"
  (( count++ ))
done

# 3. Run btrbk: send snapshots in btrbk sink to the btrbk archive
phase="Btrbk send/receive"
# We mount BTRBK_ARCHIVE here for test purposes.
# In production this script will run automatically using a systemd timer, and
# BTRBK_ARCHIVE will be mounted using a mount unit.
automount_by_label BTRBK_ARCHIVE $BTRBK_ARCHIVE_MOUNTPOINT

run btrbk -l info -c /etc/btrbk/btrbk.conf run

rc=$?
if [[ $rc -gt 0 ]]; then
  fail "btrbk returned $rc."
fi

# 4. Delete selected TIMESHIFT snapshots OLDER than configured number of days.
#    ONLY if ALL snapshots were selected.
#    NOTE: take throttling into account!
if [[ $DELETE_MIN_AGE -lt 365 ]]; then
  phase="Timeshift delete"
  if [[ "$SELECTION" == "all" ]]; then
    # Process snapshots
    typeset -i age
    for snapshot in "${final_selection[@]:0:${max_count}}"; do
      age=$(get_snapshot_age $snapshot) # age in seconds
      age=$(( age / 86400 ))            # age in days
      if (( age > $DELETE_MIN_AGE )); then
        with_retries 3 2 false timeshift --delete "$snapshot"
        warn "timeshift snapshot $snapshot deleted (age = $age days)."
      fi
    done
  fi
fi

# 5.Get the current usage percentage of the USB mount
USAGE=$(df /mnt/btrbk_archive | awk 'NR==2 {print $5}' | sed 's/%//')
THRESHOLD=1

if [ "$USAGE" -gt "$THRESHOLD" ]; then
  send_desktop_notification "critical" "Disk usage theshold exceeded." "USB btrbk archive filesystem is at ${USAGE}% capacity. Consider pruning old snapshots."
fi
