#!/bin/bash
# Graylog DataNode preflight, fully automated from the terminal.
#
# WHY THIS EXISTS
# A first boot of Graylog + DataNode stops at a browser-based preflight screen: create a
# certificate authority, set a certificate renewal policy, provision certs, resume startup.
# A lab blueprint cannot contain a manual browser step, and a CloudShare VM may only offer
# a terminal, so every one of those steps is done here over the preflight API.
#
# THE GOTCHA THIS SCRIPT EXISTS TO PREVENT
# Certificate generation returns HTTP 204 and does NOTHING if no renewal policy exists.
# There is no error, no server log line, and the CSR sits unsigned forever while the
# DataNode stays UNCONFIGURED. So: CA -> RENEWAL POLICY -> generate, in that order, with
# the policy verified non-empty before generating.
#
# Idempotent: safe to re-run. Existing CA / policy are left alone.
#
# USAGE
#   sudo bash graylog_preflight.sh
#   sudo COMPOSE_DIR=/opt/graylog-base bash graylog_preflight.sh
#   sudo PREFLIGHT_PASSWORD=xxxx bash graylog_preflight.sh   # if log scrape fails
#
set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/graylog-base}"
HOST_PORT="${HOST_PORT:-8080}"
GL_URL="${GL_URL:-http://localhost:${HOST_PORT}}"
ORG_NAME="${ORG_NAME:-Graylog Academy}"
CERT_LIFETIME="${CERT_LIFETIME:-P365D}"
ADMIN_PASS="${ADMIN_PASS:-yabba dabba doo}"   # the real admin password, post-preflight

say() { printf '\n== %s\n' "$*"; }
api() { curl -s -u "admin:${P}" -H 'X-Requested-By: cli' -H 'Content-Type: application/json' "$@"; }
code() { curl -s -o /dev/null -w '%{http_code}' -u "admin:${P}" -H 'X-Requested-By: cli' -H 'Content-Type: application/json' "$@"; }

# ---------------------------------------------------------------------------
# 1. Preflight password
# Printed once by the graylog container: "... username 'admin' and password 'XXXX'."
# ---------------------------------------------------------------------------
say "Locating preflight password"
if [ -n "${PREFLIGHT_PASSWORD:-}" ]; then
  P="${PREFLIGHT_PASSWORD}"
  echo "   using PREFLIGHT_PASSWORD from environment"
else
  P="$(docker compose -f "${COMPOSE_DIR}/docker-compose.yml" logs graylog 2>/dev/null \
        | grep -oE "password '[^']+'" | tail -1 | sed "s/password '//; s/'//")" || true
  if [ -z "${P:-}" ]; then
    echo "   ERROR: could not find the preflight password in the graylog logs." >&2
    echo "   Look for \"Initial configuration is accessible\" in:" >&2
    echo "     docker compose -f ${COMPOSE_DIR}/docker-compose.yml logs graylog" >&2
    echo "   then re-run with: sudo PREFLIGHT_PASSWORD=xxxx bash \$0" >&2
    exit 1
  fi
  echo "   found (not printed)"
fi

# ---------------------------------------------------------------------------
# 2. Wait for the preflight API
# ---------------------------------------------------------------------------
say "Waiting for preflight API at ${GL_URL}"
for i in $(seq 1 60); do
  if [ "$(code "${GL_URL}/api/status")" = "200" ]; then echo "   up"; break; fi
  sleep 5
  [ "$i" = "60" ] && { echo "   ERROR: preflight API never answered" >&2; exit 1; }
