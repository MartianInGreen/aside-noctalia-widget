#!/usr/bin/env python3
"""aside <-> noctalia bridge.

Handles everything the noctalia widget needs that the plain `aside` CLI
does not expose (image attachments) plus a few convenience helpers.

Subcommands:
  send         Send a query to the aside daemon (text and/or image).
  attach       Grab an image (clipboard) and store it as a PNG for later send.
  list         Dump recent conversations as JSON.
  action       cancel | toggle-tts | stop-tts   (fire-and-forget socket actions)
  ping         Exit 0 if the daemon socket is reachable.

The aside daemon reads a single <=64KB chunk per socket connection, so
images are downscaled/re-encoded until their base64 fits the budget.
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

B64_BUDGET = 46_000          # max bytes of PNG we allow (b64 grows 4/3x, must stay < 64KB msg)
MAX_DIMENSIONS = 2048        # never send larger than this regardless of budget


def socket_path(name: str = "aside.sock") -> Path:
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    return Path(xdg) / name if xdg else Path(f"/run/user/{os.getuid()}") / name


def daemon_send(msg: dict, expect_reply: bool = False) -> dict | None:
    """Send one JSON command to the aside daemon socket."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(str(socket_path()))
    except (FileNotFoundError, ConnectionRefusedError, PermissionError, OSError) as e:
        print(f"aside daemon not reachable ({e})", file=sys.stderr)
        raise SystemExit(2)

    try:
        s.sendall((json.dumps(msg) + "\n").encode("utf-8"))
        s.shutdown(socket.SHUT_WR)
        if not expect_reply:
            return None
        chunks = []
        while True:
            data = s.recv(65536)
            if not data:
                break
            chunks.append(data)
            if len(chunks) * 65536 > 1 << 20:
                break
        return json.loads(b"".join(chunks).decode("utf-8"))
    finally:
        try:
            s.close()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Image handling
# ---------------------------------------------------------------------------

def encode_image(raw: bytes) -> bytes:
    """Return PNG bytes that fit into the daemon's 64KB socket message.

    Progressively downscales / reduces colors with Pillow until the
    base64 payload fits the budget.  Falls back to raw bytes when they
    already fit and Pillow is unavailable.
    """
    if len(raw) * 4 // 3 < B64_BUDGET and len(raw) < 1 << 20:
        return raw  # small enough already

    try:
        from PIL import Image
    except ImportError:
        raise SystemExit("image too large and Pillow unavailable to shrink it")

    img = Image.open(io.BytesIO(raw))
    if img.mode not in ("RGB", "RGBA", "L"):
        img = img.convert("RGBA")

    def encode(im: "Image.Image", quantize: int | None) -> bytes:
        buf = io.BytesIO()
        im.save(buf, "PNG", optimize=True)
        return buf.getvalue()

    attempts: list[tuple[int, int | None]] = []
    d = MAX_DIMENSIONS
    while d >= 320:
        attempts.append((d, None))
        attempts.append((d, 256))
        attempts.append((d, 128))
        d //= 2
    attempts.append((256, 64))
    attempts.append((192, 48))

    best = raw
    for max_side, colors in attempts:
        im = img
        w, h = im.size
        scale = max(1.0, max(w, h) / max_side)
        if scale > 1.0:
            im = im.resize((max(1, int(w / scale)), max(1, int(h / scale))), Image.LANCZOS)
        if colors:
            try:
                im = im.convert("RGB").quantize(colors=colors)
            except Exception:
                pass
        best = encode(im, colors)
        if len(best) * 4 // 3 < B64_BUDGET:
            return best
    return best  # smallest we could produce


