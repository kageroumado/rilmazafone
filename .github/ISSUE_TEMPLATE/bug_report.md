---
name: Bug report
about: Report a problem with Rilmazafone (build fails, wrong Finder layout, code signing, canvas rendering, CLI, etc.)
title: ""
labels: ""
assignees: kageroumado
---

## Summary

<!-- One or two sentences: what happens, and when. -->

## Environment

- **Rilmazafone**: <!-- e.g. 1.0 (GitHub build) or 1.0 (App Store build) — the two differ; see below -->
- **Build**: <!-- GitHub (free, unsandboxed, has CLI) or App Store (sandboxed). If unsure: does `Rilmazafone.app/Contents/MacOS/Rilmazafone build …` work? Only the GitHub build has the CLI. -->
- **macOS**: <!-- e.g. 26.1 (Build 25B?) -->
- **Hardware**: <!-- e.g. M4 MacBook Air -->
- **Output settings**: <!-- format (LZFSE/UDZO/UDBZ/LZMA), filesystem (APFS/HFS+), code signing on/off -->

## Steps to reproduce

1.
2.
3.

## Expected behavior

<!-- What you expected to happen. -->

## Actual behavior

<!-- What actually happened. Screenshots of the canvas or the mounted DMG are very helpful. -->

## Which stage?

<!-- If it's a build failure, which of the 7 build steps failed? The build sheet names them:
     estimate size → create → mount → copy contents → configure layout (.DS_Store) → set volume icon → compress/sign. -->

- [ ] Designing in the app (canvas / inspector / rendering)
- [ ] Building the DMG (which step above?)
- [ ] The *produced* DMG is wrong when mounted (icon positions, background, window size, volume icon)
- [ ] Code signing
- [ ] CLI (`build` / `init`)

## The template / document (optional but very helpful)

A `.dmgtemplate` is a plain directory package — its `document.json` is just JSON. Attaching
it (zip the `.dmgtemplate`, or paste `document.json`) lets the exact layout be reproduced.
Redact any absolute `sourcePath`s you'd rather not share.

## Log excerpt

- **CLI**: progress and errors print to **stderr** — paste the output of:

  ```sh
  Rilmazafone.app/Contents/MacOS/Rilmazafone build MyApp.dmgtemplate -o out.dmg
  ```

- **GUI**: the build sheet shows the failing step and its message — a screenshot of it is ideal.
- **Crashes**: attach the report from **Console → Crash Reports** (or `~/Library/Logs/DiagnosticReports/Rilmazafone-*.ips`).
