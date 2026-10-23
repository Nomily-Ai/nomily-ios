#!/usr/bin/env python3
"""Smoke test for the summary poster (image-text share) flow.

Drive: ensure Nomily foreground -> Library -> first recording with a summary
-> transcript detail -> Summary tab -> View Full Summary -> poster toolbar
button -> assert the poster sheet renders (template chips visible) ->
screenshot for eyeballing.

Run: python3 tools/ui-tests/smoke_poster.py  (USB + iproxy 8100 + WDA required)
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from wda_client import WDA  # noqa: E402

OUT = Path("/tmp/poster_smoke")


def main() -> int:
    OUT.mkdir(exist_ok=True)
    wda = WDA()
    sid = wda.start_session()
    print("session:", sid)
    wda.terminate_app()
    time.sleep(1)
    wda.launch_app()
    time.sleep(3.5)  # splash logo

    # Library tab ("资料库" / "Library").
    try:
        wda.tap_text("资料库")
    except Exception:
        try:
            wda.tap_text("Library")
        except Exception as exc:
            print("FAIL: cannot find Library tab:", exc)
            wda.screenshot(OUT / "fail_1_home.png")
            return 1
    time.sleep(1.5)

    # First row in the library = most recent clip. Locate it via OCR so the
    # tap lands on the actual row, not a filter chip.
    boxes = wda.texts()
    row = None
    for b in boxes:
        if ("2026" in b.text or "KB" in b.text) and b.center[1] > 220:
            row = b
            break
    if row is None:
        print("FAIL: no library row found; saw:", [b.text for b in boxes][:12])
        wda.screenshot(OUT / "fail_1b_library.png")
        return 1
    print("tapping row:", row.text[:40], "at", row.center)
    wda.tap(*row.center, settle=2.0)
    wda.screenshot(OUT / "1_detail.png")

    # Open the summary tab ("AI 纪要"). Locate it via OCR; fall back to the
    # fixed position (segmented control under the player card).
    try:
        wda.tap_text("AI 纪要")
    except Exception:
        wda.tap(250, 446, settle=1.5)
    time.sleep(1.0)
    wda.screenshot(OUT / "2_summary_tab.png")

    # If this clip has no summary yet, generate one on the spot.
    boxes = wda.texts()
    joined = " ".join(b.text for b in boxes)
    if "查看完整摘要" not in joined and "View Full Summary" not in joined:
        for needle in ("生成摘要", "生成 AI 纪要", "Summarize"):
            if any(needle in b.text for b in boxes):
                wda.tap_text(needle)
                print("requested summary generation:", needle)
                break
        else:
            print("no summary and no generate button; saw:", [b.text for b in boxes][:14])
        # Wait for the job to finish and the full-summary link to appear.
        deadline = time.time() + 90
        while time.time() < deadline:
            time.sleep(3)
            boxes = wda.texts()
            joined = " ".join(b.text for b in boxes)
            if "查看完整摘要" in joined or "View Full Summary" in joined:
                break
        wda.screenshot(OUT / "2b_after_generate.png")

    # Full summary view.
    try:
        wda.tap_text("查看完整摘要")
    except Exception:
        try:
            wda.tap_text("View Full Summary")
        except Exception as exc:
            print("FAIL: cannot open full summary:", exc)
            wda.screenshot(OUT / "fail_2_detail.png")
            return 1
    time.sleep(1.2)

    # Poster button is an SF Symbol only (no text label) — tap by source
    # position: it sits between the raw-toggle and share buttons on the right.
    shot = OUT / "3_full_summary.png"
    wda.screenshot(shot)
    # Fallback: use the accessibility label through the source XML.
    src = wda.source()
    needle = "分享为图片"
    idx = src.find(needle)
    if idx < 0:
        idx = src.find("Share as Image")
    print("poster a11y found:", idx >= 0)

    # OCR the toolbar icons: tap the second-from-right icon in the nav bar.
    # The toolbar order is [mindmap?] [raw] [poster] [share] — the poster is
    # third from the right edge, y ≈ nav bar. Use OCR boxes to find "Done"
    # nothing; just probe the standard nav-bar coordinates.
    # Screen is 430pt wide on 15 Pro Max; nav icons sit y≈118-130.
    # Probe candidates from right: share ≈ x 400, poster ≈ x 362, raw ≈ x 328.
    # We tap x=362 and check the sheet content.
    wda.tap(362, 126, settle=2.0)
    wda.screenshot(OUT / "4_after_probe.png")

    src2 = wda.source()
    ok = any(k in src2 for k in ("简约", "Minimal", "暗夜", "Midnight", "商务", "Business"))
    print("poster sheet detected:", ok)
    wda.screenshot(OUT / "5_poster_sheet.png")
    wda.end_session()
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
