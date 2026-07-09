#!/usr/bin/env bash
# Build + serve the local UCB NY shows website, refreshing every hour.
# First run creates the venv and installs deps.
#
#   bash serve-local.sh            # serve at http://localhost:8086, refresh hourly
#   PORT=9000 bash serve-local.sh  # custom port
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -d .venv ]]; then
  echo "==> Creating virtualenv + installing deps…"
  python3 -m venv .venv
  ./.venv/bin/pip install -q -r requirements.txt
fi

exec ./.venv/bin/python build_local.py --serve --loop --open --port "${PORT:-8086}"
