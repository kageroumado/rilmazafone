# Rilmazafone

Rilmazafone combines visual DMG design with the release pipeline in one saved document. Arrange the installer as it will appear in Finder, then archive the app and publish it to GitHub from the same release plan.

<a href="https://kagerou.glass/rilmazafone/"><img src=".github/download.svg" alt="Download Rilmazafone for Mac" width="360" height="80"></a>

![Rilmazafone’s DMG design canvas](screenshot.png)

![The release plan from Xcode archive to GitHub publishing](.github/rilmazafone-releaseplan.png)

## Highlights

- Design a DMG as it will appear in Finder, then publish from the same release plan.
- Save the installer layout and release configuration for repeatable releases.
- Run the saved release plan from either the app or CLI.

<details>
<summary>Full feature list</summary>

- Arrange app icons, files, and the Applications shortcut on a visual canvas.
- Compose backgrounds with images, gradients, text, and glass panels.
- Save reusable `.dmgtemplate` designs and `.releaseplan` configurations.
- Archive, sign, notarize, package, and verify app and DMG artifacts.
- Publish GitHub releases and update a Homebrew cask.
- CLI commands for DMG generation and release build/publish.
- Undo/redo, portable source paths, and Finder thumbnails in the GitHub edition.

</details>

## Notes

- macOS 26+; Xcode for the release pipeline.
- Homebrew: `brew install --cask kageroumado/tap/rilmazafone`.
- The App Store edition contains the designer; the GitHub edition adds the CLI and release pipeline. [Edition differences](REFERENCE.md#build-variants) · [Workflow and formats](REFERENCE.md).
