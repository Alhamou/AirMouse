# AirMouse

Use your iPhone as a full-screen **trackpad** for your Mac over the local Wi-Fi.
On the Mac, a small native menu bar app runs the server. The iPhone just opens a web page, so there's nothing to install on the phone.

- **Local only.** There's no domain, no cloud and no internet access. Everything runs on your LAN.
- **HTTPS + WSS on one port (8443),** using a private root CA that lives on your Mac.
- **Access token in the URL.** Other devices on your network can't control your Mac.

```
iPhone Safari ──(wss://<mac-ip>:8443/ws?t=TOKEN, ~60 Hz JSON)──▶ AirMouse.app ──▶ CGEvent ──▶ cursor
```

## Project structure

```
AirMouse/
├── macos/                    # native macOS menu bar app (Swift) — recommended
│   ├── Sources/AirMouse/     #   server, input, certificates, menu bar, QR window, voice handoff to Haki
│   ├── Resources/            #   Info.plist, AppIcon.icns
│   ├── scripts/make-icon.swift
│   └── build.sh              #   builds/signs AirMouse.app, --install copies to /Applications
├── static/index.html         # the trackpad + TV + voice page (shared by the app and the Python server)
├── server.py, setup.sh, requirements.txt   # optional Python server, same protocol
└── README.md
```

## 1. Build and install the Mac app

Requirements: macOS 13+ and Xcode (or the Command Line Tools).

```bash
cd AirMouse/macos
./build.sh --install
```

This compiles the app, signs it with your Apple Development certificate if you have one (otherwise ad-hoc),
copies it to **/Applications** and launches it. On the first launch AirMouse:
- adds a trackpad icon to the **menu bar** (no Dock icon). The icon is filled while an iPhone is connected.
- turns on **Start at Login**. You can switch it off in the menu.
- shows the **QR code** window.
- asks for **Accessibility** permission (see section 2).

To build without installing, run `./build.sh`; the result is in `macos/build/AirMouse.app`.

### Menu

| Item                                 | What it does                                              |
|--------------------------------------|-----------------------------------------------------------|
| status line                          | "iPhone connected" / "Waiting for iPhone — <ip>" / errors |
| Allow Accessibility Access…          | shown only while the permission is missing                |
| Show QR Code… / Copy Link            | the link to open on the iPhone                            |
| Send Root Certificate via AirDrop…   | sends `rootCA.pem` to the iPhone (see section 3)          |
| Show Root Certificate in Finder      |                                                           |
| Start at Login                       | on by default                                             |
| Reset Access Link                    | new token; old links and connected phones stop working   |
| Quit AirMouse                        |                                                           |

Certificates live in `~/Library/Application Support/AirMouse/`. The root CA is created once.
The server certificate is re-issued automatically when the Mac's IP changes, so you only trust the root once on the iPhone.

## 2. Grant Accessibility permission (one time)

macOS only lets apps move the cursor and click after you allow it.

1. When macOS asks, click **Open System Settings**. You can also use the menu item **Allow Accessibility Access…**.
2. In **System Settings → Privacy & Security → Accessibility**, switch **AirMouse** on.

The permission stays across rebuilds as long as the app is signed with the same certificate.
With ad-hoc signing you have to switch it off and on again after each rebuild.

## 3. Trust the root certificate on the iPhone (one time)

1. **Send the certificate.** In the menu, choose **Send Root Certificate via AirDrop…** and pick your iPhone.
   The iPhone says **"Profile Downloaded"**.
2. **Install the profile.** On the iPhone, open **Settings → General → VPN & Device Management**.
   Tap **AirMouse Local CA** → **Install** → enter your passcode → **Install** → **Done**.
3. **Enable full trust.** Open **Settings → General → About → Certificate Trust Settings**. Under
   *"Enable full trust for root certificates"*, switch on **AirMouse Local CA** → **Continue**.
