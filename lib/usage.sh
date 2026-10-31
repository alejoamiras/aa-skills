# shellcheck shell=bash
# Helpers bin/claude-usage and bin/codex-usage share; each sources this file, so it must run on bash 3.2
# (stock macOS). The sourcing tool sets TOOL, MAIN_DIR, ACCOUNTS_ROOT, LABELS_FILE, CACHE_DIR, LOCK_DIR,
# NEVER, RESERVED (selector words no account may be named), RESERVED_IN (where they select) and SNAPSHOTS
# (the cache files a rename voids), and defines die and valid_name.

# shellcheck disable=SC2034 # the tools read these
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; YEL=$'\033[33m'
  GRN=$'\033[32m'; RST=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; YEL=''; GRN=''; RST=''
fi

# Directory key -> display label. The slot is always "main": its display name
# comes from the roster account matched to it, never from an alias.
label_for() {
  local key="$1" k v
  [[ ${key} == main ]] && { printf 'main'; return; }
  if [[ -f ${LABELS_FILE} ]]; then
    while IFS='=' read -r k v || [[ -n ${k} ]]; do
      [[ ${k} == "${key}" && -n ${v} ]] && { printf '%s' "${v}"; return; }
    done < "${LABELS_FILE}"
  fi
  printf '%s' "${key}"
}

# Display label -> directory key. Falls through unchanged so every command
# accepts either name.
key_for() {
  local want="$1" k v
  if [[ -f ${LABELS_FILE} ]]; then
    while IFS='=' read -r k v || [[ -n ${k} ]]; do
      [[ ${k} == main ]] && continue   # a pre-roster alias for the slot; ignored
      [[ ${v} == "${want}" && -n ${k} ]] && { printf '%s' "${k}"; return; }
    done < "${LABELS_FILE}"
  fi
  printf '%s' "${want}"
}

resolve_dir() {
  local key; key=$(key_for "$1")
  valid_name "${key}" || die "invalid account name: $1"
  [[ ${key} == main ]] && { printf '%s' "${MAIN_DIR}"; return 0; }
  [[ -d ${ACCOUNTS_ROOT}/${key} ]] || die "unknown account: $1 (try: ${TOOL} list)"
  printf '%s' "${ACCOUNTS_ROOT}/${key}"
}

refuse_reserved() {
  local r
  [[ $1 == main ]] && die "'main' is reserved for ~/${MAIN_DIR##*/}"
  for r in "${RESERVED[@]}"; do
    [[ $1 == "${r}" ]] && die "'$1' is reserved: it means \"pick for me\" in ${RESERVED_IN}"
  done
  return 0
}

# Remove one mapping by exact key match, never by pattern.
drop_label() {
  local key="$1" line tmp
  [[ -f ${LABELS_FILE} ]] || return 0
  tmp="${LABELS_FILE}.$$"
  : > "${tmp}"
  while IFS= read -r line || [[ -n ${line} ]]; do
    [[ ${line} == "${key}="* ]] && continue
    printf '%s\n' "${line}" >> "${tmp}"
  done < "${LABELS_FILE}"
  mv -f "${tmp}" "${LABELS_FILE}"
}

cmd_rename() {
  local old="${1:-}" new="${2:-}" key line tmp taken
  [[ -n ${old} && -n ${new} ]] || die "usage: ${TOOL} rename <current-name> <new-name>"
  valid_name "${new}" || die "invalid name: ${new} (letters, digits, . _ - only; no leading dot)"

  key=$(key_for "${old}")
  [[ ${key} == main ]] && die "main is the ~/${MAIN_DIR##*/} slot, not an account: it takes the name of the roster account logged into it (${TOOL} add <name>)"
  [[ -d ${ACCOUNTS_ROOT}/${key} ]] || die "unknown account: ${old} (try: ${TOOL} list)"
  refuse_reserved "${new}"
  taken=$(key_for "${new}")
  [[ ${taken} != "${key}" && -d ${ACCOUNTS_ROOT}/${taken} ]] &&
    die "name already in use: ${new}"

  mkdir -p "${ACCOUNTS_ROOT}"
  tmp="${LABELS_FILE}.$$"
  : > "${tmp}"
  if [[ -f ${LABELS_FILE} ]]; then
    while IFS= read -r line || [[ -n ${line} ]]; do
      [[ ${line} == "${key}="* ]] && continue
      printf '%s\n' "${line}" >> "${tmp}"
    done < "${LABELS_FILE}"
  fi
  [[ ${new} != "${key}" ]] && printf '%s=%s\n' "${key}" "${new}" >> "${tmp}"
  mv -f "${tmp}" "${LABELS_FILE}"

  rm -f "${SNAPSHOTS[@]}"   # the cached rows carry the old name
  printf '%s → %s\n' "${old}" "${new}"
}

