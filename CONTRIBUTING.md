# Contributing

What the repository is, and how to run it, is in the [README](README.md). How the code fits
together is in [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md). The protocol itself is open-dmcn's
`SPEC_CORE.md` and its extension documents; where this repository and open-dmcn disagree,
open-dmcn is right.

## Working on the code

| You changed | Check it with |
|---|---|
| The kit, or `App/AppState` | `make test`, on Linux or macOS |
| Views in `App/Shared` | Xcode: the previews, or Run and **Explore with sample mail** (or the `-sampleMail` launch argument). SwiftUI doesn't exist on Linux, so CI's `app` job is the only other check. |
| The project or its settings | Edit it in Xcode, like any iOS project. Nothing generates it. |

`make test` also runs the formatter's check, so run `make format` before you push.

**Keep logic out of the views.** Anything that decides what a person sees belongs in the kit or
in `App/AppState`, where a test can reach it. A view renders what it's given.

**Adding a file to `App/AppState`?** Add it to the app target in Xcode as well. SwiftPM picks it
up on its own; the Xcode project doesn't.

**Matching the web client.** The design tokens in `App/Shared/DesignSystem/Tokens.swift` are the
web's, value for value. Change them there first, then here. The icons are generated: run
`make icons`, don't edit them. When a feature lands or changes on either side, update
[docs/PARITY-WITH-WEB.md](docs/PARITY-WITH-WEB.md).

**Adding a state to the inbox?** Add it to `SampleAccount`, so people can see it and tests can
reach it.

## Rules that are easy to break

Most of these protect interoperability. The app has to agree byte for byte with Go and the
browser, so some code here looks stranger than it needs to. If it does, there's usually a
comment saying why, and a test that fails if you tidy it.

**`proto/` is a mirror.** It's byte-identical to open-dmcn's `proto/` at `OPEN_DMCN_VERSION`,
checked by `make proto-sync-check`. To change the schema: change it in open-dmcn, tag it, move
the pin, and run `make proto-sync`. Never hand-edit `proto/` or `Sources/DMCNKit/Proto/`.

**Signatures are checked by re-marshaling.** Go, the browser and DMCNKit all verify a signature
over `Canonical.marshal` of what they parsed, so a one-byte encoding difference breaks interop
silently. Every encoding the kit produces is pinned by a known-answer vector shared with Go and
the browser (`KEMVectorTests`, `ParityVectorTests`). A new signed structure gets a vector, with
the same constant asserted on the other sides, before it's used.

**Match Go's fixed-width fields.** Go holds several ids and keys as fixed arrays and re-marshals
from them, so a field Go always emits must be emitted here too: `reply_to_id` as 16 zero bytes
for a non-reply, and the envelope's legacy payload nonce, tag and ratchet key as zeros
(`fillGoFixedWidthFields`). Omitting one fails the signature at the relay. Reading is the same
in reverse: verify over the header as Go parsed it (`asParsedByGo`), not as it arrived.

**Owner-signed bytes are an allowlist.** `ownerSignableBytes` builds a fresh record from the
owner-owned fields, as Go does. Never clear fields on a copy instead: unknown fields would leak
into the signed bytes.

**The reader checks gate what is shown.** A verified header signature proves only internal
consistency. A sender address is attribution only after `ReaderChecks.senderBinding` matches. On
a mismatch, the body and snippet are withheld and the address is never shown as who the message
is from; a warning may name it as the claim that failed. When the key matches but the directory
disowns the record, the address isn't attribution either, but the text can be read behind the
gate: that failure can be temporary (SPEC_CORE §3). An unresolved sender is unverified, never
rejected.

**Keys never leave `AccountKeys`.** The kit asks for `sign` and `sharedSecret`, never private
bytes. No private key material in logs, errors or `description`.

**No product code here.** This repository implements only what open-dmcn publishes: the core
protocol and its extension documents. Product features (device pairing, device enrolment and
approval, billing, push registration, anything in a product's own schema) live in that product's
build, in its own repository, and plug in from outside through the kit, which runs an outside op
over its relay connection without knowing the op's schema. Never copy product schema, op names
or behaviour in here, not even as a stub or a comment: a public repository is permanent.

**The deployment seam.** The reference app and any other build of these sources differ in
`App/Config/Deployment.xcconfig` and `App/Shared/Deployment.swift`, plus whatever that build adds
from outside through the kit. A difference belongs in the seam only if both answers are correct;
one that is merely older on one side is drift. The reference app names the server it is signed
in to, never a product.

**Dependencies are a licensing act.** Apache 2.0 or similarly permissive only; no GPL or LGPL
(static linking on iOS). A new package linked into the app goes into `SHIPPED` in
`dev/third-party-notices.sh`, and `make notices` regenerates what the Acknowledgements screen
shows. `make test` fails while that file is stale.

**User-facing copy.** Plain words, no protocol mechanics, no em-dashes. A warning names how to
check (phone, text) and never blames the reader.
