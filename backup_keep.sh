#!/usr/bin/env bash
# backup_keep.sh – Export all Google Keep notes to organized text files
# ---------------------------------------------------------------
# Prerequisites:
#   • `gog` must be installed and authenticated (see `gog auth …`).
#   • `jq` (JSON processor) must be available (`brew install jq` on macOS).

set -euo pipefail

# -----------------------------------------------------------------
# Configurable paths
# -----------------------------------------------------------------
# Where the backup will be stored – change as you like.
BACKUP_ROOT="${HOME}/keep-backup"

# Temporary file for the raw JSON dump
TMP_JSON="$(mktemp)"

# -----------------------------------------------------------------
# Create the root backup directory
# -----------------------------------------------------------------
mkdir -p "${BACKUP_ROOT}"

# -----------------------------------------------------------------
# Pull every Keep note as JSON
# -----------------------------------------------------------------
# The exact sub‑command may vary – most `gog` builds expose a `keep list`
# command that accepts `--json`. If yours differs, adjust the line below.
gog keep list --json > "${TMP_JSON}"

# -----------------------------------------------------------------
# Helper: sanitize a string for use as a filename
# -----------------------------------------------------------------
sanitize() {
  # Replace anything that isn’t a letter, number, hyphen or underscore
  # with an underscore, then collapse consecutive underscores.
  echo "$1" | tr -c 'A-Za-z0-9_- ' '_' | tr -s '_' | sed 's/^_//;s/_$//'
}

# -----------------------------------------------------------------
# Process each note
# -----------------------------------------------------------------
jq -c '.[]' "${TMP_JSON}" | while IFS= read -r note; do
  # Extract fields from the JSON object
  ID=$(echo "$note" | jq -r '.id')
  TITLE=$(echo "$note" | jq -r '.title // empty')
  TEXT=$(echo "$note" | jq -r '.text // empty')
  # Labels come back as an array; join them with slashes for a path.
  LABELS=$(echo "$note" | jq -r '.labels[]?' | paste -sd/ -)

  # Determine the directory for this note
  if [[ -z "$LABELS" ]]; then
    NOTE_DIR="${BACKUP_ROOT}/Unlabeled"
  else
    # Turn each label into a safe directory component
    SAFE_LABELS=$(echo "$LABELS" | tr '/' '\n' | while read -r l; do sanitize "$l"; done | paste -sd/ -)
    NOTE_DIR="${BACKUP_ROOT}/${SAFE_LABELS}"
  fi
  mkdir -p "${NOTE_DIR}"

  # Build a safe filename – fall back to the note ID if title is empty.
  if [[ -n "$TITLE" ]]; then
    FILE_NAME="$(sanitize "$TITLE").txt"
  else
    FILE_NAME="${ID}.txt"
  fi

  # Write the note out
  {
    echo "Title: $TITLE"
    echo
    echo "$TEXT"
  } > "${NOTE_DIR}/${FILE_NAME}"
done

# Clean up the temporary JSON file
rm -f "${TMP_JSON}"

echo "✅  All Keep notes have been exported to ${BACKUP_ROOT}"