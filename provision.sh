#!/usr/bin/env bash
# Cloud Gaming PC bootstrap for Vast Ubuntu Desktop (VM) template.
# Steam/Proton/Sunshine/Selkies are preinstalled — we configure credentials,
# optional Tailscale, a local Moonlight PIN helper, and report ready state.
set -uo pipefail

CC_PROVISION_URL="${CC_PROVISION_URL:-}"
CC_AGENT_TOKEN="${CC_AGENT_TOKEN:-}"
CC_SUNSHINE_USERNAME="${CC_SUNSHINE_USERNAME:-}"
CC_SUNSHINE_PASSWORD="${CC_SUNSHINE_PASSWORD:-}"
CC_PAIRING_PORT="${CC_PAIRING_PORT:-8765}"
CC_SELKIES_PORT="${CC_SELKIES_PORT:-6100}"
CC_TAILSCALE_AUTH_KEY="${CC_TAILSCALE_AUTH_KEY:-}"
SUNSHINE_API="https://127.0.0.1:47990"
PAIRING_LOG="/var/log/cc-moonlight-pair.log"

pid1_env() { tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n "s/^$1=//p" | head -n1; }
: "${PUBLIC_IP:=$(pid1_env PUBLIC_IPADDR)}"

report() {
  [ -z "$CC_PROVISION_URL" ] && return 0
  local body="{\"stage\":\"$1\""
  [ -n "${2:-}" ] && body="$body,\"progress_pct\":$2"
  # Progress text goes in log_line — `message` is reserved for fatal errors
  # (see ManagesApplicationProvisioning::hasApplicationProvisioningFailed).
  [ -n "${3:-}" ] && body="$body,\"log_line\":\"$3\""
  body="$body}"
  curl -fsS -X POST "$CC_PROVISION_URL" \
    -H "Authorization: Bearer $CC_AGENT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body" >/dev/null 2>&1 || true
}

report_fail() {
  [ -z "$CC_PROVISION_URL" ] && return 0
  local stage="$1" pct="$2" msg="$3"
  curl -fsS -X POST "$CC_PROVISION_URL" \
    -H "Authorization: Bearer $CC_AGENT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"stage\":\"$stage\",\"progress_pct\":$pct,\"message\":\"$msg\"}" >/dev/null 2>&1 || true
}

report_meta() {
  [ -z "$CC_PROVISION_URL" ] && return 0
  local key="$1" val="$2"
  python3 - "$CC_PROVISION_URL" "$CC_AGENT_TOKEN" "$key" "$val" <<'PY' || true
import json, sys, urllib.request
url, token, key, val = sys.argv[1:5]
body = json.dumps({"stage": "boot_desktop", key: val}).encode()
req = urllib.request.Request(url, data=body, method="POST")
req.add_header("Authorization", f"Bearer {token}")
req.add_header("Content-Type", "application/json")
urllib.request.urlopen(req, timeout=15).read()
PY
}

wait_http() {
  local url="$1" tries="${2:-120}"
  local i=0 code
  while [ "$i" -lt "$tries" ]; do
    # Any HTTP response (incl. 401 from Selkies auth) means the stream is up.
    code=$(curl -sS -o /dev/null -w '%{http_code}' -m 5 "$url" 2>/dev/null || echo 000)
    if [ "$code" != "000" ]; then
      return 0
    fi
    sleep 5
    i=$((i + 1))
  done
  return 1
}

configure_sunshine() {
  [ -n "$CC_SUNSHINE_USERNAME" ] [ -n "$CC_SUNSHINE_PASSWORD" ] || return 0
  if command -v sunshine >/dev/null 2>&1; then
    sunshine --credentials "$CC_SUNSHINE_USERNAME" "$CC_SUNSHINE_PASSWORD" >/dev/null 2>&1 || true
  fi
  if [ -f /etc/sunshine/sunshine.conf ]; then
    grep -q '^username' /etc/sunshine/sunshine.conf 2>/dev/null \
      || printf '\nusername = %s\npassword = %s\n' "$CC_SUNSHINE_USERNAME" "$CC_SUNSHINE_PASSWORD" \
        >> /etc/sunshine/sunshine.conf
  fi
  systemctl restart sunshine 2>/dev/null || true
}

start_pairing_helper() {
  [ -n "$CC_SUNSHINE_USERNAME" ] [ -n "$CC_SUNSHINE_PASSWORD" ] || return 0
  cat > /tmp/cc-moonlight-pair.py <<'PY'
import json, os, subprocess, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

USER = os.environ.get("CC_SUNSHINE_USERNAME", "")
PASS = os.environ.get("CC_SUNSHINE_PASSWORD", "")
API = "https://127.0.0.1:47990/api/pin"
TOKEN = os.environ.get("CC_AGENT_TOKEN", "")

class Handler(BaseHTTPRequestHandler):
    def _auth_ok(self):
        auth = self.headers.get("Authorization", "")
        return auth == f"Bearer {TOKEN}" and TOKEN

    def do_POST(self):
        if self.path != "/pin":
            self.send_response(404)
            self.end_headers()
            return
        if not self._auth_ok():
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b'{"error":"Unauthorized"}')
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        pin = str(body.get("pin", "")).strip()
        if len(pin) != 4 or not pin.isdigit():
            self.send_response(422)
            self.end_headers()
            self.wfile.write(b'{"error":"Invalid PIN"}')
            return
        payload = json.dumps({"pin": pin, "name": "Moonlight"}).encode()
        req = urllib.request.Request(API, data=payload, method="POST")
        req.add_header("Content-Type", "application/json")
        import base64
        creds = base64.b64encode(f"{USER}:{PASS}".encode()).decode()
        req.add_header("Authorization", f"Basic {creds}")
        ctx = __import__("ssl").create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = __import__("ssl").CERT_NONE
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
                resp.read()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
        except Exception as exc:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(exc)}).encode())

    def log_message(self, *_):
        pass

port = int(os.environ.get("CC_PAIRING_PORT", "8765"))
HTTPServer(("0.0.0.0", port), Handler).serve_forever()
PY
  CC_SUNSHINE_USERNAME="$CC_SUNSHINE_USERNAME" \
  CC_SUNSHINE_PASSWORD="$CC_SUNSHINE_PASSWORD" \
  CC_AGENT_TOKEN="$CC_AGENT_TOKEN" \
  CC_PAIRING_PORT="$CC_PAIRING_PORT" \
    nohup python3 /tmp/cc-moonlight-pair.py >> "$PAIRING_LOG" 2>&1 &
}

maybe_tailscale() {
  [ -n "$CC_TAILSCALE_AUTH_KEY" ] || return 0
  if command -v tailscale >/dev/null 2>&1; then
    tailscale up --auth-key="$CC_TAILSCALE_AUTH_KEY" --accept-routes >/dev/null 2>&1 || true
    hostname="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null || true)"
    [ -n "$hostname" ] && report_meta tailscale_hostname "$hostname"
  fi
}

report boot_desktop 10 "Waiting for desktop stream"
# Probe localhost only — public-IP hairpin from inside the VM often times out.
TARGET="http://127.0.0.1:${CC_SELKIES_PORT}/"

if ! wait_http "$TARGET" 120; then
  report_fail boot_desktop 100 "Selkies did not respond on port ${CC_SELKIES_PORT}"
  exit 1
fi

report boot_desktop 60 "Configuring streaming"
configure_sunshine
start_pairing_helper
maybe_tailscale

report ready 100 "Desktop ready"
exit 0