4. Scan the QR code from the menu with the **Camera** app and open it in Safari.

If you trusted the old Python `certs/rootCA.pem` before, you can delete that profile. The app uses its own CA.

## 4. Use it

The whole screen works like a Magic Trackpad.

| Gesture                                  | Action                                         |
|------------------------------------------|------------------------------------------------|
| Slide one finger                         | moves the cursor (with acceleration)           |
| Tap                                      | left click                                     |
| Two quick taps                           | double click                                   |
| Tap, then touch again and slide / hold   | drag (the button is released when you lift)    |
| Two-finger slide (any direction)         | scroll, with momentum after a flick            |
| Two-finger tap                           | right click                                    |
| Three-finger swipe left / right          | next / previous desktop (or full-screen app)   |
| Three-finger swipe up                    | Mission Control (swipe down closes it)         |
| Three-finger swipe down                  | App Exposé, the current app's windows (swipe up closes it) |

Three-finger swipes send the standard macOS shortcuts (Ctrl+←/→, Ctrl+↑, Ctrl+↓). They must stay enabled in
**System Settings → Keyboard → Keyboard Shortcuts → Mission Control**. They're on by default.

Settings (⚙︎, saved on the phone):
- **Tracking speed**: base cursor speed. Fast swipes are accelerated on top of this.
- **Scroll momentum**: keep scrolling after a two-finger flick.
- **Invert scroll**.

Tip: in Safari, tap **Share → Add to Home Screen** to get a full-screen launcher with the AirMouse icon.

### Voice typing (with Haki)

The 🎤 tab at the top switches from the trackpad to voice. Tap anywhere to start talking, then tap again to send.
While recording, "✕ Cancel" discards the clip without sending it.
The text is typed into whatever field is focused on the Mac.

