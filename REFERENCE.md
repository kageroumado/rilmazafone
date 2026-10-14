# rilmazafone reference

[Overview](README.md)

## Usage

Rilmazafone is a document-based app — each `.dmgtemplate` file represents one DMG design.

### Basic Workflow

1. **Create a new document** (Cmd+N)
2. **Add your app** — Drag a `.app` bundle from Finder onto the canvas, or click the **+** button at the bottom of the sidebar and choose "Add Application...". An Applications symlink and an arrow symbol are added automatically.
3. **Add additional items** — Use the **+** button or drag files/folders onto the canvas to include READMEs, license files, or additional resources. Items can be set to copy or symlink via the inspector.
4. **Design the background** — Switch the background type in the inspector between None, Color, Gradient, or Image. For image backgrounds, drag images onto the canvas or sidebar. Multiple image layers can be stacked and individually adjusted with blur, variable blur, color adjustments, vignette, and bloom effects. Text and SF Symbol layers can also be added — all layers are composited into a single background PNG at build time.
5. **Configure appearance** — Use the inspector to adjust icon size, text size, grid spacing, and window dimensions. Size presets (Compact, Standard, Large) apply coordinated defaults. Per-icon frosted glass backgrounds with shadow and bevel effects can be enabled in the Effects section when an item is selected.
6. **Configure build settings** — In the inspector, choose your compression format and filesystem:

   | Format | Description |
   |--------|-------------|
   | **LZFSE (ULFO)** | Fast, good compression. Default. macOS 10.11+ |
   | **zlib (UDZO)** | Most compatible. Works on all macOS versions |
   | **bzip2 (UDBZ)** | Smaller than zlib, slower to create |
   | **lzma (ULMO)** | Smallest files, slowest compression |

   | Filesystem | Description |
   |------------|-------------|
   | **APFS** | Modern filesystem. Default. macOS 10.13+ |
   | **HFS+** | Legacy. Use for compatibility with older macOS |

   Enable **Code Signing** if you need the DMG signed — Rilmazafone auto-detects signing identities from your keychain. If your app is already signed, the matching identity is pre-selected automatically.

7. **Build** — Click the Build button in the toolbar (or Cmd+Shift+B), choose an output location, and the DMG is created. The build sheet shows progress through each step.

### Release Plans (2.0)

A `.releaseplan` turns a design into a repeatable release. Create one with **File → New Release Plan**, from the template chooser, or convert an open design with **File → Save as Release Plan…** — then save it into your app's repository (its folder is the default repo root, and the plan auto-fills from there: scheme, version, GitHub repo from the `origin` remote, signing identity from the keychain).

The window shows the pipeline as the document: the stage list runs live in the center, and a three-tab inspector (Project / Publish / Run) holds the configuration. Opening an existing plan starts in execute mode — the plan is a recipe being run, not edited; the pencil unlocks it.

The pipeline has two phases with a deliberate seam:

- **Build** (repeatable; failures revert the version bump) — bump, archive into Xcode Organizer, sign every nested Mach-O inside-out with Developer ID, notarize + staple the app, build the DMG from the embedded design, notarize + staple the DMG, mount and re-verify everything, then optional EdDSA `.sig` and dSYM archiving. Ends with final artifacts you can ship anywhere.
- **Publish** (the point of no return; failures fix forward) — commit + push the version bump *before* the release so the tag pins the right commit, create the GitHub release with the DMG (+ `.sig`), bump your Homebrew cask, run an optional post script.

