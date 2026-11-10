#!/usr/bin/env bash
# backup_keep.sh - Back up a personal Google Keep account into text files
# organized by Keep label, from two independent sources:
#
#   gkeepapi  daily, via the unofficial gkeepapi library (master token in Keychain)
#   takeout   newest scheduled Google Takeout export found in Google Drive (via gog)
#
# Each source writes its own tree, so a failure in one never touches the other:
#   <BACKUP_ROOT>/gkeepapi/<Label>/<Title>__<createdUsec>.txt
#   <BACKUP_ROOT>/takeout/<Label>/<Title>__<createdUsec>.txt
# Notes with several labels are written into each label folder; notes without
# labels go to _Unlabeled/. Trashed notes are skipped.
#
# Usage: backup_keep.sh [--env FILE] [--gkeepapi|--no-gkeepapi] [--takeout|--no-takeout]
# Flags override ENABLE_GKEEPAPI / ENABLE_TAKEOUT from keep-backup.env.
# Exit status is non-zero if any enabled source fails or the Takeout export is stale.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${KEEP_BACKUP_ENV:-$SCRIPT_DIR/keep-backup.env}"

# Defaults (overridable in keep-backup.env)
KEEP_EMAIL=""
ENABLE_GKEEPAPI=1
ENABLE_TAKEOUT=1
BACKUP_ROOT="$HOME/backups/keep-backup"
KEYCHAIN_SERVICE="keep-backup-master-token"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"   # explicit: cron has no default keychain search list
PYTHON="$SCRIPT_DIR/.venv/bin/python"
TAKEOUT_DRIVE_ACCOUNT=""       # gog account whose Drive receives Takeout; defaults to KEEP_EMAIL
TAKEOUT_MAX_AGE_DAYS=70        # alert if the newest Takeout export is older than this

OVERRIDE_GKEEPAPI=""
OVERRIDE_TAKEOUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_FILE="$2"; shift 2 ;;
    --gkeepapi) OVERRIDE_GKEEPAPI=1; shift ;;
    --no-gkeepapi) OVERRIDE_GKEEPAPI=0; shift ;;
    --takeout) OVERRIDE_TAKEOUT=1; shift ;;
    --no-takeout) OVERRIDE_TAKEOUT=0; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
elif [[ -n "${KEEP_BACKUP_ENV:-}" || "$ENV_FILE" != "$SCRIPT_DIR/keep-backup.env" ]]; then
  echo "Error: env file not found: $ENV_FILE" >&2
  exit 2
fi
[[ -n "$OVERRIDE_GKEEPAPI" ]] && ENABLE_GKEEPAPI="$OVERRIDE_GKEEPAPI"
[[ -n "$OVERRIDE_TAKEOUT" ]] && ENABLE_TAKEOUT="$OVERRIDE_TAKEOUT"
TAKEOUT_DRIVE_ACCOUNT="${TAKEOUT_DRIVE_ACCOUNT:-$KEEP_EMAIL}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

if [[ "$ENABLE_GKEEPAPI" != 1 && "$ENABLE_TAKEOUT" != 1 ]]; then
  log "Both sources are disabled; nothing to do."
  exit 0
fi
command -v jq >/dev/null || { log "Error: jq not found"; exit 1; }

