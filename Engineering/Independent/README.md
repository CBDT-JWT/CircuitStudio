# Circuit Studio editor

The document model, renderer, connectivity, router, history, native bridge and
SPICE import/export are implemented for Circuit Studio. No upstream editor
executable code is imported.

At the user's request, Build33 uses the same vector symbol and palette artwork
as the reference project. This is graphic data, not independently authored
artwork. See `graphics/SOURCE.json` for the source revision and the separate
bundled license. The editing canvas, library and exported images have no source
branding or author watermark. Required notices remain in third-party licenses.

The graphic changes include physical terminal geometry. Older saved Circuit
Studio documents are migrated from their actual electrical graph before being
shown. Unsupported port migrations fail without overwriting the original file.

Build32 was uploaded for both platforms but was not selected or submitted.
Build31 is retired. Build33 must not be represented as having cleared App Store
redistribution checks merely because the reference data is publicly accessible.

Run `node --test Engineering/Independent/*.test.mjs`,
`python3 Engineering/build.py`, and the native bridge/course verification scripts.