# Seconds since a file or dir was written, or NEVER when there is none.
file_age() {
  local mt now
  [[ -e $1 ]] || { printf '%s' "${NEVER}"; return; }
  # `stat -f` means "format" to BSD stat and "filesystem" to GNU stat, so the
  # wrong one returns junk instead of failing. Validate rather than trust.
  mt=$(stat -c %Y "$1" 2> /dev/null)
  [[ ${mt} =~ ^[0-9]+$ ]] || mt=$(stat -f %m "$1" 2> /dev/null)
  [[ ${mt} =~ ^[0-9]+$ ]] || { printf '%s' "${NEVER}"; return; }
  now=$(date +%s)
  printf '%s' "$((now - mt))"
}

# Create a lock dir, failing if it exists. uutils mkdir 0.10.0 (Ubuntu 26.04) reports success to both
# sides of a creation race; perl's mkdir is one mkdir(2), and BSD and GNU mkdir(1) are already atomic.
claim_dir() {
  if [[ -x /usr/bin/perl ]]; then /usr/bin/perl -e 'mkdir $ARGV[0] or exit 1' -- "$1"; else mkdir "$1"; fi
}

# Drop the lock only while we still hold it: one stolen after a stall belongs
# to another process now.
release_lock() {
  [[ $(cat "${LOCK_DIR}/pid" 2> /dev/null) == "$$" ]] && rm -rf "${LOCK_DIR}"
  return 0
}

# The refresh lock, released on exit; 1 when another refresher holds it. The claim is exclusive, so of
# the N agents that may fire a refresh at once exactly one proceeds; the rest return at once rather than
# stampeding the accounts with duplicate probes.
take_refresh_lock() {
  mkdir -p "${CACHE_DIR}"
  if ! claim_dir "${LOCK_DIR}" 2> /dev/null; then
    local holder aged capped grave
    holder=$(cat "${LOCK_DIR}/pid" 2> /dev/null)
    [[ -n $(find "${LOCK_DIR}" -maxdepth 0 -mmin +5 2> /dev/null) ]] && aged=1 || aged=""
    # A recycled pid could otherwise keep a dead lock alive forever, so age
    # eventually wins regardless of liveness.
    [[ -n $(find "${LOCK_DIR}" -maxdepth 0 -mmin +30 2> /dev/null) ]] && capped=1 || capped=""
    if [[ -z ${capped} ]]; then
      [[ ${holder} =~ ^[0-9]+$ ]] && kill -0 "${holder}" 2> /dev/null && return 1
      [[ -n ${aged} ]] || return 1
    fi
    # Claim the stale lock by renaming it: mv is atomic, so of N racers exactly
    # one succeeds and the losers back off instead of all recreating it.
    grave="${LOCK_DIR}.dead.$$"
    mv "${LOCK_DIR}" "${grave}" 2> /dev/null || return 1
    rm -rf "${grave}"
    claim_dir "${LOCK_DIR}" 2> /dev/null || return 1
  fi
  printf '%s' "$$" > "${LOCK_DIR}/pid"
  trap 'release_lock' EXIT
  # Another racer may have stolen and recreated the lock between our checks and
  # our claim; whoever wrote the pid last owns it.
  [[ $(cat "${LOCK_DIR}/pid" 2> /dev/null) == "$$" ]] || return 1
  rm -rf "${LOCK_DIR:?}".dead.* 2> /dev/null   # graves from refreshers that died mid-steal
  return 0
}

# Pad a cell to a visible width: printf's %-Ns counts ANSI escapes as
# characters, so colour + %-Ns silently shreds the column alignment.
pad_cell() {
  local painted="$1" plain="$2" width="$3" align="$4" pad
  pad=$((width - ${#plain}))
  ((pad < 0)) && pad=0
  if [[ ${align} == right ]]; then
    printf '%*s%s' "${pad}" "" "${painted}"
  else
    printf '%s%*s' "${painted}" "${pad}" ""
  fi
}

# Horizontal border: corner chars, then one width per column.
hrule() {
  local l="$1" m="$2" r="$3"; shift 3
  local out="${l}" w first=1 i
  for w in "$@"; do
    ((first)) || out+="${m}"
    first=0
    for ((i = 0; i < w + 2; i++)); do out+="─"; done
  done
  printf '%s%s\n' "${out}" "${r}"
}

jq_str() {
  printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}
