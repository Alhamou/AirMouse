#!/usr/bin/env bash
# setup.sh — one-time setup for AirMouse Mac.
#   1. creates a Python virtualenv in .venv and installs dependencies
#   2. generates a TLS certificate for this Mac's local IP (mkcert if installed, else openssl)
#
# Usage: ./setup.sh [--force-cert]
#   --force-cert   regenerate the certificate even if one already exists
set -euo pipefail
cd "$(dirname "$0")"

FORCE_CERT=0
[[ "${1:-}" == "--force-cert" ]] && FORCE_CERT=1

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "python3 not found. Install it with: xcode-select --install  (or: brew install python)" >&2
  exit 1
fi

# --- 1. Virtualenv + dependencies ------------------------------------------
echo "==> Setting up virtualenv in .venv"
[[ -d .venv ]] || "$PYTHON" -m venv .venv
.venv/bin/python -m pip install --quiet --upgrade pip
.venv/bin/python -m pip install --quiet -r requirements.txt
echo "    dependencies installed"

# --- 2. TLS certificate (local only) ---------------------------------------
# iOS only exposes motion sensors to secure (HTTPS) pages, so we need a cert for
# the Mac's LAN IP. Preferred: mkcert (local CA). Fallback: openssl self-signed.
# Either way, certs/rootCA.pem is the file to install and trust on the iPhone.

# Find the Mac's LAN IP (Wi-Fi is usually en0 on laptops; en1 on a Mac mini whose en0 is Ethernet).
IP=""
for ifc in en0 en1 en2 en3; do
  IP="$(ipconfig getifaddr "$ifc" 2>/dev/null || true)"
  [[ -n "$IP" ]] && break
done
if [[ -z "$IP" ]]; then
  echo "Could not detect a local IP address. Are you connected to a network?" >&2
  exit 1
fi
HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"

mkdir -p certs
if [[ $FORCE_CERT -eq 0 && -f certs/cert.pem && -f certs/rootCA.pem \
      && "$(cat certs/ip.txt 2>/dev/null)" == "$IP" ]]; then
  echo "==> Certificate for $IP already exists (use --force-cert to regenerate)"

elif command -v mkcert >/dev/null 2>&1; then
  echo "==> Generating certificate with mkcert for $IP and $HOST.local"
  mkcert -install   # creates the local root CA once (may ask for your Mac password)
  mkcert -cert-file certs/cert.pem -key-file certs/key.pem "$IP" "$HOST.local" localhost 127.0.0.1
  cp "$(mkcert -CAROOT)/rootCA.pem" certs/rootCA.pem
  chmod 600 certs/key.pem
  echo "$IP" > certs/ip.txt

else
  echo "==> mkcert not found (brew install mkcert) — using an openssl self-signed certificate"
  echo "    Generating certificate for $IP and $HOST.local"
  CNF="$(mktemp)"
  trap 'rm -f "$CNF"' EXIT
  # iOS requirements for TLS certs: RSA >= 2048, SHA-256, SAN, serverAuth EKU, validity <= 825 days.
  # CA:TRUE lets iOS list it under "Certificate Trust Settings" once installed as a profile.
  cat > "$CNF" <<CONF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = AirMouse Mac ($HOST)
O  = AirMouse

[v3]
basicConstraints     = critical, CA:TRUE
keyUsage             = critical, digitalSignature, keyEncipherment, keyCertSign
extendedKeyUsage     = serverAuth
subjectKeyIdentifier = hash
subjectAltName       = IP:$IP, IP:127.0.0.1, DNS:$HOST.local, DNS:localhost
CONF
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825 \
    -keyout certs/key.pem -out certs/cert.pem -config "$CNF" 2>/dev/null
  cp certs/cert.pem certs/rootCA.pem   # a self-signed cert is its own root
  chmod 600 certs/key.pem
  echo "$IP" > certs/ip.txt
fi
echo "    Root certificate for your iPhone: certs/rootCA.pem"

echo
echo "Done. Start the server with:"
echo "    .venv/bin/python server.py"
