# AirMouse Mac

Use your iPhone as a gyroscope **air mouse** for your Mac over the local Wi-Fi.
There's no app to install: the phone opens a web page served by a small Python server on the Mac.

- **Local only.** There's no domain, no cloud and no internet access. Everything runs on your LAN.
- **HTTPS + WSS on one port (8443).** iOS only gives motion sensors to secure pages, so TLS is required.
- **Access token in the URL.** Other devices on your network can't control your Mac.

```
iPhone Safari ──(wss://<mac-ip>:8443/ws?t=TOKEN, ~60 Hz JSON)──▶ server.py ──▶ Quartz CGEvent ──▶ cursor
```

## Project structure

```
AirMouse/
├── server.py          # aiohttp HTTPS + WebSocket server, Quartz mouse control, QR code
├── static/index.html  # mobile control page (vanilla JS, single file)
├── setup.sh           # venv + dependencies + local TLS certificate
├── requirements.txt   # aiohttp, pyobjc-framework-Quartz, qrcode
└── certs/             # generated: cert.pem, key.pem, rootCA.pem, token.txt (keep private)
```

## 1. Setup (Mac mini)

Requirements: macOS, Python 3.9+ (`python3`), and an iPhone on the **same Wi-Fi** as the Mac.

**Recommended:** install [mkcert](https://github.com/FiloSottile/mkcert) first. It creates a local root CA, so the iPhone keeps trusting new certificates even if the Mac's IP changes later.

```bash
brew install mkcert          # optional but recommended
cd AirMouse
chmod +x setup.sh
./setup.sh
```

`setup.sh`:
1. creates `.venv` and installs the dependencies.
2. detects the Mac's local IP (`ipconfig getifaddr en0/en1…`).
3. creates a certificate for that IP, `<hostname>.local` and `localhost`:
   - **with mkcert:** runs `mkcert -install` (may ask for your Mac password), then
     `mkcert <ip> <host>.local localhost 127.0.0.1`. It copies the CA to `certs/rootCA.pem`.
   - **without mkcert:** makes an openssl self-signed cert (valid 825 days, the iOS maximum)
     with the IP in the SAN. That cert is its own root, so it's also copied to `certs/rootCA.pem`.

Run `./setup.sh --force-cert` to regenerate the certificate, for example after the IP changes.

## 2. Grant Accessibility permission (one time)

macOS only lets apps move the cursor and click after you allow it.

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Click **+** and add the app you run the server from, such as **Terminal**, **iTerm** or **Visual Studio Code**,
   then switch it **on**. If it's already listed, switch it off and on again.
3. Restart the server. Some apps also need to be restarted after you grant the permission.

If the permission is missing, the server prints a warning when it starts and macOS shows a prompt.

## 3. Run

```bash
.venv/bin/python server.py
```

The server prints a QR code and a URL like `https://192.168.1.16:8443/?t=AbC123…`.
The token is stored in `certs/token.txt` and stays the same between restarts, so bookmarks keep working.

| Option         | Meaning                                                        |
|----------------|----------------------------------------------------------------|
| `--port 8443`  | HTTPS/WSS port                                                 |
| `--new-token`  | create a new access token (old links stop working)             |
| `--light`      | print the QR code for a light-background terminal              |

## 4. Trust the root certificate on the iPhone (one time)

Do this before you open the page. Without it, Safari shows a warning and may block the WebSocket.

1. **Send `certs/rootCA.pem` to the iPhone.**
   - **AirDrop:** in Finder, right-click `certs/rootCA.pem` → Share → AirDrop → your iPhone.
   - **Or** open `https://<mac-ip>:8443/cert` in **Safari** on the iPhone. Accept the one-time warning
     (Show Details → visit this website) to download it.

   The iPhone says **"Profile Downloaded"**. Tap **Allow** if Safari asks.
2. **Install the profile.** Open **Settings → General → VPN & Device Management**.
   (Depending on your iOS version, a **"Profile Downloaded"** item may also appear near the top of Settings.)
   Tap the AirMouse / mkcert profile → **Install** → enter your passcode → **Install** → **Done**.
3. **Enable full trust.** Open **Settings → General → About → Certificate Trust Settings**. Under
   *"Enable full trust for root certificates"*, switch on the AirMouse / mkcert certificate → **Continue**.
4. Scan the QR code with the **Camera** app and open it in Safari. There should be no warning now.

Notes:
- With **mkcert**, you only trust the root CA once. Later certificates (new IP, `--force-cert`) are trusted automatically.
- With **openssl**, each new certificate is its own root. Repeat steps 1–3 after regenerating it,
  and delete the old profile under VPN & Device Management.
- The CA private key never leaves your Mac, and `/cert` only serves the public certificate.
  Keep `certs/` private, and don't AirDrop `rootCA-key.pem` from `mkcert -CAROOT`.

## 5. Use it

1. Open the URL from the QR code and tap **Start**, then tap **Allow** for *Motion & Orientation*.
2. Hold the phone **upright in portrait**, the way you'd hold it to read it.

| Gesture                              | Action                                          |
|--------------------------------------|-------------------------------------------------|
| Hold a finger on the screen + move   | moves the cursor (turn left/right, tilt up/down)|
| Lift the finger                      | cursor stops and stays, so you can re-center your hand |
| Quick tap (< 200 ms, no movement)    | left click                                      |
| Two quick taps                       | double click                                    |
| Two-finger tap                       | right click                                     |
| Two-finger drag up/down              | scroll                                          |

Tip: tap **Share → Add to Home Screen** for a full-screen launcher.

### Settings (⚙︎, saved on the phone)
- **Sensitivity**: how many cursor pixels one degree of rotation moves (5–80).
- **Smoothing**: low-pass filter strength. Raise it if the cursor jitters, lower it if the cursor lags.
- **Dead zone**: ignores rotation below this speed (°/s), which removes hand tremor when you hold still.
- **Invert horizontal / vertical / scroll**.

## Troubleshooting

**"Motion access denied" / nothing happens after Start**
- iOS remembers a denial for the session. Close Safari completely (swipe it away in the app switcher),
  reopen the link, tap **Start** and choose **Allow**.
- Still denied? Go to Settings → Apps → Safari → Advanced → Website Data, delete the entry for the Mac's IP, and try again.
- The page must be opened via **https://**. Over plain http, iOS hides the motion sensors completely.

**"No gyroscope data" banner**
- Android Chrome: tap the lock/tune icon next to the address → Site settings → **Motion sensors → Allow**.
- In Chrome, accept the certificate warning with **Advanced → Proceed**, or install `rootCA.pem` under
  Settings → Security → Encryption & credentials → Install a certificate → CA certificate.

**Page doesn't load / "Connecting…" never turns green**
- Both devices must be on the **same Wi-Fi**. Guest networks and "client/AP isolation" block device-to-device traffic.
- Turn off **iCloud Private Relay** and any **VPN** on the iPhone for this network, if they get in the way.
- Check that the IP in the QR code matches `ipconfig getifaddr en0` (or `en1`). If the IP changed, run
  `./setup.sh --force-cert`. To keep the IP stable, set a DHCP reservation for the Mac mini in your router.
- **Firewall:** System Settings → Network → Firewall → Options. Allow incoming connections for
  `python3` (or click **Allow** when macOS asks), and make sure "Block all incoming connections" is off.
- **403 Forbidden** means the token is wrong or missing. Rescan the QR code.
- **Certificate warning still appears** means step 3 of section 4 (full trust) wasn't done, or the certificate
  was regenerated (openssl mode).

**Cursor doesn't move but the status says Connected**
- Accessibility permission is missing for the app running the server (see section 2), or you didn't restart the server after granting it.

**Left/right feels reversed or the axes are mixed up**
- Hold the phone upright in portrait. If a direction still feels wrong, use **Invert horizontal / vertical** in settings.

## Protocol

One JSON object per WebSocket text message (phone → Mac):

```json
{"t":"m","dx":3,"dy":-2}     // move by whole pixels (deltas batched at ~60 Hz)
{"t":"c","b":"l","n":1}      // click: b = "l" | "r", n = 2 for the second click of a double click
{"t":"s","dy":-12}           // scroll in pixels
```

## Security notes
- The server listens on your LAN only. Don't forward port 8443 on your router.
- Every page and WebSocket request needs the token, and the server checks it in constant time.
  Run `--new-token` to revoke old links.
- `certs/` holds your private key and token. Don't share or commit it.
