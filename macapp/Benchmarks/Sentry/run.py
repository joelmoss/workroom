#!/usr/bin/env python3
"""Build an optimized helper, collect only local telemetry, and compare fresh processes."""

import argparse
import gzip
import hashlib
import http.server
import json
import os
from pathlib import Path
import platform
import plistlib
import signal
import subprocess
import sys
import tempfile
import threading
import time


def items(body):
    """Read envelope item boundaries; payloads can contain newlines."""
    stream = memoryview(body)
    offset = body.index(b"\n") + 1
    result = []
    while offset < len(stream):
        end = body.index(b"\n", offset)
        header = json.loads(bytes(stream[offset:end]))
        offset = end + 1
        size = header["length"]
        payload = bytes(stream[offset:offset + size])
        if len(payload) != size:
            raise ValueError("truncated envelope")
        result.append((header["type"], payload))
        offset += size
        if offset < len(stream) and stream[offset] == 10:
            offset += 1
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--seconds", type=float, default=5)
    parser.add_argument("--tail", type=float, default=2)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--modes", default="off,no-profiling,full")
    parser.add_argument("--verify-chunk", action="store_true",
                        help="also run one long full-profile control after the short comparisons")
    args = parser.parse_args()
    if args.seconds < 1 or args.tail < 1 or args.rounds < 1:
        parser.error("durations and rounds must be positive")
    modes = args.modes.split(",")
    if any(mode not in ("off", "no-profiling", "full") for mode in modes):
        parser.error("unknown mode")
    root = Path(__file__).resolve().parents[3]
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=False)
    framework = root / "macapp/DerivedData/Build/Products/Debug"
    sdk_info = framework / "Sentry.framework/Resources/Info.plist"
    with sdk_info.open("rb") as handle:
        sdk_version = plistlib.load(handle)["CFBundleShortVersionString"]
    helper = output / "SentryProbe.app"
    executable = helper / "Contents/MacOS/SentryProbe"
    executable.parent.mkdir(parents=True)
    with (helper / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump({
            "CFBundleIdentifier": "com.developwithstyle.workroom.sentry-benchmark",
            "CFBundleExecutable": "SentryProbe", "CFBundleName": "SentryProbe",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0", "LSMinimumSystemVersion": "15.0",
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
        }, handle)
    command = [
        "xcrun", "swiftc", "-O", "-swift-version", "6", "-target",
        f"{platform.machine()}-apple-macos15.0", "-F", str(framework),
        "-framework", "Sentry", "-framework", "AppKit", "-lc++", "-lz",
        str(root / "macapp/WorkroomApp/Core/SentryConfig.swift"),
        str(root / "macapp/WorkroomApp/Core/LaunchSignposts.swift"),
        str(Path(__file__).with_name("Failure.swift")),
        str(Path(__file__).with_name("main.swift")), "-o", str(executable),
    ]
    subprocess.run(command, check=True)
    source_hashes = {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in (
            root / "macapp/WorkroomApp/Core/SentryConfig.swift",
            root / "macapp/WorkroomApp/Core/LaunchSignposts.swift",
            Path(__file__).with_name("Failure.swift"),
            Path(__file__).with_name("main.swift"),
        )
    }
    framework_hash = hashlib.sha256((framework / "Sentry.framework/Sentry").read_bytes()).hexdigest()
    subprocess.run(["codesign", "--force", "--sign", "-", str(helper)], check=True)
    envelopes = []
    errors = []
    active_run = [""]

    class Collector(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            try:
                data = self.rfile.read(int(self.headers["Content-Length"]))
                if self.headers.get("Content-Encoding") == "gzip":
                    data = gzip.decompress(data)
                parsed = items(data)
                metadata = []
                for kind, payload in parsed:
                    entry = {"type": kind, "bytes": len(payload)}
                    if kind == "profile_chunk":
                        entry["samples"] = len(json.loads(payload)["profile"]["samples"])
                        if entry["samples"] < 2:
                            raise ValueError("profile chunk contains no usable samples")
                    metadata.append(entry)
                name = f"envelope-{len(envelopes):04d}.bin"
                (output / name).write_bytes(data)
                envelopes.append({
                    "run": active_run[0], "file": name,
                    "items": metadata,
                })
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"{}")
            except Exception as error:
                errors.append(repr(error))
                self.send_response(500)
                self.end_headers()

    server = http.server.HTTPServer(("127.0.0.1", 0), Collector)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    reports = []
    try:
        with tempfile.TemporaryDirectory(prefix="workroom-sentry-probe-") as home:
            for iteration in range(args.rounds):
                # Rotate order to reduce systematic cache/thermal ordering effects.
                order = modes[iteration % len(modes):] + modes[:iteration % len(modes)]
                for mode in order:
                    name = f"{iteration + 1}-{mode}"
                    active_run[0] = name
                    report_path = output / f"{name}.json"
                    local_env = {
                        "SENTRY_DSN": f"http://local@127.0.0.1:{server.server_port}/1",
                        "SENTRY_ENVIRONMENT": "local-performance-probe",
                        "CFFIXED_USER_HOME": home,
                    }
                    if os.environ.get("WORKROOM_SENTRY_PROBE_DEBUG") == "1":
                        local_env["WORKROOM_SENTRY_PROBE_DEBUG"] = "1"
                    print(f"Starting {name}", flush=True)
                    launch = ["/usr/bin/open", "-n", "-a", str(helper),
                              "--stdout", str(output / f"{name}.log"),
                              "--stderr", str(output / f"{name}.stderr.log")]
                    for key, value in local_env.items():
                        launch += ["--env", f"{key}={value}"]
                    launch += ["--args", mode, str(report_path), str(args.seconds), str(args.tail)]
                    pid_file = Path(str(report_path) + ".pid")
                    try:
                        subprocess.run(launch, check=True, timeout=30)
                        deadline = time.monotonic() + args.seconds * 3 + args.tail + 60
                        while not report_path.exists():
                            error_path = Path(str(report_path) + ".error.json")
                            if error_path.exists():
                                raise RuntimeError(json.loads(error_path.read_text())["error"])
                            if time.monotonic() >= deadline:
                                raise TimeoutError(f"Helper did not finish: {name}; inspect its logs")
                            if pid_file.exists():
                                try:
                                    os.kill(int(pid_file.read_text()), 0)
                                except ProcessLookupError:
                                    raise RuntimeError(f"Helper exited without report: {name}; inspect its logs")
                            time.sleep(0.2)
                        # Let SDK.close and NSApplication.terminate finish before the next arm.
                        while pid_file.exists():
                            try:
                                os.kill(int(pid_file.read_text()), 0)
                            except ProcessLookupError:
                                break
                            if time.monotonic() >= deadline:
                                raise TimeoutError(f"Helper did not exit: {name}")
                            time.sleep(0.2)
                    finally:
                        # On interruption, stop only the helper whose owned PID and path match.
                        if pid_file.exists():
                            pid = int(pid_file.read_text())
                            process = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="],
                                                     capture_output=True, text=True)
                            if process.returncode == 0 and Path(process.stdout.strip()).resolve() == executable:
                                os.kill(pid, signal.SIGTERM)
                    report = json.loads(report_path.read_text())
                    report["run"] = name
                    evidence = report["evidence"]
                    assert report["sdk_enabled"] == (mode != "off"), report
                    assert (evidence["profiler_starts"] > 0) == (mode == "full"), report
                    assert (evidence["hang_events"] > 0) == (mode != "off"), report
                    received = [item["type"] for envelope in envelopes
                                if envelope["run"] == name for item in envelope["items"]]
                    if mode != "off":
                        assert "event" in received and "transaction" in received, received
                    if mode == "full" and args.seconds + args.tail >= 65:
                        assert "profile_chunk" in received, received
                    elif mode != "full":
                        assert "profile_chunk" not in received, received
                    reports.append(report)
                    print(json.dumps({"run": name, "startup": report["startup"],
                                      "evidence": evidence, "received": received,
                                      "phases": report["results"]}), flush=True)
    finally:
        server.shutdown()
        thread.join()
        server.server_close()
        (output / "summary.json").write_text(json.dumps({
            "sdk_version": sdk_version, "seconds": args.seconds, "tail": args.tail,
            "source_sha256": source_hashes, "sdk_framework_sha256": framework_hash,
            "compile_command": command,
            "reports": reports, "envelopes": envelopes, "collector_errors": errors,
        }, indent=2))
    assert not errors, errors
    print(f"Validated {len(reports)} fresh processes; report: {output / 'summary.json'}")
    if args.verify_chunk:
        subprocess.run([
            sys.executable, str(Path(__file__).resolve()), "--out", str(output / "chunk-control"),
            "--seconds", "5", "--tail", "65", "--rounds", "1", "--modes", "full",
        ], check=True)


if __name__ == "__main__":
    main()
