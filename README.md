# open-dmcn-apple

A native client for the **DMCN Protocol (DMCNP)** on Apple platforms: the Swift counterpart
of the browser client in [open-dmcn](https://github.com/dmcnp/open-dmcn). It is two things:

- **`DMCNKit`**, a Swift package with no UI: the core schema generated from open-dmcn's
  `proto/`, the message crypto (CEK wrap, split header/body seal, size-class padding), record
  signing bytes, the reader checks SPEC_CORE §3 requires, and a client for a DMCN web host's
  HTTP API. It builds and tests on Linux as well as on Apple platforms.
- **The reference app** (`App/`), a SwiftUI app for iPhone and iPad on top of the kit. macOS,
  and later watchOS, are further targets over the same sources, not a separate codebase.

## Try it

Open `App/OpenDMCN.xcodeproj` in Xcode 26 or later and press Run. On the first screen, choose
**Explore with sample mail**. You get an in-memory account with mail in every state, plus labels,
folders, contacts, Sent mail and a draft, opened and checked by the same code as real mail. It
needs no account or server, and it's in debug builds only. The SwiftUI previews use it too. The
button only shows on a device with no accounts: with some, add `-sampleMail` to the scheme's
launch arguments, which opens the sample mail and leaves those accounts alone.

To learn how the code fits together, read [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md). Before
changing anything, read [CONTRIBUTING.md](CONTRIBUTING.md).

The protocol itself is specified in open-dmcn (`SPEC_CORE.md` and the extension documents).
Where this repository and open-dmcn disagree, open-dmcn is right.

## Status

The app is a working mail client against a `dmcnd` web host: bring your keys over or create an
account, then read, search, write, organise and manage contacts and settings. It aims to match
the web client, and [docs/PARITY-WITH-WEB.md](docs/PARITY-WITH-WEB.md) says exactly where it does.

Interoperability is tested three ways: known-answer vectors shared with Go and the browser,
fixtures made by the real browser code, and live tests against a running `dmcnd`
(see [Build and test](#build-and-test)).

The app talks to one web host per account. Reaching relays directly is planned, not built.

## How the app reaches the network

Through a **web host**: the `/api/v1` HTTP surface open-dmcn's `dmcnd` serves for its browser
client, which the hosted product serves too. The host holds no key material. Signing in is a
challenge the account key signs, and every mailbox operation is a challenge/complete pair in
which the device signs the relay's nonce; the host passes the signature on and never sees a
private key. Talking libp2p to relays directly (SPEC_CORE §5) is the alternative. It would
remove the host from the path, but it means a Swift libp2p stack, so it waits.

## Layout

```
Package.swift            DMCNKit, DMCNKitSamples, AppState
Sources/DMCNKit/
  Proto/                 generated from proto/ — never edit
  Crypto/                seal generations, AEAD, CEK wrap, padding, canonical bytes
  Message/               split envelope open/seal, content address, snippet
  Identity/              identity record signing bytes
  Keys/                  AccountKeys: where keys live is the app's decision
  Keystore/              Argon2id, backup files, key payloads, new identities
  API/                   web host client
  Mailbox/               Inbox, reader checks, MessageSummary, the MailboxService seam
  Store/                 the sealed personal store: flags, labels, contacts, settings, Sent, drafts
  Trust/                 sender trust, the checks strip, ReaderPolicy: what may be shown
  Compose/               sending, replies, attachments, draft autosave
  MailView/              folder rows, unread, trash, search
Sources/DMCNKitSamples/  an in-memory account for previews, debug builds and tests
Tests/                   parity vectors, Go-sealed fixture, round trips, API client, app state
proto/                   byte-identical mirror of open-dmcn proto/ at OPEN_DMCN_VERSION
App/
  OpenDMCN.xcodeproj     the Xcode project
  AppState/              the app's state, with no SwiftUI, so it also builds and tests on Linux
  Shared/                SwiftUI views, by module: DesignSystem, Auth, Shell, Mail, Contacts, Settings
  Config/Deployment.xcconfig   this build's name, bundle id, default host
  Resources/             assets, generated third-party notices
docs/                    how the code fits together
dev/                     mirror, fixture, notices and icon scripts
```

## Build and test

```bash
make bootstrap        # resolve packages, build the pinned protoc-gen-swift
make test             # mirror, notices and format checks, then every test (Linux or macOS)
make format           # reformat every hand-written Swift file
make proto-sync       # copy the pinned open-dmcn schema into proto/ and regenerate
make proto            # regenerate Sources/DMCNKit/Proto (requires buf)
make go-fixture       # re-seal the Go fixture with the pinned open-dmcn (requires go)
make notices          # regenerate App/Resources/ThirdPartyNotices.txt
make icons            # regenerate the icon set from the web client's Icon.tsx
make app              # build the iOS app for the simulator (requires Xcode)
```

DMCNKit needs Swift 6.2 or later (Xcode 26). The mirror check uses `../open-dmcn` when it
exists and is at the pin, or else clones the pinned tag under `.build/`.

The live tests run the kit and the app's state against a real server, and are skipped otherwise.
Start one with a fresh data directory, and run one suite per server: it rate-limits registration.

```bash
DMCND_DEV=true DMCND_DOMAIN=localhost DMCND_LISTEN=127.0.0.1:18099 dmcnd
DMCN_LIVE_HOST=http://127.0.0.1:18099 swift test --filter LiveSession
```

To run the app on a device, put your signing team in `App/Config/Local.xcconfig`
(gitignored): `DMCN_DEVELOPMENT_TEAM = ABCDE12345`.

## Building your own app from this

Replace `App/Config/Deployment.xcconfig` (name, bundle id, default host) and
`App/Shared/Deployment.swift` (the runtime differences). Do not ship under this
repository's bundle id or display name, and see Trademarks below for the names.

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) has the rules for the
code, and most of them protect interoperability, so please read it first.

- **Bugs and proposals for the app or DMCNKit:** open an
  [issue](https://github.com/dmcnp/open-dmcn-apple/issues) here.
- **The protocol or the schema:** these change in
  [open-dmcn](https://github.com/dmcnp/open-dmcn) first, so raise it there.
- **Security vulnerabilities:** email security@dmcn.email. Please don't open a public issue.

Before you open a pull request, run `make format` and `make test`. CI runs `make test` and
`make app` on every pull request. Views and the Xcode project need a Mac to check, so if you
couldn't run a change to them, say so in the pull request.

Contributions are made under the Apache License, Version 2.0 (section 5 of [LICENSE](LICENSE)).

## License

Licensed under the **Apache License, Version 2.0**; see [LICENSE](LICENSE) and
[NOTICE](NOTICE). The license includes an express patent grant with defensive termination.
The app shows this license, this repository's NOTICE, and the license and notices of every
package linked into it, on its Acknowledgements screen.

## Trademarks

Two names, two meanings: **"DMCN"** identifies the *network* — the Decentralized Mesh
Communication Network of interoperating deployments — and **"DMCN Protocol" / "DMCNP"**
identifies the *protocol* specified in open-dmcn. The Apache License covers the code here; it
does **not** grant rights to either name or any associated logos.

You are free to build an app from this code under any name of your own. Describing it as
speaking the "DMCN Protocol" (or "DMCNP", or confusingly similar) requires that it genuinely
conform to the protocol; describing it as part of "DMCN" additionally means it actually
interoperates with the network. Names, icons or store listings implying endorsement by or
affiliation with DMCN LLC require permission.
