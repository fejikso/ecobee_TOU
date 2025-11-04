#!/usr/bin/env bash
# ecobee_TOU.sh
#
# Small helper to interact with an Ecobee thermostat (hard-coded target by default).
# Features (current):
#  - Change the thermostat mode (HEAT | OFF | AUX | COOL | AUTO)
#  - --dry-run / -n           : Print the JSON payload without making changes
#  - --probe-thermostats     : Query and print the full thermostat JSON (pretty-printed if `jq` is available)
#  - --get-current-mode      : Read-only: print a concise line showing the thermostat name, id, and current hvacMode
#  - --test-connection       : Read-only: perform a minimal selection request to verify token validity
#  - -v / --verbose          : Enables curl verbose output (curl -v) but only for mode-change POSTs and --test-connection
#
# Notes:
#  - The script targets a hard-coded thermostat id by default (see `THERMOSTAT_ID` later in the file).
#  - Credentials are loaded from a JSON file named `ecobee.conf` (expected keys: API_KEY, ACCESS_TOKEN, REFRESH_TOKEN).
#  - Read-only commands (`--probe-thermostats`, `--get-current-mode`, `--test-connection`) will attempt a token refresh
#    if the access token appears expired/invalid. `--test-connection` and `--get-current-mode` do NOT write refreshed
#    tokens back to `ecobee.conf` (they are intentionally read-only). The mode-change path will write refreshed tokens
#    back to `ecobee.conf` on successful refresh so subsequent runs continue to work.
#  - `--probe-thermostats` always prints raw JSON; it is intentionally silent with respect to curl's `-v` so output
#    remains machine-friendly. Use `jq` to pretty-print the output if available.
#
# Dependencies:
#  - `curl`, `python3`, `mktemp` and standard coreutils. `jq` is optional (used by probe for pretty-printing).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/ecobee.conf"
[ -f "$CONF_FILE" ] || CONF_FILE="${PWD}/ecobee.conf"

if [ ! -f "$CONF_FILE" ]; then
  echo "ecobee.conf not found in script dir or current dir. Please create one with API_KEY, ACCESS_TOKEN and REFRESH_TOKEN." >&2
  exit 2
fi

# Hard-coded thermostat target (change these values near the top of the script)
# THERMOSTAT_ID: set this to the thermostat identifier you want to target
# THERMOSTAT_NAME: optional friendly name used in log messages
THERMOSTAT_ID="123456789"   # <-- change this value to target a different thermostat
THERMOSTAT_NAME="Downstairs"   # <-- change the friendly name as desired

# Common helper function to read config
read_conf_value() {
  local key="$1"
  CONF_FILE_ENV="$CONF_FILE" KEY_ENV="$key" python3 - <<PY
import json,sys,os
try:
    conf_file = os.environ['CONF_FILE_ENV']
    key = os.environ['KEY_ENV']
    if not os.path.exists(conf_file):
        print(f"Config file not found: {conf_file}", file=sys.stderr)
        sys.exit(3)
    with open(conf_file) as f:
        content = f.read()
        if not content.strip():
            print(f"Config file is empty: {conf_file}", file=sys.stderr)
            sys.exit(3)
        j = json.loads(content)
    if key in j:
        print(j[key])
    else:
        sys.exit(3)
except KeyError as e:
    print(f"Missing environment variable: {e}", file=sys.stderr)
    sys.exit(3)
except json.JSONDecodeError as e:
    print(f"JSON decode error: {e}", file=sys.stderr)
    sys.exit(3)
except Exception as e:
    print(f"Unexpected error: {e}", file=sys.stderr)
    sys.exit(3)
PY
}

DRY_RUN=0

# Global verbose flag: -v or --verbose (can be passed anywhere). We strip it from $@ so
# positional checks (like --help, --probe-thermostats) continue to work normally.
VERBOSE=0
NEWARGS=()
for _a in "$@"; do
  case "$_a" in
    -v|--verbose)
      VERBOSE=1
      ;;
    *) NEWARGS+=("$_a") ;;
  esac
done
set -- "${NEWARGS[@]:-}"

# Curl defaults: use silent mode. We still honor VERBOSE but only for certain actions
# (mode changes and --test-connection). Use these named arg arrays when invoking curl.
DEFAULT_CURL_ARGS=(-s)

