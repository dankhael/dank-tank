# usage-cache.sh — caching shared by claude-usage, codex-usage and opencode-usage.
#
# Sourced, not run. The caller sets CACHE_DIR, CACHE and MAX_AGE, and defines
# `fetch`, which writes a fresh reading to $CACHE and returns
#   0 ok · 2 not signed in · 3 credentials rejected · 5 rate limited · else failed
#
# `fetch` must check the payload before replacing $CACHE: whatever it accepts is
# shown as a current reading.
#
# $STALE exists exactly while the last attempt failed. It holds the reason and,
# on a second line, when it failed in microseconds; its age drives the backoff.

STALE="$CACHE_DIR/stale"
BEGAN="$CACHE_DIR/.began" # when the query behind $CACHE started, in microseconds
TMP_FILE=''

# A killed fetch must not leave its half-written file behind.
make_temp()    { TMP_FILE=$(mktemp "$CACHE_DIR/.fetch.XXXXXX"); }
discard_temp() { [[ -n "$TMP_FILE" ]] && rm -f "$TMP_FILE"; TMP_FILE=''; }
trap discard_temp EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Seconds since FILE was last written; huge when it does not exist.
age_of() {
  local at
  at=$(stat -c %Y "$1" 2>/dev/null) || { echo 999999; return; }
  echo $(( $(date +%s) - at ))
}

# EPOCHREALTIME's decimal separator follows the locale.
now_us() { printf '%s' "${EPOCHREALTIME//[!0-9]/}"; }

stale_reason() {
  local reason=''
  [[ -f "$STALE" ]] || return 0
  read -r reason < "$STALE"
  printf '%s' "${reason:-network}"
}

# After a failure, wait before asking again instead of retrying on every poll. A
# $CREDENTIALS file newer than the failure is worth retrying right away.
backing_off() {
  local wait=60
  [[ -f "$STALE" ]] || return 1
  [[ -n "${CREDENTIALS:-}" && "$CREDENTIALS" -nt "$STALE" ]] && return 1
  [[ $(stale_reason) == rate ]] && wait=300
  (( $(age_of "$STALE") < wait ))
}

# Record why a fetch failed. Succeeds when an older reading can stand in for it,
# which is then reported as stale.
failed() {
  local reason
  case "$1" in
    2) reason=login ;;
    3) reason=auth ;;
    5) reason=rate ;;
    *) reason=network ;;
  esac
  printf '%s\n%s\n' "$reason" "$(now_us)" > "$STALE"
  still_failed
}

# Whether the failure on record happened after ASKED, so that asking again would
# only repeat it.
failed_since() { # failed_since ASKED
  local at=''
  [[ -f "$STALE" ]] || return 1
  { read -r _; read -r at; } < "$STALE"
  [[ "$at" =~ ^[0-9]+$ ]] && (( at >= $1 ))
}

# Same outcome as the failure already on record, without recording a new one.
still_failed() {
  [[ -f "$CACHE" ]] && return 0
  case "$(stale_reason)" in
    login) return 2 ;;
    auth)  return 3 ;;
    *)     return 4 ;;
  esac
}

# ensure_cache FORCE — fetch if the cache is older than MAX_AGE, or always when
# FORCE is 1. Returns 0 whenever there is a reading to show, fresh or stale.
ensure_cache() {
  local force=${1:-0} asked began rc
  asked=$(now_us)
  if [[ "$force" != 1 ]]; then
    (( $(age_of "$CACHE") < MAX_AGE )) && return 0
    backing_off && { still_failed; return; }
  fi

  # One fetch at a time: the bar, the timer and a shell can all land here at
  # once, and whoever waited may find the question already answered. A forced
  # refresh accepts only a query that began after it was asked for; a failure
  # that came in meanwhile is answer enough.
  mkdir -p "$CACHE_DIR"
  exec 9>"$CACHE_DIR/.lock"
  flock -w 25 9 || { failed 4; return; }
  if [[ "$force" == 1 ]]; then
    failed_since "$asked" && { still_failed; return; }
    [[ -f "$CACHE" && ! -f "$STALE" ]] && read -r began 2>/dev/null < "$BEGAN" &&
      [[ "$began" =~ ^[0-9]+$ ]] && (( began >= asked )) && return 0
  else
    (( $(age_of "$CACHE") < MAX_AGE )) && return 0
    backing_off && { still_failed; return; }
  fi

  find "$CACHE_DIR" -maxdepth 1 -name '.fetch.*' -mmin +10 -delete 2>/dev/null
  began=$(now_us)
  fetch; rc=$?
  discard_temp
  (( rc == 0 )) || { failed "$rc"; return; }
  rm -f "$STALE"
  echo "$began" > "$BEGAN"
}
