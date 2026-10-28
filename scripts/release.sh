#!/bin/zsh
# Baut ein unsigniertes IPA, lädt es als GitHub-Release hoch und trägt die Version in die
# SideStore-Quelle (sidestore/source.json) ein. SideStore signiert beim Installieren selbst.
#
#   scripts/release.sh 1.1 "Was ist neu …"
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?Version angeben, z. B. 1.1}
NOTES=${2:-"Babel $VERSION"}
REPO=MosesCommitsFraud/Babel
BUILD=$(git rev-list --count HEAD)
OUT=build/release
IPA=build/Babel-$VERSION.ipa

# Version ins Projekt schreiben
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \"[^\"]+\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
xcodegen generate >/dev/null

rm -rf "$OUT"
xcodebuild -project Babel.xcodeproj -scheme Babel -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUT/dd" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build | tail -1

mkdir -p "$OUT/Payload"
cp -R "$OUT/dd/Build/Products/Release-iphoneos/Babel.app" "$OUT/Payload/"
(cd "$OUT" && zip -qry ../Babel-$VERSION.ipa Payload)

SIZE=$(stat -f %z "$IPA")
URL="https://github.com/$REPO/releases/download/v$VERSION/Babel-$VERSION.ipa"

# Neue Version oben in die Quelle eintragen
python3 - "$VERSION" "$BUILD" "$SIZE" "$URL" "$NOTES" <<'EOF'
import json, sys, datetime
version, build, size, url, notes = sys.argv[1:]
p = "sidestore/source.json"
src = json.load(open(p))
app = src["apps"][0]
app["versions"] = [v for v in app["versions"] if v["version"] != version]
app["versions"].insert(0, {
    "version": version, "buildVersion": build,
    "date": datetime.date.today().isoformat(),
    "localizedDescription": notes,
    "downloadURL": url, "size": int(size), "minOSVersion": "26.0",
})
json.dump(src, open(p, "w"), ensure_ascii=False, indent=2)
EOF

gh release create "v$VERSION" "$IPA" -R "$REPO" --title "Babel $VERSION" --notes "$NOTES"
git add project.yml Babel.xcodeproj sidestore/source.json
git commit -m "Release $VERSION"
git push
echo "Fertig: $URL"
