#!/usr/bin/env python3
"""Inspect the mounted, signed distribution, without following its install link."""
import os
import plistlib
import subprocess
import sys
from pathlib import Path

from check_publication import findings, leaks, private_terms

APP = "OpenConnect Native.app"
RES = "Contents/Resources/"
HELPER = RES + "OpenConnect/bin/CiscoConnectHelper"
MAIN = "Contents/MacOS/CiscoConnect"
BINARY = {MAIN, HELPER}
META = {"Contents/PkgInfo", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"}
RESOURCE = {name: name for name in [
    "InstallPrivilegedHelper.sh", "UninstallPrivilegedHelper.sh",
    "OpenConnectVPNScript.sh", "com.max.openconnectnative.helper.plist"]}
RESOURCE["OpenConnect/vpnc-script"] = "OpenConnectVPNScript.sh"
UPSTREAM = "OpenConnect/vpnc-script.upstream"
LICENSE = "OpenConnect/OpenConnect-LGPL-2.1.txt"
ICON = "OpenConnectNative.icns"


def audit(root):
    terms = private_terms()
    link = root / "Applications"
    app = root / APP
    if set(os.listdir(root)) != {APP, "Applications"} or not link.is_symlink() or os.readlink(link) != "/Applications" or app.is_symlink() or not app.is_dir():
        raise ValueError("Unexpected disk image layout")
    required = META | BINARY | {RES + r for r in [*RESOURCE, ICON, UPSTREAM]}
    allowed = required | {RES + LICENSE}
    dirs = {str(parent) for name in allowed for parent in Path(name).parents} | {"Contents/Frameworks"}
    seen = set()
    libs = set()
    for file in app.rglob("*"):
        name = file.relative_to(app).as_posix()
        if file.is_symlink() or findings(name.encode(), "", terms):
            raise ValueError("Unexpected link or private path")
        if file.is_dir() and name in dirs:
            continue
        dylib = file.parent == app / "Contents/Frameworks" and file.suffix == ".dylib"
        if not file.is_file() or not (name in allowed or dylib):
            raise ValueError("Unexpected bundle entry")
        data = file.read_bytes()
        vendor = name in {RES + UPSTREAM, RES + LICENSE}
        machine = dylib or name in BINARY
        if findings(data, name, terms, binary=machine or vendor or name == RES + ICON):
            raise ValueError("Private data in bundle")
        if name in BINARY and findings(data.replace(b"\0", b"\n"), name, terms):
            raise ValueError("Private value in first-party executable")
        if machine:
            subprocess.run(["otool", "-hv", file], check=True, stdout=subprocess.DEVNULL)
            if data[:4].hex() not in {"cffaedfe","feedfacf","cafebabe","cafebabf"}:
                raise ValueError("Invalid Mach-O")
        if dylib:
            libs.add(file.name)
        if name.startswith(RES):
            item = name[len(RES):]
            if item in RESOURCE or item == ICON:
                source = Path(__file__).resolve().parents[1] / "App/Resources" / RESOURCE.get(item, item)
                if data != source.read_bytes():
                    raise ValueError("Unexpected first-party resource")
            if vendor:
                if item == UPSTREAM:
                    source = os.environ.get("VPNC_SCRIPT") or subprocess.check_output(["brew","--prefix"], text=True).strip() + "/etc/vpnc/vpnc-script"
                else:
                    source = os.environ.get("OPENCONNECT_LICENSE") or subprocess.check_output(["brew","--prefix","openconnect"], text=True).strip() + "/COPYING.LGPL"
                if data != Path(source).read_bytes():
                    raise ValueError("Unexpected third-party resource")
        seen.add(name)
    if required - seen or not libs:
        raise ValueError("Missing runtime component")
    reachable = set()
    queue = [app / HELPER, app / MAIN]
    while queue:
        for line in subprocess.check_output(["otool", "-L", queue.pop()], text=True).splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith("@rpath/"):
                lib = dependency[7:]
                if lib in libs and lib not in reachable:
                    reachable.add(lib)
                    queue.append(app / "Contents/Frameworks" / lib)
    if libs != reachable:
        raise ValueError("Unreferenced runtime library")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleExecutable") != "CiscoConnect" or info.get("CFBundleIdentifier") != "com.max.ciscoconnect":
        raise ValueError("Unexpected bundle identity")
    leaks("dir", str(app))


if __name__ == "__main__":
    try:
        audit(Path(sys.argv[1]))
    except (ValueError, OSError, subprocess.CalledProcessError):
        sys.exit("Disk image rejected: content, dependency or scanner verification failed")
