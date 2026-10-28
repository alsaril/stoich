#!/bin/bash
# Release the mod: checks, tests, builds dist/<name>_<version>.zip from the
# committed code and tags v<version>. Pushing the tag is left to you.
#
#   ./release.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
MOD=stoich
cd "$ROOT"

die() { echo "release: $*" >&2; exit 1; }

read -r NAME VERSION < <(python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["name"], d["version"])' "$MOD/info.json")
TAG="v$VERSION"
ZIP="dist/${NAME}_${VERSION}.zip"
echo "release: $NAME $VERSION"

[ -z "$(git status --porcelain)" ] || die "uncommitted changes (commit or stash them first)"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
grep -qx "Version: $VERSION" "$MOD/changelog.txt" 2>/dev/null || die "$MOD/changelog.txt has no entry for $VERSION"

(cd "$MOD" && lua tests/run.lua) || die "tests failed"

mkdir -p dist
rm -f "$ZIP"
git archive --format=zip --prefix="${NAME}_${VERSION}/" -o "$ZIP" "HEAD:$MOD" -- . ':(exclude)tests'
unzip -l "$ZIP" | grep -q "/tests/" && die "tests/ ended up in $ZIP"

git tag -a "$TAG" -m "$NAME $VERSION"
echo "release: built $ZIP ($(unzip -l "$ZIP" | tail -1 | awk '{print $2}') files), tagged $TAG"
echo "release: to publish the tag: git push origin $TAG"
