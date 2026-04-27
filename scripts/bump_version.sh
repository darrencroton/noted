#!/usr/bin/env bash
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$REPO/Noted/Sources/Noted/Info.plist"



# Read current version
CURRENT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

if [[ -z "$1" ]]; then
  echo "Usage: $0 <major|minor|patch|x.y.z>"
  echo 'scripts/bump_version.sh patch    # patch: 0.1.0 -> 0.1.1'
  echo 'scripts/bump_version.sh minor    # minor: 0.1.0 -> 0.2.0'
  echo 'scripts/bump_version.sh major    # major: 0.1.0 -> 1.0.0'
  echo 'scripts/bump_version.sh 0.2.0    # explicit'
  echo "Current version $CURRENT"
  exit 0
fi

# Determine new version
case "$1" in
  major) NEW="$((MAJOR+1)).0.0" ;;
  minor) NEW="$MAJOR.$((MINOR+1)).0" ;;
  patch) NEW="$MAJOR.$MINOR.$((PATCH+1))" ;;
  *)     NEW="$1" ;;
esac

echo "$CURRENT -> $NEW"

# Update Info.plist
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $NEW" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $NEW"            "$PLIST"
