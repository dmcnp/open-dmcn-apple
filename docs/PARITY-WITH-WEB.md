# Parity with the web client

The app aims to match the reference web client (`cmd/dmcnd/web` in open-dmcn) in features and
design, on a phone. This is what's there, what isn't, and where it differs on purpose. Update it
when either side changes.

## Design

Colours, type scale, spacing, 4-point corners and the icon set are the web's, value for value
(`App/Shared/DesignSystem/`, from `tokens.css` and `Icon.tsx`). Layout follows the web's phone
layout: top bar, drawer, list, reader, floating Compose, full-screen composer.

Native on purpose: HTML mail wider than the view is scaled to fit, as Apple Mail does, rather than cut off. Sheets are the system's, with its rounded corners rather than the web's 4-point
ones. Swipe actions come from `List`, so they look like iOS's rather than the web's
hand-built ones. Text follows Dynamic Type, which the web can't. The reader has an edge swipe back. The launch screen is the app icon on the page colour, which follows the system's light or dark setting even when the app's theme says otherwise, because iOS draws it before any of the app runs.

## Features

| Area | Web | App |
|---|---|---|
| Set up, choose an account, import a backup | Yes | Yes |
| Create an account | Yes | Yes |
| Ask for a mailbox (petition) | Yes | Yes |
| Protect keys | Passkey or passphrase | Face ID/passcode or passphrase |
| Open a passkey-wrapped backup | Yes | No: needs WebAuthn. The app says so |
| Lock after leaving | Yes | Yes, same 2 minutes |
| Several accounts open at once | Yes | One at a time: switching locks and goes to the picker |
| Shared device unlock | Yes | No |
| Inbox, Starred, Sent, Drafts, Archive, Deleted, folders, labels | Yes | Yes |
| Unread, star, archive, delete, restore, delete for good | Yes | Yes |
| Search, operators, on-device index | Yes | Yes |
| Checks strip, trust gate, block, trust, key-change handling | Yes | Yes, stricter (see below) |
| HTML mail, remote images opt-in | Yes | Yes, in a locked-down web view |
| Attachments, View source | Yes | Yes |
| Compose, reply, reply all, attachments, drafts, signature | Yes | Yes |
| Recipient review, key-change warnings, add to contacts | Yes | Yes |
| Forward | No | Yes, an addition |
| Rich text composing | Yes | No: plain text only, and drafts resume as plain text |
| Contacts, pins | Yes | Yes |
| Contacts' pin-disagreement alert | Yes | Kit only, no icon yet |
| Settings: signature, labels, folders, theme, keep deleted, remote images, backup, blocked senders | Yes | Yes |
| Settings: density, change passphrase, block a whole domain | Yes | No |
| Mailbox export | Yes | No |
| Key rotation, forwarding settings | Yes | No |
| Push notifications | Yes | No: waiting on who runs the push gateway |
| Tablet layout | Desktop layout | Phone layout on iPad |

## Where the app is deliberately stricter

The reader follows SPEC_CORE §3 where the web doesn't. `ReaderPolicy.swift` lists each of these:

- A message whose key differs from the directory's is withheld, with no plain-text peek.
- What's attached to a disowned message isn't believed. The web still reads a stapled attestation.
- Your own mail needs your account's key, not just your address.
- A verified delivery receipt doesn't open bridged mail.
- Nothing is decided, or unlocked, until the directory has answered.

## Known limits that come from the server

- Flags on a Sent row are refused (`flags/sent:<id>` isn't a valid key), so starring or deleting
  from Sent fails. The app says so; the web fails silently.
- The blocklist is per device on the reference server.
- Listing the personal store past its first page fails on the reference server.
