# CLAUDE.md

Operating guide for Claude Code in this repository. Everything a person needs applies to you too:
`README.md` for what this is, `docs/HOW-IT-WORKS.md` for how it fits together, and
**`CONTRIBUTING.md` for the rules, which you must follow**.

## Build and test

```bash
make test        # mirror, notices and format checks, then every test
make format      # run before reporting work as done
make proto       # regenerate Sources/DMCNKit/Proto (buf + the pinned protoc-gen-swift)
make app         # macOS only: xcodebuild for the iOS simulator
```

DMCNKit and `App/AppState` build and test on Linux, which is how most work is checked. The
views in `App/Shared` and the Xcode project need macOS with Xcode, so a change to either is
unverified until CI's `app` job builds it. Say so when reporting.
