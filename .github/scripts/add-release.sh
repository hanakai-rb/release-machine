#!/usr/bin/env bash
set -euo pipefail

# Usage: add-release.sh <gem-name> <tag> <tagger-email>
#
# Adds a release entry to RELEASES.md in the format:
# - YYYY-MM-DD - gem-name vX.Y.Z by @username
#
# Requires GITHUB_TOKEN environment variable for API access.

GEM_NAME="${1:?Gem name required}"
TAG="${2:?Tag required}"
TAGGER_EMAIL="${3:?Tagger email required}"
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN environment variable required}"

[ -f RELEASES.md ] || { echo "ERROR: RELEASES.md not found"; exit 1; }

DATE=$(date -u +"%Y-%m-%d")

# Look up GitHub username from email
GITHUB_USER=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/search/commits?q=author-email:${TAGGER_EMAIL}" |
  jq -r '.items[0].author.login // empty' 2>/dev/null || true)

# Refer to releaser by their GitHub username, or fallback to email prefix
if [ -n "$GITHUB_USER" ]; then
  DISPLAY_USER="@$GITHUB_USER"
else
  DISPLAY_USER=$(echo "$TAGGER_EMAIL" | cut -d'@' -f1)
fi

NEW_ENTRY="- ${DATE} - ${GEM_NAME} ${TAG} by ${DISPLAY_USER}"

# Insert before first list item, or append if none exist
if grep -q "^- " RELEASES.md; then
  # Use awk for portable insertion
  awk -v entry="$NEW_ENTRY" 'BEGIN{done=0} /^-/ && !done {print entry; done=1} {print}' RELEASES.md > RELEASES.md.tmp && mv RELEASES.md.tmp RELEASES.md
else
  echo "" >> RELEASES.md
  echo "$NEW_ENTRY" >> RELEASES.md
fi

echo -e "\n\nAdded release entry: $NEW_ENTRY"
