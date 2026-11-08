#!/usr/bin/env python3
"""Verify an installed Nixie Countdown plugin on Linux or macOS.

Starts OBS, drives a Nixie Countdown source through OBS's built-in remote
control interface (obs-websocket), checks sizes, buttons, hotkeys, the
countdown and the blink at zero, and takes screenshots into a report folder.
At the end it opens a pre-filled "Test report" issue in your browser and puts
one image of all the screenshots on the clipboard to paste in. Nothing is
posted until you review it and click Submit there.

Your own setup is left alone: the test runs in a temporary scene collection,
which is deleted afterwards, and the WebSocket settings are restored exactly.

Uses only the Python standard library (Python 3.8 or newer). Close OBS, then:
    python3 verify-linux-macos.py

Copyright (c) 2026 DMX Digital
SPDX-License-Identifier: MIT
"""

import argparse
import base64
import datetime
import hashlib
import json
import os
import platform
import secrets
import shutil
import signal
import socket
import string
import struct
import subprocess
import sys
import time
import traceback
import urllib.parse
import zlib

REPO = "simulacra10/nixie-countdown"
PLUGIN = "nixie-countdown"
SOURCE_KIND = "nixie_countdown_source"
SOURCE_NAME = "Nixie Verify"
FLATPAK_ID = "com.obsproject.Studio"

IS_MAC = sys.platform == "darwin"
PLATFORM_NAME = "macOS" if IS_MAC else "Linux"
# Release packages for macOS are built against OBS 31; on Linux the plugin is
# built against the distribution's OBS, which may be 30.
MIN_OBS_VERSION = (31, 0, 0) if IS_MAC else (30, 0, 0)

# Built-in tube image sizes (data/digits): digits 150x300, colon 50x300
DIGIT_W, COLON_W, TUBE_H = 150, 50, 300

# Screenshots are scaled to this width; enough to compare, quick to decode.
SHOT_WIDTH = 320
# Identical frames render to identical pixels, so "same" allows almost no
# change; a digit change alters a few percent of the image.
SAME_MAX, DIFFERENT_MIN, BLANK_MAX = 0.001, 0.003, 0.005

NOT_READY = 207  # obs-websocket: OBS is still starting up

STAMP = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
# Letters and digits only: OBS drops other characters from the file name.
COLLECTION_NAME = "NixieVerify" + STAMP.replace("-", "")


# ------------------------------------------------------------------
# Output and results
# ------------------------------------------------------------------

USE_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None
COLORS = {"pass": "32", "fail": "31", "skip": "33", "manual": "36", "title": "1"}


def color(text, kind):
    return "\033[{}m{}\033[0m".format(COLORS[kind], text) if USE_COLOR else text


def heading(text):
    print()
    print(color(text, "title"))


RESULTS = []


def add_result(name, status, details=""):
    RESULTS.append({"name": name, "status": status, "details": details})
    print("  [{:<6}] {}".format(color(status.upper(), status), name))
    if details and status != "pass":
        print("           " + details)


class CheckFailed(Exception):
    pass


def check(condition, message):
    if not condition:
        raise CheckFailed(message)


def step(name, body):
    """Runs one check. body returns a details string, or raises to fail."""
    try:
        details = body()
        add_result(name, "pass", str(details or ""))
        return True
    except Exception as e:  # noqa: BLE001 - every failure becomes a result
        add_result(name, "fail", str(e) or type(e).__name__)
        return False


# ------------------------------------------------------------------
# WebSocket client (RFC 6455, just enough for obs-websocket)
# ------------------------------------------------------------------