# Per-action curl arg arrays (set as needed below):
# PROBE_CURL_ARGS  - used for --probe-thermostats (always silent)
# TEST_CURL_ARGS   - used for --test-connection (becomes -v when VERBOSE=1)
# MODE_CURL_PREFIX - prefix used when performing mode-change POSTs (becomes -v when VERBOSE=1)

 
# Provide a short help/usage message
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
Usage: ecobee_TOU.sh (MODE [--dry-run] | --probe-thermostats | --test-connection | --help)

Modes (case-insensitive): HEAT | OFF | AUX | COOL | AUTO
  - AUX maps to Ecobee's `auxHeatOnly` mode.

Options:
  --dry-run, -n         Print the JSON payload without making changes
  --probe-thermostats   Query and print thermostat JSON (pretty-printed if `jq` is installed)
  --get-current-mode    Print the current hvacMode for the target thermostat (read-only)
  --test-connection     Perform a read-only connectivity/token test
  -v, --verbose         Enable verbose curl output (curl -v) for mode changes and --test-connection
  --help, -h            Show this help message

Notes:
  - The script reads credentials from `ecobee.conf` (JSON). Required keys: API_KEY, ACCESS_TOKEN, REFRESH_TOKEN.
  - The `-v/--verbose` option enables curl verbose output but only applies to actions that perform network writes or connection tests (mode changes and `--test-connection`). It does not enable verbose output for `--probe-thermostats` because that command already prints the API JSON response.
  - See `Ecobee_TOU_README.md` for full details and examples.
USAGE
  exit 0
fi
 
# Diagnostic options: test connection or probe thermostats
if [ "${1:-}" = "--probe-thermostats" ]; then
  # read tokens using helper function
  API_KEY=$(read_conf_value API_KEY) || { echo "API_KEY not found in $CONF_FILE" >&2; exit 2; }
  ACCESS_TOKEN=$(read_conf_value ACCESS_TOKEN) || { echo "ACCESS_TOKEN not found in $CONF_FILE" >&2; exit 2; }
  REFRESH_TOKEN=$(read_conf_value REFRESH_TOKEN) || REFRESH_TOKEN=""

  API_URL_BASE="https://api.ecobee.com/1"
  
  # Build the selection request
  selection='{
    "selection": {
      "selectionType": "registered",
      "selectionMatch": "",
      "includeRuntime": true,
      "includeSettings": true,
      "includeSensors": true
    }
  }'

  echo "Querying Ecobee API for available thermostats..."
  
  # probe should always be silent; do not honor -v here
  PROBE_CURL_ARGS=("${DEFAULT_CURL_ARGS[@]}")

  # First attempt with current token
  response=$(curl "${PROBE_CURL_ARGS[@]}" -H "Content-Type: text/json" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "${API_URL_BASE}/thermostat?format=json&body=$(echo "$selection" | jq -c | python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read()))')")

  # Check if response is valid JSON and handle token refresh if needed
  if ! echo "$response" | jq -e . >/dev/null 2>&1 || \
     echo "$response" | grep -qi "invalid access token\|expired\|unauthorized"; then
    if [ -z "$REFRESH_TOKEN" ]; then
      echo "Access token expired and no REFRESH_TOKEN available in $CONF_FILE" >&2
      exit 4
    fi
    echo "Access token expired; attempting refresh..."
    token_resp=$(curl "${PROBE_CURL_ARGS[@]}" -X POST "https://api.ecobee.com/token" \
      -d "grant_type=refresh_token&refresh_token=${REFRESH_TOKEN}&client_id=${API_KEY}")
    
    new_access=$(echo "$token_resp" | jq -r '.access_token // empty')
    if [ -z "$new_access" ]; then
      echo "Token refresh failed: $token_resp" >&2
      exit 5
    fi
    
    # Retry with new token
    response=$(curl "${PROBE_CURL_ARGS[@]}" -H "Content-Type: text/json" \
      -H "Authorization: Bearer ${new_access}" \
      "${API_URL_BASE}/thermostat?format=json&body=$(echo "$selection" | jq -c | python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read()))')")
  fi

  # Pretty print the response
    echo "$response" | jq .
    exit 0
