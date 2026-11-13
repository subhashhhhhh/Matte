#!/bin/zsh
#
# Builds the release: one build for Apple silicon, one for Intel (each download stays small).
#
#   scripts/release.sh            build the DMGs and zips into dist/
#   scripts/release.sh --publish  also create the GitHub release, update
#                                 updates/latest.json and the Homebrew cask
#
# The version comes from MARKETING_VERSION in the project. Release notes for
# --publish are read from docs/releases/<version>.md (in git): the changelog
# only; the download and install instructions are appended here.
#
# Every build is signed with the "Matte Self-Signed" certificate in the login
# keychain (docs/signing.md). The in-app updater only installs a download signed
# with the same certificate as the running app, so it must never change.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
DIST="$ROOT/dist"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

PROJECT=Instagram.xcodeproj
xcodegen generate --quiet

setting() {
  xcodebuild -project "$PROJECT" -scheme Instagram -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' "/ $1 = / { print \$2; exit }"
}
VERSION=$(setting MARKETING_VERSION)
MIN_MACOS=$(setting MACOSX_DEPLOYMENT_TARGET)
[[ -n "$VERSION" ]] || { echo "Could not read MARKETING_VERSION" >&2; exit 1; }
# The updater compares versions as up to three numbers.
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || { echo "Version $VERSION isn't like 1.2 or 1.2.3" >&2; exit 1; }

IDENTITY="Matte Self-Signed"
REPO="subhashhhhhh/Matte"
TAP_REPO="subhashhhhhh/homebrew-matte"
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" \
  || { echo "The \"$IDENTITY\" signing identity isn't in the keychain (see docs/signing.md)" >&2; exit 1; }

NOTES="$ROOT/docs/releases/$VERSION.md"
if [[ "${1:-}" == "--publish" ]]; then
  # Everything --publish needs, checked before anything is built or published: a failure
  # halfway would leave a live release that the cask or the updater can't use.
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Commit your changes first" >&2; exit 1; }
  ! gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 || { echo "v$VERSION is already released; raise MARKETING_VERSION" >&2; exit 1; }
  [[ -f "$NOTES" ]] || { echo "Missing release notes: $NOTES" >&2; exit 1; }
  gh api "repos/$TAP_REPO/contents/Casks/matte.rb" --silent 2>/dev/null \
    || { echo "The Homebrew tap $TAP_REPO (with Casks/matte.rb) doesn't exist yet; start it from packaging/matte.rb" >&2; exit 1; }
fi

mkdir -p "$DIST"
BUILD_NUMBER=$(git rev-list --count HEAD)
echo "Matte $VERSION ($BUILD_NUMBER), macOS $MIN_MACOS+"

