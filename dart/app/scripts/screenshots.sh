#!/usr/bin/env bash
# Thin back-compat wrapper around scripts/integration.sh. Kept so older
# docs / muscle memory (`scripts/screenshots.sh`) still work.
#
# Usage: scripts/screenshots.sh [<device-id>]
# See scripts/integration.sh for the real implementation.

set -euo pipefail
exec "$(dirname "$0")/integration.sh" screenshots "$@"