Publishing needs the [GitHub CLI](https://cli.github.com) signed in, and a notarization keychain profile (`xcrun notarytool store-credentials` — the ⓘ next to the Notary profile field has the full command). Everything the plan stores is a reference — no secrets land in the file.

### Command Line

Rilmazafone can also build DMGs headlessly from the terminal, useful for CI/CD pipelines and automation. The CLI is exclusive to the GitHub build — the App Store build launches the GUI regardless of arguments.

```bash
# Generate a starter template
Rilmazafone.app/Contents/MacOS/Rilmazafone init MyApp.dmgtemplate

# Edit document.json to set volume name, items, source paths, etc.
# Then build:
Rilmazafone.app/Contents/MacOS/Rilmazafone build MyApp.dmgtemplate -o dist/MyApp.dmg
```

For convenience, symlink the binary:

```bash
ln -s /Applications/Rilmazafone.app/Contents/MacOS/Rilmazafone /usr/local/bin/rilmazafone
rilmazafone init MyApp.dmgtemplate
rilmazafone build MyApp.dmgtemplate -o MyApp.dmg
```

Run `rilmazafone --help`, `rilmazafone build --help`, or `rilmazafone init --help` for full usage.

The release pipeline is scriptable too — the same engine behind the Publish button:

```bash
rilmazafone release build   MyApp.releaseplan            # → notarized, verified artifacts
rilmazafone release publish MyApp.releaseplan -n "Fixes" # → GitHub release (builds first if needed)
rilmazafone release staple  MyApp.releaseplan            # finish an --async-notarize build
rilmazafone release status  MyApp.releaseplan            # build record · notarization · published?
rilmazafone release doctor  MyApp.releaseplan            # preflight: identity · notary · gh access
```

`--install` on `build` or `publish` copies the finished app into `/Applications` (the installed copy goes to the Trash); the plan's `installToApplications` does it on every run.

`--json` streams stage events as NDJSON for CI. Exit codes: 0 success, 1 pipeline failure, 2 usage error; every run appends a transcript to the plan's `release.log`.

**Key `document.json` fields for CLI use:**

| Field | Description |
|-------|-------------|
| `volumeName` | Name shown when the DMG is mounted |
| `items` | Array of icons to place. Set `kind` (`app`, `file`, `folder`, `applicationsSymlink`), `label`, `sourcePath` (absolute or `~/`-prefixed), and `position` (`[x, y]`) |
| `window.width` / `window.height` | Finder window dimensions |
| `iconSize` | Icon size in the Finder window |
| `dmgFormat` | Compression: `ULFO` (LZFSE), `UDZO` (zlib), `UDBZ` (bzip2), `ULMO` (lzma) |
| `filesystem` | `APFS` or `HFS+` |
| `codeSign.enabled` / `codeSign.identity` | Optional code signing |
| `background.type` | `none`, `color`, `gradient`, or `image` |

Progress prints to stderr. Exit code 0 on success, 1 on failure.

## Architecture

Rilmazafone is a SwiftUI document-based app using `ReferenceFileDocument` with a directory-based package format (`.dmgtemplate`).

### Project Structure

```
Rilmazafone/
  Model/          DMGConfiguration — all nested model types (Codable, Sendable, nonisolated)
  Document/       RilmazafoneDocument (ReferenceFileDocument + @Observable) with undo support
  Release/        The 2.0 release pipeline (GitHub build only, compiled out of the App Store build)
    ReleasePlan       .releaseplan model with path resolution and no-secrets invariant
    ReleasePipeline   The engine: staged Build/Publish run with revert vs. fix-forward policies
    ReleasePlanDocument, Views/  The plan document and its window (pipeline + tabbed inspector)
    CLIReleaseRunner  `release build/publish/staple/status/doctor`
  Services/       Stateless service enums for the build pipeline
    BuildManager    @Observable build orchestrator and composite background rendering
    DMGBuilder      hdiutil/codesign process wrapper
    DSStoreWriter   Pure Swift .DS_Store buddy-allocator/B-tree binary format writer
    IconComposer    ICNS parser and volume icon compositor
    AliasRecordBuilder  Classic Alias Manager binary record builder
    CompositeRenderer   CIFilter pipeline for compositing background layers
    ProcessRunner   Async process execution utility
  Views/          SwiftUI views organized by panel (Canvas, Sidebar, Inspector, Sheets, Toolbar)
  Headers/        Bridging header + private QuartzCore headers
RilmazafoneThumbnails/  QuickLook extension serving Finder thumbnails for both document types
```

### Key Design Decisions

- **Zero external dependencies** — Pure Swift with Apple system frameworks only.
- **Stateless services** — `DMGBuilder`, `DSStoreWriter`, `IconComposer`, `AliasRecordBuilder`, and `CompositeRenderer` are enums with static methods. No singletons, no shared mutable state.
- **Pure Swift binary formats** — The `.DS_Store` buddy-allocator/B-tree, ICNS parser, and Alias record builder are implemented entirely in Swift.
- **Comprehensive undo/redo** — Every document mutation registers with `UndoManager` via named action methods.
- **Path portability** — Document files use `~/` abbreviation for source paths, so projects work across machines.
- **Dual `@Observable` + `ObservableObject`** — `RilmazafoneDocument` uses `@Observable` for fine-grained SwiftUI observation and `ObservableObject` for `ReferenceFileDocument` auto-save signaling.

### Build Pipeline

The build process (orchestrated by `BuildManager`) runs in 7 steps:

1. **Estimate size** — Calculate disk image size from source file sizes
2. **Create writable DMG** — `hdiutil create` with the chosen filesystem
3. **Mount** — `hdiutil attach` the temporary image
4. **Copy contents** — Copy/symlink all items into the volume
5. **Configure layout** — Render composite background, write `.DS_Store` (icon positions, window bounds, background alias)
6. **Set volume icon** — Compose app icon onto disk icon (ICNS), apply to volume
7. **Compress** — Detach, convert to final format, optionally code sign

### Build Variants

Rilmazafone builds two products from the same codebase. The designer, the build pipeline, and the DMGs they produce are identical — the differences are packaging:

| | GitHub build (`Rilmazafone`) | App Store build (`Rilmazafone AS`) |
|---|---|---|
| **Price** | Free | [$19.99](https://apps.apple.com/app/apple-store/id6790960011?pt=128650112&ct=GitHub&mt=8) — a convenience build that supports development |
| **CLI** (`build` / `init` / `release`) | ✓ | — (any argv launches the GUI) |
| **Release pipeline** (`.releaseplan`) | ✓ | — (the sandbox can't run `xcodebuild`, `codesign`, or `notarytool`) |
| **Finder thumbnails** (QuickLook) | ✓ | — |
| **Sandbox** | Unsandboxed | App Sandbox |
| **Glass panel preview** | Real-time backdrop blur via private CoreAnimation APIs (`CABackdropLayer`, `CAFilter`) | Public APIs only |

The private-API glass preview lives in `BackdropBlurView.swift`, which is a member of the GitHub target only; the App Store target's release build additionally fails if private symbols ever appear in the product. These APIs may break in future macOS versions — everything else uses only public APIs.

If you build from source, the GitHub build is the full experience. The [App Store copy](https://apps.apple.com/app/apple-store/id6790960011?pt=128650112&ct=GitHub&mt=8) exists for people who prefer the convenience of Mac App Store installs and updates — and as the way to pay for this work if you want it to continue.

### Document Format

`.dmgtemplate` files are directory-based packages containing:

```
MyApp.dmgtemplate/
  document.json                # Configuration manifest (all settings as JSON)
  thumbnail.png                # Rendered preview, refreshed on save (drives Finder thumbnails)
  Assets/
    background-<uuid>.png      # Background layer images
    volume-icon.icns           # Custom volume icon (if provided)
    app-icon-<uuid>.icns       # Cached app icons
```

`.releaseplan` files wrap a design with its pipeline:

```
MyApp.releaseplan/
  plan.json                    # Project, signing, notarization, artifacts, distribution —
                               # keychain references and paths only, never secrets
  Design.dmgtemplate/          # The DMG design, an ordinary template editable in the canvas
```
