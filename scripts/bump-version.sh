#!/usr/bin/env bash
set -euo pipefail

# Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in the Xcode project.
# Usage:
#   ./scripts/bump-version.sh                # Auto-bump minor (0.15.0 -> 0.16.0)
#                                            # or, if current has -sb.N suffix,
#                                            # bumps suffix (0.64.7-sb.1 -> 0.64.7-sb.2)
#   ./scripts/bump-version.sh 0.16.0         # Set specific version
#   ./scripts/bump-version.sh 0.64.7-sb.1    # Set specific fork-suffixed version
#   ./scripts/bump-version.sh patch          # Bump patch (0.15.0 -> 0.15.1) or
#                                            # bump suffix (0.64.7-sb.1 -> 0.64.7-sb.2)
#   ./scripts/bump-version.sh minor          # Bump minor; if fork-suffixed, reset suffix to -sb.1
#   ./scripts/bump-version.sh major          # Bump major; if fork-suffixed, reset suffix to -sb.1
#
# Fork-suffix convention: "-sb.N" identifies a sbourass-fork build layered on top of upstream
# version X.Y.Z. After an upstream sync, set the new base via explicit version
# (e.g. 0.65.0-sb.1) — `minor`/`major` shortcuts assume the upstream-base bump should reset the
# fork iteration counter.

PROJECT_FILE="cmux.xcodeproj/project.pbxproj"

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Error: $PROJECT_FILE not found. Run from repo root." >&2
  exit 1
fi

# Accept either plain X.Y.Z or X.Y.Z-sb.N
VERSION_RE='^([0-9]+)\.([0-9]+)\.([0-9]+)(-sb\.([0-9]+))?$'

# Get current versions
CURRENT_MARKETING=$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
MIN_BUILD="$CURRENT_BUILD"

echo "Current: MARKETING_VERSION=$CURRENT_MARKETING, CURRENT_PROJECT_VERSION=$CURRENT_BUILD"

# Parse current marketing version, with optional fork suffix
if ! [[ "$CURRENT_MARKETING" =~ $VERSION_RE ]]; then
  echo "Error: cannot parse MARKETING_VERSION='$CURRENT_MARKETING' (expected X.Y.Z or X.Y.Z-sb.N)" >&2
  exit 1
fi
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"
HAS_SUFFIX=0
SUFFIX_NUM=0
if [[ -n "${BASH_REMATCH[4]:-}" ]]; then
  HAS_SUFFIX=1
  SUFFIX_NUM="${BASH_REMATCH[5]}"
fi

# Keep Sparkle build numbers monotonic with the latest published stable appcast.
# If local build numbers have fallen behind due merges/rebases, auto-correct upward.
LATEST_RELEASE_BUILD="$(
  curl -fsSL --max-time 8 https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml 2>/dev/null \
    | sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' \
    | head -n1
)"
if [[ "$LATEST_RELEASE_BUILD" =~ ^[0-9]+$ ]]; then
  if (( LATEST_RELEASE_BUILD > MIN_BUILD )); then
    MIN_BUILD="$LATEST_RELEASE_BUILD"
  fi
  echo "Latest release appcast build: $LATEST_RELEASE_BUILD"
else
  echo "Latest release appcast build: unavailable (continuing with local build baseline)"
fi

# Determine new marketing version
if [[ $# -eq 0 ]]; then
  if (( HAS_SUFFIX )); then
    NEW_MARKETING="$MAJOR.$MINOR.$PATCH-sb.$((SUFFIX_NUM + 1))"
  else
    NEW_MARKETING="$MAJOR.$((MINOR + 1)).0"
  fi
elif [[ "$1" == "minor" ]]; then
  if (( HAS_SUFFIX )); then
    NEW_MARKETING="$MAJOR.$((MINOR + 1)).0-sb.1"
  else
    NEW_MARKETING="$MAJOR.$((MINOR + 1)).0"
  fi
elif [[ "$1" == "patch" ]]; then
  if (( HAS_SUFFIX )); then
    NEW_MARKETING="$MAJOR.$MINOR.$PATCH-sb.$((SUFFIX_NUM + 1))"
  else
    NEW_MARKETING="$MAJOR.$MINOR.$((PATCH + 1))"
  fi
elif [[ "$1" == "major" ]]; then
  if (( HAS_SUFFIX )); then
    NEW_MARKETING="$((MAJOR + 1)).0.0-sb.1"
  else
    NEW_MARKETING="$((MAJOR + 1)).0.0"
  fi
elif [[ "$1" =~ $VERSION_RE ]]; then
  NEW_MARKETING="$1"
else
  echo "Usage: $0 [version|minor|patch|major]" >&2
  echo "  version: X.Y.Z or X.Y.Z-sb.N (e.g., 0.16.0 or 0.64.7-sb.1)" >&2
  echo "  minor:   bump minor (resets fork suffix to -sb.1 when present)" >&2
  echo "  patch:   bump patch (or fork suffix counter when present)" >&2
  echo "  major:   bump major (resets fork suffix to -sb.1 when present)" >&2
  exit 1
fi

# Always increment build number, and never go backwards relative to published releases.
NEW_BUILD=$((MIN_BUILD + 1))

echo "New:     MARKETING_VERSION=$NEW_MARKETING, CURRENT_PROJECT_VERSION=$NEW_BUILD"

# Update project file
sed -i '' "s/MARKETING_VERSION = $CURRENT_MARKETING;/MARKETING_VERSION = $NEW_MARKETING;/g" "$PROJECT_FILE"
sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PROJECT_FILE"

# Verify
UPDATED_MARKETING=$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
UPDATED_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')

if [[ "$UPDATED_MARKETING" != "$NEW_MARKETING" ]] || [[ "$UPDATED_BUILD" != "$NEW_BUILD" ]]; then
  echo "Error: Version update failed!" >&2
  exit 1
fi

echo "Updated $PROJECT_FILE successfully."