fi

# Quick connection test: if first arg is --test-connection, perform a connectivity check and exit.
if [ "${1:-}" = "--get-current-mode" ]; then
  # Read-only: query the configured thermostat and print its current hvacMode
  API_KEY=$(read_conf_value API_KEY)
  ACCESS_TOKEN=$(read_conf_value ACCESS_TOKEN)
  REFRESH_TOKEN=$(read_conf_value REFRESH_TOKEN) || REFRESH_TOKEN=""

  API_URL_BASE="https://api.ecobee.com/1"

  # Use the top-level THERMOSTAT_ID defined near the top of the script
  TARGET_ID="${THERMOSTAT_ID}"

  # Build JSON body to query the specific thermostat and request settings/runtime
  BODY_JSON=$(TARGET_ID_ENV="$TARGET_ID" python3 - <<PY
import json,os
target_id = os.environ['TARGET_ID_ENV']
print(json.dumps({
  "selection": {
    "selectionType": "thermostats",
    "selectionMatch": target_id,
    "includeSettings": True,
    "includeRuntime": True
  }
}))
PY
)
  
  BODY_ENC=$(echo "$BODY_JSON" | python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read()))')

  # Always silent for this probe (do not honor -v here)
  GET_CURL_ARGS=("${DEFAULT_CURL_ARGS[@]}")

  response=$(curl "${GET_CURL_ARGS[@]}" -H "Content-Type: text/json" -H "Authorization: Bearer ${ACCESS_TOKEN}" "${API_URL_BASE}/thermostat?format=json&body=${BODY_ENC}") || response=""

  # If response not JSON or indicates invalid token, try refresh (read-only; do not write tokens)
  if ! echo "$response" | python3 -m json.tool >/dev/null 2>&1 || echo "$response" | grep -qi "invalid access token\|expired\|unauthorized"; then
    if [ -z "$REFRESH_TOKEN" ]; then
      echo "Access token expired/invalid and no REFRESH_TOKEN available in $CONF_FILE" >&2
      exit 4
    fi
    token_resp=$(curl "${GET_CURL_ARGS[@]}" -X POST "https://api.ecobee.com/token" -d "grant_type=refresh_token&refresh_token=${REFRESH_TOKEN}&client_id=${API_KEY}") || token_resp=""
    new_access=$(printf '%s' "$token_resp" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin); print(j.get("access_token",""))
except Exception:
  print("")')
    if [ -z "$new_access" ]; then
      echo "Token refresh failed: $token_resp" >&2
      exit 5
    fi
    # retry with refreshed token (do not write it to conf)
    response=$(curl "${GET_CURL_ARGS[@]}" -H "Content-Type: text/json" -H "Authorization: Bearer ${new_access}" "${API_URL_BASE}/thermostat?format=json&body=${BODY_ENC}") || response=""
  fi

  # Parse and print a concise current-mode line
  if echo "$response" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin)
  tl=j.get("thermostatList",[])
  if not tl:
    sys.exit(2)
  t=tl[0]
  name=t.get("name","Unnamed")
  ident=t.get("identifier","unknown")
  mode=t.get("settings",{}).get("hvacMode") or t.get("runtime",{}).get("actualMode") or "unknown"
  print(f"{name} ({ident}): {mode}")
except Exception:
  sys.exit(3)
'
  then
    exit 0
  else
    echo "Failed to parse API response or thermostat not found: $response" >&2
    exit 6
  fi

fi