class WebSocket:
    GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    def __init__(self, host, port, timeout=20):
        self.sock = socket.create_connection((host, port), timeout=5)
        self.sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16))
        request = (
            "GET / HTTP/1.1\r\nHost: {h}:{p}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: {k}\r\nSec-WebSocket-Version: 13\r\n"
            "Sec-WebSocket-Protocol: obswebsocket.json\r\n\r\n"
        ).format(h=host, p=port, k=key.decode())
        self.sock.sendall(request.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("OBS closed the connection during the handshake")
            response += chunk
        head, self.buffer = response.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise ConnectionError("OBS refused the WebSocket connection")
        accept = base64.b64encode(hashlib.sha1(key + self.GUID).digest())
        if accept not in head:
            raise ConnectionError("unexpected WebSocket handshake reply")

    def _recv_exact(self, n):
        chunks = [self.buffer]
        have = len(self.buffer)
        while have < n:
            chunk = self.sock.recv(max(65536, n - have))
            if not chunk:
                raise ConnectionError("OBS closed the connection")
            chunks.append(chunk)
            have += len(chunk)
        data = b"".join(chunks)
        self.buffer = data[n:]
        return data[:n]

    def _send_frame(self, opcode, payload):
        header = bytearray([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack("!H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack("!Q", n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i & 3] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def send_text(self, text):
        self._send_frame(0x1, text.encode("utf-8"))

    def recv_text(self):
        parts = []
        while True:
            b1, b2 = self._recv_exact(2)
            opcode = b1 & 0x0F
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._recv_exact(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._recv_exact(8))[0]
            mask = self._recv_exact(4) if b2 & 0x80 else None
            data = self._recv_exact(n)
            if mask:
                data = bytes(b ^ mask[i & 3] for i, b in enumerate(data))
            if opcode == 0x8:
                raise ConnectionError("OBS closed the WebSocket connection")
            if opcode == 0x9:
                self._send_frame(0xA, data)
                continue
            if opcode == 0xA:
                continue
            parts.append(data)
            if b1 & 0x80:
                return b"".join(parts).decode("utf-8")

    def close(self):
        try:
            self._send_frame(0x8, struct.pack("!H", 1000))
            # Wait briefly for OBS's close frame so it logs a normal close.
            self.sock.settimeout(2)
            while True:
                self.recv_text()
        except (OSError, ConnectionError, ValueError):
            pass
        self.sock.close()


def sha256_b64(text):
    return base64.b64encode(hashlib.sha256(text.encode("utf-8")).digest()).decode()


class Obs:
    """obs-websocket protocol 5 client."""

    def __init__(self, port, password):
        self.ws = WebSocket("127.0.0.1", port)
        self.counter = 0
        hello = json.loads(self.ws.recv_text())
        check(hello.get("op") == 0, "unexpected first message from OBS")
        identify = {"rpcVersion": 1, "eventSubscriptions": 0}
        auth = hello["d"].get("authentication")
        if auth:
            secret = sha256_b64(password + auth["salt"])
            identify["authentication"] = sha256_b64(secret + auth["challenge"])
        self.ws.send_text(json.dumps({"op": 1, "d": identify}))
        check(json.loads(self.ws.recv_text()).get("op") == 2, "OBS rejected the connection (wrong password?)")

    def call(self, request_type, data=None):
        # obs-websocket answers "not ready" until OBS has finished loading,
        # so retry that for up to 2 minutes; fail on anything else.
        deadline = time.time() + 120
        while True:
            self.counter += 1
            request_id = "req-{}".format(self.counter)
            request = {"requestType": request_type, "requestId": request_id}
            if data is not None:
                request["requestData"] = data
            self.ws.send_text(json.dumps({"op": 6, "d": request}))
            while True:
                msg = json.loads(self.ws.recv_text())
                if msg.get("op") == 7 and msg["d"].get("requestId") == request_id:
                    break
            status = msg["d"]["requestStatus"]
            if status.get("result"):
                return msg["d"].get("responseData") or {}
            if status.get("code") == NOT_READY and time.time() < deadline:
                time.sleep(0.5)
                continue
            raise RuntimeError(
                "OBS request {} failed (code {}) {}".format(request_type, status.get("code"), status.get("comment", ""))
            )

    def close(self):
        self.ws.close()


def connect_obs(port, password, timeout=90):
    deadline = time.time() + timeout
    while True:
        try:
            return Obs(port, password)
        except (OSError, ConnectionError, ValueError):
            if time.time() > deadline:
                raise RuntimeError("could not connect to OBS on port {} within {} seconds".format(port, timeout))
            time.sleep(1)


# ------------------------------------------------------------------
# PNG reading and writing (8-bit RGB or RGBA, as OBS produces)
# ------------------------------------------------------------------


class Image:
    def __init__(self, width, height, rgba):
        self.width, self.height, self.rgba = width, height, rgba

    def visible_fraction(self):
        """Fraction of pixels that show anything: not transparent and not black."""
        p = self.rgba
        visible = sum(1 for i in range(0, len(p), 4) if p[i + 3] > 16 and p[i] + p[i + 1] + p[i + 2] > 60)
        return visible / float(self.width * self.height)


def changed_fraction(a, b):
    """Fraction of pixels where any channel differs by more than 40."""
    if a.width != b.width or a.height != b.height:
        return 1.0
    pa, pb = a.rgba, b.rgba
    changed = 0
    for i in range(0, len(pa), 4):
        if (
            abs(pa[i] - pb[i]) > 40
            or abs(pa[i + 1] - pb[i + 1]) > 40
            or abs(pa[i + 2] - pb[i + 2]) > 40
            or abs(pa[i + 3] - pb[i + 3]) > 40
        ):
            changed += 1
    return changed / float(a.width * a.height)


def png_decode(data):
    check(data[:8] == b"\x89PNG\r\n\x1a\n", "screenshot is not a PNG")
    pos, idat = 8, []
    width = height = depth = color_type = interlace = None
    while pos < len(data):
        length, chunk_type = struct.unpack("!I4s", data[pos : pos + 8])
        body = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if chunk_type == b"IHDR":
            width, height, depth, color_type, _, _, interlace = struct.unpack("!IIBBBBB", body)
        elif chunk_type == b"IDAT":
            idat.append(body)
        elif chunk_type == b"IEND":
            break
    check(depth == 8 and color_type in (2, 6) and interlace == 0, "unsupported PNG format")
    bpp = 4 if color_type == 6 else 3
    stride = width * bpp
    raw = zlib.decompress(b"".join(idat))
    out = bytearray(height * stride)
    prev = bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind = raw[start]
        line = bytearray(raw[start + 1 : start + 1 + stride])
        if kind == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif kind == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif kind == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif kind == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 255
        out[y * stride : (y + 1) * stride] = line
        prev = line
    if bpp == 3:
        rgba = bytearray(width * height * 4)
        rgba[0::4], rgba[1::4], rgba[2::4] = out[0::3], out[1::3], out[2::3]
        rgba[3::4] = b"\xff" * (width * height)
        out = rgba
    return Image(width, height, out)


def png_encode(image):
    w, h, p = image.width, image.height, image.rgba
    raw = b"".join(b"\x00" + bytes(p[y * w * 4 : (y + 1) * w * 4]) for y in range(h))

    def chunk(kind, body):
        return struct.pack("!I", len(body)) + kind + body + struct.pack("!I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack("!IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b"")
    )


# A 3x5 pixel font for the labels on the screenshot sheet.
FONT = {
    "0": "XXXX.XX.XX.XXXX", "1": ".X.XX..X..X.XXX", "2": "XXX..XXXXX..XXX", "3": "XXX..XXXX..XXXX",
    "4": "X.XX.XXXX..X..X", "5": "XXXX..XXX..XXXX", "6": "XXXX..XXXX.XXXX", "7": "XXX..X..X..X..X",
    "8": "XXXX.XXXXX.XXXX", "9": "XXXX.XXXX..XXXX", "A": ".X.X.XXXXX.XX.X", "B": "XX.X.XXX.X.XXX.",
    "C": "XXXX..X..X..XXX", "D": "XX.X.XX.XX.XXX.", "E": "XXXX..XX.X..XXX", "F": "XXXX..XX.X..X..",
    "G": "XXXX..X.XX.XXXX", "H": "X.XX.XXXXX.XX.X", "I": "XXX.X..X..X.XXX", "J": "..X..X..XX.XXXX",
    "K": "X.XX.XXX.X.XX.X", "L": "X..X..X..X..XXX", "M": "X.XXXXXXXX.XX.X", "N": "XX.X.XX.XX.XX.X",
    "O": "XXXX.XX.XX.XXXX", "P": "XXXX.XXXXX..X..", "Q": "XXXX.XX.XXXX..X", "R": "XX.X.XXX.X.XX.X",
    "S": "XXXX..XXX..XXXX", "T": "XXX.X..X..X..X.", "U": "X.XX.XX.XX.XXXX", "V": "X.XX.XX.XX.X.X.",
    "W": "X.XX.XXXXXXXX.X", "X": "X.XX.X.X.X.XX.X", "Y": "X.XX.X.X..X..X.", "Z": "XXX..X.X.X..XXX",
    "-": "......XXX......", " ": "...............",
}


def draw_text(canvas, cw, x, y, text, scale=2, rgb=(220, 220, 220)):
    for ch in text.upper():
        glyph = FONT.get(ch, FONT[" "])
        for row in range(5):
            for col in range(3):
                if glyph[row * 3 + col] == "X":
                    for dy in range(scale):
                        for dx in range(scale):
                            i = ((y + row * scale + dy) * cw + x + col * scale + dx) * 4
                            canvas[i : i + 4] = bytes((rgb[0], rgb[1], rgb[2], 255))
        x += 4 * scale


def save_sheet(paths, out_path, columns=4):
    """Combines screenshots into one labeled grid image."""
    images = []
    for path in paths:
        with open(path, "rb") as f:
            images.append((os.path.splitext(os.path.basename(path))[0], png_decode(f.read())))
    pad, label_h = 8, 14
    tile_w = max(img.width for _, img in images)
    tile_h = max(img.height for _, img in images)
    rows = (len(images) + columns - 1) // columns
    cw = pad + columns * (tile_w + pad)
    ch = pad + rows * (label_h + tile_h + pad)
    canvas = bytearray(bytes((40, 40, 40, 255)) * (cw * ch))
    for n, (label, img) in enumerate(images):
        x0 = pad + (n % columns) * (tile_w + pad)
        y0 = pad + (n // columns) * (label_h + tile_h + pad)
        draw_text(canvas, cw, x0, y0 + 2, label)
        # Draw over black, the way the tubes look on a dark scene.
        for y in range(img.height):
            src = img.rgba
            row = bytearray(img.width * 4)
            for x in range(img.width):
                s = (y * img.width + x) * 4
                a = src[s + 3]
                row[x * 4 : x * 4 + 4] = bytes((src[s] * a // 255, src[s + 1] * a // 255, src[s + 2] * a // 255, 255))
            d = ((y0 + label_h + y) * cw + x0) * 4
            canvas[d : d + len(row)] = row
    with open(out_path, "wb") as f:
        f.write(png_encode(Image(cw, ch, canvas)))


# ------------------------------------------------------------------
# Desktop integration
# ------------------------------------------------------------------


def run_quiet(cmd, **kwargs):
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kwargs).returncode
    except OSError:
        return 127


def applescript_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def notify(text):
    if IS_MAC:
        run_quiet(["osascript", "-e", "display notification {} with title \"Nixie Countdown\"".format(applescript_string(text))])
    elif shutil.which("notify-send"):
        run_quiet(["notify-send", "Nixie Countdown verification", text])


def ask_yes_no_on_top(text, title):
    """Asks in a dialog over OBS, so the tester needn't find this terminal."""
    if IS_MAC:
        script = "tell me to activate\ndisplay dialog {} with title {} buttons {{\"No\", \"Yes\"}} default button \"Yes\" with icon note".format(
            applescript_string(text), applescript_string(title)
        )
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
        return "Yes" in r.stdout
    notify("Waiting for your answer: " + title)
    if shutil.which("zenity"):
        return run_quiet(["zenity", "--question", "--title", title, "--text", text, "--width", "460"]) == 0
    if shutil.which("kdialog"):
        return run_quiet(["kdialog", "--title", title, "--yesno", text]) == 0
    try:
        import tkinter
        from tkinter import messagebox

        root = tkinter.Tk()
        root.withdraw()
        root.attributes("-topmost", True)
        answer = messagebox.askyesno(title, text, parent=root)
        root.destroy()
        return bool(answer)
    except Exception:  # noqa: BLE001 - no GUI toolkit; ask in the terminal
        print("\a")
        return input("  " + text.replace("\n", "\n  ") + " (y/n) ").strip().lower().startswith("y")


def bring_terminal_back():
    if IS_MAC:
        app = {"Apple_Terminal": "Terminal", "iTerm.app": "iTerm"}.get(os.environ.get("TERM_PROGRAM", ""))
        if app:
            run_quiet(["osascript", "-e", "tell application {} to activate".format(applescript_string(app))])
    else:
        notify("OBS has closed. Switch back to the terminal to finish.")
    sys.stdout.write("\a")
    sys.stdout.flush()


def copy_image_to_clipboard(path):
    if IS_MAC:
        script = 'set the clipboard to (read (POSIX file {}) as «class PNGf»)'.format(applescript_string(path))
        return run_quiet(["osascript", "-e", script]) == 0
    with open(path, "rb") as f:
        data = f.read()
    for cmd, needs in (
        (["wl-copy", "--type", "image/png"], "WAYLAND_DISPLAY"),
        (["xclip", "-selection", "clipboard", "-t", "image/png", "-i"], "DISPLAY"),
    ):
        if os.environ.get(needs) and shutil.which(cmd[0]):
            try:
                subprocess.run(cmd, input=data, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=True)
                return True
            except (OSError, subprocess.SubprocessError):
                pass
    return False


def copy_text_to_clipboard(text):
    data = text.encode("utf-8")
    candidates = [["pbcopy"]] if IS_MAC else []
    if os.environ.get("WAYLAND_DISPLAY"):
        candidates.append(["wl-copy"])
    if os.environ.get("DISPLAY"):
        candidates.append(["xclip", "-selection", "clipboard"])
    for cmd in candidates:
        if shutil.which(cmd[0]):
            try:
                subprocess.run(cmd, input=data, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=True)
                return True
            except (OSError, subprocess.SubprocessError):
                pass
    return False


def show_file(path):
    if IS_MAC:
        return run_quiet(["open", "-R", path]) == 0
    uri = "file://" + urllib.parse.quote(path)
    if shutil.which("gdbus") and run_quiet([
        "gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1",
        "--object-path", "/org/freedesktop/FileManager1", "--method", "org.freedesktop.FileManager1.ShowItems",
        "['{}']".format(uri), "",
    ]) == 0:
        return True
    return run_quiet(["xdg-open", os.path.dirname(path)]) == 0


def open_url(url):
    return run_quiet(["open" if IS_MAC else "xdg-open", url]) == 0


# ------------------------------------------------------------------
# Finding OBS and the plugin
# ------------------------------------------------------------------


def find_obs(override):
    """Returns (command list, config dir, process name) or None."""
    if IS_MAC:
        candidates = [override] if override else [
            "/Applications/OBS.app/Contents/MacOS/OBS",
            os.path.expanduser("~/Applications/OBS.app/Contents/MacOS/OBS"),
        ]
        for path in candidates:
            if path and os.path.isfile(path):
                return [path], os.path.expanduser("~/Library/Application Support/obs-studio"), "OBS"
        return None
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    native = override or shutil.which("obs")
    if native and os.path.isfile(native):
        return [native], os.path.join(xdg, "obs-studio"), "obs"
    if not override and shutil.which("flatpak") and run_quiet(["flatpak", "info", FLATPAK_ID]) == 0:
        config = os.path.expanduser("~/.var/app/{}/config/obs-studio".format(FLATPAK_ID))
        return ["flatpak", "run", FLATPAK_ID], config, "obs"
    return None


def find_plugin(config_dir):
    """Returns (binary path, data dir) of the installed plugin, or (None, None)."""
    if IS_MAC:
        bundle = os.path.join(config_dir, "plugins", PLUGIN + ".plugin", "Contents")
        candidates = [(os.path.join(bundle, "MacOS", PLUGIN), os.path.join(bundle, "Resources"))]
    else:
        user = os.path.join(config_dir, "plugins", PLUGIN)
        candidates = [(os.path.join(user, "bin", "64bit", PLUGIN + ".so"), os.path.join(user, "data"))]
        for libdir in ("/usr/lib/x86_64-linux-gnu", "/usr/lib/aarch64-linux-gnu", "/usr/lib64", "/usr/lib",
                       "/usr/local/lib/x86_64-linux-gnu", "/usr/local/lib64", "/usr/local/lib"):
            share = "/usr/local/share" if libdir.startswith("/usr/local") else "/usr/share"
            candidates.append((os.path.join(libdir, "obs-plugins", PLUGIN + ".so"),
                               os.path.join(share, "obs", "obs-plugins", PLUGIN)))
    for binary, data in candidates:
        if os.path.isfile(binary):
            return binary, data
    return None, None


def describe_os():
    machine = platform.machine()
    if IS_MAC:
        version = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
        return "macOS {} ({})".format(version, machine)
    name = "Linux"
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    name = line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    session = os.environ.get("XDG_SESSION_TYPE") or ("wayland" if os.environ.get("WAYLAND_DISPLAY") else "x11")
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "unknown desktop")
    return "{}, kernel {} ({}), {} on {}".format(name, platform.release(), machine, desktop, session)


def process_running(name):
    # Only this user's processes: never touch another user's OBS.
    return run_quiet(["pgrep", "-u", str(os.getuid()), "-x", name]) == 0


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def parse_version(text):
    parts = []
    for piece in (text or "").split("-")[0].split(".")[:3]:
        digits = "".join(c for c in piece if c.isdigit())
        parts.append(int(digits) if digits else 0)
    return tuple(parts + [0] * (3 - len(parts)))


# ------------------------------------------------------------------
# The run
# ------------------------------------------------------------------


class Terminated(Exception):
    pass


def on_signal(signum, frame):
    # Closing the terminal or Ctrl+C still restores the user's settings.
    raise Terminated()


def main():
    parser = argparse.ArgumentParser(description="Verify an installed Nixie Countdown plugin on Linux or macOS.")
    parser.add_argument("--obs", help="path to the OBS program, if it is not in the standard place")
    parser.add_argument("--expected-sha256", help="SHA-256 of the plugin binary you expect to be installed")
    parser.add_argument("--output-dir", help="where to write the report (default: a new folder on the Desktop)")
    parser.add_argument("--skip-manual", action="store_true", help="skip the one question that needs you to look")
    parser.add_argument("--no-submit", action="store_true", help="don't offer to submit the results")
    args = parser.parse_args()
    interactive = not os.environ.get("CI")

    desktop = os.path.expanduser("~/Desktop")
    output_dir = args.output_dir or os.path.join(desktop if os.path.isdir(desktop) else os.path.expanduser("~"),
                                                 "nixie-verify-" + STAMP)
    shots_dir = os.path.join(output_dir, "screenshots")
    os.makedirs(shots_dir, exist_ok=True)

    print(color("Nixie Countdown verification ({})".format(PLATFORM_NAME), "title"))
    print("Report folder: " + output_dir)

    found = find_obs(args.obs)
    if not found:
        print(color("OBS not found. Install OBS, or pass its location with --obs.", "fail"))
        return 2
    obs_cmd, config_dir, process_name = found
    if process_running(process_name):
        print(color("OBS is running. Close it and run this script again.", "fail"))
        return 2

    report = {
        "tool": os.path.basename(__file__),
        "date": datetime.datetime.now().astimezone().isoformat(),
        "os": describe_os(),
        "obs_command": " ".join(obs_cmd),
        "obs_version": None,
        "obs_websocket_version": None,
        "plugin_version": None,
        "plugin_binary": None,
        "plugin_sha256": None,
        "results": RESULTS,
    }

    heading("Installation")
    binary, data_dir = find_plugin(config_dir)

    def plugin_installed():
        check(binary is not None, "plugin not found in {} or the system plugin folders".format(config_dir))
        with open(binary, "rb") as f:
            report["plugin_sha256"] = hashlib.sha256(f.read()).hexdigest()
        report["plugin_binary"] = binary
        return "SHA-256 " + report["plugin_sha256"]

    step("Plugin installed", plugin_installed)

    def data_files():
        missing = [n + ".png" for n in list("0123456789") + ["colon"]
                   if not os.path.isfile(os.path.join(data_dir, "digits", n + ".png"))]
        if not os.path.isfile(os.path.join(data_dir, "locale", "en-US.ini")):
            missing.append("locale/en-US.ini")
        check(not missing, "missing in {}: {}".format(data_dir, ", ".join(missing)))
        return "all 11 tube images and the locale file"

    def old_plugin_removed():
        # The plugin used to be called obs-nixie-countdown. If that is still
        # installed, OBS loads both and they claim the same source type.
        old = [p for p in (os.path.join(config_dir, "plugins", "obs-nixie-countdown"),
                           os.path.join(config_dir, "plugins", "obs-nixie-countdown.plugin"))
               if os.path.exists(p)]
        for libdir in ("/usr/lib/x86_64-linux-gnu", "/usr/lib/aarch64-linux-gnu", "/usr/lib64", "/usr/lib",
                       "/usr/local/lib/x86_64-linux-gnu", "/usr/local/lib64", "/usr/local/lib"):
            path = os.path.join(libdir, "obs-plugins", "obs-nixie-countdown.so")
            if os.path.exists(path):
                old.append(path)
        check(not old, "remove the old plugin first: " + ", ".join(old))
        return "not installed"

    step("Old obs-nixie-countdown plugin removed", old_plugin_removed)
    if binary:
        step("Plugin data files installed", data_files)
    if args.expected_sha256 and binary:
        step("Plugin matches the expected build",
             lambda: (check(report["plugin_sha256"] == args.expected_sha256.lower(),
                            "expected " + args.expected_sha256.lower()), "hash matches")[1])
    if not binary:
        print(color("The plugin is not installed, so OBS checks were skipped.", "fail"))
        return 2

    # Turn on the WebSocket server for this run with a one-time port and password.
    port = free_port()
    password = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32))
    ws_config = os.path.join(config_dir, "plugin_config", "obs-websocket", "config.json")
    ws_original = None
    if os.path.isfile(ws_config):
        with open(ws_config, "rb") as f:
            ws_original = f.read()
    scenes_dir = os.path.join(config_dir, "basic", "scenes")
    scenes_before = set(os.listdir(scenes_dir)) if os.path.isdir(scenes_dir) else set()
    logs_dir = os.path.join(config_dir, "logs")
    launch_time = time.time()

    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, on_signal)

    obs = None
    proc = None
    original_collection = None
    state = {"scene": None, "item": None, "shots": 0}

    def set_source(settings):
        obs.call("SetInputSettings", {"inputName": SOURCE_NAME, "inputSettings": settings, "overlay": True})
        time.sleep(0.3)

    def assert_size(width, height):
        t = obs.call("GetSceneItemTransform", {"sceneName": state["scene"], "sceneItemId": state["item"]})["sceneItemTransform"]
        w, h = int(t["sourceWidth"]), int(t["sourceHeight"])
        check((w, h) == (width, height), "size is {}x{}, expected {}x{}".format(w, h, width, height))
        return "{}x{}".format(width, height)

    def press(prop):
        obs.call("PressInputPropertiesButton", {"inputName": SOURCE_NAME, "propertyName": prop})

    def shot(label):
        data = obs.call("GetSourceScreenshot", {"sourceName": SOURCE_NAME, "imageFormat": "png", "imageWidth": SHOT_WIDTH})["imageData"]
        png = base64.b64decode(data.split(",", 1)[1])
        state["shots"] += 1
        with open(os.path.join(shots_dir, "{:02d}-{}.png".format(state["shots"], label)), "wb") as f:
            f.write(png)
        return png_decode(png)

    def assert_same(a, b, what):
        f = changed_fraction(a, b)
        check(f <= SAME_MAX, "{}: images differ ({:.2%} of pixels changed)".format(what, f))

    def assert_different(a, b, what):
        f = changed_fraction(a, b)
        check(f >= DIFFERENT_MIN, "{}: images should differ but only {:.2%} of pixels changed".format(what, f))

    try:
        config = json.loads(ws_original.decode("utf-8")) if ws_original else {}
        config.update({"first_load": False, "server_enabled": True, "alerts_enabled": False, "auth_required": True,
                       "server_port": port, "server_password": password})
        os.makedirs(os.path.dirname(ws_config), exist_ok=True)
        # A new file is readable by this user only; an existing one keeps OBS's permissions.
        fd = os.open(ws_config, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(config, f, indent=4)

        heading("Starting OBS")
        # The port and password are only in the config file above, never on the
        # command line, which every user can read on Linux (NIXIE-2026-007).
        proc = subprocess.Popen(
            obs_cmd + ["--disable-shutdown-check", "--disable-updater"],
            cwd=os.path.dirname(obs_cmd[0]) if os.path.isabs(obs_cmd[0]) else None,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        )

        def connected():
            nonlocal obs
            obs = connect_obs(port, password)
            v = obs.call("GetVersion")
            report["obs_version"] = v.get("obsVersion")
            report["obs_websocket_version"] = v.get("obsWebSocketVersion")
            return "OBS {}, obs-websocket {}".format(report["obs_version"], report["obs_websocket_version"])

        if not step("OBS starts and accepts the test connection", connected):
            raise RuntimeError("could not connect to OBS; see the result above")

        step("OBS is version {}.{}.{} or newer".format(*MIN_OBS_VERSION),
             lambda: (check(parse_version(report["obs_version"]) >= MIN_OBS_VERSION, "found " + str(report["obs_version"])),
                      report["obs_version"])[1])

        # Work in a temporary scene collection so the user's scenes are untouched.
        original_collection = obs.call("GetSceneCollectionList")["currentSceneCollectionName"]
        obs.call("CreateSceneCollection", {"sceneCollectionName": COLLECTION_NAME})
        time.sleep(2)
        state["scene"] = obs.call("GetCurrentProgramScene")["currentProgramSceneName"]

        heading("Plugin in OBS")
        step("Nixie Countdown source type is registered",
             lambda: (check(SOURCE_KIND in obs.call("GetInputKindList", {"unversioned": True})["inputKinds"],
                            "OBS did not load the plugin ({} not in the source list)".format(SOURCE_KIND)), SOURCE_KIND)[1])

        def defaults():
            d = obs.call("GetInputDefaultSettings", {"inputKind": SOURCE_KIND})["defaultInputSettings"]
            check((d.get("hours"), d.get("minutes"), d.get("seconds")) == (0, 5, 0), "default duration is not 5:00")
            check(d.get("format") == 0, "default format is not Automatic")
            check(d.get("show_separators") and d.get("blink_at_zero") and not d.get("auto_start"), "default switches are wrong")
            check(d.get("spacing") == 0, "default spacing is not 0")
            return "5:00, Automatic, colons on, blink on, auto restart off, spacing 0"

        step("Default settings", defaults)

        def create():
            r = obs.call("CreateInput", {"sceneName": state["scene"], "inputName": SOURCE_NAME, "inputKind": SOURCE_KIND,
                                         "inputSettings": {"hours": 0, "minutes": 0, "seconds": 5, "format": 2},
                                         "sceneItemEnabled": True})
            state["item"] = r["sceneItemId"]
            time.sleep(0.5)
            return assert_size(4 * DIGIT_W + COLON_W, TUBE_H)

        if not step("Create a source (5 seconds, MM:SS)", create) or state["item"] is None:
            raise RuntimeError("could not create the test source; see the result above")

        heading("Display")
        step("Seconds only format: 2 tubes", lambda: (set_source({"format": 1}), assert_size(2 * DIGIT_W, TUBE_H))[1])
        step("Hours, minutes and seconds format: 6 tubes and 2 colons",
             lambda: (set_source({"format": 3}), assert_size(6 * DIGIT_W + 2 * COLON_W, TUBE_H))[1])
        step("Automatic format picks seconds only for 5 seconds",
             lambda: (set_source({"format": 0}), assert_size(2 * DIGIT_W, TUBE_H))[1])
        step("Colons can be hidden",
             lambda: (set_source({"format": 2, "show_separators": False}), assert_size(4 * DIGIT_W, TUBE_H))[1])
        step("Tube spacing",
             lambda: (set_source({"show_separators": True, "spacing": 10}), assert_size(4 * DIGIT_W + COLON_W + 4 * 10, TUBE_H))[1])

        def clamped():
            set_source({"hours": 99999999, "spacing": 1000000, "format": 3})
            # 999 hours max gives "999:00:05": 7 tubes, 2 colons, spacing clamped to 150
            assert_size(7 * DIGIT_W + 2 * COLON_W + 8 * 150, TUBE_H)
            obs.call("GetVersion")
            set_source({"hours": 0, "spacing": 0, "format": 2})
            return "clamped to 999 hours and spacing 150; OBS still responding"

        step("Out of range settings are clamped (NIXIE-2026-001)", clamped)
        add_result("Network path for tube images is refused (NIXIE-2026-002)", "skip", "Windows only")

        heading("Timer (screenshots are saved in the report folder)")
        press("btn_reset")
        time.sleep(0.3)
        s0 = shot("reset-0005")
        frames = {}

        def drawn():
            v = s0.visible_fraction()
            check(v > 0.05, "only {:.1%} of the image shows anything".format(v))
            return "{:.0%} of the image lit".format(v)

        step("Tubes are drawn", drawn)

        def started():
            press("btn_start")
            time.sleep(2.2)
            press("btn_pause")
            time.sleep(0.3)
            frames["s1"] = shot("after-start-0003")
            assert_different(s0, frames["s1"], "after 2 seconds")
            return "display changed"

        def paused():
            check("s1" in frames, "needs the previous step")
            time.sleep(1.5)
            assert_same(frames["s1"], shot("paused"), "while paused")
            return "display unchanged for 1.5 seconds"

        def reset():
            press("btn_reset")
            time.sleep(0.3)
            assert_same(s0, shot("after-reset"), "after reset")
            return "matches the starting display"

        def finished():
            press("btn_start")
            time.sleep(6)
            visible = blank = 0
            lit = None
            for i in range(10):
                image = shot("finished-{}".format(i))
                if image.visible_fraction() <= BLANK_MAX:
                    blank += 1
                else:
                    visible += 1
                    lit = image
                time.sleep(0.12)
            check(visible and blank, "expected both lit and dark frames, got {} lit and {} dark".format(visible, blank))
            assert_different(s0, lit, "at zero compared to the start")
            return "{} lit and {} dark frames in about 1.5 seconds".format(visible, blank)

        step("Start / Resume button counts down", started)
        step("Pause button stops the countdown", paused)
        step("Reset button returns to the full duration", reset)
        step("Countdown reaches zero and blinks", finished)

        heading("Hotkeys")
        press("btn_reset")
        time.sleep(0.3)

        def hotkey(name):
            obs.call("TriggerHotkeyByName", {"hotkeyName": name, "contextName": SOURCE_NAME})

        def hotkey_start_pause():
            hotkey("NixieCountdown.StartPause")
            time.sleep(2.2)
            hotkey("NixieCountdown.StartPause")
            time.sleep(0.3)
            a = shot("hotkey-started")
            assert_different(s0, a, "after the hotkey started the timer")
            time.sleep(1.2)
            assert_same(a, shot("hotkey-paused"), "after the hotkey paused the timer")
            return "starts and pauses"

        def hotkey_reset():
            hotkey("NixieCountdown.Reset")
            time.sleep(0.3)
            assert_same(s0, shot("hotkey-reset"), "after the reset hotkey")
            return "returns to the full duration"

        step("Start/Pause hotkey", hotkey_start_pause)
        step("Reset hotkey", hotkey_reset)

        heading("Context bar (needs you)")
        if args.skip_manual or not interactive:
            add_result("Context bar buttons appear", "skip", "skipped")
        else:
            print("  Answer the question in the box on top of OBS.")
            seen = ask_yes_no_on_top(
                "One thing to check by eye:\n\n"
                "1. In OBS, click \"Nixie Verify\" in the Sources panel.\n"
                "2. Look at the bar under the preview, next to Properties and Filters.\n\n"
                "Do you see Start / Resume, Pause and Reset buttons there?\n\n"
                "(You can drag this box aside if it covers the bar.)",
                "Nixie Countdown verification",
            )
            if seen:
                add_result("Context bar buttons appear", "manual", "tester reported: buttons visible")
            else:
                add_result("Context bar buttons appear", "fail", "tester reported: buttons not visible")
    except (Terminated, KeyboardInterrupt):
        add_result("Run completed", "fail", "stopped before the end")
    except Exception as e:  # noqa: BLE001 - report it and still clean up
        add_result("Run completed", "fail", str(e) or traceback.format_exc().splitlines()[-1])
    finally:
        heading("Cleaning up")
        if obs:
            try:
                if state["item"] is not None:
                    obs.call("RemoveInput", {"inputName": SOURCE_NAME})
                if original_collection:
                    obs.call("SetCurrentSceneCollection", {"sceneCollectionName": original_collection})
                    time.sleep(2)
            except Exception as e:  # noqa: BLE001
                print("  Could not switch back to your scene collection: {}".format(e))
            obs.close()
        if proc:
            close_obs(proc, process_name)
        if ws_original is not None:
            with open(ws_config, "wb") as f:
                f.write(ws_original)
        elif os.path.isfile(ws_config):
            os.remove(ws_config)
        if os.path.isdir(scenes_dir):
            for name in os.listdir(scenes_dir):
                if name not in scenes_before and name.startswith("NixieVerify"):
                    os.remove(os.path.join(scenes_dir, name))
        print("  OBS closed, WebSocket settings restored, temporary scene collection removed.")
        for sig in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_DFL)
        bring_terminal_back()

    # ------------------------------------------------------------------
    # OBS log
    # ------------------------------------------------------------------

    heading("OBS log")
    plugin_log_lines = []
    logs = []
    if os.path.isdir(logs_dir):
        logs = sorted((os.path.join(logs_dir, n) for n in os.listdir(logs_dir) if n.endswith(".txt")),
                      key=os.path.getmtime, reverse=True)
        logs = [p for p in logs if os.path.getmtime(p) >= launch_time - 5]
    if logs:
        with open(logs[0], errors="replace") as f:
            lines = [line.rstrip("\n") for line in f if "nixie" in line.lower()]
        with open(os.path.join(output_dir, "obs-log-nixie.txt"), "w") as f:
            f.write("\n".join(lines) + "\n")
        # Only the plugin's own lines go into the report text, without timestamps.
        plugin_log_lines = [line.split(": ", 1)[1] if line[:2].isdigit() and ": " in line else line
                            for line in lines if "[" + PLUGIN + "]" in line]

        def loaded():
            for line in lines:
                if "plugin loaded successfully (version " in line:
                    report["plugin_version"] = line.split("(version ", 1)[1].split(")", 1)[0]
                    return "version " + report["plugin_version"]
            raise CheckFailed('no "plugin loaded successfully" line in the OBS log')

        step("Plugin reports it loaded", loaded)

        def no_errors():
            errors = [l for l in lines if "missing built-in image" in l or "error" in l.lower()]
            check(not errors, "found: " + (errors[0] if errors else ""))
            return "none"

        step("No plugin errors in the log", no_errors)
    else:
        add_result("OBS log found", "fail", "no log written since the test started in " + logs_dir)

    # ------------------------------------------------------------------
    # Report
    # ------------------------------------------------------------------

    failed = sum(1 for r in RESULTS if r["status"] == "fail")
    passed = sum(1 for r in RESULTS if r["status"] == "pass")
    manual = sum(1 for r in RESULTS if r["status"] == "manual")
    report["summary"] = {"passed": passed, "failed": failed, "tester_confirmed": manual, "total": len(RESULTS)}
    with open(os.path.join(output_dir, "report.json"), "w") as f:
        json.dump(report, f, indent=2)

    shots = sorted(os.path.join(shots_dir, n) for n in os.listdir(shots_dir) if n.endswith(".png"))
    sheet = None
    if shots:
        sheet = os.path.join(output_dir, "nixie-verify-screenshots.png")
        save_sheet(shots, sheet)

    print()
    if failed == 0:
        print(color("All {} automated checks passed.".format(passed), "pass"))
    else:
        print(color("{} of {} checks failed.".format(failed, len(RESULTS)), "fail"))
    print("Report folder: " + output_dir)
    exit_code = 0 if failed == 0 else 1

    if args.no_submit or not interactive:
        return exit_code
    submit(report, passed, failed, manual, plugin_log_lines, sheet, output_dir)
    return exit_code


def close_obs(proc, process_name):
    if IS_MAC:
        run_quiet(["osascript", "-e", 'tell application "OBS" to quit'])
    else:
        # OBS on Linux shuts down cleanly on SIGINT (as with Ctrl+C) but ignores
        # SIGTERM in some versions; send SIGTERM too if SIGINT doesn't work.
        # pkill also reaches OBS running inside Flatpak.
        run_quiet(["pkill", "-INT", "-u", str(os.getuid()), "-x", process_name])
    def still_running():
        # Collect our own child first: pgrep also lists finished, unreaped processes.
        proc.poll()
        return process_running(process_name)

    deadline = time.time() + 30
    while time.time() < deadline and still_running():
        if not IS_MAC and time.time() > deadline - 20:
            run_quiet(["pkill", "-TERM", "-u", str(os.getuid()), "-x", process_name])
        time.sleep(0.5)
    if still_running():
        print("  OBS did not close on its own; stopping it.")
        run_quiet(["pkill", "-KILL", "-u", str(os.getuid()), "-x", process_name])
        time.sleep(1)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()


def submit(report, passed, failed, manual, plugin_log_lines, sheet, output_dir):
    if failed == 0:
        result = "All passed ({} automated checks{})".format(passed, ", context bar confirmed by tester" if manual else "")
    else:
        result = "Some failed ({} of {} checks failed)".format(failed, passed + failed)
    plugin_text = "plugin " + report["plugin_version"] if report["plugin_version"] else "plugin version unknown"
    if report["plugin_sha256"]:
        plugin_text += ", SHA-256 " + report["plugin_sha256"]
    tools_text = "OBS {}, obs-websocket {}".format(report["obs_version"], report["obs_websocket_version"])
    test_type = "Installed plugin ({})".format(report["tool"])
    check_lines = "\n".join(
        "[{}] {}{}".format(r["status"].upper(), r["name"], " - " + r["details"] if r["details"] else "") for r in RESULTS
    )
    log_text = "\n\nPlugin lines from the OBS log:\n" + "\n".join(plugin_log_lines) if plugin_log_lines else ""

    heading("Submit the results")
    print("  This report would be posted publicly on GitHub:")
    print("    What was tested: " + test_type)
    print("    Result:          " + result)
    print("    System:          " + report["os"])
    print("    Version:         " + plugin_text)
    print("    Tools:           " + tools_text)
    print("    Output:          the list of checks above and the plugin's lines from the OBS log")
    if sheet:
        print("    Screenshots:     one image of the test source, which you paste in")
    print()
    print("  It opens in your browser for you to check first. You need a free GitHub account.")
    if not input("  Open the report in your browser now? (y/n) ").strip().lower().startswith("y"):
        print("  Not submitted. The report is saved in {}. Thanks for testing!".format(output_dir))
        return
    notes = input("  Anything to add? For example your computer model, or what looked wrong (optional, press Enter to skip) ")

    def report_url(output):
        fields = [
            ("template", "test-report.yml"),
            ("title", "Installed plugin on {}: {}".format(PLATFORM_NAME, result)),
            ("test-type", test_type),
            ("result", result),
            ("os", report["os"]),
            ("version", plugin_text),
            ("tools", tools_text),
            ("output", output),
            ("notes", notes),
            # Used by GitHub only if the Test report form isn't available; with
            # the form, the fields above are used and this is ignored.
            ("body", "**What was tested:** {}\n**Result:** {}\n**Operating system:** {}\n**Version or commit tested:** {}\n"
                     "**Tools:** {}\n\n**Output**\n```text\n{}\n```\n\n**Notes**\n{}".format(
                         test_type, result, report["os"], plugin_text, tools_text, output, notes)),
        ]
        return "https://github.com/{}/issues/new?{}".format(REPO, urllib.parse.urlencode(fields, quote_via=urllib.parse.quote))

    # Browsers and GitHub reject very long links; keep only the checks that did
    # not pass if needed and put the full text on the clipboard instead.
    full_output = check_lines + log_text
    url = report_url(full_output)
    text_on_clipboard = False
    if len(url) > 7500:
        text_on_clipboard = copy_text_to_clipboard(full_output)
        short = "\n".join("[{}] {} - {}".format(r["status"].upper(), r["name"], r["details"]) for r in RESULTS if r["status"] != "pass")
        note = "(Shortened to the checks that did not pass.{})\n".format(
            " The full list is on your clipboard; paste it here." if text_on_clipboard else " The full list is in report.json.")
        url = report_url(note + short)

    image_on_clipboard = bool(sheet) and not text_on_clipboard and copy_image_to_clipboard(sheet)

    # The browser covers this window once it opens, so explain first and wait.
    print()
    print(color("  What to do in the browser:", "title"))
    n = 1
    if text_on_clipboard:
        print("    {}. Click in the Output box and paste. This adds the full list of checks.".format(n))
        n += 1
    paste = "Cmd+V" if IS_MAC else "Ctrl+V"
    if image_on_clipboard:
        print("    {}. Click in the Notes box and press {}. This adds the screenshots.".format(n, paste))
        n += 1
    elif sheet:
        print("    {}. A file window opens too. Drag nixie-verify-screenshots.png from it".format(n))
        print("       into the Notes box. This adds the screenshots.")
        n += 1
    print('    {}. Check the report, then click "Submit new issue".'.format(n))
    input("  Press Enter to open the report ")
    if not open_url(url):
        print("  Could not open a browser. Open this link yourself:")
        print("  " + url)
    if sheet and not image_on_clipboard:
        show_file(sheet)
    print("  Opened in your browser. Thank you for testing!")


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.default_int_handler)
    sys.exit(main())
