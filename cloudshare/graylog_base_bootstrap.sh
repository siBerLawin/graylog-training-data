#!/bin/bash
# Graylog Base bootstrap for a CloudShare blueprint VM (Ubuntu 24.04).
#
# TOPOLOGY: mongo:8.0 + graylog-datanode + graylog-enterprise, all 7.1.7.
# This mirrors the gl_sandbox stack, which is the configuration the Academy Module 2/3
# content was actually validated against. It is NOT the Framework's older
# docker-compose-glservices.yml topology (mongo:6 + opensearch:2.12.0 + Graylog 6.3.5),
# which fails here: Graylog 7.1 requires MongoDB >= 7.
#
# WHY A SCRIPT AND NOT CLICKING
# The blueprint is a UI artifact we cannot version. If the base is BUILT by a script that
# lives in git, the image stays reproducible from source anyway.
#
# WHAT IT DOES NOT DO (deliberately, later layers)
#   - no HTTPS / certs, no Illuminate, no licenses, no OliveTin, no module content.
# Goal: Graylog reachable on :9000 with a working indexer. Snapshot after that.
#
# USAGE
#   sudo bash graylog_base_bootstrap.sh
#   sudo GL_VER=7.1.7 GL_HEAP=1g DN_HEAP=1g bash graylog_base_bootstrap.sh
#
set -euo pipefail

GL_VER="${GL_VER:-7.1.7}"          # graylog-enterprise AND graylog-datanode
MONGO_VER="${MONGO_VER:-8.0}"      # Graylog 7.1 requires >= 7

# 4 GB box tuning. Measured on gl_sandbox under a 3.7 GB ceiling: datanode ~1.87 GB,
# graylog ~1.24 GB, mongodb ~0.10 GB. That is ~3.2 GB and it is TIGHT on a 4 GB VM.
# Lower these first if anything gets OOM killed.
GL_HEAP="${GL_HEAP:-1g}"
DN_HEAP="${DN_HEAP:-1g}"

# ---------------------------------------------------------------------------
# CRITICAL: Graylog and DataNode must share the SAME password secret. When they
# drift, indexing dies and the errors point at the wrong layer ("Could not
# decrypt", "No indexer hosts, fallback 127.0.0.1:9200"), which reads like an
# OpenSearch problem and is not. Defined ONCE here so they cannot diverge.
# ---------------------------------------------------------------------------
PASSWORD_SECRET="${PASSWORD_SECRET:-somepasswordpepper}"

# sha256 of "yabba dabba doo", the Framework's standard lab password. Kept identical
# so existing Academy scripts and content work unchanged (admin / yabba dabba doo).
ROOT_PASSWORD_SHA2="${ROOT_PASSWORD_SHA2:-941828f6268291fa3aa87a866e8367e609434f42761bdf02dc7fc7958897bae6}"

# ---------------------------------------------------------------------------
# CloudShare Web Access: publish on an ALLOWED port.
# Web Access gives the environment a static, shareable URL so a learner opens
# Graylog in their own browser (the same shape as Instruqt's tab, and it removes
# any need for a learner desktop VM). It only proxies these ports:
#   80, 443, 3695, 8000-8010, 8080, 8180, 8280, 8360, 8365, 8585, 8443-8449
# Graylog's default 9000 is NOT among them, so the container's 9000 is published
# on the host as 8080.
HOST_PORT="${HOST_PORT:-8080}"

# Graylog must advertise the URL the BROWSER uses, not its own address. Behind the
# Web Access proxy the page would otherwise load and then send every API call to the
# wrong host, which looks like a broken Graylog and is not. Same reason the Framework
# sets GLEURI=https://$dns.logfather.org/ in docker_graylog_https.sh.
#   1. Once Web Access is enabled, RE-RUN with the CloudShare URL:
#        sudo GL_EXTERNAL_URI=https://xxxx.cloudshare.com/ bash graylog_base_bootstrap.sh
#   2. Until then it advertises the VM's own address on HOST_PORT, which is fine
#      for curl and for a browser on the same internal network.
VM_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
GL_EXTERNAL_URI="${GL_EXTERNAL_URI:-http://${VM_IP}:${HOST_PORT}/}"

INSTALL_DIR="/opt/graylog-base"

echo "==> Graylog Base: graylog+datanode ${GL_VER}, mongo ${MONGO_VER}, heaps GL=${GL_HEAP} DN=${DN_HEAP}"
echo "==> Publishing Graylog on host port ${HOST_PORT} (CloudShare Web Access allows"
echo "    80, 443, 3695, 8000-8010, 8080, 8180, 8280, 8360, 8365, 8585, 8443-8449; NOT 9000)"
echo "==> Graylog will advertise itself at ${GL_EXTERNAL_URI}"

