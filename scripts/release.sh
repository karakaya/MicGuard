#!/usr/bin/env bash
# Full local release: bump, build, sign, notarize, staple, DMG, GitHub release, cask bump.
# Mirrors the local-cloud-browser flow — everything runs on this machine, no CI secrets.
#
# Prerequisites (one-time, all in the login keychain):
#   - "Developer ID Application: Milan Karakaya (MQXW376WC6)" signing identity
#   - notarytool keychain profile: xcrun notarytool store-credentials notarytool
#   - gh CLI authenticated
#
# Usage: scripts/release.sh <version>   e.g. scripts/release.sh 1.3
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "usage: scripts/release.sh <version>   (e.g. 1.3 or 1.3.1)" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
PLIST="MicGuard/App/Info.plist"
IDENTITY="Developer ID Application: Milan Karakaya (MQXW376WC6)"
DMG="MicGuard-${VERSION}.dmg"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

if ! git diff-index --quiet HEAD --; then
  echo "error: working tree is dirty — commit or stash first" >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "error: tag v$VERSION already exists" >&2
  exit 1
fi

echo "==> Running tests"
swift test

echo "==> Bumping version to $VERSION"
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
# Keep project.yml in sync (Info.plist is the source of truth, but avoid stale values)
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $BUILD/" project.yml

echo "==> Building universal Release app"
xcodegen generate
xcodebuild -project MicGuard.xcodeproj -scheme MicGuard -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  build | tail -2
APP="$BUILD_DIR/DerivedData/Build/Products/Release/MicGuard.app"

echo "==> Signing app"
codesign --force --options runtime --timestamp \
  --entitlements MicGuard/App/MicGuard.entitlements \
  --sign "$IDENTITY" "$APP"

echo "==> Notarizing and stapling app"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/MicGuard.zip"
xcrun notarytool submit "$BUILD_DIR/MicGuard.zip" --keychain-profile notarytool --wait
xcrun stapler staple "$APP"

echo "==> Building, signing, notarizing DMG"
STAGING="$BUILD_DIR/staging"
mkdir "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "MicGuard" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
codesign --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile notarytool --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "==> Committing, tagging, pushing"
git add "$PLIST" project.yml MicGuard.xcodeproj
git commit -m "Release v$VERSION"
git tag "v$VERSION"
git push origin HEAD "v$VERSION"

echo "==> Creating GitHub release"
gh release create "v$VERSION" "$DMG" \
  --target "$(git rev-parse HEAD)" \
  --title "MicGuard $VERSION" \
  --latest --generate-notes
rm "$DMG"

echo "==> Bumping Homebrew cask"
if ! gh workflow run bump.yml -R milan0x/homebrew-tap; then
  echo "warning: cask bump trigger failed — the tap's 6-hourly cron will pick it up." >&2
fi

echo "Released v$VERSION."