if [ "${1:-}" = "--test-connection" ]; then
  # read tokens
  API_KEY=$(read_conf_value API_KEY)
  ACCESS_TOKEN=$(read_conf_value ACCESS_TOKEN)
  REFRESH_TOKEN=$(read_conf_value REFRESH_TOKEN) || REFRESH_TOKEN=""

  API_URL_BASE="https://api.ecobee.com/1"
  
  # Build a minimal request
  BODY_JSON=$(python3 - <<PY
import json
print(json.dumps({
  "selection": {
    "selectionType": "registered",
    "selectionMatch": "",
    "includeSettings": False
  }
}))
PY
)

  # URL-encode the body
  BODY_ENC=$(echo "$BODY_JSON" | python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read()))')

  url="${API_URL_BASE}/thermostat?format=json&body=${BODY_ENC}"
  # For test-connection, allow verbose output when requested
  TEST_CURL_ARGS=("${DEFAULT_CURL_ARGS[@]}")
  if [ "$VERBOSE" -eq 1 ]; then TEST_CURL_ARGS=(-v); fi
  
  # Use a temp file to capture both response and HTTP code
  tmp_file=$(mktemp)
  http_code=$(curl "${TEST_CURL_ARGS[@]}" \
    -H "Content-Type: text/json" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "$url" \
    -o "$tmp_file" \
    -w "%{http_code}") || http_code="000"
  response=$(cat "$tmp_file" 2>/dev/null || true)
  rm -f "$tmp_file"
  
  # Only try to parse JSON if we have a successful HTTP response and non-empty body
  if [ "$http_code" = "200" ] && [ -n "${response//[[:space:]]/}" ] && echo "$response" | jq -e . >/dev/null 2>&1; then
    status_code=$(echo "$response" | jq -r '.status.code // empty' 2>/dev/null)
    if [ -n "$status_code" ] && [ "$status_code" = "0" ]; then
      RESPONSE_ENV="$response" python3 - <<PY
import sys,json,os
response = os.environ.get('RESPONSE_ENV', '')
try:
    if not response or not response.strip():
        print("Error: Empty response received", file=sys.stderr)
        sys.exit(1)
    j=json.loads(response)
except json.JSONDecodeError as e:
    print(f"Error parsing JSON: {e}", file=sys.stderr)
    sys.exit(1)
thermostats = j.get('thermostatList', [])
if not thermostats:
    print("No thermostats found.")
    sys.exit(0)
print("\nAvailable thermostats:")
print("-" * 60)
for t in thermostats:
    identifier = t.get('identifier', 'Unknown')
    name = t.get('name', 'Unnamed')
    connected = t.get('runtime', {}).get('connected', False)
    mode = t.get('settings', {}).get('hvacMode', 'unknown')
    heat_stages = t.get('settings', {}).get('heatStages', 'unknown')
    cool_stages = t.get('settings', {}).get('coolStages', 'unknown')
    model = t.get('modelNumber', 'Unknown')
    print(f"ID: {identifier}")
    print(f"Name: {name}")
    print(f"Model: {model}")
    print(f"Connected: {'Yes' if connected else 'No'}")
    print(f"Current Mode: {mode}")
    print(f"Heat Stages: {heat_stages}")
    print(f"Cool Stages: {cool_stages}")
    print("-" * 60)
PY
      exit $?
    else
      echo "API returned error: $(echo "$response" | jq -r '.status.message // "Unknown error"')" >&2
      exit 3
    fi
  else
    echo "Invalid JSON response from API: $response" >&2
    exit 4
  fi

  echo "Testing Ecobee API connection using ACCESS_TOKEN from $CONF_FILE..."
  file=$(mktemp)
  http_code=$(curl "${TEST_CURL_ARGS[@]}" -H "Content-Type: text/json" -H "Authorization: Bearer ${ACCESS_TOKEN}" "${API_URL_BASE}/thermostat?format=json&body=${BODY_ENC}" -o "$file" -w "%{http_code}") || http_code=$?
  body=$(cat "$file" 2>/dev/null || true)
  rm -f "$file"

  if [ "$http_code" = "200" ] || echo "$body" | grep -q '"status"'; then
    # check status.code
    code=$(printf '%s' "$body" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin)
  print(j.get("status",{}).get("code",""))
except Exception:
  print("parse_error")')
    if [ "$code" = "0" ]; then
      echo "Connection OK: API reachable and token accepted (status.code 0)."
      exit 0
    else
      echo "API reachable but returned status.code: $code" >&2
      printf '%s\n'"$body"'\n'
      exit 3
    fi
  fi

  if [ "$http_code" = "401" ] || echo "$body" | grep -qi "invalid access token\|expired"; then
    if [ -z "$REFRESH_TOKEN" ]; then
      echo "Access token invalid/expired and no REFRESH_TOKEN available in $CONF_FILE" >&2
      exit 4
    fi
    echo "Access token invalid/expired; attempting refresh..."
  token_resp=$(curl "${TEST_CURL_ARGS[@]}" -X POST "https://api.ecobee.com/token" -d "grant_type=refresh_token&refresh_token=${REFRESH_TOKEN}&client_id=${API_KEY}")
    new_access=$(printf '%s' "$token_resp" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin); print(j.get("access_token",""))