echo "==> Preflight"
free -h || true
df -h / || true

echo "==> Installing Docker"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# The embedded OpenSearch inside DataNode will not start without this.
echo "==> Setting vm.max_map_count"
sysctl -w vm.max_map_count=262144
grep -q "^vm.max_map_count" /etc/sysctl.conf || echo "vm.max_map_count=262144" >> /etc/sysctl.conf

echo "==> Writing compose to ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
cat > "${INSTALL_DIR}/docker-compose.yml" <<COMPOSE
services:
  mongodb:
    hostname: "mongo"
    image: "mongo:${MONGO_VER}"
    volumes:
      - "mongodb_data:/data/db"
    networks: [graylog_net]
    logging:
      driver: "json-file"
      options: { max-size: "10m", max-file: "3" }
    restart: "on-failure"

  datanode:
    image: "graylog/graylog-datanode:${GL_VER}"
    depends_on:
      mongodb: { condition: "service_started" }
    hostname: "datanode-01"
    environment:
      GRAYLOG_DATANODE_NODE_ID_FILE: "/var/lib/graylog-datanode/node-id"
      GRAYLOG_DATANODE_PASSWORD_SECRET: "${PASSWORD_SECRET}"
      GRAYLOG_DATANODE_ROOT_PASSWORD_SHA2: "${ROOT_PASSWORD_SHA2}"
      GRAYLOG_DATANODE_MONGODB_URI: "mongodb://mongodb:27017/graylog"
      GRAYLOG_DATANODE_OPENSEARCH_DATA_LOCATION: "/usr/share/opensearch/data"
      GRAYLOG_DATANODE_OPENSEARCH_HEAP: "${DN_HEAP}"
    ulimits:
      memlock: { hard: -1, soft: -1 }
      nofile:  { soft: 65536, hard: 65536 }
    ports:
      - "8977:8977/tcp"
      - "9200:9200/tcp"
    networks: [graylog_net]
    logging:
      driver: "json-file"
      options: { max-size: "10m", max-file: "3" }
    volumes:
      - "graylog_datanode_os:/usr/share/opensearch/data"
      - "graylog_datanode:/var/lib/graylog-datanode"
    restart: "on-failure"

  graylog:
    hostname: "graylog"
    image: "graylog/graylog-enterprise:${GL_VER}"
    depends_on:
      mongodb: { condition: "service_started" }
    entrypoint: "/usr/bin/tini --  /docker-entrypoint.sh"
    environment:
      # Disk guard. Graylog's DEFAULT journal cap is 5gb, which on this 20 GB VM
      # (18 GB usable) can fill the disk on its own and take Graylog down with
      # "No space left on device". The Framework's compose caps it at 1gb; we go
      # lower still because the lab dataset is tiny (4,623 events).
      GRAYLOG_MESSAGE_JOURNAL_MAX_SIZE: "${JOURNAL_MAX:-512mb}"
      GRAYLOG_NODE_ID_FILE: "/usr/share/graylog/data/config/node-id"
      GRAYLOG_PASSWORD_SECRET: "${PASSWORD_SECRET}"
      GRAYLOG_ROOT_PASSWORD_SHA2: "${ROOT_PASSWORD_SHA2}"
      GRAYLOG_HTTP_BIND_ADDRESS: "0.0.0.0:9000"
      GRAYLOG_HTTP_EXTERNAL_URI: "${GL_EXTERNAL_URI}"
      GRAYLOG_HTTP_PUBLISH_URI: "${GL_EXTERNAL_URI}"
      GRAYLOG_MONGODB_URI: "mongodb://mongodb:27017/graylog"
      # No GRAYLOG_ELASTICSEARCH_HOSTS: with DataNode, Graylog discovers the
      # indexer through MongoDB and authenticates with JWT.
      GRAYLOG_INDEXER_USE_JWT_AUTHENTICATION: "true"
      GRAYLOG_SERVER_JAVA_OPTS: "-Xms${GL_HEAP} -Xmx${GL_HEAP}"
      GRAYLOG_REPORT_DISABLE_SANDBOX: "true"
      GRAYLOG_TELEMETRY_ENABLED: "false"
      GRAYLOG_HTTP_COOKIE_SAME_SITE_STRICT: "false"
    ports:
      - "${HOST_PORT}:9000/tcp"
      - "5044:5044/tcp"
      - "12201:12201/tcp"
      - "12201:12201/udp"
      - "12299:12299/tcp"
      - "12299:12299/udp"
      - "5555:5555/tcp"
      - "5555:5555/udp"
    networks: [graylog_net]
    logging:
      driver: "json-file"
      options: { max-size: "10m", max-file: "3" }
    volumes:
      - "graylog_config:/usr/share/graylog/data/config"
      - "graylog_data:/usr/share/graylog/data/data"
      - "graylog_journal:/usr/share/graylog/data/journal"
    restart: "on-failure"