done
echo "   server: $(api "${GL_URL}/api/status")"
echo "   datanode: $(api "${GL_URL}/api/data_nodes" | grep -o '"status":"[^"]*"' | head -1)"

# ---------------------------------------------------------------------------
# 3. Certificate authority
# ---------------------------------------------------------------------------
say "Certificate authority"
if [ -n "$(api "${GL_URL}/api/ca" | tr -d '[:space:]')" ]; then
  echo "   already exists: $(api "${GL_URL}/api/ca")"
else
  out="$(api -X POST "${GL_URL}/api/ca/create" -d "{\"organization\":\"${ORG_NAME}\"}")" || true
  echo "   created: ${out}"
  if [ -z "$(api "${GL_URL}/api/ca" | tr -d '[:space:]')" ]; then
    echo "   ERROR: CA still empty after create. Try POST ${GL_URL}/api/ca instead." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 4. RENEWAL POLICY. This is the gate. Generation silently no-ops without it.
# ---------------------------------------------------------------------------
say "Certificate renewal policy (the gate)"
if [ -n "$(api "${GL_URL}/api/renewal_policy" | tr -d '[:space:]')" ]; then
  echo "   already set: $(api "${GL_URL}/api/renewal_policy")"
else
  api -X POST "${GL_URL}/api/renewal_policy" \
      -d "{\"mode\":\"AUTOMATIC\",\"certificate_lifetime\":\"${CERT_LIFETIME}\"}" >/dev/null || true
  sleep 2
  pol="$(api "${GL_URL}/api/renewal_policy" | tr -d '[:space:]')"
  if [ -z "${pol}" ]; then
    echo "   ERROR: renewal policy is STILL empty. Do not continue; cert generation would" >&2
    echo "   return 204 and do nothing. Check the accepted schema with:" >&2
    echo "     curl -i -u admin:\$P -X POST ${GL_URL}/api/renewal_policy -H 'X-Requested-By: cli' \\" >&2
    echo "          -H 'Content-Type: application/json' -d '{\"mode\":\"AUTOMATIC\",\"certificate_lifetime\":\"P365D\"}'" >&2
    exit 1
  fi
  echo "   set: $(api "${GL_URL}/api/renewal_policy")"
fi

# ---------------------------------------------------------------------------
# 5. Generate certificates
# ---------------------------------------------------------------------------
say "Generating certificates"
gen_code="$(code -X POST "${GL_URL}/api/generate" -d '{}')"
echo "   POST /api/generate -> ${gen_code}"
if [ "${gen_code}" = "404" ]; then
  gen_code="$(code -X POST "${GL_URL}/api/certificates" -d '{}')"
  echo "   POST /api/certificates -> ${gen_code}"
fi

# ---------------------------------------------------------------------------
# 6. Wait for the DataNode to leave UNCONFIGURED. This, not the HTTP code, is success.
# ---------------------------------------------------------------------------
say "Waiting for DataNode to be READY (not merely out of UNCONFIGURED)"
# STARTING is transitional. Breaking out on "anything but UNCONFIGURED" calls resume
# against a DataNode that is still coming up, and the resume endpoints answer 500.
# Wait for a terminal ready state instead.
configured=""
for i in $(seq 1 60); do
  st="$(api "${GL_URL}/api/data_nodes" | grep -o '"datanode_status":"[^"]*"' | head -1 | cut -d'"' -f4)"
  [ -z "${st}" ] && st="$(api "${GL_URL}/api/data_nodes" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)"
  echo "   [$i] ${st:-unknown}"
  case "${st}" in
    AVAILABLE|CONNECTED|READY|CONFIGURED) configured="${st}"; break ;;
    UNCONFIGURED|STARTING|""|unknown)     ;;   # keep waiting
    *) configured="${st}"; break ;;            # unknown terminal state, proceed and report
  esac
  sleep 5
done
if [ -z "${configured}" ]; then
  echo >&2
  echo "   ERROR: DataNode is still UNCONFIGURED. The CSR is likely unsigned." >&2
  echo "   Check:  curl -s -u admin:\$P ${GL_URL}/api/data_nodes" >&2
  echo "           docker compose -f ${COMPOSE_DIR}/docker-compose.yml logs --tail=50 datanode" >&2
  exit 1
fi
echo "   DataNode is now: ${configured}"

# ---------------------------------------------------------------------------
# 7. Resume startup. Endpoint name varies; try the candidates.
# ---------------------------------------------------------------------------
say "Resuming startup"
# 500 here usually means "called too early", not "wrong endpoint" (a wrong path 404s).
# Retry a few times, since DataNode may still be settling even after reporting ready.
resumed=""
for attempt in 1 2 3; do
  for ep in finish resume startOver; do
    c="$(code -X POST "${GL_URL}/api/${ep}" -d '{}')"
    echo "   [try ${attempt}] POST /api/${ep} -> ${c}"
    case "${c}" in
      200|201|202|204) resumed="${ep}"; break ;;
    esac
  done
  [ -n "${resumed}" ] && { echo "   accepted via /api/${resumed}"; break; }
  # Maybe Graylog resumed on its own once certs existed.
  if curl -fsS -u "admin:${ADMIN_PASS}" "${GL_URL}/api/system" >/dev/null 2>&1; then
    echo "   Graylog is already serving its real API; no resume needed."
    resumed="auto"; break
  fi
  echo "   none accepted, waiting 20s before retrying"
  sleep 20
done
[ -z "${resumed}" ] && echo "   WARNING: no resume endpoint accepted. Graylog may still come up on its own." 

# ---------------------------------------------------------------------------
# 8. Wait for the real Graylog server (preflight hands over on the same port)
# ---------------------------------------------------------------------------
say "Waiting for Graylog server (up to 5 minutes)"
for i in $(seq 1 60); do
  if curl -fsS -u "admin:${ADMIN_PASS}" "${GL_URL}/api/system" >/dev/null 2>&1; then
    echo
    curl -fsS -u "admin:${ADMIN_PASS}" "${GL_URL}/api/system" \
      | python3 -c 'import sys,json;d=json.load(sys.stdin);print("Graylog UP:",d.get("version"),"| lb:",d.get("lb_status"))' 2>/dev/null || echo "Graylog UP"
    echo "Indexer health:"
    curl -fsS -u "admin:${ADMIN_PASS}" "${GL_URL}/api/system/indexer/cluster/health" \
      | python3 -c 'import sys,json;print("  ",json.load(sys.stdin))' 2>/dev/null || echo "  (unreadable)"
    echo
    docker stats --no-stream --format "  {{.Name}}  {{.MemUsage}}  {{.CPUPerc}}" 2>/dev/null || true
    echo
    echo "Preflight complete. Snapshot this VM as the 'Graylog Base' blueprint."
    exit 0
  fi
  sleep 5
done

echo >&2
echo "Graylog server did not come up after preflight. It may still be restarting." >&2
echo "  docker compose -f ${COMPOSE_DIR}/docker-compose.yml ps" >&2
echo "  docker compose -f ${COMPOSE_DIR}/docker-compose.yml logs --tail=40 graylog" >&2
exit 1
