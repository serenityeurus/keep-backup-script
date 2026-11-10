#!/usr/bin/env python3
"""One-time: exchange a browser oauth_token for a Keep master token and store it
in the macOS Keychain. Nothing is printed or written to disk.

Usage: setup_master_token.py <email> [keychain-service]

Get the oauth_token:
  1. Open https://accounts.google.com/EmbeddedSetup in a browser and sign in.
  2. Click "I agree" (the page may then spin forever; that is fine).
  3. DevTools -> Application -> Cookies -> accounts.google.com -> copy the
     value of the "oauth_token" cookie (starts with "oauth2_4/").
"""
import getpass
import subprocess
import sys
import uuid

import gpsoauth


def main():
    if len(sys.argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    email = sys.argv[1]
    service = sys.argv[2] if len(sys.argv) == 3 else "keep-backup-master-token"

    oauth_token = getpass.getpass("oauth_token cookie value (hidden): ").strip()
    android_id = uuid.uuid4().hex[:16]
    resp = gpsoauth.exchange_token(email, oauth_token, android_id)
    master = resp.get("Token")
    if not master:
        print(f"error: token exchange failed: {resp.get('Error', 'unknown error')}", file=sys.stderr)
        return 1

    # Feed the command to `security -i` on stdin so the token never appears in
    # a process argument list. -U updates an existing item.
    cmd = f'add-generic-password -U -s "{service}" -a "{email}" -w "{master}"\n'
    subprocess.run(["security", "-i"], input=cmd, text=True, check=True,
                   stdout=subprocess.DEVNULL)
    print(f"Stored master token in Keychain (service={service}, account={email}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
