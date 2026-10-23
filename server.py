#!/usr/bin/env python3
"""AirMouse Mac — use an iPhone as a gyroscope air mouse for macOS.

Serves the mobile control page over HTTPS and receives compact JSON messages
over a WebSocket, which are turned into Quartz (CoreGraphics) mouse events.

Protocol (phone -> Mac), one JSON object per WebSocket text frame:
    {"t":"m","dx":3,"dy":-2}     move cursor by a relative amount (pixels)
    {"t":"c","b":"l","n":1}      click; b = "l" | "r", n = 2 for the 2nd click of a double click
    {"t":"s","dy":-12}           scroll by pixels (positive = content moves down)
"""
from __future__ import annotations

import argparse
import json
import secrets
import socket
import ssl
import sys
from pathlib import Path

import qrcode
import Quartz
from aiohttp import WSMsgType, web

ROOT = Path(__file__).resolve().parent
INDEX_HTML = ROOT / "static" / "index.html"
CERTS = ROOT / "certs"
CERT_FILE = CERTS / "cert.pem"
KEY_FILE = CERTS / "key.pem"
ROOT_CA_FILE = CERTS / "rootCA.pem"
CERT_IP_FILE = CERTS / "ip.txt"
TOKEN_FILE = CERTS / "token.txt"

MAX_DELTA = 1000  # ignore absurd values from a misbehaving client


# --------------------------------------------------------------------------- #
# Mouse control (Quartz CGEvent)
# --------------------------------------------------------------------------- #
class Mouse:
    """Thin wrapper around CGEvent for synthesizing mouse input."""

    BUTTONS = {
        "l": (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp, Quartz.kCGMouseButtonLeft),
        "r": (Quartz.kCGEventRightMouseDown, Quartz.kCGEventRightMouseUp, Quartz.kCGMouseButtonRight),
    }

    def __init__(self) -> None:
        self.displays: list = []
        self.refresh_displays()

    def refresh_displays(self) -> None:
        """Cache the bounds of all active displays (global coordinates, points)."""
        err, ids, count = Quartz.CGGetActiveDisplayList(16, None, None)
        self.displays = [Quartz.CGDisplayBounds(d) for d in ids[:count]] if err == 0 else []
        if not self.displays:
            self.displays = [Quartz.CGDisplayBounds(Quartz.CGMainDisplayID())]

    @staticmethod
    def position():
        """Current cursor location as a CGPoint."""
        return Quartz.CGEventGetLocation(Quartz.CGEventCreate(None))

    def _clamp(self, x: float, y: float, cur) -> tuple[float, float]:
        """Keep (x, y) on screen. Moving onto another display is allowed;
        moving off the desktop clamps to the display the cursor is on."""
        if any(Quartz.CGRectContainsPoint(b, (x, y)) for b in self.displays):
            return x, y
        b = next((b for b in self.displays if Quartz.CGRectContainsPoint(b, cur)), self.displays[0])
        x = min(max(x, b.origin.x), b.origin.x + b.size.width - 1)
        y = min(max(y, b.origin.y), b.origin.y + b.size.height - 1)
        return x, y

    def move(self, dx: float, dy: float) -> None:
        cur = self.position()
        pos = self._clamp(cur.x + dx, cur.y + dy, cur)
        ev = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, pos, Quartz.kCGMouseButtonLeft)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)

    def click(self, button: str = "l", count: int = 1) -> None:
        """Press + release. count=2 marks the second click of a double click,
        which is how macOS recognizes double clicks from synthetic events."""
        down, up, btn = self.BUTTONS[button]
        pos = self.position()
        for etype in (down, up):
            ev = Quartz.CGEventCreateMouseEvent(None, etype, pos, btn)
            Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGMouseEventClickState, count)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)

    def scroll(self, dy: int) -> None:
        ev = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitPixel, 1, dy)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


def _num(value) -> float:
    """Coerce a JSON value to a bounded float (raises on garbage)."""
    v = float(value)
    if v != v:  # NaN
        raise ValueError("NaN")
    return max(-MAX_DELTA, min(MAX_DELTA, v))


def handle_message(mouse: Mouse, msg: dict) -> None:
    t = msg.get("t")
    if t == "m":
        mouse.move(_num(msg.get("dx", 0)), _num(msg.get("dy", 0)))
    elif t == "c":
        mouse.click("r" if msg.get("b") == "r" else "l", 2 if msg.get("n") == 2 else 1)
    elif t == "s":
        mouse.scroll(int(_num(msg.get("dy", 0))))


