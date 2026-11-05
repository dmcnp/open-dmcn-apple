#!/usr/bin/env bash
# Writes App/Resources/ThirdPartyNotices.txt: the LICENSE and NOTICE of every package linked
# into the Apple app, at the versions Package.resolved pins. Apache 2.0 §4 requires a binary
# distribution to carry both, and AcknowledgementsView shows this file.
#
# SHIPPED lists what the app links on Apple platforms. It is not every resolved package:
# swift-asn1 is resolved only for swift-crypto's CryptoExtras, which DMCNKit does not use, and
# swift-crypto's BoringSSL is compiled only off Apple platforms (CryptoKit is used there).
# Adding a dependency to DMCNKit means adding it here.
#
#   dev/third-party-notices.sh          write the file
#   dev/third-party-notices.sh --check  fail if the committed file is stale
set -euo pipefail
cd "$(dirname "$0")/.."

SHIPPED=(swift-protobuf swift-crypto)
OUT=App/Resources/ThirdPartyNotices.txt

[ -d .build/checkouts ] || swift package resolve >/dev/null

version() {
  python3 -c 'import json,sys; pins=json.load(open("Package.resolved"))["pins"]; print(next(p["state"].get("version") or p["state"]["revision"] for p in pins if p["identity"]==sys.argv[1]))' "$1"
}

# The icon set is copied from the web client (dev/generate-icons.py), so no package carries its
# licence for us.
lucide_licence() {
  cat <<'LICENCE'


Lucide icons
------------------------------------------------------------------------

ISC License

Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2022 as part of Feather (MIT).
All other copyright (c) for Lucide are held by Lucide Contributors 2022.

Permission to use, copy, modify, and/or distribute this software for any purpose with or without
fee is hereby granted, provided that the above copyright notice and this permission notice appear
in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS
SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
OF THIS SOFTWARE.
LICENCE
}

render() {
  echo "Open-source software in this app"
  echo "================================"
  for pkg in "${SHIPPED[@]}"; do
    dir=.build/checkouts/$pkg
    echo
    echo
    echo "$pkg $(version "$pkg")"
    echo "------------------------------------------------------------------------"
    for f in NOTICE.txt NOTICE LICENSE.txt LICENSE; do
      if [ -f "$dir/$f" ]; then
        echo
        cat "$dir/$f"
      fi
    done
  done
  lucide_licence
}

if [ "${1:-}" = "--check" ]; then
  if ! diff -q <(render) "$OUT" >/dev/null; then
    echo "$OUT is stale: run make notices" >&2
    exit 1
  fi
  exit 0
fi
render > "$OUT"
echo "wrote $OUT"
