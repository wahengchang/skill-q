#!/usr/bin/env bash
# Compatibility wrapper: `bin/skill-q sync` owns synchronization now.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec "$ROOT/bin/skill-q" sync "$@"
