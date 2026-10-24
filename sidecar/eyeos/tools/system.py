"""Python-executed macOS tools (SPEC §9.5)."""
import asyncio
import datetime as dt
import subprocess
import tempfile

import cv2

CATEGORIES = [
    ("coding", ("com.microsoft.VSCode", "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92", "com.googlecode.iterm2",
                "com.apple.Terminal", "com.jetbrains.", "dev.zed.Zed")),
    ("design", ("com.figma.Desktop", "com.bohemiancoding.sketch3")),
]
BROWSERS = ("com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox")
CALL_APPS = ("us.zoom.xos", "com.apple.FaceTime", "com.microsoft.teams2")


def category(bundle_id, title):
    bundle_id, title = bundle_id or "", title or ""
    if bundle_id in CALL_APPS or (bundle_id == "com.tinyspeck.slackmacgap" and "Huddle" in title):
        return "call"
    if bundle_id in BROWSERS and any(k in title for k in ("Meet –", "Meet - ", "Zoom", "Teams")):
        return "call"
    for cat, ids in CATEGORIES:
        if any(bundle_id == i or (i.endswith(".") and bundle_id.startswith(i)) for i in ids):
            return cat
    if bundle_id in BROWSERS or bundle_id in ("com.apple.Preview", "com.apple.iBooksX"):
        return "reading"
    return "other"


def run(cmd, timeout=10, input=None):
    """Blocking subprocess; returns (ok, stdout or stderr)."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=input)
    except subprocess.TimeoutExpired:
        return False, "timed out"
    return p.returncode == 0, (p.stdout if p.returncode == 0 else p.stderr).strip()


def osa(script, timeout=10):
    return run(["osascript", "-e", script], timeout)


async def arun(fn, *a):
    return await asyncio.to_thread(fn, *a)


# ---------- state ----------

def dark_mode():
    ok, out = run(["defaults", "read", "-g", "AppleInterfaceStyle"], 3)
    return ok and out == "Dark"


def active_app():
    from AppKit import NSWorkspace
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    name = str(app.localizedName()) if app else ""
    bid = str(app.bundleIdentifier()) if app and app.bundleIdentifier() else ""
    ok, title = osa(f'tell application "System Events" to tell (first process whose frontmost is true) to get name of front window', 3)
    title = title if ok else ""
    return {"name": name, "bundle_id": bid, "window_title": title, "category": category(bid, title)}


def time_of_day():
    now = dt.datetime.now().astimezone()
    return {"local_time": now.isoformat(timespec="seconds"), "weekday": now.strftime("%a"),
            "is_night": now.hour >= 20 or now.hour < 6}


def screenshot_jpeg(width=1280):
    """Main display screenshot, resized, as JPEG bytes (or None without Screen Recording)."""
    with tempfile.NamedTemporaryFile(suffix=".jpg") as f:
        ok, _ = run(["screencapture", "-x", "-m", "-t", "jpg", f.name], 10)
        img = cv2.imread(f.name) if ok else None
    if img is None:
        return None
    h, w = img.shape[:2]
    img = cv2.resize(img, (width, int(h * width / w)))
    return cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 70])[1].tobytes()


def screen_luma():
    with tempfile.NamedTemporaryFile(suffix=".jpg") as f:
        ok, _ = run(["screencapture", "-x", "-m", "-t", "jpg", f.name], 10)
        img = cv2.imread(f.name, cv2.IMREAD_GRAYSCALE) if ok else None
    if img is None:
        return None
    return round(float(cv2.resize(img, (64, 64 * img.shape[0] // img.shape[1])).mean()))


def seconds_since_key():
    from Quartz import CGEventSourceSecondsSinceLastEventType, kCGEventSourceStateCombinedSessionState, kCGEventKeyDown
    return CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGEventKeyDown)


# ---------- actions ----------

def set_dark_mode(enabled):
    ok, out = osa(f'tell application "System Events" to tell appearance preferences to set dark mode to {str(bool(enabled)).lower()}')
    return ok, ("dark mode " + ("on" if enabled else "off")) if ok else out


def shortcut(name):
    ok, out = run(["shortcuts", "run", name], 20)
    if not ok:
        return False, f'Shortcut "{name}" failed or is missing ({out[:200]}). Create it in Shortcuts.app.'
    return True, f'ran shortcut "{name}"'


# R2: universalaccess defaults are write-protected on this macOS, so these go through user Shortcuts.
def set_increase_contrast(enabled):
    return shortcut(f"eyeOS Contrast {'On' if enabled else 'Off'}")


def set_reduce_transparency(enabled):
    return shortcut(f"eyeOS Transparency {'On' if enabled else 'Off'}")


def set_reduce_motion(enabled):
    return shortcut(f"eyeOS Motion {'On' if enabled else 'Off'}")


def set_cursor_size(size):
    return shortcut(f"eyeOS Cursor {'Large' if size > 1.5 else 'Normal'}")


def set_focus(enabled):
    return shortcut(f"eyeOS Focus {'On' if enabled else 'Off'}")


def focus_shortcuts_present():
    ok, out = run(["shortcuts", "list"], 10)
    names = set(out.splitlines()) if ok else set()
    return {"eyeOS Focus On", "eyeOS Focus Off"} <= names, sorted(n for n in names if n.startswith("eyeOS"))


_FRAME = '''tell application "Finder" to set b to bounds of window of desktop
tell application "System Events" to tell (first process whose frontmost is true)
  set w to front window
  {body}
end tell'''


def enlarge_active_window(fraction):
    f = max(0.6, min(1.0, fraction))
    body = (f"set W to (item 3 of b) * {f}\n  set H to ((item 4 of b) - 25) * {f}\n"
            "  set position of w to {((item 3 of b) - W) / 2, 25 + ((item 4 of b) - 25 - H) / 2}\n"
            "  set size of w to {W, H}")
    ok, out = osa(_FRAME.format(body=body))
    return ok, f"window resized to {int(f * 100)}% and centered" if ok else out


def move_window_closer_to_center():
    body = ("set {W, H} to size of w\n"
            "  set position of w to {((item 3 of b) - W) / 2, 25 + ((item 4 of b) - 25 - H) / 2}")
    ok, out = osa(_FRAME.format(body=body))
    return ok, "window centered" if ok else out


READER_JS = ("(function(){var s=document.createElement('style');s.textContent="
             "'body{font-size:20px!important;line-height:1.6!important;max-width:70ch!important;margin:auto!important;"
             "background:#fdfdf8!important;color:#111!important}p,li{font-size:20px!important}';"
             "document.head.appendChild(s);return 'ok'})()")


def apply_reading_mode(bundle_id):
    if bundle_id == "com.apple.Safari":
        ok, out = osa('tell application "System Events" to keystroke "r" using {command down, shift down}')
        return ok, "Safari Reader toggled" if ok else out
    if bundle_id == "com.google.Chrome":
        ok, out = osa(f'tell application "Google Chrome" to execute front window\'s active tab javascript "{READER_JS}"')
        return ok, "reader CSS applied" if ok else out + " (enable View > Developer > Allow JavaScript from Apple Events)"
    return False, "reading mode only works in Safari or Chrome"
