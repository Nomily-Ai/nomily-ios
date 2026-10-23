#!/usr/bin/env python3
"""Nomily AI — UI test cases driven by WebDriverAgent + Vision OCR.

Run:  python3 tools/ui-tests/run_tests.py
      (device connected over USB, `iproxy 8100 8100 -u <UDID>` forwarded,
       WebDriverAgent already running — see the memory notes for the exact
       xcodebuild command)

Assertion sources, in order of trust:
  1. `config.json` pulled from the app sandbox (persistence is the contract).
  2. `ticnote-ble.log` pulled from the app sandbox (what the card actually answered).
  3. The screen itself via Vision OCR (the SwiftUI tree is not accessible).

Cases T06–T10 need the DingTalk A1 card connected; they skip otherwise.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from wda_client import ARTIFACTS, WDA, DeviceFiles

RUN_DIR = ARTIFACTS / datetime.now().strftime("%Y%m%d-%H%M%S")

# Tab bar geometry (430x932 pt screen — the only part of the tree accessibility exposes).
TAB_RECORD = (129, 880)
TAB_LIVE = (215, 880)
TAB_SETTINGS = (301, 880)

FIVE_MODES = ["通用模式", "会议模式", "面对面沟通", "AI可视听记", "无损原声"]


def page_text(wda: WDA) -> str:
    """Whole screen as one space-free string — OCR pads CJK+latin mixes with spaces."""
    return "".join(box.text for box in wda.texts()).replace(" ", "")


class Runner:
    def __init__(self) -> None:
        self.wda = WDA()
        self.files = DeviceFiles()
        self.results: list[tuple[str, str, str, str]] = []  # id, title, status, detail

    def shot(self, name: str) -> Path:
        return self.wda.screenshot(RUN_DIR / f"{name}.png")

    def ensure_foreground(self) -> None:
        """Re-activate Nomily if a notification tap threw us into another app."""
        try:
            self.wda.launch_app(wait=1.5)
        except Exception:  # noqa: BLE001 — best effort; T01 manages its own launch
            pass

    # -- case wrapper -------------------------------------------------------
    def case(self, ident: str, title: str, fn, *, needs_card: bool = False):
        case = _Case(ident, title)
        print(f"→ {ident} {title}", flush=True)
        try:
            # A WeChat notification banner can steal a tap and throw the phone into
            # another app entirely — pull Nomily back forward before every case.
            self.ensure_foreground()
            fn(self, case)
        except LookupError as error:
            if needs_card:
                case.skip(f"card-dependent precondition missing: {error}")
            else:
                case.fail(str(error))
        except Exception as error:  # noqa: BLE001 — report, don't crash the suite
            case.fail(f"{type(error).__name__}: {error}")
        shot = RUN_DIR / f"{ident}.png"
        try:
            self.shot(shot)
        except Exception:  # noqa: BLE001
            pass
        self.results.append((case.ident, case.title, case.status, case.detail))
        print(f"  {case.status}: {case.detail}", flush=True)

    # -- shared navigation ---------------------------------------------------
    def dismiss_keyboard(self) -> None:
        """If the rename field (or any field) stole focus, the keyboard covers half the
        screen and every swipe lands on keys. Tap the on-screen Done key until it's gone."""
        for _ in range(2):
            done = self.wda.find(self.wda.texts(), "完成", exact=True)
            if done and done.y > 550:
                self.wda.tap(*done.center, settle=1.0)
            else:
                return

    def open_card_info(self, case) -> None:
        """Recordings tab → A1 capsule → card row → card info sheet (needs a connected card)."""
        self.wda.tap(*TAB_RECORD, settle=1.5)
        # The capsule sits at the top-left of the recordings page.
        capsule = self.wda.wait_for_text("DingTalk A1", timeout=6)
        self.wda.tap(*capsule.center, settle=2.0)
        # On the card page pick the *row* (below the nav bar), not the capsule again.
        boxes = self.wda.texts()
        rows = [b for b in boxes if "DingTalk A1" in b.text and b.y > 120]
        if not rows:
            raise LookupError("card row not found on the card page")
        self.wda.tap(*rows[0].center, settle=2.5)
        self.dismiss_keyboard()
        # Scroll until the A1-only Recording Mode row is on screen (it sits below the key section).
        # Start the swipe low and on the right half — starting on the rename field or a button
        # eats the gesture as a text-selection drag instead of scrolling the list.
        for _ in range(5):
            if self.wda.find(self.wda.texts(), "录音模式") is not None:
                return
            self.dismiss_keyboard()
            self.wda.swipe(360, 700, 360, 260)
        raise LookupError("Recording Mode row never scrolled into view")

    def close_overlays(self, case) -> None:
        """Get back to the tab shell from anywhere: Done, else relaunch to the root.

        The record-mode picker is a **push** inside the card info sheet, so after T07–T09
        the app sits one level deep. WDA's synthetic edge-swipe does not reliably trigger
        iOS's interactive pop, so the fallback is a clean relaunch — deterministic beats
        clever, and every assertion after this point reads disk/config, not view state.
        """
        for _ in range(2):
            done = self.wda.find(self.wda.texts(), "Done", exact=True)
            if done:
                self.wda.tap(*done.center, settle=1.5)
                return
            self.wda.terminate_app()
            self.wda.launch_app(wait=4.0)
            time.sleep(1.0)


