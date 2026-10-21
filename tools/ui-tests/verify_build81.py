#!/usr/bin/env python3
"""build 81: tap the pill → PLAUD must wake+connect; then check the List page."""
import sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from wda_client import WDA

OUT = Path("/tmp/plaud81")
OUT.mkdir(exist_ok=True)


def dump(w, tag):
    shot = w.screenshot(OUT / f"{tag}.png")
    boxes = w.texts(shot)
    print(f"=== {tag} ===")
    for b in boxes:
        if b.y < 860:
            print(f"  ({int(b.x)},{int(b.y)}) {b.text}")
    return boxes


w = WDA()
w.start_session()
try:
    w.terminate_app()
    w.launch_app(wait=5.0)
    time.sleep(1.5)

    boxes = dump(w, "10_before")
    pill = None
    for b in boxes:
        if b.y < 120 and ("PLAUD" in b.text.upper() or "TicNote" in b.text):
            pill = b
            break
    if pill is None:
        raise SystemExit("pill not found")

    print(f"→ tapping pill at ({int(pill.x)},{int(pill.y)})")
    w.tap(int(pill.x), int(pill.y), settle=2.0)

    for i in range(8):
        time.sleep(3)
        boxes = dump(w, f"2{i}_wait")
        names = [b.text for b in boxes]
        if any("卡上录音" in n or "开始录音" in n or "重新连接" in n for n in names):
            print("→ card page appeared")
            break
finally:
    try:
        w.end_session()
    except Exception:
        pass
