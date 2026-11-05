#!/bin/bash
set -euo pipefail
# V11 replaces the old sidebar/toolbar layout; run the current geometry and lifecycle suite.
exec bash "$(dirname "$0")/run-review-orbit.sh" "$@"