STATE_DIR="$BACKUP_ROOT/.state"
mkdir -p "$STATE_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# render_tree <notes.json> <dest-dir>
# Renders a JSON array of notes (Takeout schema) into a label tree, built in a
# staging dir and swapped into place only after every file is written.
# ---------------------------------------------------------------------------
render_tree() {
  local notes_json="$1" dest="$2"
  local staging
  staging="$(mktemp -d "$(dirname "$dest")/.$(basename "$dest").staging.XXXXXX")"

  local expected written=0
  expected=$(jq '[.[] | select(.isTrashed != true) | ([.labels[]?.name] | if length == 0 then 1 else (unique | length) end)] | add // 0' "$notes_json")

  while IFS=$'\t' read -r dir file b64; do
    mkdir -p "$staging/$dir"
    local path="$staging/$dir/$file" n=1
    while [[ -e "$path" ]]; do path="$staging/$dir/${file%.txt}_$n.txt"; n=$((n + 1)); done
    printf '%s' "$b64" | base64 --decode > "$path"
    written=$((written + 1))
  done < <(jq -r '
    def safe: gsub("[^A-Za-z0-9 _.-]"; "_") | gsub("_+"; "_") | gsub("^[ _.]+|[ _.]+$"; "") | .[0:80];
    def ts: if (. // 0) > 0 then (. / 1000000 | floor | todate) else "" end;
    .[] | select(.isTrashed != true)
    | (.title // "") as $title
    | ((.createdTimestampUsec // 0) | tostring) as $key
    | (($title | safe) as $t | (if $t == "" then $key else "\($t)__\($key)" end) + ".txt") as $file
    | ([.labels[]?.name] | unique) as $labels
    | (if ($labels | length) == 0 then ["_Unlabeled"]
       else [$labels[] | safe | if . == "" then "_Unnamed" else . end] end) as $dirs
    | ([ "Title: \($title)",
         "Labels: \($labels | join(", "))",
         "Created: \(.createdTimestampUsec | ts)",
         "Edited: \(.userEditedTimestampUsec | ts)",
         "Pinned: \(.isPinned // false)  Archived: \(.isArchived // false)  Color: \(.color // "DEFAULT")",
         "" ]
       + (if ((.listContent // []) | length) > 0
          then [.listContent[] | (if .isIndented then "  " else "" end) + (if .isChecked then "[x] " else "[ ] " end) + (.text // "")]
          else [.textContent // ""] end)
       | join("\n") + "\n") as $body
    | $dirs[] | "\(.)\t\($file)\t\($body | @base64)"
  ' "$notes_json")

  if [[ "$written" -ne "$expected" ]]; then
    rm -rf "$staging"
    log "Error: wrote $written of $expected files for $dest; previous backup left in place"
    return 1
  fi

  if [[ -e "$dest" ]]; then
    local old="$dest.old.$$"
    mv "$dest" "$old" && mv "$staging" "$dest" && rm -rf "$old"
  else
    mv "$staging" "$dest"
  fi
  log "Wrote $written files to $dest"
}

# ---------------------------------------------------------------------------
# Source 1: gkeepapi
# ---------------------------------------------------------------------------
run_gkeepapi() {
  [[ -n "$KEEP_EMAIL" ]] || { log "gkeepapi: KEEP_EMAIL is not set"; return 1; }
  [[ -x "$PYTHON" ]] || { log "gkeepapi: $PYTHON not found (run: uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python gkeepapi)"; return 1; }

  local out="$WORK/gkeepapi.json"
  # Token flows Keychain -> stdin; it never appears in argv, env, or on disk.
  if ! security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEEP_EMAIL" -w "$KEYCHAIN_PATH" >/dev/null 2>"$WORK/security.err"; then
    log "gkeepapi: cannot read Keychain item '$KEYCHAIN_SERVICE' from $KEYCHAIN_PATH: $(tr '\n' ' ' < "$WORK/security.err")"
    return 1
  fi
  if ! security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEEP_EMAIL" -w "$KEYCHAIN_PATH" 2>/dev/null \
      | "$PYTHON" "$SCRIPT_DIR/gkeep_dump.py" "$KEEP_EMAIL" > "$out"; then
    log "gkeepapi: fetch failed (expired/revoked master token or gkeepapi API change)"
    return 1
  fi
  jq -e 'type == "array"' "$out" >/dev/null || { log "gkeepapi: unexpected output"; return 1; }
  log "gkeepapi: fetched $(jq length "$out") notes"
  render_tree "$out" "$BACKUP_ROOT/gkeepapi"
}

# ---------------------------------------------------------------------------
# Source 2: Google Takeout export in Drive
# ---------------------------------------------------------------------------
run_takeout() {
  [[ -n "$TAKEOUT_DRIVE_ACCOUNT" ]] || { log "takeout: TAKEOUT_DRIVE_ACCOUNT/KEEP_EMAIL is not set"; return 1; }
  command -v gog >/dev/null || { log "takeout: gog not found"; return 1; }
  command -v unzip >/dev/null || { log "takeout: unzip not found"; return 1; }

  local listing="$WORK/takeout-files.json"
  if ! gog --no-input --readonly -a "$TAKEOUT_DRIVE_ACCOUNT" drive search \
      "name contains 'takeout-' and trashed = false" --raw-query --max=100 --json > "$listing"; then
    log "takeout: Drive search failed for $TAKEOUT_DRIVE_ACCOUNT"
    return 1
  fi

  # Export parts are named takeout-YYYYMMDDTHHMMSSZ-NNN.zip; pick the newest export.
  local export_id
  export_id=$(jq -r '[.files[]?.name | capture("^(?<e>takeout-[0-9]{8}T[0-9]{6}Z)-[0-9]+\\.zip$").e] | sort | last // empty' "$listing")
  if [[ -z "$export_id" ]]; then
    log "takeout: no Takeout export found in Drive for $TAKEOUT_DRIVE_ACCOUNT"
    return 1
  fi

  # Staleness check: the scheduled export runs every 2 months and expires after a year.
  local stamp export_epoch age_days
  stamp="${export_id#takeout-}"
  export_epoch=$(date -j -u -f '%Y%m%dT%H%M%SZ' "$stamp" +%s)
  age_days=$(( ( $(date +%s) - export_epoch ) / 86400 ))
  local stale=0
  if (( age_days > TAKEOUT_MAX_AGE_DAYS )); then
    log "takeout: newest export $export_id is $age_days days old (> $TAKEOUT_MAX_AGE_DAYS); renew the scheduled Takeout export"
    stale=1
  fi

  if [[ "$(cat "$STATE_DIR/takeout_last" 2>/dev/null)" == "$export_id" ]]; then
    log "takeout: $export_id already processed"
    return "$stale"
  fi

  local dl="$WORK/takeout-dl" unz="$WORK/takeout-unzipped"
  mkdir -p "$dl" "$unz"
  local id name
  while IFS=$'\t' read -r id name; do
    log "takeout: downloading $name"
    gog --no-input --readonly -a "$TAKEOUT_DRIVE_ACCOUNT" drive download "$id" --out "$dl/$name" >/dev/null \
      || { log "takeout: download failed for $name"; return 1; }
    unzip -q -o "$dl/$name" -d "$unz" || { log "takeout: unzip failed for $name"; return 1; }
  done < <(jq -r --arg e "$export_id" '.files[] | select(.name | startswith($e + "-")) | "\(.id)\t\(.name)"' "$listing")

  local notes="$WORK/takeout.json"
  find "$unz" -path '*/Keep/*.json' -type f -print0 | xargs -0 jq -s '.' > "$notes"
  if [[ "$(jq length "$notes")" -eq 0 ]]; then
    log "takeout: $export_id contains no Keep notes (was Keep selected in the export?)"
    return 1
  fi
  log "takeout: $export_id contains $(jq length "$notes") notes"
  render_tree "$notes" "$BACKUP_ROOT/takeout" || return 1
  echo "$export_id" > "$STATE_DIR/takeout_last"
  return "$stale"
}

# ---------------------------------------------------------------------------
# Run enabled sources independently and record status
# ---------------------------------------------------------------------------
status_gkeepapi="disabled"
status_takeout="disabled"
rc=0
if [[ "$ENABLE_GKEEPAPI" == 1 ]]; then
  if run_gkeepapi; then status_gkeepapi="ok"; else status_gkeepapi="failed"; rc=1; fi
fi
if [[ "$ENABLE_TAKEOUT" == 1 ]]; then
  if run_takeout; then status_takeout="ok"; else status_takeout="failed"; rc=1; fi
fi

jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg g "$status_gkeepapi" --arg t "$status_takeout" \
  '{finishedAt: $at, gkeepapi: $g, takeout: $t}' > "$STATE_DIR/last_run.json"
log "Done: gkeepapi=$status_gkeepapi takeout=$status_takeout"
exit "$rc"
