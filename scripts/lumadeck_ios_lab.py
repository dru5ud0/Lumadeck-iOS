#!/usr/bin/env python3
"""Control and capture the Lumadeck iOS test device over USB.

This wrapper keeps device identifiers, output paths, and pymobiledevice3
invocations consistent. Passcodes are read from an environment variable and
translated directly into HID taps; they are never printed or written to disk.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


APP_ROOT = Path(__file__).resolve().parents[1]
WORKSPACE_ROOT = APP_ROOT.parents[1]
DEFAULT_PYMOBILEDEVICE3 = Path(
    os.environ.get(
        "PYMOBILEDEVICE3_EXE",
        Path(os.environ.get("LOCALAPPDATA", ""))
        / "Temp"
        / "opencode"
        / "pymobiledevice3-venv"
        / "Scripts"
        / "pymobiledevice3.exe",
    )
)
DEFAULT_UDID = "00008030-001A6418022A802E"
DEFAULT_BUNDLE_ID = "com.nuvio.app.B63937U9BG"
DEFAULT_EVIDENCE_ROOT = WORKSPACE_ROOT / "loot" / "logs" / "lumadeck-ios"
MOCK_STATES = (
    "connecting",
    "playing",
    "paused",
    "preparing-relay",
    "compatibility",
    "reconnecting",
    "live",
    "ended",
    "failed",
    "long-title",
)

# iPhone 11 passcode keypad centers in normalized 16-bit display coordinates.
# Coordinates can be overridden without changing code if display calibration changes.
DEFAULT_PASSCODE_KEYPAD = {
    "1": (13150, 31600),
    "2": (32768, 31600),
    "3": (52350, 31600),
    "4": (13150, 37800),
    "5": (32768, 37800),
    "6": (52350, 37800),
    "7": (13150, 44000),
    "8": (32768, 44000),
    "9": (52350, 44000),
    "0": (32768, 50250),
}


class LabError(RuntimeError):
    """A device-lab operation failed."""


class IPhoneLab:
    def __init__(self, executable: Path, udid: str, bundle_id: str) -> None:
        if not executable.is_file():
            raise LabError(f"pymobiledevice3 executable not found: {executable}")
        self.executable = executable
        self.udid = udid
        self.bundle_id = bundle_id
        self.environment = os.environ.copy()
        self.environment["PYMOBILEDEVICE3_UDID"] = udid

    def run(
        self,
        arguments: list[str],
        *,
        timeout: int = 120,
        input_text: str | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        command = [str(self.executable), *arguments]
        result = subprocess.run(
            command,
            input=input_text,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=timeout,
            env=self.environment,
            check=False,
        )
        if check and result.returncode != 0:
            detail = (result.stderr or result.stdout).strip()
            raise LabError(f"pymobiledevice3 failed ({result.returncode}): {detail}")
        return result

    def devices(self) -> list[dict[str, Any]]:
        result = self.run(["usbmux", "list"])
        value = json.loads(result.stdout)
        return value if isinstance(value, list) else []

    def mount_developer_image(self) -> None:
        self.run(["mounter", "auto-mount"], timeout=180)

    def lock_state(self, *, check: bool = True) -> str:
        result = self.run(
            ["developer", "core-device", "get-lockstate"],
            check=check,
        )
        return (result.stdout or result.stderr).strip()

    def screenshot(self, destination: Path) -> Path:
        destination.parent.mkdir(parents=True, exist_ok=True)
        self.run(
            [
                "developer",
                "core-device",
                "screen-capture",
                "screenshot",
                str(destination),
            ]
        )
        return destination

    def launch(self, arguments: list[str] | None = None) -> None:
        command = ["developer", "core-device", "launch-application", self.bundle_id]
        if arguments:
            command.extend(["--", *arguments])
        for attempt in range(3):
            result = self.run(command, check=False)
            if result.returncode == 0:
                return
            if attempt < 2:
                time.sleep(1)
        detail = (result.stderr or result.stdout).strip()
        raise LabError(f"pymobiledevice3 failed ({result.returncode}): {detail}")

    def button(self, name: str) -> None:
        self.run(["developer", "core-device", "hid", "button", name, "press"])

    def tap(self, x: int, y: int) -> None:
        self._validate_coordinate(x)
        self._validate_coordinate(y)
        self.run(
            [
                "developer",
                "core-device",
                "universal-hid-service",
                "tap",
                str(x),
                str(y),
            ]
        )

    def drag(self, x1: int, y1: int, x2: int, y2: int, duration: float) -> None:
        for coordinate in (x1, y1, x2, y2):
            self._validate_coordinate(coordinate)
        self.run(
            [
                "developer",
                "core-device",
                "universal-hid-service",
                "drag",
                str(x1),
                str(y1),
                str(x2),
                str(y2),
                "--duration",
                str(duration),
            ]
        )

    def gesture_session(self, instructions: list[str]) -> None:
        payload = "\n".join(instructions) + "\n"
        self.run(
            [
                "developer",
                "core-device",
                "universal-hid-service",
                "session",
            ],
            input_text=payload,
        )

    def unlock(self, passcode: str) -> None:
        if not passcode or any(character not in DEFAULT_PASSCODE_KEYPAD for character in passcode):
            raise LabError("automatic unlock currently requires a numeric passcode")
        instructions = [
            "drag 32768 59000 32768 17000 30 0.45",
            "sleep 0.8",
        ]
        for character in passcode:
            x, y = DEFAULT_PASSCODE_KEYPAD[character]
            instructions.append(f"tap {x} {y}")
            instructions.append("sleep 0.12")
        self.gesture_session(instructions)
        time.sleep(1)

    @staticmethod
    def _validate_coordinate(value: int) -> None:
        if not 0 <= value <= 65535:
            raise LabError(f"HID coordinate must be between 0 and 65535: {value}")


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def create_evidence_run(lab: IPhoneLab, root: Path, label: str) -> Path:
    run_directory = root / f"{utc_timestamp()}-{label}"
    run_directory.mkdir(parents=True, exist_ok=False)
    devices = lab.devices()
    lock_state = lab.lock_state(check=False)
    manifest = {
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "label": label,
        "udid": lab.udid,
        "bundleId": lab.bundle_id,
        "devices": devices,
        "lockState": lock_state,
    }
    write_json(run_directory / "manifest.json", manifest)
    try:
        lab.screenshot(run_directory / "iphone.png")
    except LabError as error:
        write_json(run_directory / "screenshot-error.json", {"error": str(error)})
    return run_directory


def capture_mock_matrix(
    lab: IPhoneLab,
    root: Path,
    states: list[str],
    settle_seconds: float,
) -> Path:
    run_directory = root / f"{utc_timestamp()}-airplay-mock-matrix"
    run_directory.mkdir(parents=True, exist_ok=False)
    captures = []
    for state in states:
        lab.launch(["--airplay-mock", state])
        time.sleep(settle_seconds)
        screenshot = lab.screenshot(run_directory / f"{state}.png")
        captures.append({"state": state, "screenshot": screenshot.name})
    write_json(
        run_directory / "manifest.json",
        {
            "createdAt": datetime.now(timezone.utc).isoformat(),
            "udid": lab.udid,
            "bundleId": lab.bundle_id,
            "captures": captures,
        },
    )
    return run_directory


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pymobiledevice3", type=Path, default=DEFAULT_PYMOBILEDEVICE3)
    parser.add_argument("--udid", default=os.environ.get("PYMOBILEDEVICE3_UDID", DEFAULT_UDID))
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("status")
    subparsers.add_parser("mount")
    launch = subparsers.add_parser("launch")
    launch.add_argument("argument", nargs="*")
    subparsers.add_parser("home")
    subparsers.add_parser("lock")

    screenshot = subparsers.add_parser("screenshot")
    screenshot.add_argument("output", type=Path)

    tap = subparsers.add_parser("tap")
    tap.add_argument("x", type=int)
    tap.add_argument("y", type=int)

    drag = subparsers.add_parser("drag")
    drag.add_argument("x1", type=int)
    drag.add_argument("y1", type=int)
    drag.add_argument("x2", type=int)
    drag.add_argument("y2", type=int)
    drag.add_argument("--duration", type=float, default=0.45)

    unlock = subparsers.add_parser("unlock")
    unlock.add_argument("--passcode-env", default="RX_PHONE_PASSWORD")

    capture = subparsers.add_parser("capture")
    capture.add_argument("--label", default="manual")
    capture.add_argument("--output-root", type=Path, default=DEFAULT_EVIDENCE_ROOT)

    matrix = subparsers.add_parser("mock-matrix")
    matrix.add_argument("--state", action="append", choices=MOCK_STATES, dest="states")
    matrix.add_argument("--settle-seconds", type=float, default=1.5)
    matrix.add_argument("--output-root", type=Path, default=DEFAULT_EVIDENCE_ROOT)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        lab = IPhoneLab(args.pymobiledevice3, args.udid, args.bundle_id)
        if args.command == "status":
            print(json.dumps({"devices": lab.devices(), "lockState": lab.lock_state(check=False)}, indent=2))
        elif args.command == "mount":
            lab.mount_developer_image()
            print("Developer image mounted.")
        elif args.command == "launch":
            lab.launch(args.argument)
            print(f"Launched {lab.bundle_id}.")
        elif args.command == "home":
            lab.button("home")
        elif args.command == "lock":
            lab.button("lock")
        elif args.command == "screenshot":
            print(lab.screenshot(args.output).resolve())
        elif args.command == "tap":
            lab.tap(args.x, args.y)
        elif args.command == "drag":
            lab.drag(args.x1, args.y1, args.x2, args.y2, args.duration)
        elif args.command == "unlock":
            passcode = os.environ.get(args.passcode_env, "")
            if not passcode:
                raise LabError(f"passcode environment variable is not set: {args.passcode_env}")
            lab.unlock(passcode)
            print("Unlock gesture sent.")
        elif args.command == "capture":
            print(create_evidence_run(lab, args.output_root, args.label).resolve())
        elif args.command == "mock-matrix":
            states = args.states or list(MOCK_STATES)
            print(capture_mock_matrix(lab, args.output_root, states, args.settle_seconds).resolve())
        else:
            raise LabError(f"unsupported command: {args.command}")
    except (LabError, OSError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        print(f"iPhone lab failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
