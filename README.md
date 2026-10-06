# Circuit Studio

A native Mac canvas for circuit design, offline simulation, and technical illustration.

[Website & Mac download](https://www.weitao-jiang.cn/static/circuit-studio/) · [Releases](https://github.com/CBDT-JWT/CircuitStudio/releases) · [Report an issue](https://github.com/CBDT-JWT/CircuitStudio/issues)

![Circuit Studio schematic and offline AC simulation](Website/assets/schematic.webp)

## Two canvas modes

Every new document starts with an empty canvas. Choose the mode in the canvas header:

- **Schematic**: circuit symbols, electrical wires and labels, voltage probes, and embedded ngspice 47 simulation. Operating point, DC, AC and transient analyses run locally.
- **Illustration**: block diagrams and paper figures, with 13 shapes including input/output/bidirectional ports, summing junctions, flowchart shapes, text, and attached arrows. Simulation tools are hidden and SPICE generation is disabled.

Switching modes preserves existing objects. The mode is stored with the document and can be undone. Older documents open automatically; pure figure documents become Illustration and electrical documents remain Schematic.

On Mac, the waveform panel offers **New tab** and **Open in new window**. Each expanded result is a snapshot of that analysis, so further circuit edits and simulations do not change an already-open result. AC magnitude/phase, zoom, cursors, and trace controls remain available.

![Circuit Studio illustration mode](Website/assets/illustration.webp)

## Install on Mac

Requires **macOS 26 or later**, on **Apple Silicon or Intel**. Download the universal DMG, open it, then drag **Circuit Studio.app** into **Applications**.

The current direct-download build uses an Apple Development certificate and **is not notarized by Apple**. If macOS blocks it, first attempt to launch the app, then choose **Open Anyway** in **System Settings → Privacy & Security**. See [Apple's instructions](https://support.apple.com/102445). Checksums and signature status are included in each release.

Drawing and simulation run offline, without an account, Homebrew installation, or external simulation executable. Documents are ordinary `.circuit` packages; save them in iCloud Drive if desired. Website downloads require an email address; the developer's server stores that address privately and displays only the number of distinct emails whose installer downloads completed.

## One-click updates

Version 1.2.0 adds Sparkle 2.10.0 updates. Choose **Circuit Studio → Check for Updates…** or use Settings. Automatic checks and background downloads are enabled by default and can be disabled in Settings. When an update is ready, install and relaunch to use it. Existing 1.1.0 installations need one manual download of 1.2.0 to gain the updater.

The app verifies both the update feed and installer with its embedded Ed25519 public key. The private signing key remains in the publisher's local macOS Keychain, under account `circuitstudio-release`. Updates use GitHub Releases over HTTPS, send no system profile, and do not upload circuit documents or simulation data. Direct Mac builds include Sparkle; App Store and iOS builds omit it.

## Drawing and export

- Vector circuit symbols including MOS, BJT, R/C/L, sources, op amp, supplies and connections.
- Grid snapping, attached endpoints, orthogonal routing, mathematical labels, selection, duplication, undo/redo, alignment and distribution.
- Native document windows and Mac keyboard shortcuts. Use **A** to search, **W** to draw a wire (or an illustration connector), **L** for arrows, **T** for labels/text, and **F** to fit.
- PDF/SVG vector export; PNG/JPEG/TIFF raster export; CircuitikZ import/export; SPICE netlists in Schematic mode.
- Publication styling, grayscale export, editable system diagrams, flowcharts and device cross-section examples.

The shared SwiftUI application also includes iPhone/iPad layouts. This release's downloadable installer is for macOS.

## Build

Use Xcode 27, including its command-line tools. The repository includes prebuilt ngspice static libraries for Mac, iOS and the iOS simulator, with their licenses and pinned source/build instructions.

```sh
xcodebuild -project CircuitStudio.xcodeproj -scheme CircuitStudio \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/circuitstudio-build CODE_SIGNING_ALLOWED=NO build

swift test --scratch-path /tmp/circuitstudio-tests
```

The default app uses `DocumentGroup` and opens blank documents. `CIRCUITSTUDIO_PREVIEW` is only for deterministic screenshot and layout checks.

After adding Swift files, regenerate the project with `python3 scripts/generate_project.py`. To rebuild the embedded engine from the pinned upstream source, run `python3 scripts/build_ngspice.py` (requires Xcode and autotools).

## Package a DMG

```sh
python3 -m venv /tmp/circuitstudio-packaging
/tmp/circuitstudio-packaging/bin/pip install dmgbuild==1.6.7
/tmp/circuitstudio-packaging/bin/python scripts/package_macos.py
```

This creates a universal release build, signs Sparkle's nested helpers and the app, verifies the signature and architectures inside the mounted installer, and builds a Finder disk image with an Applications link, background and installation instructions. Files and SHA256 checksums are written to `Release/Direct/`. The default signing choice prefers Developer ID, then Apple Development; a signing certificate is required for the updater.

With a Developer ID Application certificate and an existing notarytool Keychain profile:

```sh
python scripts/package_macos.py \
  --sign-identity 'Developer ID Application: Your Name (TEAMID)' \
  --notary-profile YOUR_EXISTING_PROFILE
```

Credentials and signing overrides belong outside version control. Packaging does not upload to the App Store.

## Publish locally

Publishing runs on the owner's Mac; no GitHub Actions signing secrets are required. Before each release, increase **both** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Release/Release.xcconfig`, add `docs/release-VERSION.md`, and commit the source changes. Then run:

```sh
python3 scripts/publish_release.py
```

The command builds the universal DMG, signs and verifies the update feed, pushes the source and version tag, uploads a draft GitHub release, deploys the website and private download service through the existing root SSH connection, then publishes the release. Installed apps discover the new version through the latest release's signed `appcast.xml`. The command checks that the local signing key matches the app's public key and that the build number increases. It keeps up to three update entries with their original release URLs.

Prerequisites: Xcode, `gh` authenticated for this repository, `rsync`, server SSH access, a Mac app signing identity, and the existing Sparkle Keychain key. Sparkle tools are downloaded from a pinned official distribution with SHA256 verification. Preserve the publisher's Keychain through secure Mac backups; changing its trusted signing key requires a planned key transition.

For a previously built and verified DMG, use `--skip-build`. If deployment stops after creating a draft, retry from the same source commit with `--resume --skip-build`. A published version is immutable; use a new version/build for further changes. To notarize a future release, supply `--sign-identity 'Developer ID Application: Your Name (TEAMID)' --notary-profile YOUR_EXISTING_PROFILE`.

## Private download registry

The Linux service uses Flask and Gunicorn behind nginx, bound to `127.0.0.1:5087`. An email submission creates a one-hour download link. The counter counts distinct email addresses after a complete response is streamed; repeat downloads do not increase the number. It is a download metric, not a verified installation count. The website refreshes it every five seconds while visible. Requests are rate limited; email addresses have no public API.

Production files:

- Private database: `/srv/circuitstudio/data/downloads.sqlite3`, accessible to root and the dedicated service account.
- Installers: `/srv/circuitstudio/releases/`, outside the public website directory.
- Service: `circuitstudio-downloads.service`; inspect it with `systemctl status circuitstudio-downloads` and `journalctl -u circuitstudio-downloads`.
- Each deployment backs up the previous website/configuration and a consistent SQLite snapshot in `/srv/circuitstudio/backups/`, preserving the existing contact list.

Export the email list through authenticated SSH, without exposing it on the website:

```sh
ssh -o ClearAllForwardings=yes root@www.weitao-jiang.cn \
  python3 /srv/circuitstudio/service/contacts.py \
  --database /srv/circuitstudio/data/downloads.sqlite3 \
  --output /root/circuitstudio-contacts.csv
scp -o ClearAllForwardings=yes \
  root@www.weitao-jiang.cn:/root/circuitstudio-contacts.csv ./circuitstudio-contacts.csv
```

Add `--downloaded-only` to export only addresses with a completed download. CSV files are created with owner-only permissions. Do not commit an exported list. The website's privacy notice explains what is recorded and how users can request removal; submitting an address does not subscribe it to a mailing campaign.

Run the backend checks with a virtual environment containing `Service/requirements.txt`:

```sh
python -m unittest discover -s Service -p 'test_*.py'
```

## Project structure

| Path | Purpose |
| --- | --- |
| `Sources/CircuitCore` | Document models, geometry, symbols, vector/raster export, connectivity, SPICE and simulation |
| `Sources/CircuitStudio` | Native document app, canvas, inspector, tools and waveform windows |
| `Tests/CircuitCoreTests` | Electrical, geometry, compatibility, export and real simulation checks |
| `scripts` | Project generation, engine builds, editor checks, screenshots, DMG packaging and local publishing |
| `Vendor/ngspice` | Pinned engine, prebuilt XCFramework, build notes and licenses |
| `Vendor/Sparkle` | Pinned Mac updater framework and license |
| `Website` | Static marketing site and actual application captures |
| `Service` | Private email registry, completed download count, CSV export and server installer |

32 core tests and 17 editor interaction checks cover the current release's core behavior. Native UI checks additionally exercise blank startup, mode switching and simulation result tabs/windows. The document format is version 3, with backward compatibility for versions 1 and 2.

## Scope

Simulation supports OP/DC/AC/TRAN and native `.model` / `.param` definitions. XSPICE dynamic code models, OSDI plugins, Noise and Monte Carlo are not included. CircuitikZ import supports the app's own metadata and a limited subset of external numeric-coordinate circuit syntax. Device cross-sections are illustrations. Arbitrary Bézier editing, Visio import, hierarchy, CloudKit conflict handling, Quick Look extensions and full cross-device Handoff validation remain future work.

## License

Application source: [MIT](LICENSE). ngspice and its incorporated third-party code retain their own licenses in [Vendor/ngspice/COPYING](Vendor/ngspice/COPYING). Sparkle retains its license in [Vendor/Sparkle/LICENSE](Vendor/Sparkle/LICENSE). Both notices ship inside the app. Original artwork and asset provenance are documented in [Website/ASSETS.md](Website/ASSETS.md).