The transcription itself is done by [Haki](https://github.com/Alhamou/Haki), which must be installed in `/Applications`.
Haki uses its own OpenAI key, model and language settings. AirMouse only passes the recording along:

```
iPhone mic ──(POST /voice?t=TOKEN)──▶ AirMouse.app ──▶ ~/Library/Caches/Haki/Inbox/airmouse-<id>.m4a
           ──▶ open -g haki://transcribe?file=… ──▶ Haki ──▶ OpenAI ──▶ text pasted at the cursor
```

The first time, Safari asks for microphone access. Recordings are limited to 10 MB (about 10 minutes).

### LG TV pointer

The 📺 tab turns the pad into a Magic Remote for an LG webOS TV: slide a finger and the TV's own pointer
appears over whatever is on screen. Tap = OK, two fingers = scroll, two-finger tap = Back. The buttons at
the bottom are a joystick (hold and push to move the pointer, tap = OK), Back, Home, **123** (type a channel number), **Aa** (type into the TV's focused text field,
live; Return sends Enter), power, channel −/+ and volume: press the 🔊
button and slide left / right to change the volume, or tap it to mute.

Power turns the TV off while it's connected, and otherwise wakes it with Wake-on-LAN. The Mac learns the
TV's hardware address on the first connection, and the TV needs "Turn on via Wi-Fi" (Mobile TV On) enabled.

Set the TV's IP address with **Set TV Address…** in the menu (default `192.168.1.51`). The first time the
tab opens, the TV asks to allow AirMouse; accept it with the remote. The Mac keeps the key the TV returns,
so later connections need no prompt. The Mac must be awake, because it relays the phone's input to the TV:

```
iPhone ──(wss, "to":"tv")──▶ AirMouse.app ──(SSAP wss://TV:3001)──▶ getPointerInputSocket ──▶ TV pointer
```

## Troubleshooting

**Page doesn't load / "Connecting…" never turns green**
- Both devices must be on the **same Wi-Fi**. Guest networks and "client/AP isolation" block device-to-device traffic.
- Turn off **iCloud Private Relay** and any **VPN** on the iPhone for this network, if they get in the way.
- The IP in the menu's status line must match the QR code. After a network change, use **Show QR Code…** to get the new link.
  To keep the IP stable, set a DHCP reservation for the Mac in your router.
- **Firewall:** System Settings → Network → Firewall → Options. Allow incoming connections for **AirMouse**.
- **403 Forbidden** means the token is wrong or missing. Rescan the QR code.
- **Certificate warning** means section 3, step 3 (full trust) wasn't done.
- **"Port 8443 is already in use"** in the menu means the Python server is probably still running. Stop it, then choose **Restart Server**.

**Cursor doesn't move but the phone says Connected**
- Accessibility permission is missing (see section 2). The menu shows **⚠︎ Allow Accessibility Access…** in this case.

**Voice tab shows "Could not send: Haki is not installed on this Mac."**
- Install Haki in `/Applications` and open it once, so macOS registers its `haki://` URL scheme.

**Voice clip is sent but no text appears**
- Haki must be running, with an API key saved and Accessibility permission granted. Check its menu bar icon.

**TV tab says "TV unreachable" or "TV declined pairing"**
- The TV must be on and on the same network, at the address in **Set TV Address…**.
- "Mobile TV On" / "LG Connect Apps" must be enabled in the TV's network settings.
- After a decline, switch tabs and back to 📺 to get the prompt again.

**Three-finger swipe does nothing**
- Check that the Mission Control shortcuts above are enabled. To switch desktops you need at least two
  (Mission Control → **+** at the top right).

## Optional: Python server

`server.py` serves the same page and protocol without the app. It's useful for development:

```bash
./setup.sh                    # venv, dependencies, certificate in certs/
.venv/bin/python server.py    # prints a QR code; grant Accessibility to your terminal app
```

Don't run it at the same time as the app, because both use port 8443.
The Python server has no voice support (`POST /voice`); use the app for that.

## Protocol

One JSON object per WebSocket text message (phone → Mac):

```json
{"t":"m","dx":3,"dy":-2}     // move by whole pixels (deltas batched at ~60 Hz)
{"t":"c","b":"l","n":1}      // click: b = "l" | "r", n = 2 for the second click of a double click
{"t":"d","s":1}              // hold (1) / release (0) the left button, for dragging
{"t":"s","dx":0,"dy":-12}    // scroll in pixels (vertical + horizontal)
{"t":"g","d":"l"}            // three-finger swipe: d = "l" | "r" | "u" | "d"
```

With `"to":"tv"`, `m`, `c` and `s` drive the LG TV's pointer instead (a right click is the Back key), plus
`{"t":"b","k":"HOME","to":"tv"}` for a remote key (also `CHANNELUP`, `VOLUMEDOWN`, `MUTE`, digits `0`–`9`),
`{"t":"p","to":"tv"}` for power (off, or wake from standby), `{"t":"n","n":"25","to":"tv"}` to go to a channel, `{"t":"k","s":"abc"}` / `{"t":"k","d":2}` / `{"t":"k","e":1}`
(with `"to":"tv"`) to type, delete and press Enter in the TV's text field, and `{"t":"h","to":"tv"}` when the TV tab opens.
The Mac answers with `{"t":"tv","s":"connected","m":"TV connected"}` whenever the TV link changes
(`s` = `off` | `connecting` | `pairing` | `connected` | `error`).

Voice clips are a separate HTTPS request: `POST /voice?t=TOKEN` with the recording as the body
(`Content-Type: audio/mp4`, `audio/webm`, …). The answer is `200 OK` once the clip is handed to Haki,
`403` for a bad token, `413` if it's over 10 MB and `503` if Haki isn't installed.

## Security notes
- The server listens on your LAN only. Don't forward port 8443 on your router.
- Every page and WebSocket request needs the token, which is compared in constant time.
  **Reset Access Link** revokes old links.
- The root CA's private key (`rootCA-key.pem`) never leaves your Mac, and `/cert` only serves the public certificate.
