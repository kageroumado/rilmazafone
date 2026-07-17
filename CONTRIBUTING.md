# Contributing

Bug reports and fixes are welcome. Rilmazafone writes real `.DS_Store`, Alias, and
ICNS binary formats by hand and drives `hdiutil`/`codesign`, so the most valuable
contributions are grounded in DMGs that were actually built and mounted — not layouts
that merely look right on the canvas.

## Bugs

Open an issue with the Bug report template. The single most useful thing you can attach
is the `.dmgtemplate` itself — it's a plain directory package whose `document.json` is
just JSON, so it reproduces the exact layout. Redact any absolute `sourcePath`s you'd
rather not share.

For build failures, note which of the seven pipeline steps failed (the build sheet names
them). For the CLI, progress and errors print to **stderr**:

```sh
Rilmazafone.app/Contents/MacOS/Rilmazafone build MyApp.dmgtemplate -o out.dmg
```

Security-sensitive issues shouldn't go in public issues — report them privately to
[@kageroumado on X](https://x.com/kageroumado).

## Build

Open in Xcode and Run the **Rilmazafone** scheme:

```sh
open Rilmazafone.xcodeproj
```

Or a headless compile check without local signing identities:

```sh
xcodebuild -project Rilmazafone.xcodeproj -scheme Rilmazafone -configuration Debug \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
```

The project has **zero external dependencies** — Apple system frameworks only.

### Tests

```sh
xcodebuild test -project Rilmazafone.xcodeproj -scheme Rilmazafone -destination 'platform=macOS'
```

The suite covers the parts most likely to break silently: `.DS_Store` binary-format
correctness, Alias record generation, Codable round-trips, and document read/write with
undo. If you change any non-UI logic — especially a binary-format writer — add or update
a test.

## Style

SwiftFormat (`.swiftformat`) and SwiftLint (`.swiftlint.yml`). Run both before committing:

```sh
swiftformat .
swiftlint
```

## Layout

- `Model/` — `DMGConfiguration` and its nested types: `Codable`, `Sendable`,
  `nonisolated`. The single source of truth for a document, serialized to `document.json`.
- `Document/` — `RilmazafoneDocument` (`ReferenceFileDocument` + `@Observable`) with full
  undo/redo. Every mutation registers with `UndoManager` via a named action method.
- `Services/` — stateless service enums with static methods, no shared mutable state:
  - `BuildManager` — `@Observable` orchestrator for the 7-step build + composite
    background rendering.
  - `DMGBuilder` — `hdiutil` / `codesign` process wrapper.
  - `DSStoreWriter` — pure-Swift `.DS_Store` buddy-allocator / B-tree writer.
  - `IconComposer` — ICNS parser and volume-icon compositor.
  - `AliasRecordBuilder` — classic Alias Manager binary record builder.
  - `CompositeRenderer` — `CIFilter` pipeline that composites background layers.
- `Views/` — SwiftUI, organized by panel (Canvas, Sidebar, Inspector, Sheets, Toolbar).

The hand-rolled binary formats (`DSStoreWriter`, `AliasRecordBuilder`, `IconComposer`) are
the fragile, high-value code. Read the README's Architecture section before touching them.

## Build variants

Two products ship from one codebase: the **GitHub build** (`Rilmazafone` — free, MIT,
unsandboxed, includes the CLI and the private-API glass preview in `BackdropBlurView.swift`)
and the **App Store build** (`Rilmazafone AS` — sandboxed, public APIs only; its release
build fails if private symbols appear in the product). Keep `BackdropBlurView.swift` and any
other private-API code out of the App Store target.

## Pull requests

Use the template. Reference the issue you fix and keep it focused. Because Rilmazafone
produces real disk images, **build and mount a DMG to confirm the layout** when your change
could affect output — don't rely on the canvas preview alone. `swiftformat --lint .` must
pass. Fill in the Authorship section: agent, model, and whether the session was attended or
automatic.

Contributions to the GitHub build are MIT-licensed.
