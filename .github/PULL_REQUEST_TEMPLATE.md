<!-- Thanks for contributing to Rilmazafone! Fill in what's relevant; delete what isn't. -->

## Summary

<!-- One or two sentences: what this changes, and why. -->

## Related issue(s)

<!-- e.g. "Fixes #12" or "Relates to #12". Delete if none. -->

## Changes

<!-- Bullet the key changes. Keep it skimmable. -->

-

## How it was tested

<!-- Rilmazafone writes real binary formats (.DS_Store, Alias records, ICNS) and shells out to
     hdiutil/codesign — a clean build is not enough. Say what you actually produced and mounted. -->

- **macOS / hardware**: <!-- e.g. macOS 26.1, M4 MacBook Air -->
- **Unit tests**: <!-- `xcodebuild test -project Rilmazafone.xcodeproj -scheme Rilmazafone -destination 'platform=macOS'` -->
- **End-to-end**: <!-- Did you build a real DMG and mount it? Did the Finder layout (icon positions, window size, background, volume icon) match the canvas? Which format/filesystem? -->
- **Both build variants** (if the change isn't target-specific): <!-- GitHub (unsandboxed, CLI) and App Store (sandboxed, public APIs only). -->
- **Result**: <!-- what you observed; a screenshot of the mounted DMG is welcome -->

## Risk / regressions

<!-- What could this break? Flag anything touching the binary-format writers (DSStoreWriter,
     AliasRecordBuilder, IconComposer), the build pipeline, path portability (~/ abbreviation),
     or the App Store target's public-API-only constraint. -->

## Checklist

- [ ] Builds (`xcodebuild … build`)
- [ ] `swiftformat --lint .` and `swiftlint` pass
- [ ] Tests pass (and new tests added for changed non-UI logic)
- [ ] If it produces a DMG differently, I built and mounted one to confirm the layout
- [ ] No private symbols added to the App Store target
- [ ] No unrelated changes bundled in

---

## Authorship

<!-- These PRs are usually written by an agent — record who wrote it and how. -->

- **Agent**: <!-- the agent's name (e.g. Sora), or the human author -->
- **Model**: <!-- the model the agent runs on, e.g. Opus 4.8 (1M context) — leave blank if human-authored -->
- **Session**: <!-- "attended" (a human participated / reviewed live) or "automatic" (unattended agent run) -->
