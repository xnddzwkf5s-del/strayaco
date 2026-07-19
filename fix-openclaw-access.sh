#!/usr/bin/env bash
# =============================================================================
# fix-openclaw-access.sh
# One-command fixer: secure remote access to OpenClaw via Tailscale Serve
#
# Run on the DO droplet (as root or the openclaw user):
#   curl -fsSL https://realform.com.au/fix-openclaw-access.sh | [sudo] bash
#
# LESSONS LEARNED (Jul 2026):
#   - Tailscale client must be installed on the LAPTOP too — not just the droplet
#   - Browser needs HTTPS for WebSocket (HTTP + non-localhost = "device identity" error)
#   - tailscale serve needs operator permissions — run: tailscale set --operator=$USER
#   - gateway.bind must be loopback when using tailscale.mode serve (not lan/tailnet)
#   - Do NOT set controlUi.allowedOrigins manually — Tailscale Serve auto-seeds origins
#   - gateway.auth.allowTailscale = true skips the token prompt (Tailscale identity headers)
#   - systemctl --user via SSH needs DBUS_SESSION_BUS_ADDRESS or --machine flag
#   - User accesses https://<hostname>.tail<XXXX>.ts.net/ — no port, no IP
# =============================================================================
set -euo pipefail

# --- Colours ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()      { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()     { printf "${RED}[ERROR]${NC} %s\n" "$*"; }
heading() { printf "\n${BOLD}${BLUE}=== %s ===${NC}\n\n" "$*"; }

# --- Helpers ---
run_as_user() {
  local user="$1"; shift
  if [ "$(id -u)" -eq 0 ] && [ "$user" != "root" ]; then
    su - "$user" -c "$*"
  else
    "$@"
  fi
}

restart_gateway_safe() {
  local user="$1"
  local uid
  uid=$(id -u "$user" 2>/dev/null || echo "1000")
  local bus="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus"

  # Method 1: systemd with machine flag
  if systemctl --machine="$user@.host" --user restart openclaw-gateway.service 2>/dev/null; then
    return 0
  fi
  # Method 2: systemd with explicit DBUS
  if su - "$user" -c "$bus systemctl --user restart openclaw-gateway.service" 2>/dev/null; then
    return 0
  fi
  # Method 3: run openclaw stop + start
  if su - "$user" -c "openclaw gateway stop 2>/dev/null; sleep 2; openclaw gateway start > /dev/null 2>&1 &"; then
    sleep 5
    return 0
  fi
  return 1
}

# =============================================================================
# STEP 0: Detect the OpenClaw user & config
# =============================================================================
heading "Step 0: Detecting OpenClaw setup"

OC_USER=""
OC_HOME=""

for TRY_USER in openclaw ubuntu root; do
  TRY_HOME=$(eval echo "~$TRY_USER" 2>/dev/null)
  if [ -f "$TRY_HOME/.openclaw/openclaw.json" ]; then
    OC_USER="$TRY_USER"
    OC_HOME="$TRY_HOME"
    break
  fi
done

if [ -z "$OC_USER" ] && [ "$(id -u)" -eq 0 ] && [ -d /root/.openclaw ]; then
  OC_USER="root"
  OC_HOME="/root"
fi

if [ -z "$OC_USER" ] && [ -d "$HOME/.openclaw" ]; then
  OC_USER=$(whoami)
  OC_HOME="$HOME"
fi

if [ -z "$OC_USER" ] && id "openclaw" &>/dev/null; then
  OC_USER="openclaw"
  OC_HOME="/home/openclaw"
fi

if [ -z "$OC_USER" ]; then
  err "No OpenClaw config found. Run 'openclaw onboard' first."
  exit 1
fi
info "Config owner: ${BOLD}$OC_USER${NC} ($OC_HOME/.openclaw/)"

OPENCLAW_BIN=""
for TRY_BIN in /usr/local/bin/openclaw "$OC_HOME/.openclaw/bin/openclaw" $(which openclaw 2>/dev/null || true); do
  if [ -x "$TRY_BIN" ]; then
    OPENCLAW_BIN="$TRY_BIN"
    break
  fi
done

if [ -z "$OPENCLAW_BIN" ]; then
  err "OpenClaw binary not found."
  exit 1
fi
ok "OpenClaw: $OPENCLAW_BIN"

read_json() {
  local file="$1" key="$2"
  python3 -c "
import json, sys
try:
    d = json.load(open('$file'))
    parts = '$key'.split('.')
    for p in parts:
        d = d.get(p, {})
    val = d if isinstance(d, str) else ''
    print(val, end='')
except: pass
" 2>/dev/null
}

# =============================================================================
# STEP 1: Tailscale
# =============================================================================
heading "Step 1: Tailscale"

