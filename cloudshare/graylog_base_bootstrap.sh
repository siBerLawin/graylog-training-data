#!/bin/bash
# Graylog Base bootstrap for a CloudShare blueprint VM (Ubuntu 24.04).
#
# WHAT THIS IS
# The Instruqt Framework builds its VM through /common/base_setup.sh, which depends on
# env vars (CLASS, TITLE, licenses, apitoken, dns, NEEDS_DOCKER) that the Instruqt track
# setup lifecycle script writes into /etc/profile. None of that exists on CloudShare, so
# running those scripts raw fails early and confusingly. This is the same Docker path
# (base_setup.sh -> install_graylog_docker.sh) with the Instruqt dependencies stripped out
# and the heaps sized for a 4 GB box.
#
# WHY A SCRIPT AND NOT CLICKING
# The blueprint itself is a UI artifact we cannot version. If the base is BUILT by a script
# that lives in git, the image becomes reproducible from source anyway. That recovers most
# of what a UI-authored blueprint appears to cost us.
#
# WHAT IT DOES NOT DO (deliberately, these come later)
#   - no HTTPS / certs        (Framework: docker_graylog_https.sh)
#   - no Illuminate           (Framework: inst_illuminate.sh)
#   - no licenses             (Framework: base_setup.sh, needs the license JWTs)
#   - no OliveTin             (Framework: setup_olivetin.sh)
#   - no per-module content   (that is the class folder, stays in git)
# Goal here is only: Graylog reachable on :9000. Snapshot after that works.
#
# USAGE
#   sudo bash cloudshare_base_bootstrap.sh
#   sudo GL_VER=7.1.7 bash cloudshare_base_bootstrap.sh     # pin a Graylog version
#
set -euo pipefail

# Match the Graylog the Academy modules were validated on, NOT the stale 6.3.5-1 pinned in
# the Framework's compose file (the Framework sed-overrides it via GL_VER_OVERRIDE at
# install time, which is why that pin looks wrong).
GL_VER="${GL_VER:-7.1.7}"

# 4 GB box: the Framework's 2g + 2g will not start here. 1g + 1g leaves room for MongoDB,
# Docker and the OS. Raise both to 2g if the account's hardware limit is ever lifted.
OS_HEAP="${OS_HEAP:-1g}"
GL_HEAP="${GL_HEAP:-1g}"

# sha256 of the Framework's standard lab password, kept identical so Academy content and
# scripts that assume admin / "yabba dabba doo" keep working.
GL_ROOT_SHA2="941828f6268291fa3aa87a866e8367e609434f42761bdf02dc7fc7958897bae6"

INSTALL_DIR="/opt/graylog-base"

echo "==> Graylog Base bootstrap: Graylog ${GL_VER}, heaps OS=${OS_HEAP} GL=${GL_HEAP}"

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

# OpenSearch refuses to start without this.
echo "==> Setting vm.max_map_count"
sysctl -w vm.max_map_count=262144
grep -q "^vm.max_map_count" /etc/sysctl.conf || echo "vm.max_map_count=262144" >> /etc/sysctl.conf

echo "==> Writing compose to ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
cat > "${INSTALL_DIR}/docker-compose.yml" <<COMPOSE
services:
  mongodb:
    image: "mongo:6"
    volumes:
      - "mongodb_data:/data/db"
    restart: "always"

  opensearch:
    container_name: "opensearch"
    image: "opensearchproject/opensearch:2.12.0"
    environment:
      OPENSEARCH_JAVA_OPTS: "-Xms${OS_HEAP} -Xmx${OS_HEAP} -Dlog4j2.formatMsgNoLookups=true"
      bootstrap.memory_lock: "true"
      discovery.type: "single-node"
      http.host: "0.0.0.0"
      action.auto_create_index: "false"
      DISABLE_INSTALL_DEMO_CONFIG: "true"
      DISABLE_SECURITY_PLUGIN: "true"
    ulimits:
      memlock:
        hard: -1
        soft: -1
    ports:
      - "9200:9200/tcp"
    volumes:
      - "os-data1:/usr/share/opensearch/data"
    restart: "always"

  graylog:
    image: "graylog/graylog-enterprise:${GL_VER}"
    depends_on:
      opensearch:
        condition: "service_started"
      mongodb:
        condition: "service_started"
    entrypoint: "/usr/bin/tini -- wait-for-it opensearch:9200 --  /docker-entrypoint.sh"
    environment:
      GRAYLOG_MESSAGE_JOURNAL_MAX_SIZE: 1gb
      GRAYLOG_PASSWORD_SECRET: somepasswordpepper
      GRAYLOG_ROOT_USERNAME: "admin"
      GRAYLOG_ROOT_PASSWORD_SHA2: "${GL_ROOT_SHA2}"
      GRAYLOG_HTTP_BIND_ADDRESS: "0.0.0.0:9000"
      GRAYLOG_ELASTICSEARCH_HOSTS: "http://opensearch:9200"
      GRAYLOG_MONGODB_URI: "mongodb://mongodb:27017/graylog"
      GRAYLOG_SERVER_JAVA_OPTS: "-Xms${GL_HEAP} -Xmx${GL_HEAP}"
      GRAYLOG_TELEMETRY_ENABLED: "false"
      GRAYLOG_HTTP_COOKIE_SAME_SITE_STRICT: "false"
    ports:
      - "9000:9000/tcp"
      - "5044:5044/tcp"
      - "12201:12201/tcp"
      - "12201:12201/udp"
      - "1514:1514/tcp"
      - "1515:1515/tcp"
    volumes:
      - "graylog_data:/usr/share/graylog/data/data"
      - "graylog_journal:/usr/share/graylog/data/journal"
      - "graylog_config:/usr/share/graylog/data/config"
    restart: "always"

volumes:
  mongodb_data:
  os-data1:
  graylog_data:
  graylog_journal:
  graylog_config:
COMPOSE

echo "==> Pulling images (slowest step, several minutes)"
cd "${INSTALL_DIR}"
docker compose pull

echo "==> Starting stack"
docker compose up -d

echo "==> Waiting for Graylog API (up to 5 minutes)"
for i in $(seq 1 60); do
  if curl -fsS -u 'admin:yabba dabba doo' http://localhost:9000/api/system >/dev/null 2>&1; then
    echo
    echo "Graylog is UP. Version:"
    curl -fsS -u 'admin:yabba dabba doo' http://localhost:9000/api/system \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  ", d.get("version"), "| lb:", d.get("lb_status"))' 2>/dev/null || true
    echo
    echo "Memory after start:"
    docker stats --no-stream --format "  {{.Name}}  {{.MemUsage}}  {{.CPUPerc}}" || true
    echo
    echo "NEXT: verify, then snapshot this VM as the 'Graylog Base' blueprint."
    exit 0
  fi
  sleep 5
done

echo "Graylog did not come up in time. Check: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs graylog" >&2
echo "On a 4 GB box the usual cause is memory: lower OS_HEAP/GL_HEAP, or check 'docker compose ps' for a restart loop." >&2
exit 1
