# Google Keep Backup Script

Backs up a **personal** Google Keep account into Markdown files organized by Keep label. It pulls from two independent sources, and each one can be turned on or off:

| Source | How | Freshness | Labels | Risk |
|---|---|---|---|---|
| `gkeepapi` | Unofficial [gkeepapi](https://github.com/kiwiz/gkeepapi) library (Keep's private API) | Every run (e.g. daily) | Yes | Can break when Google changes the private API; needs a master token |
| `takeout` | Newest scheduled Google Takeout export in Google Drive, fetched with `gog` | Every 2 months | Yes | Official and stable; the schedule has to be renewed yearly |

Each source writes its own tree, so a failure in one never touches the other:

```
~/backups/keep-backup/
  gkeepapi/<Label>/<Title>__<createdUsec>.md
  takeout/<Label>/<Title>__<createdUsec>.md
  .state/last_run.json      # {"finishedAt", "gkeepapi": ok|failed|disabled, "takeout": ...}
  .state/takeout_last       # newest Takeout export already processed
```

A note with several labels is written into each label folder. Notes with no labels go to `_Unlabeled/`, and trashed notes are skipped. Each tree is built in a staging directory and swapped into place only after every file is written. If a run fails, the previous backup stays as it was.

Note file format (Markdown with YAML front matter; checklists become task lists):

```markdown
---
title: "Groceries"
labels: ["Home","Shopping"]
created: 2023-11-14T22:13:20Z
edited: 2023-11-14T22:21:40Z
pinned: true
archived: false
color: DEFAULT
source: gkeepapi
---

# Groceries

- [x] Milk
  - [ ] 2%
```

Text notes keep their body as-is, so Markdown you wrote in Keep renders as Markdown.

To re-render a notes JSON file (Takeout schema) into a tree without contacting Google, run `./backup-keep.sh --render notes.json <dest-dir>`.

## Setup

1. Dependencies: `gog`, `jq`, `unzip`, and `uv` (for the Python venv).
2. Config:
   ```bash
   cp keep-backup.env.example keep-backup.env   # set KEEP_EMAIL, enable/disable sources
   ```
3. **gkeepapi source**
   ```bash
   uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python gkeepapi
   .venv/bin/python setup_master_token.py you@gmail.com
   ```
   `setup_master_token.py` prompts for the `oauth_token` cookie (instructions are in the script), exchanges it for a master token, and stores that token in the macOS Keychain. The token is never printed, never written to disk, and never passed as a command argument. At backup time it goes from the Keychain to the script over stdin.
4. **Takeout source**
   - At <https://takeout.google.com>: *Deselect all* → select **Keep** → Delivery method **Add to Drive** → Frequency **Export every 2 months for 1 year** → File type `.zip` → Create export.
   - `gog` needs Drive access to that account (`gog auth add you@gmail.com --services drive --readonly` if it has none). The script always runs gog with `--readonly`.
   - The run fails (non-zero exit) when the newest export is older than `TAKEOUT_MAX_AGE_DAYS` (default 70), which means the schedule has lapsed and needs renewing.

## Usage

```bash
./backup-keep.sh                       # sources enabled in keep-backup.env
./backup-keep.sh --no-takeout          # gkeepapi only
./backup-keep.sh --no-gkeepapi         # takeout only
./backup-keep.sh --env /path/to/keep-backup.env
```

The exit status is non-zero if any enabled source fails or the Takeout export is stale.

## Schedule (cron, daily 2 AM)

```
0 2 * * * /Users/serenity/repos/keep-backup-script/backup-keep.sh >> /Users/serenity/backups/keep-backup/backup.log 2>&1
```

Only new Takeout exports are downloaded. On other days the Takeout source only runs the staleness check.
