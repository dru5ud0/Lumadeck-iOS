#!/usr/bin/env python3
"""Generate and serve deterministic AirPlay media fixtures with JSONL logs."""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import socket
import subprocess
import sys
import threading
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit


APP_ROOT = Path(__file__).resolve().parents[1]
WORKSPACE_ROOT = APP_ROOT.parents[1]
DEFAULT_LAB_ROOT = WORKSPACE_ROOT / "loot" / "airplay-lab"
DEFAULT_FIXTURE_ROOT = DEFAULT_LAB_ROOT / "fixtures"
DEFAULT_LOG = WORKSPACE_ROOT / "loot" / "logs" / "lumadeck-airplay-origin.jsonl"
DEFAULT_FFMPEG = Path("C:/msys64/ucrt64/bin/ffmpeg.exe")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def parse_range(value: str | None, length: int) -> tuple[int, int] | None:
    if not value or not value.lower().startswith("bytes=") or length <= 0:
        return None
    requested = value[6:].split(",", 1)[0].strip()
    if "-" not in requested:
        return None
    start_text, end_text = requested.split("-", 1)
    try:
        if not start_text:
            suffix = int(end_text)
            if suffix <= 0:
                return None
            start = max(0, length - suffix)
            return start, length - 1
        start = int(start_text)
        end = int(end_text) if end_text else length - 1
    except ValueError:
        return None
    if start < 0 or start >= length or end < start:
        return None
    return start, min(end, length - 1)


class RequestLog:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()

    def append(self, record: dict[str, object]) -> None:
        payload = json.dumps(record, sort_keys=True) + "\n"
        with self.lock, self.path.open("a", encoding="utf-8") as output:
            output.write(payload)


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, root: Path, request_log: RequestLog, auth_token: str | None) -> None:
        super().__init__(address, FixtureHandler)
        self.root = root.resolve()
        self.request_log = request_log
        self.auth_token = auth_token


class FixtureHandler(BaseHTTPRequestHandler):
    server: FixtureServer
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        self._serve(send_body=True)

    def do_HEAD(self) -> None:
        self._serve(send_body=False)

    def _serve(self, *, send_body: bool) -> None:
        started = utc_now()
        status = HTTPStatus.OK
        bytes_sent = 0
        request_range = self.headers.get("Range")
        try:
            if self.path == "/health":
                body = b"ok\n"
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if send_body:
                    self.wfile.write(body)
                    bytes_sent = len(body)
                return
            if self.server.auth_token:
                expected = f"Bearer {self.server.auth_token}"
                if self.headers.get("Authorization") != expected:
                    status = HTTPStatus.UNAUTHORIZED
                    self.send_error(status)
                    return
            relative = unquote(urlsplit(self.path).path).lstrip("/")
            candidate = (self.server.root / relative).resolve()
            if self.server.root not in candidate.parents or not candidate.is_file():
                status = HTTPStatus.NOT_FOUND
                self.send_error(status)
                return
            length = candidate.stat().st_size
            selected_range = parse_range(request_range, length)
            start, end = selected_range or (0, max(0, length - 1))
            content_length = max(0, end - start + 1)
            status = HTTPStatus.PARTIAL_CONTENT if selected_range else HTTPStatus.OK
            content_type = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
            if candidate.suffix == ".m3u8":
                content_type = "application/vnd.apple.mpegurl"
            elif candidate.suffix == ".ts":
                content_type = "video/mp2t"
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(content_length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Cache-Control", "no-store" if candidate.suffix == ".m3u8" else "public, max-age=60")
            if selected_range:
                self.send_header("Content-Range", f"bytes {start}-{end}/{length}")
            self.end_headers()
            if send_body and content_length:
                with candidate.open("rb") as source:
                    source.seek(start)
                    remaining = content_length
                    while remaining:
                        block = source.read(min(64 * 1024, remaining))
                        if not block:
                            break
                        self.wfile.write(block)
                        remaining -= len(block)
                        bytes_sent += len(block)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.server.request_log.append(
                {
                    "timestamp": started,
                    "client": self.client_address[0],
                    "method": self.command,
                    "path": self.path,
                    "status": int(status),
                    "range": request_range,
                    "bytesSent": bytes_sent,
                    "userAgent": self.headers.get("User-Agent"),
                    "authorizationPresent": bool(self.headers.get("Authorization")),
                }
            )

    def log_message(self, format: str, *args) -> None:
        return


def generate_fixtures(root: Path, ffmpeg: Path, duration: int) -> dict[str, object]:
    if not ffmpeg.is_file():
        raise FileNotFoundError(f"ffmpeg not found: {ffmpeg}")
    root.mkdir(parents=True, exist_ok=True)
    mp4 = root / "lumadeck-airplay-test.mp4"
    hls = root / "hls"
    hls.mkdir(parents=True, exist_ok=True)
    common = [
        str(ffmpeg), "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30",
        "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000",
        "-t", str(duration), "-c:v", "libx264", "-preset", "veryfast",
        "-pix_fmt", "yuv420p", "-g", "60", "-keyint_min", "60",
        "-sc_threshold", "0", "-c:a", "aac", "-b:a", "128k",
    ]
    subprocess.run([*common, "-movflags", "+faststart", str(mp4)], check=True)
    subprocess.run(
        [
            *common,
            "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod",
            "-hls_segment_filename", str(hls / "segment-%03d.ts"),
            str(hls / "index.m3u8"),
        ],
        check=True,
    )
    files = [mp4, *sorted(hls.glob("*"))]
    manifest = {
        "generatedAt": utc_now(),
        "durationSeconds": duration,
        "files": [
            {"path": str(path.relative_to(root)).replace("\\", "/"), "bytes": path.stat().st_size, "sha256": sha256(path)}
            for path in files
        ],
    }
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def lan_address() -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.connect(("8.8.8.8", 80))
        return probe.getsockname()[0]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate = subparsers.add_parser("generate")
    generate.add_argument("--root", type=Path, default=DEFAULT_FIXTURE_ROOT)
    generate.add_argument("--ffmpeg", type=Path, default=DEFAULT_FFMPEG)
    generate.add_argument("--duration", type=int, default=30)
    serve = subparsers.add_parser("serve")
    serve.add_argument("--root", type=Path, default=DEFAULT_FIXTURE_ROOT)
    serve.add_argument("--host", default="0.0.0.0")
    serve.add_argument("--port", type=int, default=8765)
    serve.add_argument("--log", type=Path, default=DEFAULT_LOG)
    serve.add_argument("--auth-token-env")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "generate":
            print(json.dumps(generate_fixtures(args.root, args.ffmpeg, args.duration), indent=2))
            return 0
        if not args.root.is_dir():
            raise FileNotFoundError(f"fixture root not found: {args.root}")
        token = os.environ.get(args.auth_token_env) if args.auth_token_env else None
        server = FixtureServer((args.host, args.port), args.root, RequestLog(args.log), token)
        print(f"Origin ready: http://{lan_address()}:{args.port}/", flush=True)
        print(f"MP4: http://{lan_address()}:{args.port}/lumadeck-airplay-test.mp4", flush=True)
        print(f"HLS: http://{lan_address()}:{args.port}/hls/index.m3u8", flush=True)
        server.serve_forever()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"AirPlay origin failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
