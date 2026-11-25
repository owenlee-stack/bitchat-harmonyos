#!/usr/bin/env python3
"""Cross-platform mesh interoperability lab (FR-032 / US16 / T075).

Semi-automated orchestrator for the acceptance scenarios defined in
CHECKLIST.md / scenarios.json, across one or two HarmonyOS (hdc) devices
and/or one Android (adb) reference device.

The HarmonyOS app intentionally ships no debug test hook (unlike the
Android TestHookReceiver); this lab therefore drives device preparation
(install / launch / log capture) and validates results by scanning
captured hilog/logcat for the per-scenario expected markers, while the
operator performs the on-screen steps printed from the checklist.

Usage:
    python tools/meshlab/meshlab.py doctor
    python tools/meshlab/meshlab.py setup --hap <path.hap> [--apk <path.apk>]
    python tools/meshlab/meshlab.py watch --scenario discovery --pair hm-hm
    python tools/meshlab/meshlab.py evidence

Evidence JSON and raw logs are written to tools/meshlab/out/ and MUST
stay local (never commit them): they may contain nicknames and message
metadata observed during the run.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent
SCENARIOS_PATH = TOOL_DIR / "scenarios.json"
EVIDENCE_DIR = TOOL_DIR / "out"

HM_BUNDLE = "com.bitchat.harmonyos"
HM_ABILITY = "EntryAbility"
ANDROID_PACKAGE_DEFAULT = "com.bitchat.droid"


class LabError(Exception):
    pass


def load_scenarios() -> dict:
    with open(SCENARIOS_PATH, "r", encoding="utf-8") as handle:
        return json.load(handle)["scenarios"]


def find_tool(name: str) -> str:
    from shutil import which

    path = which(name)
    if not path:
        raise LabError(f"tool not found on PATH: {name}")
    return path


def run_checked(argv: list, timeout: int = 120) -> str:
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise LabError(f"command timed out: {' '.join(argv)}") from exc
    if proc.returncode != 0:
        raise LabError(
            f"command failed ({proc.returncode}): {' '.join(argv)}\n{proc.stderr.strip()}"
        )
    return proc.stdout.strip()


def start_background(argv: list, out_path: Path) -> subprocess.Popen:
    out_handle = open(out_path, "wb")
    return subprocess.Popen(
        argv,
        stdout=out_handle,
        stderr=subprocess.STDOUT,
    )


class HdcDevice:
    """One HarmonyOS device driven through hdc."""

    kind = "harmony"

    def __init__(self, serial: str | None = None) -> None:
        self.tool = find_tool("hdc")
        self.serial = serial or self._first_target()

    def _base(self) -> list:
        return [self.tool, "-t", self.serial] if self.serial else [self.tool]

    def _first_target(self) -> str | None:
        out = run_checked([self.tool, "list", "targets"])
        lines = [line.strip() for line in out.splitlines() if line.strip()]
        targets = [line for line in lines if "[Empty]" not in line]
        if not targets:
            raise LabError("no HarmonyOS device attached (hdc list targets empty)")
        if len(targets) > 1:
            raise LabError(
                "multiple HarmonyOS devices attached; pass --hdc-serial "
                f"(one of: {', '.join(targets)})"
            )
        return targets[0]

    def shell(self, command: str) -> str:
        return run_checked(self._base() + ["shell", command])

    def install(self, hap: Path) -> None:
        print(f"[hdc {self.serial}] installing {hap.name} ...")
        run_checked(self._base() + ["install", str(hap)], timeout=300)

    def launch(self) -> None:
        print(f"[hdc {self.serial}] launching {HM_BUNDLE}/{HM_ABILITY} ...")
        self.shell(f"aa start -b {HM_BUNDLE} -a {HM_ABILITY}")

    def stop(self) -> None:
        self.shell(f"aa force-stop {HM_BUNDLE}")

    def reset_log(self) -> None:
        self.shell("hilog -r")

    def start_log(self, out_path: Path) -> subprocess.Popen:
        return start_background(self._base() + ["hilog"], out_path)


class AdbDevice:
    """One Android reference device driven through adb."""

    kind = "android"

    def __init__(self, serial: str | None = None, package: str = ANDROID_PACKAGE_DEFAULT) -> None:
        self.tool = find_tool("adb")
        self.package = package
        self.serial = serial or self._first_device()

    def _base(self) -> list:
        return [self.tool, "-s", self.serial] if self.serial else [self.tool]

    def _first_device(self) -> str | None:
        out = run_checked([self.tool, "devices"])
        lines = [line.strip() for line in out.splitlines()[1:] if line.strip()]
        devices = [line.split("\t")[0] for line in lines if line.endswith("device")]
        if not devices:
            raise LabError("no Android device attached (adb devices empty)")
        if len(devices) > 1:
            raise LabError(
                "multiple Android devices attached; pass --adb-serial "
                f"(one of: {', '.join(devices)})"
            )
        return devices[0]

    def shell(self, command: str) -> str:
        return run_checked(self._base() + ["shell", command])

    def install(self, apk: Path) -> None:
        print(f"[adb {self.serial}] installing {apk.name} ...")
        run_checked(self._base() + ["install", "-r", str(apk)], timeout=300)

    def launch(self) -> None:
        print(f"[adb {self.serial}] launching {self.package} ...")
        self.shell(
            f"monkey -p {self.package} -c android.intent.category.LAUNCHER 1"
        )

    def stop(self) -> None:
        self.shell(f"am force-stop {self.package}")

    def reset_log(self) -> None:
        run_checked(self._base() + ["logcat", "-c"])

    def start_log(self, out_path: Path) -> subprocess.Popen:
        return start_background(self._base() + ["logcat", "-v", "time"], out_path)


def pick_devices(pair: str, hdc_serial: str | None, adb_serial: str | None,
                 android_package: str) -> list:
    """Return the device objects for the requested pair."""
    if pair == "hm-hm":
        # Two hdc devices: caller must pass explicit serials for both.
        tool = find_tool("hdc")
        out = run_checked([tool, "list", "targets"])
        targets = [line.strip() for line in out.splitlines()
                   if line.strip() and "[Empty]" not in line]
        if hdc_serial:
            targets = [t for t in targets if t == hdc_serial] + \
                      [t for t in targets if t != hdc_serial and t in (hdc_serial,)]
        if len(targets) < 2:
            raise LabError(
                "pair hm-hm needs two attached HarmonyOS devices "
                f"(found {len(targets)}); connect both and retry"
            )
        return [HdcDevice(targets[0]), HdcDevice(targets[1])]
    if pair == "hm-android":
        return [HdcDevice(hdc_serial), AdbDevice(adb_serial, android_package)]
    raise LabError(f"unknown pair: {pair} (expected hm-hm or hm-android)")


def scan_markers(log_path: Path, markers: list) -> dict:
    matched: list = []
    try:
        content = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        content = ""
    for marker in markers:
        if marker.lower() in content.lower():
            matched.append(marker)
    return {
        "expected": markers,
        "matched": matched,
        "missing": [m for m in markers if m not in matched],
    }


def cmd_doctor(args: argparse.Namespace) -> None:
    print("== meshlab doctor ==")
    for name in ("hdc", "adb"):
        try:
            path = find_tool(name)
            print(f"  {name}: {path}")
        except LabError as exc:
            print(f"  {name}: MISSING ({exc})")
    try:
        out = run_checked([find_tool("hdc"), "list", "targets"])
        targets = [line.strip() for line in out.splitlines()
                   if line.strip() and "[Empty]" not in line]
        print(f"  HarmonyOS devices: {targets if targets else 'none'}")
    except LabError as exc:
        print(f"  HarmonyOS devices: {exc}")
    try:
        out = run_checked([find_tool("adb"), "devices"])
        print("  Android devices:\n" + "\n".join(
            f"    {line.strip()}" for line in out.splitlines()[1:] if line.strip()))
    except LabError as exc:
        print(f"  Android devices: {exc}")


def cmd_setup(args: argparse.Namespace) -> None:
    devices: list = []
    if args.hap:
        device = HdcDevice(args.hdc_serial)
        device.install(Path(args.hap))
        devices.append(device)
    if args.apk:
        device = AdbDevice(args.adb_serial, args.android_package)
        device.install(Path(args.apk))
        devices.append(device)
    if not devices:
        raise LabError("nothing to do: pass --hap and/or --apk")
    for device in devices:
        device.launch()
    print("setup complete")


def cmd_watch(args: argparse.Namespace) -> None:
    scenarios = load_scenarios()
    scenario = next((s for s in scenarios if s["id"] == args.scenario), None)
    if scenario is None:
        ids = ", ".join(s["id"] for s in scenarios)
        raise LabError(f"unknown scenario '{args.scenario}' (available: {ids})")

    devices = pick_devices(args.pair, args.hdc_serial, args.adb_serial,
                           args.android_package)

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = EVIDENCE_DIR / f"{stamp}_{args.scenario}_{args.pair}"
    run_dir.mkdir(parents=True, exist_ok=True)

    print(f"== scenario: {scenario['title']} (pair: {args.pair}) ==")
    print("operator steps:")
    for index, step in enumerate(scenario["steps"], start=1):
        print(f"  {index}. {step}")
    print("pass criteria:", scenario["pass"])
    print("log capture starts; perform the steps on the devices now.")

    captures: list = []
    for index, device in enumerate(devices):
        log_path = run_dir / f"{device.kind}_{index}_{device.serial or 'default'}.log"
        device.reset_log()
        proc = device.start_log(log_path)
        captures.append((device, log_path, proc))

    started_at = datetime.now(timezone.utc)
    try:
        if args.duration > 0:
            print(f"capturing for {args.duration}s (override interactively with --duration 0)...")
            time.sleep(args.duration)
        else:
            input("press ENTER to stop capture and evaluate ...")
    except KeyboardInterrupt:
        print("\ncapture interrupted by operator")
    finally:
        for _, _, proc in captures:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
    ended_at = datetime.now(timezone.utc)

    marker_results: dict = {}
    for device, log_path, _ in captures:
        markers = scenario["markers"].get(device.kind, [])
        if markers:
            marker_results[device.kind] = scan_markers(log_path, markers)

    operator_result = "unknown"
    if not args.yes:
        answer = input("operator verdict: did the scenario pass on-screen? [y/N] ")
        operator_result = "pass" if answer.strip().lower() == "y" else "fail"

    all_matched = all(
        not result["missing"] for result in marker_results.values()
    ) if marker_results else False
    verdict = "PASS" if (operator_result == "pass" and all_matched) else (
        "PARTIAL" if operator_result == "pass" else "FAIL")

    record = {
        "scenario": scenario["id"],
        "title": scenario["title"],
        "pair": args.pair,
        "started_at": started_at.isoformat(),
        "ended_at": ended_at.isoformat(),
        "devices": [
            {"kind": d.kind, "serial": d.serial} for d, _, _ in captures
        ],
        "markers": marker_results,
        "operator_result": operator_result,
        "verdict": verdict,
        "raw_logs": [str(p) for _, p, _ in captures],
        "note": "marker scan is advisory; the operator verdict is authoritative",
    }
    record_path = run_dir / "evidence.json"
    with open(record_path, "w", encoding="utf-8") as handle:
        json.dump(record, handle, ensure_ascii=False, indent=2)

    print("marker scan:")
    for kind, result in marker_results.items():
        print(f"  {kind}: matched={result['matched']} missing={result['missing']}")
    print(f"verdict: {verdict}")
    print(f"evidence: {record_path}")
    print("reminder: evidence may contain nicknames/message metadata; keep local, do not commit.")


def cmd_evidence(args: argparse.Namespace) -> None:
    if not EVIDENCE_DIR.exists():
        print("no evidence recorded yet")
        return
    for record_path in sorted(EVIDENCE_DIR.glob("*/evidence.json")):
        with open(record_path, "r", encoding="utf-8") as handle:
            record = json.load(handle)
        print(
            f"{record['started_at']}  {record['scenario']:<12} {record['pair']:<11}"
            f"  {record['verdict']:<8}  {record_path.parent.name}"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    doctor = sub.add_parser("doctor", help="check hdc/adb and attached devices")
    doctor.set_defaults(func=cmd_doctor)

    setup = sub.add_parser("setup", help="install builds and launch the apps")
    setup.add_argument("--hap", help="path to the HarmonyOS .hap to install")
    setup.add_argument("--apk", help="path to the Android .apk to install")
    setup.add_argument("--hdc-serial")
    setup.add_argument("--adb-serial")
    setup.add_argument("--android-package", default=ANDROID_PACKAGE_DEFAULT)
    setup.set_defaults(func=cmd_setup)

    watch = sub.add_parser("watch", help="run one acceptance scenario")
    watch.add_argument("--scenario", required=True,
                       help="scenario id from scenarios.json")
    watch.add_argument("--pair", default="hm-hm", choices=["hm-hm", "hm-android"])
    watch.add_argument("--duration", type=int, default=240,
                       help="capture seconds; 0 = wait for ENTER (default 240)")
    watch.add_argument("--yes", action="store_true",
                       help="skip the operator verdict prompt (result: unknown)")
    watch.add_argument("--hdc-serial")
    watch.add_argument("--adb-serial")
    watch.add_argument("--android-package", default=ANDROID_PACKAGE_DEFAULT)
    watch.set_defaults(func=cmd_watch)

    evidence = sub.add_parser("evidence", help="list recorded evidence runs")
    evidence.set_defaults(func=cmd_evidence)

    return parser


def main(argv: list) -> int:
    args = build_parser().parse_args(argv)
    try:
        args.func(args)
    except LabError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
