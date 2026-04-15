#!/usr/bin/env bash
# Thin wrapper — delegates to Fastlane.
# Usage:
#   ./scripts/distribute.sh                     # dev flavor → Firebase App Distribution
#   ./scripts/distribute.sh beta                # prod → TestFlight + Play internal
#   ./scripts/distribute.sh release             # prod → App Store + Play production
#   ./scripts/distribute.sh dev_distribute notes:"my notes"  # with release notes
set -euo pipefail

LANE="${1:-dev_distribute}"
shift || true  # remaining args passed through to fastlane

cd "$(dirname "$0")/../dart/app"
bundle exec fastlane "$LANE" "$@"
