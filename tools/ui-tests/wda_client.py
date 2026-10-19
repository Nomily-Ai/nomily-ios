#!/usr/bin/env python3
"""WebDriverAgent client + OCR for the Nomily UI tests.

Why a hand-rolled client: the app exposes almost nothing through accessibility (the tree is
just the tab bar), so the tests drive the UI by **coordinates read off screenshots**. Vision
OCR turns a screenshot into labelled points, which is enough for `tap("Recording Mode")`.

Nothing here depends on Appium's server — WDA's own HTTP API is all we need.
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

WDA_BASE = os.environ.get("WDA_URL", "http://localhost:8100")
DEVICE_UDID = os.environ.get("DEVICE_UDID", "00008130-000C39142191001C")
BUNDLE_ID = "com.nomily.app"

REPO = Path(__file__).resolve().parents[2]
ARTIFACTS = Path(os.environ.get("UI_TEST_ARTIFACTS", "/tmp/nomily-ui-tests"))

OCR_BIN = Path("/tmp/nomily-ocr")


# --------------------------------------------------------------------------- tooling discovery

def pymobiledevice3() -> str:
    candidate = shutil.which("pymobiledevice3")
    if candidate:
        return candidate
    fallback = Path.home() / ".workbuddy/binaries/python/envs/default/bin/pymobiledevice3"
    if fallback.exists():
        return str(fallback)
    raise RuntimeError("pymobiledevice3 not found (PATH or the managed venv)")


def ensure_ocr_binary() -> Path:
    """Compile `ocr.swift` once and cache the binary in /tmp."""
    source = Path(__file__).resolve().parent / "ocr.swift"
    if OCR_BIN.exists() and OCR_BIN.stat().st_mtime >= source.stat().st_mtime:
        return OCR_BIN
    subprocess.run(
        ["/usr/bin/swiftc", "-O", "-o", str(OCR_BIN), str(source)],
        check=True,
        capture_output=True,
    )
    return OCR_BIN


# --------------------------------------------------------------------------- models

@dataclass
class TextBox:
    text: str
    x: float
    y: float
    w: float
    h: float

    @property
    def center(self) -> tuple[int, int]:
        return int(self.x + self.w / 2), int(self.y + self.h / 2)


# --------------------------------------------------------------------------- WDA

class WDA:
    def __init__(self, url: str = WDA_BASE) -> None:
        self.url = url.rstrip("/")
        self.session_id: str | None = None

    # -- plumbing ----------------------------------------------------------
    def _request(self, method: str, path: str, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            f"{self.url}{path}",
            data=data,
            headers={"Content-Type": "application/json"},
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as error:
            payload = error.read().decode(errors="replace")
            raise RuntimeError(f"{method} {path} → {error.code}: {payload}") from None

    # -- session -----------------------------------------------------------
    def status(self) -> dict:
        return self._request("GET", "/status")

    def start_session(self) -> str:
        result = self._request(
            "POST",
            "/session",
            {
                "capabilities": {
                    "alwaysMatch": {
                        "bundleId": BUNDLE_ID,
                        "platformName": "iOS",
                        "automationName": "XCUITest",
                        "noReset": True,
                        "shouldTerminateApp": False,
                        # Keep the app in whatever state the previous case left it in.
                        "forceAppLaunch": False,
                    }
                }
            },
        )
        self.session_id = result.get("sessionId") or result["value"]["sessionId"]
        return self.session_id

    def end_session(self) -> None:
        if self.session_id:
            try:
                self._request("DELETE", f"/session/{self.session_id}")
            finally:
                self.session_id = None

    # -- interactions ------------------------------------------------------
    def terminate_app(self, bundle: str = BUNDLE_ID) -> None:
        assert self.session_id, "no session"
        self._request("POST", f"/session/{self.session_id}/wda/apps/terminate", {"bundleId": bundle})

    def launch_app(self, bundle: str = BUNDLE_ID, wait: float = 4.0) -> None:
        assert self.session_id, "no session"
        self._request("POST", f"/session/{self.session_id}/wda/apps/launch", {"bundleId": bundle})
        time.sleep(wait)

    def _actions(self, actions: list[dict]) -> None:
        assert self.session_id, "no session"
        self._request(
            "POST",
            f"/session/{self.session_id}/actions",
            {
                "actions": [
                    {
                        "type": "pointer",
                        "id": "finger1",
                        "parameters": {"pointerType": "touch"},
                        "actions": actions,
                    }
                ]
            },
        )

    def tap(self, x: int, y: int, settle: float = 1.2) -> None:
        self._actions(
            [
                {"type": "pointerMove", "duration": 0, "x": x, "y": y},
                {"type": "pointerDown", "button": 0},
                {"type": "pause", "duration": 90},
                {"type": "pointerUp", "button": 0},
            ]
        )
        time.sleep(settle)

    def swipe(self, x1: int, y1: int, x2: int, y2: int, milliseconds: int = 350) -> None:
        self._actions(
            [
                {"type": "pointerMove", "duration": 0, "x": x1, "y": y1},
                {"type": "pointerDown", "button": 0},
                {"type": "pointerMove", "duration": milliseconds, "x": x2, "y": y2},
                {"type": "pointerUp", "button": 0},
            ]
        )
        time.sleep(0.8)

    def source(self) -> str:
        assert self.session_id, "no session"
        return self._request("GET", f"/session/{self.session_id}/source")["value"]

    def screenshot(self, path: Path) -> Path:
        assert self.session_id, "no session"
        blob = self._request("GET", f"/session/{self.session_id}/screenshot")["value"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(base64.b64decode(blob))
        return path

    # -- OCR-backed helpers ------------------------------------------------
    def texts(self, shot: Path | None = None) -> list[TextBox]:
        image = shot or self.screenshot(ARTIFACTS / "_ocr.png")
        result = subprocess.run(
            [str(ensure_ocr_binary()), str(image)], check=True, capture_output=True
        )
        raw = json.loads(result.stdout.decode())
        return [TextBox(**row) for row in raw]

    @staticmethod
    def find(boxes: list[TextBox], needle: str, exact: bool = False) -> TextBox | None:
        # OCR pads CJK+latin mixes with spaces ("AI Visual Notes") — compare space-free.
        squash = lambda s: s.replace(" ", "").replace("\u3000", "")
        target = squash(needle)
        for box in boxes:
            text = squash(box.text)
            if (text == target) if exact else (target in text):
                return box
        return None

    def tap_text(self, needle: str, shot: Path | None = None, settle: float = 1.2) -> TextBox:
        boxes = self.texts(shot)
        box = self.find(boxes, needle)
        if box is None:
            raise LookupError(f"'{needle}' not on screen (saw: {[b.text for b in boxes][:12]})")
        x, y = box.center
        self.tap(x, y, settle=settle)
        return box

    def wait_for_text(self, needle: str, timeout: float = 8.0, poll: float = 1.5) -> TextBox:
        deadline = time.time() + timeout
        last: list[TextBox] = []
        while time.time() < deadline:
            last = self.texts()
            box = self.find(last, needle)
            if box is not None:
                return box
            time.sleep(poll)
        raise LookupError(
            f"'{needle}' never appeared within {timeout:.0f}s (last seen: {[b.text for b in last][:12]})"
        )


# --------------------------------------------------------------------------- device files

class DeviceFiles:
    """Reads the app's sandbox over USB — persistence assertions live here."""

    def __init__(self, udid: str = DEVICE_UDID) -> None:
        self.udid = udid
        self.binary = pymobiledevice3()

    def pull(self, relative: str, destination: Path) -> Path | None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            [
                self.binary, "apps", "pull", "--udid", self.udid,
                BUNDLE_ID, relative, str(destination),
            ],
            capture_output=True,
        )
        return destination if result.returncode == 0 and destination.exists() else None

    def config(self) -> dict:
        path = self.pull("Documents/config.json", ARTIFACTS / "_config.json")
        if path is None:
            return {}
        return json.loads(path.read_text())

    def ble_log(self) -> str:
        path = self.pull("Documents/ticnote-ble.log", ARTIFACTS / "_ble.log")
        return path.read_text(errors="replace") if path else ""


# --------------------------------------------------------------------------- tiny assert kit

class Case:
    def __init__(self, ident: str, title: str) -> None:
        self.ident = ident
        self.title = title
        self.status = "PASS"
        self.detail = ""

    def fail(self, message: str) -> None:
        self.status = "FAIL"
        self.detail = message

    def skip(self, message: str) -> None:
        if self.status != "FAIL":
            self.status = "SKIP"
            self.detail = message

    def ok(self, message: str = "") -> None:
        if self.detail:
            self.detail += " · "
        self.detail += message


def main_guard() -> None:
    if "--selftest" in sys.argv:
        print("ocr:", ensure_ocr_binary())
        client = WDA()
        print("wda:", client.status()["value"]["ready"])