except Exception:
  print("")')
    if [ -z "$new_access" ]; then
      echo "Token refresh failed: $token_resp" >&2
      exit 5
    fi
    echo "Token refresh succeeded. Updated access token (not writing to conf here)."
    # re-run test with new token
  file=$(mktemp)
  http_code=$(curl "${TEST_CURL_ARGS[@]}" -H "Content-Type: text/json" -H "Authorization: Bearer ${new_access}" "${API_URL_BASE}/thermostat?format=json&body=${BODY_ENC}" -o "$file" -w "%{http_code}") || http_code=$?
    body=$(cat "$file" 2>/dev/null || true)
    rm -f "$file"
    if [ "$http_code" = "200" ] || echo "$body" | grep -q '"status"'; then
      code=$(printf '%s' "$body" | python3 -c 'import sys,json
try:
  j=json.load(sys.stdin)
  print(j.get("status",{}).get("code",""))
except Exception:
  print("parse_error")')
      if [ "$code" = "0" ]; then
        echo "Connection OK after refresh: API reachable and refreshed token accepted (status.code 0)."
        exit 0
      else
        echo "API reachable after refresh but returned status.code: $code" >&2
        printf '%s\n'"$body"'\n'
        exit 6
      fi
    else
      echo "HTTP $http_code - API response after refresh: $body" >&2
      exit 7
    fi
  fi

  echo "HTTP $http_code - API response: $body" >&2
  exit 8
fi

if [ -z "${1:-}" ]; then
  echo "Usage: $0 (MODE [--dry-run] | --probe-thermostats | --test-connection)" >&2
  echo "MODE: HEAT | OFF | AUX | COOL | AUTO" >&2
  exit 2
fi

MODE_RAW="$1"
shift || true

# simple option parsing: only support --dry-run (or -n)
for a in "$@"; do
  case "$a" in
    --dry-run|-n|--no-run) DRY_RUN=1 ;; 
    *) echo "Unknown option: $a" >&2; exit 2;;
  esac
done

# normalize mode
MODE_UPPER=$(echo "$MODE_RAW" | tr '[:lower:]' '[:upper:]')
case "$MODE_UPPER" in
  HEAT) HVAC_MODE="heat";;
  OFF) HVAC_MODE="off";;
  AUX) HVAC_MODE="auxHeatOnly";;
  COOL) HVAC_MODE="cool";;
  AUTO) HVAC_MODE="auto";;
  *) echo "Unsupported mode: $MODE_RAW. Supported: HEAT, OFF, AUX, COOL, AUTO" >&2; exit 2;;
esac

API_KEY=$(read_conf_value API_KEY) || { echo "API_KEY not found in $CONF_FILE" >&2; exit 2; }
ACCESS_TOKEN=$(read_conf_value ACCESS_TOKEN) || { echo "ACCESS_TOKEN not found in $CONF_FILE" >&2; exit 2; }
REFRESH_TOKEN=$(read_conf_value REFRESH_TOKEN) || REFRESH_TOKEN=""

API_URL_BASE="https://api.ecobee.com/1"

# Build the JSON payload (always use thermostat id selection)
TMP_JSON=$(mktemp)
cat > "$TMP_JSON" <<JSON
{
  "selection": {
    "selectionType": "thermostats",
    "selectionMatch": "${THERMOSTAT_ID}"
  },
  "thermostat": {
    "settings": {
      "hvacMode": "${HVAC_MODE}"
    }
  }
}
JSON

# For mode-change operations, enable verbose curl output only when requested
MODE_CURL_ARGS=("${DEFAULT_CURL_ARGS[@]}")
if [ "$VERBOSE" -eq 1 ]; then MODE_CURL_ARGS=(-v); fi

CURL_OPTS=(
  --request POST
  -H "Content-Type: application/json;charset=UTF-8"
  -H "Authorization: Bearer ${ACCESS_TOKEN}"
  --data-urlencode
  "@${TMP_JSON}"
  "${API_URL_BASE}/thermostat?format=json"
)

