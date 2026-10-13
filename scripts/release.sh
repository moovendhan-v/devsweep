#!/bin/bash
# Builds a release zip and writes the Homebrew cask with the right version + sha256.
#
#   GITHUB_OWNER=<user> scripts/release.sh            # build + zip + cask (local only)
#   GITHUB_OWNER=<user> scripts/release.sh --publish  # also create the GitHub release and push the tap
#
# Bump the version first:  echo 1.0.1 > VERSION
set -euo pipefail
cd "$(dirname "$0")/.."

OWNER="${GITHUB_OWNER:?Set GITHUB_OWNER to the GitHub user or org that owns the devsweep repo}"
VERSION="$(cat VERSION)"
ZIP="build/DevSweep-$VERSION.zip"
TAP_DIR="${TAP_DIR:-homebrew-tap}"

./build_app.sh
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/DevSweep.app "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

mkdir -p "$TAP_DIR/Casks"
sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{SHA256}}/$SHA/g" -e "s/{{OWNER}}/$OWNER/g" \
    packaging/devsweep.rb.template > "$TAP_DIR/Casks/devsweep.rb"

echo
echo "Release zip : $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "sha256      : $SHA"
echo "Cask        : $TAP_DIR/Casks/devsweep.rb"

if [ "${1:-}" = "--publish" ]; then
    gh release create "v$VERSION" "$ZIP" --repo "$OWNER/devsweep" \
        --title "DevSweep $VERSION" --notes "Install: brew install --cask $OWNER/tap/devsweep"
    git -C "$TAP_DIR" add Casks/devsweep.rb
    git -C "$TAP_DIR" commit -m "devsweep $VERSION"
    git -C "$TAP_DIR" push
    echo "Published. Users install with: brew install --cask $OWNER/tap/devsweep"
else
    echo
    echo "Next: upload $ZIP to a GitHub release tagged v$VERSION in $OWNER/devsweep,"
    echo "push $TAP_DIR to $OWNER/homebrew-tap, then: brew install --cask $OWNER/tap/devsweep"
fi
