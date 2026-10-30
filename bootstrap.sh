#!/bin/sh
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYEXE=$(command -v python3 || command -v python)
if [ -z "$PYEXE" ]; then
    echo "Python not found" >&2
    exit 1
fi
# Start server.py in background (detached), then exit so Stash considers the plugin loaded
nohup "$PYEXE" "$DIR/server.py" >/dev/null 2>&1 &
exit 0
