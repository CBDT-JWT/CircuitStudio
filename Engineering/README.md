# Circuit Studio engineering editor

The offline editor is independently implemented in `Independent/`: its own project model, SVG geometry, connectivity, orthogonal router, transactional history and SPICE importer/exporter. No Analog Canvas source, symbol assets or compiled packages are bundled.

Build with `python3 Engineering/build.py`; this deterministically packages the original modules, public PDK packets, course examples, separately licensed fonts and Markdown renderer. No package install is needed. The native app serves these files over a loopback-only listener; file and clipboard access use the main-frame WKWebView bridge. Projects use `circuitstudio-project-v1`, with an adapter for existing user project data that ignores embedded artwork. Simulation settings are saved with the project.

The host runs OP, AC, DC and transient analyses locally with bundled ngspice.
The shared extractor emits a flat root and hierarchical subcircuits, retaining
PDK invocation kinds and terminal order. Models must be ngspice-compatible and
embedded in the project or imported inline; external file/control directives are
rejected. The source project itself is never modified by a run.

Circuit Studio supplies its own chrome: the existing teal accent, a bottom
floating tool dock, inset document tabs, compact collapsible library sections and
native glass simulation/AI controls. Separately licensed dependency notices remain bundled.

The right floating, collapsible native drawer switches between Simulation and
CircuitAI. Opening it fits the circuit into the unobscured canvas. Simulation
contains OP/AC/DC/transient controls, schematic probe picking, global supply
voltages, inline model import, and a run action. Settings are saved
locally per project. Runs use the native validated JSON boundary and open actual
ngspice results in the waveform window; Command-Return runs the current project.
Raw netlist and PDK mapping controls are behind Advanced. The analysis controls
scroll independently of the fixed run button so small windows remain usable.

Selecting a device opens a parameter form beside the symbol; electrical edits use the original
property validator and transactional history, including undo. Hierarchy navigation shares the document
bar; secondary Cell commands are in its menu. Unsaved tab closes use a native
macOS save/discard/cancel sheet and keep the tab open when cancelled or saving
fails.

CircuitAI opens as an in-window conversation drawer. Unverified users see the
App Store purchase/restore flow; no separate account is required. Verified
subscriptions connect through the existing gateway. Each send refreshes the
current topology and includes a bounded conversation in the gateway's versioned
JSON context. Conversations and simulation results are isolated by runtime tab
session, including separate copies of the same authored project. Closing the
drawer preserves the conversation; switching tabs preserves available results.


The shared model library provides seven public PDK packets: GF180MCU 180nm 3.3V
NMOS/PMOS at TT/FF/SS/FS/SF, plus SKY130 1.8V SVT and LVT at TT. Coefficients
remain upstream BSIM4 values; SKY130 wrapper geometry alone is converted from
micrometres to SI. Source commits, hashes, licenses and preparation scripts are
included. These experimental open PDKs are not TSMC or signoff libraries.
Supported bindings load their matching implementations automatically; imported
implementations and selected corners take precedence. Partial conflicting
libraries produce a clear error rather than duplicate model cards.

Personal self-contained model packets can be named and saved locally, then
reused in other projects. Native library checks verify persistence, deduplication
and rejection of control/file directives. `scripts/verify_model_library.py` runs
all bundled packets through the actual embedded ngspice; an optional first
argument supplies a read-only inverter SPICE export for an additional SKY130
solve. Local results are recorded separately from GUI and purchase validation.

## Course CAD drawings

`CourseCAD/source-inventory.json` records the supplied 30 source filenames and
page counts. The generator emits 35 authored example families, 155 editable
configurations and 211 analysis presets; textbook scans are not bundled.
`Independent/course-layouts.json` gives every example an explicit layout,
including device orientation, real supply trunks and local grounds. Routing
failure is an error; it never creates disconnected name stubs as a substitute.
Controlled-voltage-source blocks retain actual control terminals and owned model
implementations. The preparation pipeline verifies that layout does not change
the simulation source.

`node --test Engineering/Independent/model.test.mjs` checks pin connectivity, crossings, transactions, transform geometry, AI rails/ground and export bounds. `python3 scripts/verify_independent_courses.py EVIDENCE_DIRECTORY` prepares all 155 configurations, validates their physical net partitions and compiles the current native solver to run all 211 analysis presets. `scripts/verify_independent.py` exercises the actual WKWebView/native bridge, real plots, probe picking, clipboard PNG and document serialization. Runtime evidence is distinct from manual UI, live provider and StoreKit purchase validation.
