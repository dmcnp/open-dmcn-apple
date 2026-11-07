# proto/ — the core schema, mirrored

These files are a byte-identical copy of `proto/` in
[open-dmcn](https://github.com/dmcnp/open-dmcn) at the tag in `../OPEN_DMCN_VERSION`. The
schema is canonical there. **Never edit it here.** Change it in open-dmcn, release a tag, move
the pin, then:

```bash
make proto-sync   # copy the pinned schema into proto/
make proto        # regenerate Sources/DMCNKit/Proto/*.pb.swift
```

`make test` runs `make proto-sync-check`, which fails on any difference from the pinned tag.

A new **signed** core field needs this client to ship before any producer emits it: Go and the
browser verify a signature by re-marshaling what they parsed, and so does DMCNKit
(`Canonical.marshal`). A client generated before the field drops it, re-marshals without it,
and rejects every header or record that carries it.
