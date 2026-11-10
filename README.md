# Google Keep Backup Script

Backs up a **personal** Google Keep account into text files organized by Keep label. It pulls from two independent sources, and each one can be turned on or off:

| Source | How | Freshness | Labels | Risk |
|---|---|---|---|---|
| `gkeepapi` | Unofficial [gkeepapi](https://github.com/kiwiz/gkeepapi) library (Keep's private API) | Every run (e.g. daily) | Yes | Can break when Google changes the private API; needs a master token |
| `takeout` | Newest scheduled Google Takeout export in Google Drive, fetched with `gog` | Every 2 months | Yes | Official and stable; the schedule has to be renewed yearly |

Each source writes its own tree, so a failure in one never touches the other:

```
~/keep-backup/
  gkeepapi/<Label>/<Title>__<createdUsec>.txt
  takeout/<Label>/<Title>__<createdUsec>.txt
  .state/last_run.json      # {"finishedAt", "gkeepapi": ok|failed|disabled, "takeout": ...}
  .state/takeout_last       # newest Takeout export already processed
```

A note with several labels is written into each label folder. Notes with no labels go to `_Unlabeled/`, and trashed notes are skipped. Each tree is built in a staging directory and swapped into place only after every file is written. If a run fails, the previous backup stays as it was.

Note file format:

```
Title: Groceries
Labels: Home, Shopping
Created: 2023-11-14T22:13:20Z
Edited: 2023-11-14T22:21:40Z
Pinned: true  Archived: false  Color: DEFAULT

[x] Milk
[ ] Eggs
```

## Setup

1. Dependencies: `gog`, `jq`, `unzip`, and `uv` (for the Python venv).
2. Config:
   ```bash
   cp keep-backup.conf.example keep-backup.conf   # set KEEP_EMAIL, enable/disable sources
   ```
3. **gkeepapi source**
   ```bash
   uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python gkeepapi
   .venv/bin/python setup_master_token.py you@gmail.com
   ```
   `setup_master_token.py` prompts for the `oauth_token` cookie (instructions are in the script), exchanges it for a master token, and stores that token in the macOS Keychain. The token is never printed, never written to disk, and never passed as a command argument. At backup time it goes from the Keychain to the script over stdin.
4. **Takeout source**
   - At <https://takeout.google.com>: *Deselect all* → select **Keep** → Delivery method **Add to Drive** → Frequency **Export every 2 months for 1 year** → File type `.zip` → Create export.
   - Give `gog` read-only Drive access to that account: `gog auth add you@gmail.com --services drive --readonly`
   - The run fails (non-zero exit) when the newest export is older than `TAKEOUT_MAX_AGE_DAYS` (default 70), which means the schedule has lapsed and needs renewing.

## Usage

```bash
./backup_keep.sh                       # sources enabled in keep-backup.conf
./backup_keep.sh --no-takeout          # gkeepapi only
./backup_keep.sh --no-gkeepapi         # takeout only
./backup_keep.sh --config /path/to/conf
```

The exit status is non-zero if any enabled source fails or the Takeout export is stale.

## Schedule (cron, daily 2 AM)

```
0 2 * * * /Users/serenity/repos/keep-backup-script/backup_keep.sh >> /Users/serenity/keep-backup/backup.log 2>&1
```

Only new Takeout exports are downloaded. On other days the Takeout source only runs the staleness check.
