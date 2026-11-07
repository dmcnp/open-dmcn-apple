#!/usr/bin/env bash
# Regenerates Tests/DMCNKitTests/Fixtures/go-sealed.json by sealing a message with the pinned
# open-dmcn's Go implementation (dev/go-fixture/swift_fixture_test.go).
#
# The generator imports open-dmcn internal packages, so it has to run from inside that module:
# it is copied into the checkout, run, and removed again, leaving the checkout as it was.
set -euo pipefail
cd "$(dirname "$0")/.."

src=$(dev/open-dmcn.sh path)
dest="$src/internal/core/message/swift_fixture_test.go"
out="$PWD/Tests/DMCNKitTests/Fixtures/go-sealed.json"

cp dev/go-fixture/swift_fixture_test.go "$dest"
trap 'rm -f "$dest"' EXIT
(cd "$src" && SWIFT_FIXTURE_OUT="$out" go test -tags swiftfixture -run TestWriteSwiftFixture -count=1 ./internal/core/message/)
echo "wrote $out"