def load_image_source(explicit: str | None, from_clipboard: bool) -> bytes:
    if explicit:
        p = Path(explicit).expanduser()
        if not p.is_file():
            raise SystemExit(f"image not found: {p}")
        return p.read_bytes()

    if from_clipboard:
        try:
            r = subprocess.run(["wl-paste", "--type", "image/png"],
                               capture_output=True, timeout=5)
        except FileNotFoundError:
            raise SystemExit("wl-paste not found (wl-clipboard required)")
        if r.returncode != 0 or not r.stdout:
            try:
                r2 = subprocess.run(["wl-paste"], capture_output=True, timeout=5)
                if r2.returncode == 0 and r2.stdout[:8] == b"\x89PNG\r\n\x1a\n":
                    return r2.stdout
            except Exception:
                pass
            raise SystemExit("no image in clipboard")
        return r.stdout

    raise SystemExit("no image source given")


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def cmd_send(a: argparse.Namespace) -> None:
    text = (a.text or "").strip()
    image_b64 = None
    if a.image or a.clipboard:
        raw = load_image_source(a.image, a.clipboard)
        png = encode_image(raw)
        image_b64 = base64.b64encode(png).decode("ascii")
        if not text:
            text = a.default_prompt or "Describe this image."

    if not text and not image_b64:
        raise SystemExit("nothing to send")

    msg: dict = {"action": "query", "text": text}
    if a.new:
        msg["conversation_id"] = "__new__"
    elif a.conversation:
        msg["conversation_id"] = a.conversation
    if image_b64:
        msg["image"] = image_b64

    daemon_send(msg)
    print("sent")


def cmd_attach(a: argparse.Namespace) -> None:
    raw = load_image_source(a.image, a.clipboard)
    png = encode_image(raw)
    dest = Path(a.output).expanduser()
    dest.write_bytes(png)
    print(dest)


def cmd_list(a: argparse.Namespace) -> None:
    conv_dir = Path(a.dir).expanduser()
    out = []
    try:
        files = sorted(conv_dir.glob("*.json"), key=lambda f: f.stat().st_mtime, reverse=True)
    except OSError:
        files = []
    for f in files[: a.limit]:
        try:
            st = f.stat()
            data = json.loads(f.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        preview = ""
        for m in data.get("messages", []):
            c = m.get("content")
            if isinstance(c, str) and c.strip():
                preview = c.strip().replace("\n", " ")[:90]
                break
            if isinstance(c, list):
                txt = " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
                if txt.strip():
                    preview = txt.strip().replace("\n", " ")[:90]
                    break
                if any(isinstance(b, dict) and b.get("type") == "image_url" for b in c):
                    preview = "[image]"
                    break
        out.append({
            "id": data.get("id", f.stem),
            "mtime": st.st_mtime,
            "messages": len(data.get("messages", [])),
            "preview": preview,
        })
    print(json.dumps(out))


def cmd_action(a: argparse.Namespace) -> None:
    if a.name == "ping":
        daemon_send({"action": "get_model"}, expect_reply=True)
        print("pong")
        return
    actions = {"cancel": "cancel", "toggle-tts": "toggle_tts", "stop-tts": "stop_tts"}
    if a.name not in actions:
        raise SystemExit(f"unknown action {a.name}")
    daemon_send({"action": actions[a.name]})
    print("ok")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("send", help="send a query to the daemon")
    p.add_argument("--text", default="")
    p.add_argument("--image", default=None, help="path to an image file to attach")
    p.add_argument("--clipboard", action="store_true", help="attach image from clipboard")
    p.add_argument("--new", action="store_true", help="force a new conversation")
    p.add_argument("--conversation", default="", help="continue this conversation id")
    p.add_argument("--default-prompt", default="", help="used as text when only an image is sent")
    p.set_defaults(func=cmd_send)

    p = sub.add_parser("attach", help="store an image as widget-optimized PNG")
    p.add_argument("--image", default=None)
    p.add_argument("--clipboard", action="store_true")
    p.add_argument("--output", required=True)
    p.set_defaults(func=cmd_attach)

    p = sub.add_parser("list", help="dump recent conversations as JSON")
    p.add_argument("dir")
    p.add_argument("--limit", type=int, default=25)
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("action", help="ping | cancel | toggle-tts | stop-tts")
    p.add_argument("name")
    p.set_defaults(func=cmd_action)

    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass
    time.sleep(0)
