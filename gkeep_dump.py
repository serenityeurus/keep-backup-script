#!/usr/bin/env python3
"""Dump all Google Keep notes via gkeepapi as JSON in the Takeout note schema.

Usage: gkeep_dump.py <email>   (master token is read from stdin, never argv/env)

Output: JSON array on stdout. Each element uses the same field names as a
Google Takeout Keep note so one renderer handles both sources:
  title, textContent, listContent[{text,isChecked,isIndented}], labels[{name}],
  isTrashed, isArchived, isPinned, color, createdTimestampUsec,
  userEditedTimestampUsec, id

Read-only: notes are downloaded and never modified, so sync never pushes changes.
"""
import json
import sys


def usec(dt):
    return int(dt.timestamp() * 1_000_000) if dt else 0


def main():
    if len(sys.argv) != 2:
        print("usage: gkeep_dump.py <email>  (master token on stdin)", file=sys.stderr)
        return 2
    email = sys.argv[1]
    token = sys.stdin.readline().strip()
    if not token:
        print("error: no master token on stdin", file=sys.stderr)
        return 2

    import gkeepapi
    from gkeepapi import node as knode

    keep = gkeepapi.Keep()
    keep.authenticate(email, token)

    notes = []
    for n in keep.all():
        if n.deleted:
            continue
        rec = {
            "id": n.id,
            "title": n.title or "",
            "labels": sorted(({"name": l.name} for l in n.labels.all()), key=lambda x: x["name"]),
            "isTrashed": bool(n.trashed),
            "isArchived": bool(n.archived),
            "isPinned": bool(n.pinned),
            "color": n.color.value if n.color else "DEFAULT",
            "createdTimestampUsec": usec(n.timestamps.created),
            "userEditedTimestampUsec": usec(n.timestamps.edited or n.timestamps.updated),
        }
        if isinstance(n, knode.List):
            rec["listContent"] = [
                {"text": i.text or "", "isChecked": bool(i.checked), "isIndented": bool(i.indented)}
                for i in n.items
                if not i.deleted
            ]
        else:
            rec["textContent"] = n.text or ""
        notes.append(rec)

    json.dump(notes, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
