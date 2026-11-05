# How it works

A short tour for someone new to the code. The authority on the protocol is open-dmcn's
`SPEC_CORE.md`; this is only a map of how this repository follows it.

## The idea in one paragraph

Mail is encrypted by the sender and only decrypted on the reader's device. The servers in
between, called relays, store sealed envelopes they can't read. Your identity is a pair of keys,
so a message proves who wrote it with a signature rather than by where it came from. That moves
work onto the client: **this app, not the server, decides whether a sender is who they claim.**
Most of the unusual code here exists for that reason.

## How a message reaches the screen

Follow one message from the mailbox to the display:

1. **The session asks for the mailbox.** `MailSession.refresh` calls `Inbox.allPreviews`, which
   asks its `MailboxService` for listings. Each row is a small sealed header. The large body stays
   on the server for now. (`App/AppState/MailSession.swift`, `Sources/DMCNKit/Mailbox/Inbox.swift`)
2. **The header is unsealed.** `SplitMessage.openHeader` finds the copy of the message key meant
   for this account, unwraps it with the account's X25519 key, and decrypts the header.
   (`Sources/DMCNKit/Message/SplitMessage.swift`, `Crypto/Seal.swift`)
3. **Its signature is verified.** This proves only that the key named in the header signed it.
   Anyone can generate a key and name someone else's address, so this alone says nothing about
   who sent it.
4. **The reader checks run.** `MessageSummary` asks the directory which key belongs to the sender
   address and compares it with the key that signed. It also checks the message was addressed to
   this mailbox, which catches a copy someone re-sealed and passed on. The result is one of the
   `Sender` cases. (`Mailbox/MessageSummary.swift`, `Mailbox/ReaderChecks.swift`)
5. **The list is drawn.** `MailFolderView` turns the mail, flags, labels and contacts into rows for
   the chosen folder, and the views render them and decide nothing. A withheld message has no
   snippet. (`Sources/DMCNKit/MailView/MailFolderView.swift`, `App/Shared/Mail/MailColumn.swift`)
6. **The body is opened on tap.** `Inbox.open` refuses a withheld message without fetching it.
   Otherwise it fetches the body, decrypts it with the same message key, and checks it against
   the hash in the signed header, so a server can't swap in another body. `ReaderPolicy.decide`
   then says what may be shown. (`App/AppState/ReaderModel.swift`, `Sources/DMCNKit/Trust/ReaderPolicy.swift`,
   `App/Shared/Mail/MessageReader.swift`)

Sending runs the same steps backwards. `Composer.send` looks every recipient up, seals one copy
for each with `SplitMessage.seal`, hands each to the web host, and keeps a copy sealed to the
account in Sent. Bcc is on the sender's copy only. `Composer.review` is what to show before Send: a
changed key is warned about, never refused, because that decision belongs to the person who pinned
it. (`Sources/DMCNKit/Compose/`) The app has no composer screen yet.

## What each sender state means

| `Sender` | What happened | What the reader sees |
|---|---|---|
| `verified` | The directory lists the key that signed | Address with a check mark |
| `unverified` | The address didn't resolve: an outage, or ordinary email | Address, unconfirmed, and the message opens |
| `mismatch` | The directory lists a different key | A warning; contents hidden |
| `disowned` | The key matches, but the domain no longer vouches for the address | A warning; plain text behind the gate, never shown as from that address |
| `unreadable` | The header didn't open or verify | A row saying so; kept, not hidden |

`misaddressed` is separate. It marks a message that opens but was written to someone else.

An unresolved sender is never rejected, because a directory outage mustn't empty a mailbox.

**To see all of these, run the app and choose Explore with sample mail.**
`Sources/DMCNKitSamples/SampleMailbox.swift` is also a readable example of using the kit.

## Why some code looks odd

The app has to produce and verify the same bytes as the Go and browser clients, down to the last
one. So you'll find code that exists only to match them, such as fields written as zeros that
nothing reads. Those are the rules in [CONTRIBUTING.md](../CONTRIBUTING.md), and tests with
shared known answers fail if they drift (`Tests/DMCNKitTests`).

## Glossary

| Term | Meaning |
|---|---|
| **Account keys** | An Ed25519 key that signs and an X25519 key that decrypts. `AccountKeys` is the only code that touches them. |
| **Relay** | A server that stores sealed mail for mailboxes. It can't read it. |
| **Web host** | A server offering relay access over HTTP (`WebHostClient`). It holds no keys. |
| **Bridge** | A service that carries mail between this network and ordinary email. |
| **Directory** | Where an address's published keys are looked up. |
| **Envelope** | A sealed message: a small header and a large body, encrypted separately. |
| **Header / body** | The header holds the sender, subject and snippet, for listing. The body holds the content, fetched on open. |
| **CEK** | Content encryption key: the random key for one message, wrapped separately for each recipient. |
| **Seal / open** | Encrypt, or decrypt and verify. |
| **Generation** (`kdf`) | Which version of the key derivation a copy used. Readers must follow what the copy declares. |
| **Padding / size class** | Sealed data is padded to fixed sizes so its length reveals less. |
| **Content address** | A hash naming the sealed body, which lets a relay check it without reading it. |
| **Snippet** | The opening text of the body, carried in the header for the list. |
| **Reader checks** | What a client must do before trusting a message (SPEC_CORE §3). |
| **Audience** | The signed list of who a message was addressed to. |
| **Parity vector** | A known answer shared with Go and the browser, proving all three encode alike. |