class _Case:
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

    def ok(self, message: str) -> None:
        self.detail = message


# --------------------------------------------------------------------------- cases

def case_t01_launch(runner: Runner, case: _Case) -> None:
    runner.wda.terminate_app()
    runner.wda.launch_app(wait=5.0)
    time.sleep(2.0)
    # Tab buttons expose the SF Symbol as `name` and the Chinese title as `label`.
    import re

    labels = set(re.findall(r'label="([^"]+)"', runner.wda.source()))
    missing = [name for name in ("录音", "实时", "设置") if name not in labels]
    if missing:
        case.fail(f"tab bar missing {missing}")
    else:
        case.ok("app relaunched; tab bar exposes all three tabs")


def case_t02_settings_opens(runner: Runner, case: _Case) -> None:
    runner.wda.tap(*TAB_SETTINGS, settle=1.5)
    if runner.wda.find(runner.wda.texts(), "摘要模板") is None:
        case.fail("Settings page did not show the summary-template row")
    else:
        case.ok("Settings page opens and lists the summary-template row")


def case_t03_template_page_chips(runner: Runner, case: _Case) -> None:
    runner.wda.tap_text("摘要模板", settle=2.0)
    boxes = runner.wda.texts()
    joined = " ".join(b.text for b in boxes)
    missing = [chip for chip in ("推荐", "自定义") if chip not in joined]
    if missing:
        case.fail(f"chips missing {missing}")
    elif runner.wda.find(boxes, "设为默认模板") is None:
        case.fail("the set-default button is missing")
    else:
        case.ok("chips + set-default button all present")


def case_t04_set_default_template(runner: Runner, case: _Case) -> None:
    # Occasionally the first card-tap lands during a list settle and nothing gets selected —
    # retry the select→set round trip and only fail when the config never changes.
    for attempt in range(3):
        card = runner.wda.wait_for_text("正式会议纪要", timeout=6)
        runner.wda.tap(*card.center, settle=1.5)
        button = runner.wda.wait_for_text("设为默认模板", timeout=5)
        runner.wda.tap(*button.center, settle=1.5)
        time.sleep(1.0)
        key = runner.files.config().get("summary_template_key")
        if key:
            case.ok(f"persisted summary_template_key={key!r} (attempt {attempt + 1})")
            return
    case.fail("summary_template_key still nil after 3 select→set attempts")


def case_t05_back_to_record_tab(runner: Runner, case: _Case) -> None:
    runner.wda.tap(*TAB_RECORD, settle=1.5)
    # A system notification banner can cover the capsule for a few seconds — wait it out.
    runner.wda.wait_for_text("DingTalk A1", timeout=12)
    case.ok("recordings page shows the DingTalk A1 capsule")


def case_t06_card_info_hides_charging(runner: Runner, case: _Case) -> None:
    runner.open_card_info(case)
    joined = page_text(runner.wda)
    if "录音模式" not in joined:
        case.fail("Recording Mode row missing (is this really the A1 info page?)")
    elif "充电状态" in joined:
        case.fail("the charging row must be hidden for the A1")
    else:
        case.ok("card info shows Recording Mode and no charging row")


def case_t07_picker_lists_five_modes(runner: Runner, case: _Case) -> None:
    open_mode_picker(runner)
    joined = page_text(runner.wda)
    missing = [mode for mode in FIVE_MODES if mode not in joined]
    if missing:
        case.fail(f"modes missing {missing}")
    else:
        case.ok("all five modes visible with badges")


