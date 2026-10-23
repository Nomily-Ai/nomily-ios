#!/usr/bin/env python3
"""Build 66 verification — two changes on a real device.

① Scanner hides already-added devices: open the scan page, OCR the list,
   and confirm no device carrying the "已添加"/"Added" badge is rendered
   (the old build showed a dedicated section).
② Watch-face square frame preview: the face rows in
   Settings → Watch → Expressions must now show a rounded-square stroke.

Prereqs: iPhone unlocked over USB, WDA running, `iproxy 8100 8100`.
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from wda_client import WDA, ensure_ocr_binary  # noqa: E402

SHOTS = Path("/tmp/nomily-verify-66")
BUNDLE = "com.nomily.app"


def main() -> int:
    ensure_ocr_binary()
    SHOTS.mkdir(parents=True, exist_ok=True)
    wda = WDA()
    if not wda.status():
        print("WDA not running")
        return 2
    wda.start_session()
    wda.terminate_app(BUNDLE)
    time.sleep(1)
    wda.launch_app(BUNDLE, wait=5.0)

    # ── ① scan page ──────────────────────────────────────────────────────
    # Enter the scan page from home. The exact entry label differs by
    # language; try the two known wordings.
    shot = wda.screenshot(SHOTS / "home.png")
    boxes = wda.texts(shot)
    for label in ("添加设备", "扫描", "Add Device", "Scan"):
        box = WDA.find(boxes, label)
        if box:
            x, y = box.center
            wda.tap(x, y)
            break
    else:
        print("SKIP: scanner entry not found on home — tap manually and rerun")
        return 3

    time.sleep(4.0)  # BLE scan needs a beat to populate
    shot = wda.screenshot(SHOTS / "scanner.png")
    texts = [b.text for b in wda.texts(shot)]
    print("SCANNER TEXTS:", texts)

    added_badges = [t for t in texts if t in ("已添加", "Added")]
    print("ADDED_BADGE_COUNT:", len(added_badges))
    print("RESULT_SCANNER:", "PASS" if not added_badges else "FAIL")

    # Leave the scanner the way we found it.
    done = WDA.find(wda.texts(wda.screenshot(SHOTS / "scanner2.png")), "完成") \
        or WDA.find(wda.texts(wda.screenshot(SHOTS / "scanner3.png")), "Done")
    if done:
        x, y = done.center()
        wda.tap(x, y)

    # ── ② watch-face preview frame ──────────────────────────────────────
    # Home → Settings tab → Watch → Expressions. Tab bar labels follow the
    # app language; probe both.
    shot = wda.screenshot(SHOTS / "after_home.png")
    for label in ("设置", "Settings"):
        box = WDA.find(wda.texts(shot), label)
        if box:
            x, y = box.center
            wda.tap(x, y)
            break
    time.sleep(2)
    shot = wda.screenshot(SHOTS / "settings.png")
    for label in ("手表", "Watch"):
        box = WDA.find(wda.texts(shot), label)
        if box:
            x, y = box.center
            wda.tap(x, y)
            break
    time.sleep(2)
    shot = wda.screenshot(SHOTS / "watch.png")
    for label in ("表情", "Expressions", "表情形"):
        box = WDA.find(wda.texts(shot), label)
        if box:
            x, y = box.center
            wda.tap(x, y)
            break
    time.sleep(2)
    shot = wda.screenshot(SHOTS / "face_picker.png")
    print("FACE_PICKER_SHOT:", shot)
    print("NOTE: inspect face_picker.png visually — each row must show a",
          "rounded-square stroke around the eyes (frame toggle on).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
