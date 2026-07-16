#!/usr/bin/env bash
# shellcheck disable=SC2015
# =============================================================================
# openpages_login.sh
#
# Performs the full OpenPages form-based login flow and verifies REST API
# access using the OPLtpaToken2 cookie (the only cookie required).
#
# Usage:
#   ./scripts/openpages_login.sh
#
# Reads from .env:
#   OPENPAGES_BASE_URL   e.g. https://geopost-uat01.op.ibmcloud.com/openpages
#   OPENPAGES_API_ROOT   e.g. https://geopost-uat01.op.ibmcloud.com
#   OPENPAGES_USERNAME   e.g. pradier.j@fr.ibm.com
#   OPENPAGES_PASSWORD   e.g. <REDACTED>
#
# Output (on success):
#   Prints the OPLtpaToken2 cookie ready to paste into .env as
#   OPENPAGES_SESSION_COOKIES=...
# =============================================================================

set -uo pipefail

# ── Load .env ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found at $ENV_FILE" >&2
  exit 1
fi

# Source only the variables we need (avoid executing arbitrary lines)
OPENPAGES_BASE_URL=$(grep '^OPENPAGES_BASE_URL=' "$ENV_FILE" | head -1 | cut -d= -f2-)
OPENPAGES_API_ROOT=$(grep '^OPENPAGES_API_ROOT=' "$ENV_FILE" | head -1 | cut -d= -f2-)
OPENPAGES_USERNAME=$(grep '^OPENPAGES_USERNAME=' "$ENV_FILE" | head -1 | cut -d= -f2-)
OPENPAGES_PASSWORD=$(grep '^OPENPAGES_PASSWORD=' "$ENV_FILE" | head -1 | cut -d= -f2-)

BASE="${OPENPAGES_BASE_URL%/}"   # strip trailing slash

if [[ -z "$BASE" || -z "$OPENPAGES_USERNAME" || -z "$OPENPAGES_PASSWORD" ]]; then
  echo "ERROR: OPENPAGES_BASE_URL, OPENPAGES_USERNAME and OPENPAGES_PASSWORD must be set in .env" >&2
  exit 1
fi

if [[ -n "$OPENPAGES_API_ROOT" ]]; then
  API_ROOT="${OPENPAGES_API_ROOT%/}"
else
  API_ROOT="$(echo "$BASE" | sed 's|/[^/]*$||')"
  echo "ℹ️   OPENPAGES_API_ROOT not set — derived: $API_ROOT"
fi

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"

# Helper: extract a named cookie value from a response header block
extract_cookie() {
  local name="$1" headers="$2"
  echo "$headers" \
    | grep -i "set-cookie: ${name}=" \
    | head -1 \
    | sed "s/.*${name}=\([^;]*\).*/\1/" \
    | tr -d '\r'
}

echo "==================================================================="
echo " OpenPages login flow"
echo " Base URL : $BASE"
echo " Username : $OPENPAGES_USERNAME"
echo "==================================================================="
echo ""

# ── Step 1: GET /logon.jsp ────────────────────────────────────────────────
echo "[1/3] GET /logon.jsp — obtain initial session cookie"
R1=$(curl -si -H "User-Agent: $UA" "$BASE/logon.jsp")

SESS=$(extract_cookie "OPJSESSIONID" "$R1")
AK=$(extract_cookie   "ak_bmsc"      "$R1")

echo "      Status       : $(echo "$R1" | grep "^HTTP/" | tail -1 | tr -d '\r')"
echo "      OPJSESSIONID : ${SESS:0:30}..."
echo ""

if [[ -z "$SESS" ]]; then
  echo "ERROR: No OPJSESSIONID returned from /logon.jsp" >&2
  exit 1
fi

