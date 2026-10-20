"""One-off UI verification for the remote live ASR settings section (build 64)."""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from wda_client import WDA

SHOTS = Path("/tmp/remote-asr-shots")
SHOTS.mkdir(exist_ok=True)

wda = WDA()
wda.start_session()
wda.terminate_app()
time.sleep(1)
wda.launch_app(wait=5.0)
time.sleep(2)

# 1) Settings tab
shot = wda.screenshot(SHOTS / "01-home.png")
box = WDA.find(wda.texts(shot), "设置")
if box is None:
    raise SystemExit("FAIL: 设置 tab not found")
wda.tap(*box.center)
time.sleep(1.5)

# 2) ASR providers row — the settings page label is "语音识别" / "转录" family; try candidates
shot = wda.screenshot(SHOTS / "02-settings.png")
row = None
for needle in ("语音识别", "转录", "ASR"):
    row = WDA.find(wda.texts(shot), needle)
    if row:
        break
if row is None:
    raise SystemExit("FAIL: ASR providers row not found on settings page")
wda.tap(*row.center)
time.sleep(1.5)

# 3) Scroll to the bottom (remote section is last)
for i in range(4):
    wda.swipe(200, 700, 200, 200, 300)
    time.sleep(0.6)
shot = wda.screenshot(SHOTS / "03-asr-bottom.png")
boxes = wda.texts(shot)
labels = [b.text for b in boxes]
print("PAGE TEXTS:", " | ".join(t for t in labels if t.strip())[:600])

# 4) Tap the remote section's 测试连接 with an empty key
probe = WDA.find(boxes, "测试连接")
if probe is None:
    raise SystemExit("FAIL: 测试连接 button not visible after scroll")
wda.tap(*probe.center)
time.sleep(3)
shot = wda.screenshot(SHOTS / "04-remote-probe-empty-key.png")
boxes2 = wda.texts(shot)
joined = " ".join(b.text for b in boxes2)
print("AFTER PROBE:", joined[:600])
if "API Key" in joined or "api key" in joined.lower():
    print("PASS: empty-key probe shows the API-Key error")
else:
    print("WARN: expected API-Key error text not found")

# 5) Screenshot the top too (service-type hints on LAN section)
wda.swipe(200, 300, 200, 750, 300)
time.sleep(0.8)
wda.screenshot(SHOTS / "05-asr-top.png")
print("DONE")
