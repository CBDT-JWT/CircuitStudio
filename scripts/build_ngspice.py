#!/usr/bin/env python3
"""Build the pinned ngspice core for Apple devices and simulators; requires Xcode."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Vendor/ngspice"
WORK = Path("/tmp/circuitstudio-ngspice-build")
VERSION = "47"
SHA256 = "894e649651f1838a14095e5a5439e7d3aa63e87ede14d283173fda4fcdef675f"
URL = f"https://downloads.sourceforge.net/project/ngspice/ng-spice-rework/{VERSION}/ngspice-{VERSION}.tar.gz"
SLICES = {
    "ios-arm64": ("iphoneos", "arm64", "-miphoneos-version-min=26.0"),
    "ios-simulator-arm64": ("iphonesimulator", "arm64", "-mios-simulator-version-min=26.0"),
    "ios-simulator-x86_64": ("iphonesimulator", "x86_64", "-mios-simulator-version-min=26.0"),
    "macos-arm64": ("macosx", "arm64", "-mmacosx-version-min=26.0"),
    "macos-x86_64": ("macosx", "x86_64", "-mmacosx-version-min=26.0"),
}

def prepare():
    WORK.mkdir(parents=True, exist_ok=True)
    archive = Path(f"/tmp/circuitstudio-ngspice-{VERSION}.tar.gz")
    if not archive.exists():
        subprocess.run(["curl", "-fL", "--retry", "3", URL, "-o", str(archive)], check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError("ngspice source checksum did not match the pinned release")
    source = WORK / f"ngspice-{VERSION}"
    if not source.exists():
        with tarfile.open(archive) as package:
            package.extractall(WORK, filter="data")
    # Release 47 references an XSPICE-only enum from its disabled branch.
    # Remove that unreachable option case; no simulation device code changes.
    options = source / "src/spicelib/analysis/cktsopt.c"
    broken = '#else\n    case OPT_ENH_RSHUNT:\n        fprintf(stderr, "WARNING - Option Rshunt available only with XSPICE enabled.\\n");\n        break;\n'
    contents = options.read_text()
    if broken in contents:
        options.write_text(contents.replace(broken, "", 1))
    VENDOR.mkdir(parents=True, exist_ok=True)
    for name in ["COPYING", "AUTHORS"]:
        shutil.copy2(source / name, VENDOR / name)
    shutil.copy2(source / "COPYING", ROOT / "Resources/ngspice-COPYING.txt")
    headers = WORK / "Headers"
    headers.mkdir(exist_ok=True)
    shutil.copy2(source / "src/include/ngspice/sharedspice.h", headers / "sharedspice.h")
    (headers / "NgSpice.h").write_text('#include <stdbool.h>\n#include "sharedspice.h"\n')
    (headers / "module.modulemap").write_text('module NgSpice { umbrella header "NgSpice.h" export * }\n')
    return source, headers

def build(name, source, jobs):
    sdk, arch, minimum = SLICES[name]
    directory = WORK / name
    directory.mkdir(exist_ok=True)
    sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    flags = f"-arch {arch} -isysroot {sdk_path} {minimum} -O2 -fPIC -include {VENDOR / 'ios_compat.h'}"
    stamp = directory / "configuration.json"
    configuration = {"flags": flags, "source": str(source), "staticAPI": True}
    if (directory / "Makefile").exists() and (not stamp.exists() or json.loads(stamp.read_text()) != configuration):
        subprocess.run(["make", "clean"], cwd=directory, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    env = os.environ.copy()
    env.update(CC=f"xcrun --sdk {sdk} clang", CXX=f"xcrun --sdk {sdk} clang++",
               CFLAGS=flags, CXXFLAGS=flags, LDFLAGS=f"-arch {arch} -isysroot {sdk_path} {minimum}",
               ac_cv_func_fork="no", ac_cv_func_vfork="no", ac_cv_func_system="no")
    host = "aarch64-apple-darwin" if arch == "arm64" else "x86_64-apple-darwin"
    print(f"Building {name} (log: {directory / 'build.log'})", flush=True)
    with (directory / "configure.log").open("w") as log:
        subprocess.run([str(source / "configure"), f"--host={host}", "--with-ngshared",
                        "--enable-static", "--enable-shared", "--disable-xspice", "--disable-osdi",
                        "--disable-openmp", "--with-readline=no", "--with-fftw3=no", "--without-x"],
                       cwd=directory, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    stamp.write_text(json.dumps(configuration))
    # Build upstream's PIC objects with SHARED_MODULE's C API enabled.
    (directory / "src/libngspice.la").unlink(missing_ok=True)
    with (directory / "build.log").open("w") as log:
        subprocess.run(["make", f"-j{jobs}"], cwd=directory, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    # Upstream forces -shared, so combine the same core objects with Apple's archiver.
    # This avoids distributing or loading any dynamic library on the device.
    objects = sorted(path for path in (directory / "src").rglob("*.o") if path.parent.name == ".libs")
    object_list = directory / "static-objects.txt"
    object_list.write_text("".join(str(path) + "\n" for path in objects))
    library = directory / "src/.libs/libngspice.a"
    subprocess.run(["xcrun", "libtool", "-static", "-filelist", str(object_list), "-o", str(library)], check=True)
    if not library.is_file():
        raise RuntimeError(f"Static library was not generated for {name}")
    print(f"Finished {name}: {library.stat().st_size / 1e6:.1f} MB", flush=True)
    return library

def package(headers):
    combinations = [("ios", ["ios-arm64"]),
                    ("ios-simulator", ["ios-simulator-arm64", "ios-simulator-x86_64"]),
                    ("macos", ["macos-arm64", "macos-x86_64"])]
    command = ["xcodebuild", "-create-xcframework"]
    for platform, names in combinations:
        folder = WORK / "Universal" / platform
        folder.mkdir(parents=True, exist_ok=True)
        output = folder / "libngspice.a"
        libraries = [WORK / name / "src/.libs/libngspice.a" for name in names]
        if len(libraries) == 1:
            shutil.copy2(libraries[0], output)
        else:
            subprocess.run(["xcrun", "lipo", "-create", *map(str, libraries), "-output", str(output)], check=True)
        command += ["-library", str(output), "-headers", str(headers)]
    output = VENDOR / "NgSpice.xcframework"
    if output.exists():
        shutil.rmtree(output)
    subprocess.run(command + ["-output", str(output)], check=True)
    (VENDOR / "BUILD.txt").write_text(f"ngspice {VERSION}\nSource: {URL}\nSHA256: {SHA256}\n"
        "Static shared-API core; XSPICE, OSDI, OpenMP, readline, FFTW and X11 disabled.\n"
        "Device: arm64; simulator and macOS: arm64 + x86_64. Minimum OS: 26.\n"
        "iOS CLI shell/plot helpers return ENOTSUP; simulation devices are unmodified.\n"
        "Release 47 patch: remove the disabled-XSPICE case referencing its missing OPT_ENH_RSHUNT enum.\n"
        "Rebuild: python3 scripts/build_ngspice.py\n")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--slice", choices=SLICES)
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("--package-only", action="store_true")
    args = parser.parse_args()
    source, headers = prepare()
    if not args.package_only:
        names = [args.slice] if args.slice else list(SLICES)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            list(executor.map(lambda name: build(name, source, args.jobs), names))
    if not args.slice:
        package(headers)
