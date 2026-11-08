#!/bin/sh
# Cross-platform dispatcher: stash resolves exec[0] via PATH; on Windows this
# hits System32\cmd.exe (bootstrap.bat), on Linux/macOS it is not in PATH, so
# stash falls back to THIS file -> bootstrap.sh. Args are ignored on purpose.
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$DIR/bootstrap.sh" "$@"