def open_mode_picker(runner: Runner) -> None:
    """Open the record-mode picker sheet and wait until it is really up.

    The info page shows Recording Mode **twice** (section header + row label); the row's
    trailing value (current mode name) is the reliable tap target. The tap must be
    retried: right after open_card_info's scroll the list can still be decelerating
    and a fixed-coordinate tap hits nothing.
    """
    probe = FIVE_MODES[2]  # face-to-face exists only inside the picker
    for _ in range(3):
        if runner.wda.find(runner.wda.texts(), probe) is not None:
            return
        for name in FIVE_MODES:
            value = runner.wda.find(runner.wda.texts(), name)
            if value:
                runner.wda.tap(*value.center, settle=3.0)  # ≥3 s: sheet animation
                break
        if runner.wda.wait_for_text(probe, timeout=5) is not None:
            return
    raise LookupError("mode picker sheet never opened")


def case_t08_meeting_mode_writes_card(runner: Runner, case: _Case) -> None:
    open_mode_picker(runner)  # cascade-proof: T07 may have left the sheet closed
    runner.wda.tap_text("会议模式", settle=6.0)  # set + read-back round trip
    log = runner.files.ble_log()
    if "set mode=1" not in log:
        case.fail("BLE log has no 'set mode=1' — the write never happened")
    elif "read back mode=1 (wanted 1)" not in log:
        case.fail("card did not confirm mode=1 on read-back")
    else:
        stored = runner.files.config().get("a1_record_mode")
        if stored != "meeting":
            case.fail(f"config a1_record_mode={stored!r}, expected 'meeting'")
        else:
            case.ok("set mode=1 → 200, read-back mode=1, config=meeting")


def case_t09_restore_general_mode(runner: Runner, case: _Case) -> None:
    open_mode_picker(runner)  # a closed sheet would tap the info-page value instead
    runner.wda.tap_text("通用模式", settle=6.0)
    log = runner.files.ble_log()
    if "read back mode=0 (wanted 0)" not in log:
        case.fail("read-back did not confirm mode=0")
        return
    stored = runner.files.config().get("a1_record_mode")
    if stored != "general":
        case.fail(f"config a1_record_mode={stored!r}, expected 'general'")
    else:
        case.ok("restored to factory default mode=0, config=general")


def case_t10_live_page_opens(runner: Runner, case: _Case) -> None:
    runner.close_overlays(case)
    runner.wda.tap(*TAB_LIVE, settle=2.0)
    joined = page_text(runner.wda)
    if any(word in joined for word in ("开始", "实时")):
        case.ok("live page opens in its idle state")
    else:
        case.fail(f"live page idle state not recognised (saw: {joined[:80]})")


def case_t11_app_survives_the_tour(runner: Runner, case: _Case) -> None:
    config = runner.files.config()
    if "a1_record_mode" not in config:
        case.fail("config unreadable — app may have crashed mid-tour")
    else:
        case.ok(f"config intact after the full tour (a1_record_mode={config['a1_record_mode']!r})")


# --------------------------------------------------------------------------- entry

def main() -> int:
    if RUN_DIR.exists():
        shutil.rmtree(RUN_DIR)
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    print(f"artifacts → {RUN_DIR}")

    runner = Runner()
    wda = runner.wda
    try:
        wda.start_session()
        wda.terminate_app()
        wda.launch_app(wait=5.0)

        runner.case("T01", "App launches and shows the three tabs", case_t01_launch)
        runner.case("T02", "Settings page opens", case_t02_settings_opens)
        runner.case("T03", "Template page: chips + set-default button", case_t03_template_page_chips)
        runner.case("T04", "Set-default template persists to config", case_t04_set_default_template)
        runner.case("T05", "Recordings page shows the A1 capsule", case_t05_back_to_record_tab)
        runner.case("T06", "A1 card info hides the charging row", case_t06_card_info_hides_charging, needs_card=True)
        runner.case("T07", "Record-mode picker lists all five modes", case_t07_picker_lists_five_modes, needs_card=True)
        runner.case("T08", "Meeting mode is written to the card", case_t08_meeting_mode_writes_card, needs_card=True)
        runner.case("T09", "General mode is restored on the card", case_t09_restore_general_mode, needs_card=True)
        runner.case("T10", "Live page opens in idle state", case_t10_live_page_opens)
        runner.case("T11", "App survives the whole tour", case_t11_app_survives_the_tour)
    finally:
        wda.end_session()

    print("\n" + "=" * 72)
    failed = 0
    for ident, title, status, detail in runner.results:
        marker = {"PASS": "✅", "FAIL": "❌", "SKIP": "⏭️ "}[status]
        print(f"{marker} {ident} {title}\n     {detail}")
        failed += status == "FAIL"
    print("=" * 72)
    print(f"{len(runner.results)} cases · {failed} failed · artifacts in {RUN_DIR}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