networks:
  graylog_net:
    driver: "bridge"

volumes:
  mongodb_data:
  graylog_datanode_os:
  graylog_datanode:
  graylog_data:
  graylog_config:
  graylog_journal:
COMPOSE

echo "==> Pulling images (slowest step, several minutes)"
cd "${INSTALL_DIR}"
docker compose pull

echo "==> Starting stack"
docker compose up -d

echo "==> Waiting for Graylog to settle (this branches: preflight vs ready)"
# On a FIRST boot with DataNode, Graylog does not start its real API at all: it stands up
# a preflight configuration service instead and waits for a CA + renewal policy + certs.
# Polling /api/system for 5 minutes in that state is pointless and reads as a hang, so
# detect preflight explicitly and say so.
PREFLIGHT=""
READY=""
for i in $(seq 1 36); do
  if curl -fsS -u 'admin:yabba dabba doo' "http://localhost:${HOST_PORT}/api/system" >/dev/null 2>&1; then
    READY=1; break
  fi
  if docker compose logs graylog 2>/dev/null | grep -q "Initial configuration is accessible"; then
    PREFLIGHT=1; break
  fi
  sleep 5
done

if [ -n "${PREFLIGHT}" ]; then
  echo
  echo "-----------------------------------------------------------------------"
  echo "GRAYLOG IS IN PREFLIGHT. This is EXPECTED on a first boot with DataNode."
  echo "It is not an error and nothing is stuck."
  echo
  echo "Graylog will not serve its real API until a certificate authority, a"
  echo "renewal policy and signed certificates exist. Do that now:"
  echo
  echo "    sudo bash graylog_preflight.sh"
  echo
  echo "That script is automated and idempotent; it finds the preflight password"
  echo "itself. Come back here only if it fails."
  echo "-----------------------------------------------------------------------"
  exit 0
fi

if [ -n "${READY}" ]; then
  echo
  curl -fsS -u 'admin:yabba dabba doo' "http://localhost:${HOST_PORT}/api/system" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print("Graylog UP:", d.get("version"), "| lb:", d.get("lb_status"))' 2>/dev/null || echo "Graylog UP"
  echo
  echo "Indexer health (must be green/yellow, NOT unavailable):"
  curl -fsS -u 'admin:yabba dabba doo' "http://localhost:${HOST_PORT}/api/system/indexer/cluster/health" \
    | python3 -c 'import sys,json; print("  ", json.load(sys.stdin))' 2>/dev/null || echo "  (unreadable)"
  echo
  echo "Memory in use:"
  docker stats --no-stream --format "  {{.Name}}  {{.MemUsage}}  {{.CPUPerc}}" || true
  echo
  echo "Advertising: ${GL_EXTERNAL_URI}"
  echo "NEXT: enable Web Access on this VM in CloudShare, then re-run with"
  echo "      sudo GL_EXTERNAL_URI=<the CloudShare URL> bash $0"
  echo "      so Graylog advertises the proxied URL to the learner's browser."
  exit 0
fi

echo >&2
echo "Graylog neither reached preflight nor came up. Triage in this order:" >&2
echo "  docker compose -f ${INSTALL_DIR}/docker-compose.yml ps" >&2
echo "  docker compose -f ${INSTALL_DIR}/docker-compose.yml logs --tail=40 graylog" >&2
echo "  docker compose -f ${INSTALL_DIR}/docker-compose.yml logs --tail=40 datanode" >&2
echo >&2
echo "Likely causes on a 4 GB VM:" >&2
echo "  1. OOM. Check 'free -h' and for restart loops. Lower GL_HEAP / DN_HEAP and rerun." >&2
echo "  2. Mongo too old. Graylog 7.1 needs MongoDB >= 7; this pins ${MONGO_VER}." >&2
echo "  3. Password secret mismatch between graylog and datanode. This script defines it" >&2
echo "     once so they cannot drift, but if you edit the compose by hand, keep them equal." >&2
exit 1