# ── Step 2: POST /j_security_check ───────────────────────────────────────
echo "[2/3] POST /j_security_check — submit credentials"
R2=$(curl -si \
  -H "User-Agent: $UA" \
  -H "Cookie: OPJSESSIONID=$SESS${AK:+; ak_bmsc=$AK}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Referer: $BASE/logon.jsp" \
  -X POST "$BASE/j_security_check" \
  --data-urlencode "j_username=$OPENPAGES_USERNAME" \
  --data-urlencode "j_password=$OPENPAGES_PASSWORD")

LTPA=$(extract_cookie "OPLtpaToken2" "$R2")

echo "      Status       : $(echo "$R2" | grep "^HTTP/" | tail -1 | tr -d '\r')"

if [[ -z "$LTPA" ]]; then
  echo ""
  echo "ERROR: Login failed — no OPLtpaToken2 returned." >&2
  echo "       Check OPENPAGES_USERNAME and OPENPAGES_PASSWORD in .env" >&2
  echo "$R2" | tail -5 | grep -i "error\|invalid\|fail" || true
  exit 1
fi
echo "      OPLtpaToken2 : ${LTPA:0:20}..."
echo ""

API_URL="$API_ROOT/opgrc/api/v2/types/SOXControl"

# Helper: call the API and print result; sets the named result variable to true/false.
# Usage: check_api <label> <header-name> <header-value> <result_var>
check_api() {
  local label="$1" header_name="$2" header_value="$3" result_var="$4"
  echo ""
  echo "[${label}] GET $API_URL"
  local resp http ct body
  resp=$(curl -si \
    -H "User-Agent: $UA" \
    -H "Accept: application/json" \
    -H "$header_name: $header_value" \
    "$API_URL")
  http=$(echo "$resp" | grep "^HTTP/" | tail -1 | tr -d '\r')
  ct=$(echo   "$resp" | grep -i "^content-type:" | head -1 | tr -d '\r')
  body=$(echo "$resp" | tail -1)
  echo "--- raw response ---------------------------------------------------"
  echo "$resp"
  echo "--------------------------------------------------------------------"
  echo "      Status       : $http"
  echo "      Content-Type : $ct"
  if echo "$ct" | grep -qi "application/json"; then
    local name
    name=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name', d.get('typeName','?')))" 2>/dev/null || echo "?")
    echo "      ✅  SOXControl type name: $name"
    eval "$result_var=true"
  else
    echo "      ❌  Response is not JSON"
    eval "$result_var=false"
  fi
}

# ── Step 3a: OPLtpaToken2 cookie ─────────────────────────────────────────
LTPA_OK=false
check_api "3a/3 — OPLtpaToken2 cookie" "Cookie" "OPLtpaToken2=$LTPA" LTPA_OK

# ── Step 3b: Basic authentication (RFC 2617) ─────────────────────────────
# macOS base64 wraps output at 76 chars with newlines — strip them.
BASIC_TOKEN=$(printf '%s:%s' "$OPENPAGES_USERNAME" "$OPENPAGES_PASSWORD" | base64 | tr -d '\n')
echo "ℹ️   Basic token (verify): Authorization: Basic ${BASIC_TOKEN:0:20}..."
BASIC_OK=false
check_api "3b/3 — Basic auth" "Authorization" "Basic $BASIC_TOKEN" BASIC_OK

echo ""

# ── Output ────────────────────────────────────────────────────────────────
echo "==================================================================="
echo " Paste into .env as OPENPAGES_SESSION_COOKIES"
echo "==================================================================="
echo ""
echo "OPENPAGES_SESSION_COOKIES=OPLtpaToken2=$LTPA"
echo ""

# ── Summary ──────────────────────────────────────────────────────────────
echo "==================================================================="
echo " Summary"
echo "==================================================================="
[[ "$LTPA_OK"  == "true" ]] \
  && echo " REST API v2 : ✅  accessible  (OPLtpaToken2 cookie)" \
  || echo " REST API v2 : ❌  blocked     (OPLtpaToken2 cookie)"
[[ "$BASIC_OK" == "true" ]] \
  && echo " REST API v2 : ✅  accessible  (Basic auth)" \
  || echo " REST API v2 : ❌  blocked     (Basic auth)"
echo ""
