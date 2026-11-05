#!/bin/bash
# Headless, synthetic inputs only. No app self-test, window server, TCC or accounts.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v
bash tests/run-recent-records.sh
bash outputs/DuckIsland/Tests/run-save-reliability.sh
zsh outputs/DuckIsland/tests/meeting/run.sh