run_post(){
  # capture http status and body
  local out file status
  file=$(mktemp)
  # choose curl prefix args for mode-change: verbose if requested, otherwise silent
  if [ "$VERBOSE" -eq 1 ]; then
    CURL_PREFIX=(-v)
  else
    CURL_PREFIX=("${DEFAULT_CURL_ARGS[@]}")
  fi
  status=$(curl "${CURL_PREFIX[@]}" "${CURL_OPTS[@]}" -o "$file" -w "%{http_code}") || status=$?
  out=$(cat "$file" 2>/dev/null || true)
  rm -f "$file"
  echo "$status"$'__SEP__'"$out"
}

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN: Would POST to ${API_URL_BASE}/thermostat?format=json with JSON:"
  cat "$TMP_JSON"
  rm -f "$TMP_JSON"
  exit 0
fi

resp_and_code=$(run_post)
http_code=${resp_and_code%%__SEP__*}
body=${resp_and_code#*__SEP__}

if [ "$http_code" = "401" ] || echo "$body" | grep -qi "invalid access token\|expired"; then
  if [ -z "$REFRESH_TOKEN" ]; then
    echo "Access token expired and no REFRESH_TOKEN available in $CONF_FILE" >&2
    rm -f "$TMP_JSON"
    exit 3
  fi
  echo "Access token appears expired; attempting refresh..."
  token_resp=$(curl "${MODE_CURL_ARGS[@]}" -X POST "https://api.ecobee.com/token" -d "grant_type=refresh_token&refresh_token=${REFRESH_TOKEN}&client_id=${API_KEY}")
  new_access=$(printf '%s' "$token_resp" | python3 -c 'import sys,json; j=json.load(sys.stdin); print(j.get("access_token",""))')
  new_refresh=$(printf '%s' "$token_resp" | python3 -c 'import sys,json; j=json.load(sys.stdin); print(j.get("refresh_token",""))')
  if [ -z "$new_access" ]; then
    echo "Token refresh failed: $token_resp" >&2
    rm -f "$TMP_JSON"
    exit 4
  fi
  echo "Refreshing ACCESS_TOKEN in $CONF_FILE"
  # update ecobee.conf with new tokens (use environment variables to avoid quoting issues)
  CONF_FILE_ENV="$CONF_FILE" NEW_ACCESS_ENV="$new_access" NEW_REFRESH_ENV="$new_refresh" python3 - <<PY
import os, json
p = os.environ['CONF_FILE_ENV']
new_access = os.environ.get('NEW_ACCESS_ENV', '')
new_refresh = os.environ.get('NEW_REFRESH_ENV', '')
with open(p) as f:
  j = json.load(f)
j['ACCESS_TOKEN'] = new_access
if new_refresh:
  j['REFRESH_TOKEN'] = new_refresh
with open(p, 'w') as f:
  json.dump(j, f, indent=2)
print('OK')
PY
  ACCESS_TOKEN="$new_access"
  # update CURL_OPTS header
  CURL_OPTS=(
    --request POST
    -H "Content-Type: application/json;charset=UTF-8"
    -H "Authorization: Bearer ${ACCESS_TOKEN}"
    --data-urlencode
    "@${TMP_JSON}"
    "${API_URL_BASE}/thermostat?format=json"
  )
  resp_and_code=$(run_post)
  http_code=${resp_and_code%%__SEP__*}
  body=${resp_and_code#*__SEP__}
fi

# cleanup tmp json
rm -f "$TMP_JSON"

# parse response for success
if [ "$http_code" = "200" ] || echo "$body" | grep -q '"status"'; then
  # check status.code == 0
  ok=$(printf '%s' "$body" | python3 -c 'import sys,json
try:
    j=json.load(sys.stdin)
    code=j.get("status",{}).get("code",None)
    print("0" if code==0 else code)
except Exception:
    print("parse_error")')
  if [ "$ok" = "0" ]; then
    echo "Success: mode set to ${HVAC_MODE} for thermostat '${THERMOSTAT_NAME}'."
    exit 0
  else
    echo "API returned non-zero status: $body" >&2
    exit 5
  fi
else
  echo "HTTP $http_code - API response: $body" >&2
  exit 6
fi
