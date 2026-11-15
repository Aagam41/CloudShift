#!/usr/bin/env bash
# Interactive GlusterFS storage preparation for one CloudShift controller.
# Usage: ./storage-manager.sh controller01
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <controller>" >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$HERE/storage_manager.py" "$1"