# arch   label (used in the file names and by the updater)
for pair in "arm64 AppleSilicon" "x86_64 Intel"; do
  arch=${pair%% *}
  label=${pair##* }
  derived="$BUILD/$arch"
  echo "\n==> Building $label ($arch)"
  xcodebuild -project "$PROJECT" -scheme Instagram -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
    ARCHS="$arch" ONLY_ACTIVE_ARCH=NO CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="" \
    OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    DEPLOYMENT_POSTPROCESSING=YES ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
    build -quiet

  app="$derived/Build/Products/Release/Matte.app"
  binary="$app/Contents/MacOS/Matte"

  # Each download must contain exactly the processor its name promises.
  [[ "$(lipo -archs "$binary")" == "$arch" ]] || { echo "Expected $arch, built: $(lipo -archs "$binary")" >&2; exit 1; }
  minos=$(vtool -show-build "$binary" | awk '/minos/ { print $2; exit }')
  [[ "$minos" == "$MIN_MACOS" ]] || { echo "Expected minimum macOS $MIN_MACOS, got $minos" >&2; exit 1; }
  codesign --verify --deep --strict "$app"
  [[ "$(codesign -dvv "$app" 2>&1)" == *"Authority=$IDENTITY"* ]] || { echo "$app isn't signed with $IDENTITY" >&2; exit 1; }

  # The updater downloads the zip; people download the disk image.
  zip="$DIST/Matte-$VERSION-$label.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"

  staging="$BUILD/dmg-$arch"
  mkdir -p "$staging"
  ditto "$app" "$staging/Matte.app"
  ln -s /Applications "$staging/Applications"
  dmg="$DIST/Matte-$VERSION-$label.dmg"
  rm -f "$dmg"
  hdiutil create -quiet -volname "Matte $VERSION" -srcfolder "$staging" -format UDZO -imagekey zlib-level=9 "$dmg"
  hdiutil verify -quiet "$dmg"
  echo "    $(basename "$dmg")  $(du -h "$dmg" | cut -f1 | xargs)"
  echo "    $(basename "$zip")  $(du -h "$zip" | cut -f1 | xargs)"
done

assets=(Matte-$VERSION-AppleSilicon.dmg Matte-$VERSION-Intel.dmg Matte-$VERSION-AppleSilicon.zip Matte-$VERSION-Intel.zip)
(cd "$DIST" && shasum -a 256 $assets | tee "SHA256SUMS-$VERSION.txt")

[[ "${1:-}" == "--publish" ]] || exit 0

notes="$NOTES"
body="$BUILD/body.md"
{
  cat "$notes"
  # The app shows the notes above this marker and drops the rest.
  print -- "\n<!-- matte:install -->\n\n---\n"
  print -- "### Install\n"
  print -- "**Homebrew** (recommended; no Gatekeeper prompt):"
  print -- '```bash\nbrew install --cask subhashhhhhh/matte/matte\n```\n'
  print -- "**Or download the disk image for your Mac:**"
  print -- "- Apple silicon (M1 and later): \`Matte-$VERSION-AppleSilicon.dmg\`"
  print -- "- Intel: \`Matte-$VERSION-Intel.dmg\`\n"
  print -- "Not sure which you have? Apple menu › **About This Mac** › **Chip** (Apple silicon) or **Processor** (Intel). Matte needs macOS $MIN_MACOS or later.\n"
  print -- "Matte isn't notarized by Apple, so the first time you open a downloaded copy macOS blocks it. Open **System Settings › Privacy & Security**, scroll to **Security** and click **Open Anyway**, or run:"
  print -- '```bash\nxattr -cr /Applications/Matte.app\n```\n'
  print -- "Matte updates itself from **Settings › About**. Checksums are in \`SHA256SUMS-$VERSION.txt\`."
} > "$body"

echo "\n==> Publishing v$VERSION"
gh release create "v$VERSION" "${assets[@]/#/$DIST/}" "$DIST/SHA256SUMS-$VERSION.txt" \
  --repo "$REPO" --target main --title "Matte $VERSION" --notes-file "$body"

echo "\n==> Updating updates/latest.json"
# The in-app updater reads this through raw.githubusercontent.com, which, unlike
# GitHub's API, isn't limited to 60 requests an hour per network.
mkdir -p "$ROOT/updates"
/usr/bin/python3 -I - "$VERSION" "$notes" "$DIST" "$ROOT/updates/latest.json" <<'PY'
import hashlib, json, os, sys
version, notes, dist, out = sys.argv[1:]
archives = {}
for label in ("AppleSilicon", "Intel"):
    name = f"Matte-{version}-{label}.zip"
    path = os.path.join(dist, name)
    with open(path, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    archives[label] = {"name": name, "size": os.path.getsize(path), "sha256": digest}
manifest = {"version": version, "tag": f"v{version}", "notes": open(notes).read().strip(), "archives": archives}
with open(out, "w") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
git -C "$ROOT" add updates/latest.json
git -C "$ROOT" commit -qm "Update manifest for $VERSION"
git -C "$ROOT" push -q
echo "    updates/latest.json → $VERSION"

echo "\n==> Updating the Homebrew cask"
sha_arm=$(shasum -a 256 "$DIST/Matte-$VERSION-AppleSilicon.dmg" | cut -d' ' -f1)
sha_intel=$(shasum -a 256 "$DIST/Matte-$VERSION-Intel.dmg" | cut -d' ' -f1)
tap="$BUILD/tap"
gh repo clone "$TAP_REPO" "$tap" -- --quiet --depth 1
sed -E -i '' \
  -e "s/^  version \".*\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 arm: +\"[0-9a-f]*\",/  sha256 arm:   \"$sha_arm\",/" \
  -e "s/^         intel: \"[0-9a-f]*\"/         intel: \"$sha_intel\"/" \
  "$tap/Casks/matte.rb"
grep -q "$sha_arm" "$tap/Casks/matte.rb" && grep -q "$sha_intel" "$tap/Casks/matte.rb" \
  || { echo "Couldn't update $tap/Casks/matte.rb" >&2; exit 1; }
git -C "$tap" commit -qam "Matte $VERSION"
git -C "$tap" push -q
echo "    $TAP_REPO → $VERSION"