# --------------------------------------------------------------------------- #
# Web app
# --------------------------------------------------------------------------- #
def make_app(token: str, mouse: Mouse) -> web.Application:
    def authorized(request: web.Request) -> bool:
        given = request.query.get("t", "")
        return secrets.compare_digest(given.encode(), token.encode())

    async def index(request: web.Request) -> web.StreamResponse:
        if not authorized(request):
            return web.Response(status=403, text="Forbidden: scan the QR code shown in the Mac terminal.\n")
        return web.FileResponse(
            INDEX_HTML,
            headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"},
        )

    async def cert(_: web.Request) -> web.StreamResponse:
        # Public root certificate only (never a key) — lets the iPhone install it as a profile.
        return web.FileResponse(
            ROOT_CA_FILE if ROOT_CA_FILE.exists() else CERT_FILE,
            headers={
                "Content-Type": "application/x-x509-ca-cert",
                "Content-Disposition": 'attachment; filename="AirMouse-rootCA.crt"',
            },
        )

    async def websocket(request: web.Request) -> web.StreamResponse:
        if not authorized(request):
            raise web.HTTPForbidden()
        ws = web.WebSocketResponse(heartbeat=15, max_msg_size=4096)
        await ws.prepare(request)
        mouse.refresh_displays()  # pick up monitor changes on each new connection
        print(f"[+] phone connected: {request.remote}")
        try:
            async for msg in ws:
                if msg.type != WSMsgType.TEXT:
                    continue
                try:
                    data = json.loads(msg.data)
                    if isinstance(data, dict):
                        handle_message(mouse, data)
                except (ValueError, TypeError):
                    pass  # ignore malformed messages
        finally:
            print(f"[-] phone disconnected: {request.remote}")
        return ws

    app = web.Application()
    app.router.add_get("/", index)
    app.router.add_get("/cert", cert)
    app.router.add_get("/ws", websocket)
    return app


# --------------------------------------------------------------------------- #
# Startup helpers
# --------------------------------------------------------------------------- #
def local_ip() -> str:
    """LAN IP of the interface used for outbound traffic (no packets are sent)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("192.0.2.1", 9))  # TEST-NET address; connect() on UDP only picks a route
            return s.getsockname()[0]
        except OSError:
            return "127.0.0.1"


def load_token(reset: bool) -> str:
    """Persisted random token so a bookmarked URL keeps working across restarts."""
    if not reset and TOKEN_FILE.exists():
        token = TOKEN_FILE.read_text().strip()
        if token:
            return token
    token = secrets.token_urlsafe(12)
    TOKEN_FILE.write_text(token + "\n")
    TOKEN_FILE.chmod(0o600)
    return token


def check_accessibility() -> None:
    """Posting mouse events requires the Accessibility permission."""
    preflight = getattr(Quartz, "CGPreflightPostEventAccess", None)
    if preflight is None or preflight():
        return
    print(
        "\n!! Accessibility permission is missing — the cursor will NOT move.\n"
        "   System Settings → Privacy & Security → Accessibility → enable your terminal app\n"
        "   (Terminal, iTerm, VS Code, …), then restart this server.\n"
    )
    request = getattr(Quartz, "CGRequestPostEventAccess", None)
    if request:
        request()  # shows the system prompt / adds the app to the list


def print_qr(url: str, light_terminal: bool) -> None:
    qr = qrcode.QRCode(border=2)
    qr.add_data(url)
    qr.make(fit=True)
    qr.print_ascii(invert=not light_terminal)


def main() -> None:
    parser = argparse.ArgumentParser(description="AirMouse Mac server")
    parser.add_argument("--port", type=int, default=8443, help="HTTPS port (default 8443)")
    parser.add_argument("--host", default="0.0.0.0", help="bind address (default 0.0.0.0)")
    parser.add_argument("--new-token", action="store_true", help="generate a new access token")
    parser.add_argument("--light", action="store_true", help="QR code for light-background terminals")
    args = parser.parse_args()

    if not (CERT_FILE.exists() and KEY_FILE.exists()):
        sys.exit("No TLS certificate found. Run ./setup.sh first.")

    ssl_ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ssl_ctx.load_cert_chain(CERT_FILE, KEY_FILE)

    token = load_token(args.new_token)
    ip = local_ip()
    url = f"https://{ip}:{args.port}/?t={token}"

    cert_ip = CERT_IP_FILE.read_text().strip() if CERT_IP_FILE.exists() else ""
    if cert_ip and cert_ip != ip:
        print(f"!! Certificate was made for {cert_ip} but this Mac is now {ip}.\n"
              f"   Run ./setup.sh --force-cert (with openssl you must also re-trust it on the phone).\n")

    check_accessibility()

    print("AirMouse Mac is running. Scan with your iPhone camera (same Wi-Fi):\n")
    print_qr(url, args.light)
    print(f"  {url}\n")
    print(f"  Root certificate for the phone: certs/rootCA.pem  (or https://{ip}:{args.port}/cert)")
    print("  Ctrl+C to stop.\n")

    web.run_app(
        make_app(token, Mouse()),
        host=args.host,
        port=args.port,
        ssl_context=ssl_ctx,
        access_log=None,
        print=None,
    )


if __name__ == "__main__":
    main()
