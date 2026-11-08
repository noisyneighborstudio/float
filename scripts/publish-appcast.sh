#!/bin/zsh
# semantic-release publish: EdDSA-sign the zip, upload it to the release, then push appcast.xml
# to the `appcasts` branch. Zip first, so the enclosure resolves before any client reads the appcast.
set -euo pipefail
cd "${0:A:h}/.."
version=${1:?usage: publish-appcast.sh <version> <git-tag>}
tag=${2:?git tag required}
build=${FLOAT_BUILD_NUMBER:?FLOAT_BUILD_NUMBER required}
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY required}"
export GH_TOKEN=${GITHUB_TOKEN:?GITHUB_TOKEN required}
source ./updates.env

artifact=dist/Float-$version.zip
[[ -f $artifact ]] || { echo "✗ missing $artifact; prepare did not run" >&2; exit 1; }

# key via stdin: never on disk, never in argv
signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | vendor/Sparkle-$SPARKLE_VERSION/bin/sign_update -f - -p $artifact)
[[ ${#signature} -eq 88 ]] || { echo "✗ unexpected signature from sign_update" >&2; exit 1; }
# a key that doesn't match the app's SUPublicEDKey makes every client reject the update
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' build/Float.app/Contents/Info.plist)
swift scripts/verify-signature.swift "$public_key" "$signature" $artifact \
  || { echo "✗ SPARKLE_PRIVATE_KEY does not match SUPublicEDKey" >&2; exit 1; }

gh release upload $tag -R $FLOAT_UPDATES_REPO --clobber $artifact
url=https://github.com/$FLOAT_UPDATES_REPO/releases/download/$tag/${artifact:t}
# a fresh asset can 504 for minutes; wait until it downloads whole three times running
size=$(stat -f %z $artifact) served=0 got=""
for _ in {1..60}; do
  got=$(curl -sL -o /dev/null -w '%{http_code} %{size_download}' $url || true)
  if [[ $got == "200 $size" ]]; then served=$((served + 1)); (( served >= 3 )) && break; else served=0; fi
  sleep 20
done
(( served >= 3 )) || { echo "✗ $url still not downloadable after 20 min (last: $got)" >&2; exit 1; }

# token as a header from the environment: out of argv, out of .git/config
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' $GH_TOKEN | base64)"
remote=https://github.com/$FLOAT_UPDATES_REPO.git
pub=$(mktemp -d)
if [[ -n $(git ls-remote --heads $remote appcasts) ]]; then
  git clone --quiet --depth 1 --branch appcasts $remote $pub
else
  git init --quiet -b appcasts $pub
fi
published=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
cat > $pub/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Float Updates</title><item>
<title>Float $version</title><pubDate>$published</pubDate>
<link>https://github.com/$FLOAT_UPDATES_REPO/releases/latest</link>
<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
<enclosure url="$url" sparkle:version="$build" sparkle:shortVersionString="$version" length="$size" type="application/octet-stream" sparkle:edSignature="$signature"/>
</item></channel></rss>
XML
git -C $pub add -- appcast.xml
git -C $pub -c user.name=github-actions -c user.email=github-actions@github.com commit --quiet -m "Publish $version"
git -C $pub push --quiet $remote HEAD:appcasts
rm -rf $pub
echo "✓ Published $version → $FLOAT_FEED_URL"
