#!/bin/sh
# Builds the app, publishes a GitHub release and updates the Homebrew cask.
# Usage: scripts/publish.sh <release-notes-file>
set -e
notes=${1:?usage: scripts/publish.sh <release-notes-file>}
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

make release
sha=$(cut -d' ' -f1 build/Clawdmeter.zip.sha256)
gh release create "v$version" build/Clawdmeter.zip build/Clawdmeter.zip.sha256 --title "v$version" --notes-file "$notes"

sed -e "s/@VERSION@/$version/" -e "s/@SHA256@/$sha/" packaging/clawdmeter.rb > build/clawdmeter.rb
current=$(gh api repos/tangheng05/homebrew-tap/contents/Casks/clawdmeter.rb --jq .sha 2>/dev/null || true)
gh api -X PUT repos/tangheng05/homebrew-tap/contents/Casks/clawdmeter.rb \
    -f message="clawdmeter $version" -f content="$(base64 -i build/clawdmeter.rb)" ${current:+-f sha="$current"} >/dev/null
echo "Published v$version"