if command -v tailscale &>/dev/null; then
  ok "Tailscale installed ($(tailscale version 2>/dev/null | head -1))"
else
  info "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

if tailscale status &>/dev/null; then
  ok "Tailscale connected"
else
  warn "Tailscale NOT connected."
  echo ""
  echo "  Run: ${BOLD}sudo tailscale up${NC}"
  echo "  (opens a URL in your browser to authenticate)"
  echo ""
  tailscale up 2>&1 || true
  exit 0
fi

systemctl enable tailscaled 2>/dev/null || true
ok "Tailscale auto-starts on boot"

# --- LESSON: Set tailscale operator so openclaw user can run serve ---
info "Setting openclaw as tailscale operator..."
tailscale set --operator=openclaw 2>/dev/null || true
ok "Tailscale operator set to openclaw"

# --- LESSON: HTTPS must be enabled on the tailnet ---
HTTPS_STATUS=$(tailscale serve status 2>&1 || echo "NOT_READY")
if echo "$HTTPS_STATUS" | grep -qi "https is not enabled\|needs https\|must be enabled\|enable https"; then
  warn "HTTPS NOT enabled. Enabling now..."
  tailscale serve --bg --https 443 localhost:18789 2>&1 || true
  info "Re-run this script after HTTPS is enabled."
  exit 0
else
  ok "HTTPS enabled on tailnet"
fi

# Get MagicDNS hostname
TAILSCALE_HOSTNAME=""
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for key in ['Self', 'Peer']:
        if key in d:
            for k, v in d[key].items():
                if isinstance(v, dict) and 'DNSName' in v:
                    print(v['DNSName'].rstrip('.'), end='')
                    sys.exit(0)
except: pass
" 2>/dev/null || echo "")

if [ -z "$TAILSCALE_HOSTNAME" ]; then
  TAILSCALE_HOSTNAME=$(tailscale status 2>/dev/null | head -1 | awk '{print $1}' | sed 's/$/.ts.net/')
fi

if [ -n "$TAILSCALE_HOSTNAME" ]; then
  ok "MagicDNS: ${BOLD}${TAILSCALE_HOSTNAME}${NC}"
fi

# =============================================================================
# STEP 2: Gateway health
# =============================================================================
heading "Step 2: Gateway health"

GW_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/ 2>/dev/null || echo "000")

if [ "$GW_STATUS" = "000" ]; then
  warn "Gateway not responding. Starting..."
  if systemctl --machine="$OC_USER@.host" --user start openclaw-gateway.service 2>/dev/null; then
    sleep 5
    GW_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/ 2>/dev/null || echo "000")
  fi
fi

if [ "$GW_STATUS" != "000" ]; then
  ok "Gateway: HTTP $GW_STATUS"
else
  warn "Gateway still down. Onboard first: su - $OC_USER -c 'openclaw onboard --install-daemon'"
fi

# =============================================================================
# STEP 3: Auth config
# =============================================================================
heading "Step 3: Auth config"

TOKEN=$(read_json "$OC_HOME/.openclaw/openclaw.json" "gateway.auth.token")
PASS=$(read_json "$OC_HOME/.openclaw/openclaw.json" "gateway.auth.password")
AUTH_MODE=$(read_json "$OC_HOME/.openclaw/openclaw.json" "gateway.auth.mode")
ALLOW_TS=$(read_json "$OC_HOME/.openclaw/openclaw.json" "gateway.auth.allowTailscale")

if [ -z "$TOKEN" ]; then
  info "No token. Generating..."
  run_as_user "$OC_USER" "$OPENCLAW_BIN" doctor --generate-gateway-token 2>/dev/null || true
  sleep 1
  TOKEN=$(read_json "$OC_HOME/.openclaw/openclaw.json" "gateway.auth.token")
fi

if [ -z "$TOKEN" ]; then
  TEMP_TOKEN="openclaw-$(date +%s)"
  run_as_user "$OC_USER" "$OPENCLAW_BIN" config set gateway.auth.token "$TEMP_TOKEN"
  TOKEN="$TEMP_TOKEN"
fi

ok "Token: ${BOLD}$TOKEN${NC}"

# --- LESSON: enable allowTailscale for auto-login ---
if [ "$ALLOW_TS" != "true" ] && [ "$ALLOW_TS" != "True" ]; then
  run_as_user "$OC_USER" "$OPENCLAW_BIN" config set gateway.auth.allowTailscale true
  ALLOW_TS="true"
  ok "auth.allowTailscale = true (auto-login via Tailscale identity)"
else
  ok "auth.allowTailscale = true"
fi

