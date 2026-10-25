# Independent Circuit Studio editor

This implementation is authored for Circuit Studio. It does not import Analog
Canvas packages, source files, JSON symbol definitions, routing algorithms or
compiled assets. The reference is a functional specification only.

The editor uses its own document model, SVG geometry, connectivity resolution,
orthogonal router, transactional history and SPICE import/export. Native Swift
continues to provide file access, clipboard, StoreKit, CircuitAI conversations,
model storage and local ngspice execution. Existing user project data is imported
through a format adapter; the adapter does not execute or render embedded artwork.

Public process-model packets and the separately licensed schematic font remain
independent dependencies with their notices. Course netlists and explicit layout
coordinates authored for Circuit Studio are retained, while their rendering and
routing are rebuilt here.

Run `node --test Engineering/Independent/*.test.mjs` for model and connectivity
checks. Build with `python3 Engineering/build.py`. New artifacts use Build 32;
Build 31 contains the retired reference implementation and must not be submitted.
