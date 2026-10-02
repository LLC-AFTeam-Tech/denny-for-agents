#!/bin/bash
# Builds a release and publishes it on GitHub, so every installed Denny offers "Update".
# Usage: scripts/release.sh 0.2.0 "What's new"   (needs `gh auth login` once)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: scripts/release.sh <version> [notes]}"
NOTES="${2:-}"

VERSION="$VERSION" scripts/build-app.sh
SHA=$(shasum -a 256 dist/DennyForAgents.zip | awk '{print $1}')

# The app refuses an update without this line in the release notes.
printf '%s\n\nSHA-256: %s\n' "$NOTES" "$SHA" > dist/release-notes.md
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
    packaging/homebrew/denny-for-agents.rb

gh release create "v$VERSION" dist/DennyForAgents.zip --title "v$VERSION" --notes-file dist/release-notes.md
echo "Released v$VERSION (SHA-256 $SHA). Copy packaging/homebrew/denny-for-agents.rb to the tap repo."