# --- LESSON: Remove any manual allowedOrigins — Tailscale Serve handles this ---
EXISTING_ORIGINS=$(run_as_user "$OC_USER" "$OPENCLAW_BIN" config get gateway.controlUi.allowedOrigins 2>/dev/null || echo "")
if [ -n "$EXISTING_ORIGINS" ] && [ "$EXISTING_ORIGINS" != "null" ]; then
  warn "Removing manual allowedOrigins — Tailscale Serve handles origins automatically"
  run_as_user "$OC_USER" "$OPENCLAW_BIN" config delete gateway.controlUi.allowedOrigins 2>/dev/null || true
  ok "allowedOrigins cleared"
fi

# =============================================================================
# STEP 4: Configure Tailscale Serve
# =============================================================================
heading "Step 4: Tailscale Serve config"

# --- LESSON: These two settings MUST be paired ---
run_as_user "$OC_USER" "$OPENCLAW_BIN" config set gateway.bind loopback 2>/dev/null
run_as_user "$OC_USER" "$OPENCLAW_BIN" config set gateway.tailscale.mode serve 2>/dev/null

ok "gateway.bind = loopback"
ok "gateway.tailscale.mode = serve"

# =============================================================================
# STEP 5: Restart
# =============================================================================
heading "Step 5: Restarting gateway"

info "Restarting gateway..."
if restart_gateway_safe "$OC_USER"; then
  ok "Gateway restarted"
else
  warn "Gateway restart had issues"
fi

sleep 5

# Verify
GW_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/ 2>/dev/null || echo "000")
if [ "$GW_STATUS" != "000" ]; then
  ok "Gateway: HTTP $GW_STATUS"
fi

# --- LESSON: Ensure tailscale serve is mapped ---
SERVE_STATUS=$(tailscale serve status 2>&1 || echo "")
if echo "$SERVE_STATUS" | grep -q "127.0.0.1:18789\|localhost:18789"; then
  ok "Tailscale Serve mapped"
else
  warn "Mapping missing — checking gateway logs..."
fi

# =============================================================================
# STEP 6: Health report
# =============================================================================
heading "Health Check"

PASS=0
WARN=0
FAIL=0

chk_pass() { PASS=$((PASS+1)); printf "%-45s ${GREEN}PASS${NC}\n" "$1"; }
chk_warn() { WARN=$((WARN+1)); printf "%-45s ${YELLOW}WARN${NC}\n" "$1"; }
chk_fail() { FAIL=$((FAIL+1)); printf "%-45s ${RED}FAIL${NC}\n" "$1"; }

command -v tailscale &>/dev/null && chk_pass "Tailscale installed" || chk_fail "Tailscale installed"
tailscale status &>/dev/null && chk_pass "Tailscale connected" || chk_fail "Tailscale connected"
tailscale serve status 2>&1 | grep -q "127.0.0.1:18789\|localhost:18789" && chk_pass "Tailscale Serve mapped" || chk_fail "Tailscale Serve mapped"
[ "$GW_STATUS" != "000" ] && chk_pass "Gateway running (HTTP $GW_STATUS)" || chk_fail "Gateway running"
[ "$ALLOW_TS" = "true" ] || [ "$ALLOW_TS" = "True" ] && chk_pass "auth.allowTailscale = true" || chk_fail "auth.allowTailscale = true"
[ -n "$TOKEN" ] && chk_pass "Gateway token configured" || chk_fail "Gateway token configured"
[ -n "$TAILSCALE_HOSTNAME" ] && chk_pass "MagicDNS hostname" || chk_fail "MagicDNS hostname"

echo ""
printf "${BOLD}Results:${NC} ${GREEN}$PASS passed${NC}"
[ "$WARN" -gt 0 ] && printf ", ${YELLOW}$WARN warnings${NC}"
[ "$FAIL" -gt 0 ] && printf ", ${RED}$FAIL failed${NC}"
printf "\n\n"

# =============================================================================
# FINAL INSTRUCTIONS
# =============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}${BOLD}OpenClaw is ready.${NC}\n"
  echo ""
  printf "${BOLD}Access URL:${NC}  ${CYAN}https://${TAILSCALE_HOSTNAME}/${NC}\n"
  echo ""
  echo "  IMPORTANT: Tailscale must ALSO be installed on your laptop:"
  echo "    https://tailscale.com/download"
  echo ""
  echo "  Then login with the same account as the droplet."
  echo "  The URL will work automatically — no port, no token needed."
  echo ""
  echo "  Token (if prompted): ${YELLOW}$TOKEN${NC}"
  echo ""
else
  printf "${RED}${BOLD}Some checks failed. Review above.${NC}\n"
fi
echo ""
echo "  SSH tunnel fallback (no Tailscale on laptop needed):"
echo "    ssh -L 18789:localhost:18789 root@$(curl -s --connect-timeout 3 ifconfig.me 2>/dev/null || echo '<droplet-ip>')"
echo "    Then open http://localhost:18789"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
