# Circuit Studio 1.2.0

- Mac documents start on a blank canvas, with Schematic for circuits and simulation, or Illustration for diagrams and ports.
- Simulation charts can open in independent native tabs and windows, retaining the results of that analysis.
- Added signed in-app updates using Sparkle 2.10.0. Updates can download in the background and install on relaunch. The app menu and settings also offer Check for Updates.
- Added a local release command that builds and verifies the universal DMG, signs the update feed and installer, publishes a GitHub release, and deploys the website and current installer.
- Website downloads require an email address. The server stores a private contact list and publishes only a live count of distinct emails that have downloaded an installer.

Requires macOS 26 or newer, on Apple Silicon or Intel. The current build uses an Apple Development certificate and is not Apple-notarized. If macOS blocks its first launch, see the website's installation instructions. In-app updates verify both the feed and installer with the embedded Ed25519 public key.
