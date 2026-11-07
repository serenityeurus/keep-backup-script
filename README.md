# Google Keep Backup Script

A simple shell script that exports all your Google Keep notes into plain-text files, organized by their labels.

## Prerequisites

- **gog** – The Google Workspace CLI  
  Install: `brew install steipete/tap/gogcli`
- **jq** – JSON processor  
  Install: `brew install jq` (already installed at /usr/bin/jq)

## Setup

1. Authenticate `gog` for Google Keep:

```bash
gog auth credentials /path/to/client_secret.json
gog auth add your@email.com --services keep
```

## Usage

```bash
chmod +x backup_keep.sh
./backup_keep.sh
```

All notes will be exported to `~/keep-backup/`, with each label creating a nested directory structure. Unlabeled notes go into `Unlabeled/`.

## Output Format

Each note becomes a `.txt` file:

```
Title: <note title>

<note body text>
```

## Automation

Add to crontab (daily at 2 AM):

```
0 2 * * * /path/to/keep-backup-script/backup_keep.sh
```