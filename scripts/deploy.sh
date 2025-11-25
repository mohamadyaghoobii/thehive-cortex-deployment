#!/bin/bash
# TheHive & Cortex Enterprise Deployment
# Version: 3.4 - Full Reset (Native/Docker)
#
# WARNING: DESTRUCTIVE ON THIS HOST (for TheHive/Cortex/ES/Cassandra)
# - Stops services
# - Kills ports: 9000, 9001, 9200, 9042
# - Removes config/data/logs of TheHive, Cortex, Elasticsearch, Cassandra
#
# Modes:
#   1) Native:  Ubuntu/Debian packages + .deb (Elasticsearch via .deb fallback)
#   2) Docker:  all stack via docker-compose (elasticsearch, cassandra, cortex, thehive)
#
# Use ONLY on a dedicated lab/PoC box.

set -euo pipefail

# ---------------------------------------------------------------------------
# COLORS & LOG HELPERS
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC}  $1"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
log_debug()   { echo -e "${BLUE}[DEBUG]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAM_GB=0
DEPLOY_MODE="native"  # or "docker"

# ---------------------------------------------------------------------------
# BANNER
# ---------------------------------------------------------------------------
print_banner() {
  clear || true
  echo -e "${CYAN}"
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║                                                                ║"
  echo "║           THEHIVE & CORTEX ENTERPRISE DEPLOYMENT              ║"
  echo "║              Version 3.4 - Full Reset (Native/Docker)         ║"
  echo "║                                                                ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo "This script can deploy on this host:"
  echo "  • TheHive  5.2.16  (native) or 5.2.x (docker image)"
  echo "  • Cortex   3.1.8"
  echo "  • Elastic  7.17.29"
  echo "  • Cassandra 3.11/4.x"
  echo "  • Java 11 (native mode)"
  echo ""
  echo "# ---------------------------------------------------------------------------! WARNING: All existing TheHive/Cortex/ES/Cassandra data on this host"
  echo "# ---------------------------------------------------------------------------! will be wiped before installation (full reset)."
  echo ""
}

# ---------------------------------------------------------------------------
# BASIC VALIDATION
# ---------------------------------------------------------------------------
validate_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
  fi
  log_ok "Running as root user."
}

validate_os() {
  if [[ ! -f /etc/os-release ]]; then
    log_error "/etc/os-release not found, cannot detect OS."
    exit 1
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    log_error "Unsupported OS: $PRETTY_NAME. Only Ubuntu/Debian."
    exit 1
  fi
  log_ok "OS detected: $PRETTY_NAME"
}

check_system_resources() {
  log_step "Checking system resources..."

  RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
  local free_disk
  local cpu_cores
  free_disk=$(df -h / | awk 'NR==2{print $4}')
  cpu_cores=$(nproc)

  log_info "System Resources:"
  log_info "  RAM:  ${RAM_GB}GB"
  log_info "  Disk: ${free_disk} free"
  log_info "  CPU:  ${cpu_cores} cores"

  if [[ $RAM_GB -lt 8 ]]; then
    log_warn "Recommended minimum RAM for production is 8GB (you have ${RAM_GB}GB)."
    log_warn "This is still OK for lab / PoC, just slower."
  fi
}

choose_deploy_mode() {
  log_step "Choose deployment mode for TheHive/Cortex on THIS host"
  echo "  1) Native  (OS packages: Elasticsearch, Cassandra, TheHive, Cortex)"
  echo "  2) Docker  (all services as containers via docker compose)"
  read -rp "Enter choice [1/2] (default: 1): " mode

  case "${mode:-1}" in
    1)
      DEPLOY_MODE="native"
      ;;
    2)
      DEPLOY_MODE="docker"
      ;;
    *)
      DEPLOY_MODE="native"
      ;;
  esac
  log_info "Selected deployment mode: ${DEPLOY_MODE}"
}

# ---------------------------------------------------------------------------
# PACKAGE MANAGER LOCK / SANITY
# ---------------------------------------------------------------------------
ensure_no_package_manager_running() {
  log_step "Ensuring no other package manager (apt/dpkg) is running..."

  local attempts=0
  while pgrep -x apt >/dev/null 2>&1 \
     || pgrep -x apt-get >/dev/null 2>&1 \
     || pgrep -x dpkg >/dev/null 2>&1 \
     || pgrep -x unattended-upgrade >/dev/null 2>&1; do

    attempts=$((attempts + 1))
    if [[ $attempts -eq 1 ]]; then
      log_warn "Another apt/dpkg process is currently running. Waiting..."
    fi

    if [[ $attempts -gt 30 ]]; then
      log_error "apt/dpkg is still running after several minutes."
      exit 1
    fi

    sleep 10
  done

  if [[ -f /var/lib/dpkg/lock-frontend ]]; then
    log_warn "dpkg frontend lock exists but no apt/dpkg processes."
    log_warn "If there was a crash, you may need manual cleanup."
  fi

  log_info "Running 'dpkg --configure -a' (just in case)..."
  dpkg --configure -a >/dev/null 2>&1 || true
  log_ok "Package manager state looks sane enough to continue."
}

# ---------------------------------------------------------------------------
# PRE-CLEANUP (DESTRUCTIVE)
# ---------------------------------------------------------------------------
pre_cleanup() {
  log_step "Stopping services and cleaning previous installation state (DESTRUCTIVE)..."

  for svc in thehive cortex elasticsearch cassandra; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
      log_info "Stopping service: ${svc}"
      systemctl stop "${svc}" 2>/dev/null || true
      systemctl disable "${svc}" 2>/dev/null || true
      systemctl reset-failed "${svc}" 2>/dev/null || true
    fi
  done

  # Kill any leftovers on ports
  for port in 9000 9001 9200 9042; do
    local pids
    pids=$(ss -lntp 2>/dev/null \
      | awk -v p=":${port}" '$4 ~ p {print $NF}' \
      | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' \
      | sort -u || true)
    if [[ -n "${pids:-}" ]]; then
      log_warn "Force-killing PIDs on port ${port}: ${pids}"
      kill -9 $pids 2>/dev/null || true
    fi
  done

  log_warn "Removing previous TheHive/Cortex/Elasticsearch/Cassandra config, data and logs..."

  rm -rf /etc/thehive /etc/cortex
  rm -rf /opt/thehive /opt/thp/thehive /opt/cortex
  rm -rf /var/log/thehive /var/log/cortex
  rm -rf /var/lib/thehive /var/lib/cortex

  rm -rf /var/lib/elasticsearch /var/log/elasticsearch
  rm -rf /var/lib/cassandra /var/log/cassandra

  # Old .deb leftovers
  rm -f /tmp/thehive_5.2.*.deb /tmp/cortex_3.1.*.deb /tmp/elasticsearch-7.17.29-amd64.deb

  log_ok "Previous installation state removed (full reset)."
}

# ---------------------------------------------------------------------------
# BASE DIRS FOR NATIVE
# ---------------------------------------------------------------------------
prepare_base_dirs() {
  log_step "Preparing base directories and placeholder config files..."

  mkdir -p /etc/thehive /etc/cortex
  mkdir -p /var/log/thehive /var/log/cortex
  mkdir -p /opt/thehive /opt/cortex
  mkdir -p /opt/thp/thehive

  # Minimum placeholder so postinst does not fail
  if [[ ! -f /etc/thehive/application.conf ]]; then
    cat > /etc/thehive/application.conf << 'EOF'
play.http.secret.key="temporary_placeholder_secret"
EOF
  fi

  if [[ ! -f /etc/thehive/logback.xml ]]; then
    cat > /etc/thehive/logback.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <appender name="STDOUT" class="ch.qos.logback.core.ConsoleAppender">
    <encoder>
      <pattern>%date [%level] from %logger in %thread - %message%n%xException</pattern>
    </encoder>
  </appender>
  <root level="INFO">
    <appender-ref ref="STDOUT"/>
  </root>
</configuration>
EOF
  fi

  log_ok "Base directories and placeholder config files prepared."
}

# ---------------------------------------------------------------------------
# SYSTEM DEPENDENCIES
# ---------------------------------------------------------------------------
install_dependencies() {
  log_step "Installing system dependencies..."

  if ! apt-get update; then
    log_warn "apt-get update failed, continuing anyway (check your repos if issues appear)."
  fi

  apt-get install -y \
    curl wget gnupg2 software-properties-common \
    apt-transport-https ca-certificates \
    openjdk-11-jdk haveged \
    python3 python3-pip \
    git tree jq net-tools lsof || true

  log_ok "System dependencies installed."
}

# ---------------------------------------------------------------------------
# ELASTICSEARCH INSTALL (APT + .DEB FALLBACK)
# ---------------------------------------------------------------------------
install_elasticsearch_if_missing() {
  if dpkg -s elasticsearch >/dev/null 2>&1; then
    log_info "Elasticsearch package already installed."
    return 0
  fi

  log_step "Installing Elasticsearch 7.17.29 (package not found)..."

  # Try to ensure Elastic 7.x repo exists (best-effort)
  if ! grep -Rqs "artifacts.elastic.co/packages/7.x/apt" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    log_info "Adding Elastic 7.x APT repository..."
    mkdir -p /usr/share/keyrings
    curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
      | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/7.x/apt stable main" \
      > /etc/apt/sources.list.d/elasticsearch-7.x.list
  else
    log_info "Elastic 7.x APT repository already configured."
  fi

  if ! apt-get update; then
    log_warn "apt-get update returned non-zero when installing Elasticsearch."
  fi

  # 1) Try official APT repo
  if apt-get install -y elasticsearch; then
    if dpkg -s elasticsearch >/dev/null 2>&1; then
      log_ok "Elasticsearch installed from APT repository."
      return 0
    fi
  fi

  log_warn "apt-get install elasticsearch failed or package not found. Falling back to .deb installation..."

  # 2) Fallback to .deb (Aliyun mirror or ES_DEB_URL override)
  local es_deb="elasticsearch-7.17.29-amd64.deb"
  local es_url_default="https://mirrors.aliyun.com/elasticstack/apt/7.x/pool/main/e/elasticsearch/${es_deb}"
  local es_url="${ES_DEB_URL:-$es_url_default}"
  local es_path=""

  if [[ -f "/tmp/${es_deb}" ]]; then
    log_info "Using existing local Elasticsearch package: /tmp/${es_deb}"
    es_path="/tmp/${es_deb}"
  elif [[ -f "${SCRIPT_DIR}/${es_deb}" ]]; then
    log_info "Using existing local Elasticsearch package: ${SCRIPT_DIR}/${es_deb}"
    es_path="${SCRIPT_DIR}/${es_deb}"
  else
    log_info "Downloading Elasticsearch package from: ${es_url}"
    if ! wget -q "${es_url}" -O "/tmp/${es_deb}"; then
      log_error "Failed to download Elasticsearch package from ${es_url}."
      log_error "Place ${es_deb} in /tmp or ${SCRIPT_DIR}, or set ES_DEB_URL to your own mirror."
      exit 1
    fi
    es_path="/tmp/${es_deb}"
  fi

  dpkg -i "${es_path}" || true
  apt-get install -f -y || true

  if dpkg -s elasticsearch >/dev/null 2>&1; then
    log_ok "Elasticsearch 7.17.29 installed via .deb."
  else
    log_error "Elasticsearch installation via .deb failed; please fix manually and re-run (native mode only)."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# CASSANDRA INSTALL
# ---------------------------------------------------------------------------
install_cassandra_if_missing() {
  if dpkg -s cassandra >/dev/null 2>&1; then
    log_info "Cassandra package already installed."
    # از همین‌جا مطمئن می‌شیم اگر قبلاً mask شده، آزادش کنیم
    systemctl unmask cassandra 2>/dev/null || true
    return 0
  fi

  log_step "Installing Cassandra (from configured APT repos)..."

  if ! apt-get update; then
    log_warn "apt-get update failed before Cassandra install."
  fi

  if ! apt-get install -y cassandra; then
    log_error "Cassandra installation failed; please check your APT Cassandra repos."
    exit 1
  fi

  # VERY IMPORTANT: unmask if masked (مثل لاگ خودت)
  systemctl unmask cassandra 2>/dev/null || true

  log_ok "Cassandra package installed."
}

# ---------------------------------------------------------------------------
# ELASTICSEARCH CONFIG
# ---------------------------------------------------------------------------
setup_elasticsearch() {
  log_step "Configuring Elasticsearch 7.17.29..."

  if ! dpkg -s elasticsearch >/dev/null 2>&1; then
    log_error "Elasticsearch package is not installed (setup_elasticsearch)."
    exit 1
  fi

  cat > /etc/elasticsearch/elasticsearch.yml << 'EOF'
cluster.name: thehive-cortex-cluster
node.name: thehive-node-1

path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

network.host: 127.0.0.1
http.port: 9200

discovery.type: single-node

bootstrap.memory_lock: true
xpack.security.enabled: false

thread_pool.write.queue_size: 1000
thread_pool.search.queue_size: 1000
EOF

  if [[ -f /etc/elasticsearch/jvm.options ]]; then
    log_info "Tuning Elasticsearch JVM heap..."
    sed -i 's/^-Xms[0-9]\+[mgMG]/-Xms1g/' /etc/elasticsearch/jvm.options || true
    sed -i 's/^-Xmx[0-9]\+[mgMG]/-Xmx1g/' /etc/elasticsearch/jvm.options || true
  fi

  mkdir -p /var/lib/elasticsearch /var/log/elasticsearch
  chown -R elasticsearch:elasticsearch /var/lib/elasticsearch /var/log/elasticsearch

  systemctl daemon-reload || true
  systemctl enable elasticsearch || true
  systemctl restart elasticsearch || true

  log_info "Waiting for Elasticsearch on http://127.0.0.1:9200 ..."
  local tries=0
  until curl -s http://127.0.0.1:9200 >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [[ $tries -gt 30 ]]; then
      log_warn "Elasticsearch did not become ready in time; check logs."
      break
    fi
    sleep 5
  done

  log_ok "Elasticsearch setup step completed."
}

# ---------------------------------------------------------------------------
# CASSANDRA CONFIG
# ---------------------------------------------------------------------------
setup_cassandra() {
  log_step "Configuring Cassandra (single-node)..."

  if ! dpkg -s cassandra >/dev/null 2>&1; then
    log_error "Cassandra package is not installed (setup_cassandra)."
    exit 1
  fi

  # خیلی مهم: اگر سرویس ماسک شده بود، آزادش کن
  systemctl unmask cassandra 2>/dev/null || true

  systemctl stop cassandra || true

  # Clean directories to avoid cluster_name mismatch
  rm -rf /var/lib/cassandra /var/log/cassandra
  mkdir -p /var/lib/cassandra/data \
           /var/lib/cassandra/commitlog \
           /var/lib/cassandra/saved_caches \
           /var/log/cassandra

  chown -R cassandra:cassandra /var/lib/cassandra /var/log/cassandra

  if [[ -f /etc/cassandra/cassandra.yaml && ! -f /etc/cassandra/cassandra.yaml.orig ]]; then
    cp /etc/cassandra/cassandra.yaml /etc/cassandra/cassandra.yaml.orig
  fi

  cat > /etc/cassandra/cassandra.yaml << 'EOF'
cluster_name: 'TheHive Cluster'

num_tokens: 16
partitioner: org.apache.cassandra.dht.Murmur3Partitioner

listen_address: 127.0.0.1
rpc_address: 127.0.0.1

seed_provider:
  - class_name: org.apache.cassandra.locator.SimpleSeedProvider
    parameters:
      - seeds: "127.0.0.1"

data_file_directories:
  - /var/lib/cassandra/data

commitlog_directory: /var/lib/cassandra/commitlog
saved_caches_directory: /var/lib/cassandra/saved_caches

commitlog_sync: periodic
commitlog_sync_period: 10000ms

authenticator: AllowAllAuthenticator
authorizer: AllowAllAuthorizer

start_native_transport: true
native_transport_port: 9042

endpoint_snitch: SimpleSnitch
EOF

  if [[ -f /etc/cassandra/jvm-server.options ]]; then
    sed -i -E 's/^-Xms[0-9]+[mMgG]/-Xms512M/' /etc/cassandra/jvm-server.options || true
    sed -i -E 's/^-Xmx[0-9]+[mMgG]/-Xmx512M/' /etc/cassandra/jvm-server.options || true
  fi

  systemctl enable cassandra || true
  systemctl start cassandra || true

  log_info "Waiting for Cassandra port 9042..."
  local tries=0
  while ! ss -lntp 2>/dev/null | awk '$4 ~ /:9042$/ {found=1} END{exit !found}'; do
    tries=$((tries + 1))
    if [[ $tries -gt 60 ]]; then
      log_warn "Cassandra port 9042 not detected in time."
      break
    fi
    sleep 2
  done

  log_info "Trying to create 'thehive' keyspace..."
  if cqlsh -e "CREATE KEYSPACE IF NOT EXISTS thehive WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};" >/dev/null 2>&1; then
    log_ok "Keyspace 'thehive' is present."
  else
    log_warn "Could not create 'thehive' keyspace; please check Cassandra logs if needed."
  fi
}

# ---------------------------------------------------------------------------
# THEHIVE INSTALL (NATIVE)
# ---------------------------------------------------------------------------
install_thehive() {
  log_step "Installing TheHive 5.2.16..."

  cd /tmp
  local pkg="thehive_5.2.16-1_all.deb"
  local url_default="https://thehive.download.strangebee.com/5.2/deb/${pkg}"
  local url="${THEHIVE_DEB_URL:-$url_default}"

  if [[ -f "/tmp/${pkg}" ]]; then
    log_info "Using local TheHive package: /tmp/${pkg}"
  else
    log_info "Downloading TheHive from: ${url}"
    if ! wget -q "${url}" -O "${pkg}"; then
      log_error "Failed to download TheHive package from ${url}."
      exit 1
    fi
  fi

  dpkg -i "${pkg}" || true
  apt-get install -f -y || true

  if dpkg -l | grep -qi "^ii\s\+thehive\s\+5.2.16"; then
    log_ok "TheHive 5.2.16 installed."
  else
    log_warn "TheHive installation might have issues; verify with: dpkg -l | grep thehive"
  fi
}

# ---------------------------------------------------------------------------
# CORTEX INSTALL (NATIVE)
# ---------------------------------------------------------------------------
install_cortex() {
  log_step "Installing Cortex 3.1.8..."

  cd /tmp
  local pkg="cortex_3.1.8-1_all.deb"
  local url_default="https://cortex.download.strangebee.com/3.1/deb/${pkg}"
  local url="${CORTEX_DEB_URL:-$url_default}"

  if [[ -f "/tmp/${pkg}" ]]; then
    log_info "Using local Cortex package: /tmp/${pkg}"
  else
    log_info "Downloading Cortex from: ${url}"
    if ! wget -q "${url}" -O "${pkg}"; then
      log_error "Failed to download Cortex package from ${url}."
      exit 1
    fi
  fi

  dpkg -i "${pkg}" || true
  apt-get install -f -y || true

  if dpkg -l | grep -qi "^ii\s\+cortex\s\+3.1.8"; then
    log_ok "Cortex 3.1.8 installed."
  else
    log_warn "Cortex installation might have issues; verify with: dpkg -l | grep cortex"
  fi

  mkdir -p /opt/cortex/data /var/log/cortex
  chown -R cortex:cortex /opt/cortex /var/log/cortex || true
}

# ---------------------------------------------------------------------------
# THEHIVE CONFIG (NATIVE)
# ---------------------------------------------------------------------------
configure_thehive() {
  log_step "Configuring TheHive (native)..."

  mkdir -p /etc/thehive

  cat > /etc/thehive/secret.conf << 'EOF'
# IMPORTANT: Change this in production.
play.http.secret.key="changeme_in_production_make_this_very_long_and_secure_12345"
EOF

  cat > /etc/thehive/application.conf << 'EOF'
include "/etc/thehive/secret.conf"

db.janusgraph {
  storage {
    backend = cql
    hostname = ["127.0.0.1"]
    cql {
      cluster-name = "TheHive Cluster"
      keyspace = "thehive"
      connection-pool {
        max-requests-per-connection = 1024
        local {
          core-connections-per-host = 2
          max-connections-per-host = 4
        }
      }
    }
  }

  index.search {
    backend = elasticsearch
    hostname = ["127.0.0.1"]
    index-name = "thehive"
    elasticsearch {
      client.sniff = false
    }
  }

  cache.db-cache = true
  cache.db-cache-size = 0.3
  cache.db-cache-clean-wait = 50
  cache.tx-cache-size = 20000
}

storage {
  provider = localfs
  localfs.location = "/opt/thp/thehive/files"
  localfs.thumbnail.location = "/opt/thp/thehive/files/thumbnails"
}

play.http.context = "/"
application.baseUrl = "http://0.0.0.0:9000"

play.http.parser.maxDiskBuffer = 2GB
play.http.parser.maxMemoryBuffer = 50M

play.modules.enabled += org.thp.thehive.connector.cortex.CortexModule

cortex {
  servers = [
    {
      name = "local-cortex"
      url = "http://127.0.0.1:9001"

      # auth block will be added later using Cortex API key

      wsConfig {
        timeout.connection = 1 minute
        timeout.idle = 10 minutes
        timeout.request = 5 minutes
        user-agent = "TheHive/5.2.16"
      }
    }
  ]
}

logger.application = INFO
logger.org.thp = INFO
logger.org.janusgraph = WARN
logger.org.apache.cassandra = WARN
logger.org.elasticsearch = WARN

play.filters.headers.contentSecurityPolicy = "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob:"

play.filters.enabled += "play.filters.cors.CORSFilter"
play.filters.cors {
  pathPrefixes = ["/api"]
  allowedOrigins = ["http://localhost:9000", "http://127.0.0.1:9000", "http://0.0.0.0:9000"]
  allowedHttpMethods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
  allowedHttpHeaders = ["Accept", "Content-Type", "Origin", "X-Requested-With", "Authorization"]
  preflightMaxAge = 1 hour
}

play.filters.hosts {
  allowed = ["."]
}

play.server.akka {
  max-header-size = 10m
  request-timeout = 60s
}

application.langs = "en"
EOF

  mkdir -p /opt/thp/thehive/{database,index,files,thumbnails} /var/log/thehive
  chown -R thehive:thehive /opt/thp/thehive /var/log/thehive || true

  log_ok "TheHive configuration written."
}

# ---------------------------------------------------------------------------
# CORTEX CONFIG (NATIVE)
# ---------------------------------------------------------------------------
configure_cortex() {
  log_step "Configuring Cortex (native)..."

  mkdir -p /etc/cortex

  cat > /etc/cortex/application.conf << 'EOF'
play.http.secret.key = "cortex_production_secret_change_this_make_it_long-and-secure_67890"

search {
  host = ["127.0.0.1:9200"]
  index = "cortex_6"
  connection {
    timeout = 30s
    retry = 3
  }
}

http {
  address = "0.0.0.0"
  port = 9001
}

auth {
  basic {
    realm = "Cortex"
  }
}

auth.methods = [
  {name = "basic"}
  {name = "key"}
]

auth.verification {
  secret = "cortex_verification_secret_change_this_12345"
}

analyzer {
  urls = [
    "https://download.thehive-project.org/analyzers.json"
  ]
  fork-join-executor {
    parallelism-min = 4
    parallelism-factor = 2.0
    parallelism-max = 16
  }
  configs = [ ]
}

responder {
  urls = [
    "https://download.thehive-project.org/responders.json"
  ]
  fork-join-executor {
    parallelism-min = 2
    parallelism-factor = 1.0
    parallelism-max = 8
  }
}

play.filters.enabled += "play.filters.cors.CORSFilter"
play.filters.cors {
  pathPrefixes = ["/api"]
  allowedOrigins = ["http://localhost:9000", "http://127.0.0.1:9000", "http://0.0.0.0:9000"]
  allowedHttpMethods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
  allowedHttpHeaders = ["Accept", "Content-Type", "Origin", "X-Requested-With", "Authorization"]
  supportsCredentials = true
  preflightMaxAge = 1 hour
}

play.ws {
  timeout.connection = 30s
  timeout.idle = 5 minutes
  timeout.request = 5 minutes
  useragent = "Cortex/3.1.8"
  ssl {
    loose {
      acceptAnyCertificate = true
    }
  }
}

logger.analyzer = INFO
logger.responder = INFO
logger.cortex = INFO
logger.org.elasticsearch = WARN
logger.com.sksamuel.elastic4s = WARN

cortex.jobs {
  clean-status-timeout = 1 hour
  clean-action-timeout = 7 days
}

docker {
  host = "unix:///var/run/docker.sock"
}
EOF

  cat > /etc/cortex/logback.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <appender name="FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
    <file>/var/log/cortex/application.log</file>
    <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
      <fileNamePattern>/var/log/cortex/application.%d{yyyy-MM-dd}.log</fileNamePattern>
      <maxHistory>30</maxHistory>
      <totalSizeCap>3GB</totalSizeCap>
    </rollingPolicy>
    <encoder>
      <pattern>%date [%level] from %logger in %thread - %message%n%xException</pattern>
    </encoder>
  </appender>

  <appender name="STDOUT" class="ch.qos.logback.core.ConsoleAppender">
    <encoder>
      <pattern>%date [%level] from %logger in %thread - %message%n%xException</pattern>
    </encoder>
  </appender>

  <root level="INFO">
    <appender-ref ref="FILE"/>
    <appender-ref ref="STDOUT"/>
  </root>
</configuration>
EOF

  mkdir -p /var/log/cortex
  chown -R cortex:cortex /var/log/cortex || true

  log_ok "Cortex configuration written."
}

# ---------------------------------------------------------------------------
# SYSTEMD SERVICES (NATIVE)
# ---------------------------------------------------------------------------
setup_systemd_services() {
  log_step "Configuring systemd services for TheHive / Cortex..."

  cat > /etc/systemd/system/thehive.service << 'EOF'
[Unit]
Description=TheHive 5.2.16
Documentation=https://thehive-project.org
After=network.target elasticsearch.service cassandra.service
Wants=elasticsearch.service cassandra.service

[Service]
Type=simple
User=thehive
Group=thehive
WorkingDirectory=/opt/thehive

Environment="JAVA_OPTS=-Xms512m -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
Environment="CONFIG_FILE=/etc/thehive/application.conf"

LimitNOFILE=65536
NoNewPrivileges=yes

ExecStart=/opt/thehive/bin/thehive \
  -Dconfig.file=/etc/thehive/application.conf \
  -Dhttp.address=0.0.0.0 \
  -Dhttp.port=9000 \
  -Dplay.server.pidfile.path=/dev/null \
  -Dlogger.file=/etc/thehive/logback.xml

Restart=on-failure
RestartSec=10s
StartLimitInterval=60s
StartLimitBurst=3

TimeoutStartSec=300
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/cortex.service << 'EOF'
[Unit]
Description=Cortex 3.1.8 - Observable Analysis Engine
Documentation=https://docs.thehive-project.org/cortex/
After=network.target elasticsearch.service
Wants=elasticsearch.service
Requires=elasticsearch.service

[Service]
Type=simple
User=cortex
Group=cortex
WorkingDirectory=/opt/cortex

Environment="JAVA_OPTS=-Xms256m -Xmx512m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -Djava.awt.headless=true"
Environment="CONFIG_FILE=/etc/cortex/application.conf"

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/cortex/data /var/log/cortex

LimitNOFILE=65536
LimitNPROC=4096

ExecStart=/opt/cortex/bin/cortex \
  -Dconfig.file=/etc/cortex/application.conf \
  -Dlogger.file=/etc/cortex/logback.xml \
  -Dpidfile.path=/dev/null \
  -Djava.security.egd=file:/dev/./urandom

StandardOutput=journal
StandardError=journal

Restart=on-failure
RestartSec=10s
StartLimitInterval=60s
StartLimitBurst=3

TimeoutStartSec=300
TimeoutStopSec=30

SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload || true
  log_ok "systemd units created and daemon reloaded."
}

start_services_native() {
  log_step "Starting native services (Elasticsearch, Cassandra, Cortex, TheHive)..."

  systemctl restart elasticsearch || true
  sleep 10

  systemctl restart cassandra || true
  sleep 20

  systemctl enable cortex thehive || true
  systemctl restart cortex || true
  sleep 10

  systemctl restart thehive || true

  log_ok "Start commands issued for native services."
}

wait_for_services_native() {
  log_step "Checking services health (native)..."

  log_info "Checking Elasticsearch..."
  curl -s http://127.0.0.1:9200 >/dev/null 2>&1 \
    && log_ok "Elasticsearch API reachable." \
    || log_warn "Elasticsearch API not reachable (yet)."

  log_info "Checking Cassandra via cqlsh..."
  cqlsh -e "DESCRIBE KEYSPACES" >/dev/null 2>&1 \
    && log_ok "Cassandra responds to cqlsh." \
    || log_warn "Cassandra cqlsh check failed."

  log_info "Checking Cortex..."
  curl -s http://127.0.0.1:9001/api/status >/dev/null 2>&1 \
    && log_ok "Cortex API reachable." \
    || log_warn "Cortex API not reachable."

  log_info "Checking TheHive..."
  curl -s http://127.0.0.1:9000/api/status >/dev/null 2>&1 \
    && log_ok "TheHive API reachable." \
    || log_warn "TheHive API not reachable (may be still starting)."
}

# ---------------------------------------------------------------------------
# DOCKER MODE HELPERS
# ---------------------------------------------------------------------------
ensure_docker_and_compose() {
  log_step "Installing Docker engine and compose (Docker mode)..."

  if ! command -v docker >/dev/null 2>&1; then
    log_info "Docker not found, installing docker.io..."
    apt-get update || true
    apt-get install -y docker.io || {
      log_error "Failed to install docker.io."
      exit 1
    }
  else
    log_info "Docker already installed."
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    log_info "'docker-compose' binary is available."
    DOCKER_COMPOSE_CMD="docker-compose"
  else
    # Try docker compose plugin
    if docker compose version >/dev/null 2>&1; then
      log_info "'docker compose' plugin is available."
      DOCKER_COMPOSE_CMD="docker compose"
    else
      log_info "Installing docker-compose..."
      apt-get install -y docker-compose || {
        log_error "Failed to install docker-compose."
        exit 1
      }
      DOCKER_COMPOSE_CMD="docker-compose"
    fi
  fi
}

write_docker_compose() {
  log_info "Writing docker-compose.yml to /opt/thehive-docker"
  mkdir -p /opt/thehive-docker

  cat > /opt/thehive-docker/docker-compose.yml << 'EOF'
version: "3.8"

services:
  elasticsearch:
    image: "elasticsearch:7.17.9"
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    ulimits:
      memlock:
        soft: -1
        hard: -1
    ports:
      - "19200:9200"
    volumes:
      - esdata_lab:/usr/share/elasticsearch/data

  cassandra:
    image: cassandra:3.11
    environment:
      - MAX_HEAP_SIZE=1024M
      - HEAP_NEWSIZE=256M
      - CASSANDRA_CLUSTER_NAME=TheHive Lab Cluster
    ports:
      - "19042:9042"
    volumes:
      - cassdata_lab:/var/lib/cassandra

  cortex:
    image: thehiveproject/cortex:3.1.8
    depends_on:
      - elasticsearch
    environment:
      - job_directory=/tmp/cortex-jobs
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - cortex-jobs_lab:/tmp/cortex-jobs
      - cortex-logs_lab:/var/log/cortex
    ports:
      - "19001:9001"

  thehive:
    image: strangebee/thehive:5.2.16
    depends_on:
      - elasticsearch
      - cassandra
      - cortex
    environment:
      - JAVA_OPTS=-Xms1g -Xmx2g
      - CLUSTER_NAME=TheHive Lab Cluster
      - CQL_HOSTS=cassandra
      - CQL_KEYSPACE=thehive
      - ES_HOSTS=http://elasticsearch:9200
      - CORTEX_SERVERS_0_NAME=local-cortex
      - CORTEX_SERVERS_0_URL=http://cortex:9001
    ports:
      - "19000:9000"
    volumes:
      - thehive-data_lab:/opt/thp/thehive

volumes:
  esdata_lab:
  cassdata_lab:
  cortex-jobs_lab:
  cortex-logs_lab:
  thehive-data_lab:
EOF
}

deploy_docker_stack() {
  log_step "Deploying Docker stack..."

  cd /opt/thehive-docker

  log_info "Pulling Docker images..."
  if ! ${DOCKER_COMPOSE_CMD} pull; then
    log_warn "compose pull failed; continuing with local images if any."
  fi

  log_info "Starting Docker stack..."
  if ! ${DOCKER_COMPOSE_CMD} up -d; then
    log_error "Failed to start docker-compose stack."
    exit 1
  fi
}

wait_for_services_docker() {
  log_step "Waiting for services to come up (Docker mode)..."

  local host_ip
  host_ip=$(hostname -I | awk '{print $1}')

  log_info "Checking TheHive (Docker) at http://${host_ip}:19000/api/status ..."
  curl -s "http://${host_ip}:19000/api/status" >/dev/null 2>&1 \
    && log_ok "TheHive (Docker) reachable." \
    || log_warn "TheHive (Docker) API not reachable yet."

  log_info "Checking Cortex (Docker) at http://${host_ip}:19001/api/status ..."
  curl -s "http://${host_ip}:19001/api/status" >/dev/null 2>&1 \
    && log_ok "Cortex (Docker) reachable." \
    || log_warn "Cortex (Docker) API not reachable yet."

  log_info "Checking Elasticsearch (Docker) at http://${host_ip}:19200 ..."
  curl -s "http://${host_ip}:19200" >/dev/null 2>&1 \
    && log_ok "Elasticsearch (Docker) reachable." \
    || log_warn "Elasticsearch (Docker) not reachable yet."

  echo ""
  echo "=== THEHIVE & CORTEX DOCKER STACK DEPLOYED ==="
  echo ""
  echo "Access URLs (Docker mode):"
  echo "  TheHive : http://${host_ip}:19000"
  echo "    Default user: admin@thehive.local / secret"
  echo ""
  echo "  Cortex  : http://${host_ip}:19001"
  echo "    Default user: admin / admin"
  echo ""
  echo "Services data stored in Docker volumes:"
  echo "  - esdata_lab"
  echo "  - cassdata_lab"
  echo "  - cortex-jobs_lab"
  echo "  - cortex-logs_lab"
  echo "  - thehive-data_lab"
  echo ""
  echo "To manage the stack:"
  echo "  cd /opt/thehive-docker"
  echo "  ${DOCKER_COMPOSE_CMD} ps           # show status"
  echo "  ${DOCKER_COMPOSE_CMD} logs thehive # see logs"
  echo "  ${DOCKER_COMPOSE_CMD} down         # stop and remove containers"
  echo ""
}

# ---------------------------------------------------------------------------
# HEALTH CHECK SCRIPT (COMMON)
# ---------------------------------------------------------------------------
create_health_check_script() {
  log_step "Creating health check helper script..."

  cat > /usr/local/bin/check-thehive-status << 'EOF'
#!/bin/bash
echo "=== TheHive & Cortex Health Check ==="
echo "Timestamp: $(date)"
echo ""

echo "Service Status (native systemd):"
echo "--------------------------------"
systemctl is-active thehive >/dev/null 2>&1 && echo "✅ TheHive (native): Running" || echo "❌ TheHive (native): Not running"
systemctl is-active cortex  >/dev/null 2>&1 && echo "✅ Cortex (native): Running"  || echo "❌ Cortex (native): Not running"
systemctl is-active elasticsearch >/dev/null 2>&1 && echo "✅ Elasticsearch (native): Running" || echo "❌ Elasticsearch (native): Not running"
systemctl is-active cassandra    >/dev/null 2>&1 && echo "✅ Cassandra (native): Running"    || echo "❌ Cassandra (native): Not running"

echo ""
echo "Docker stack (if present in /opt/thehive-docker):"
echo "-------------------------------------------------"
if [ -d /opt/thehive-docker ]; then
  if command -v docker-compose >/dev/null 2>&1; then
    (cd /opt/thehive-docker && docker-compose ps)
  elif docker compose version >/dev/null 2>&1; then
    (cd /opt/thehive-docker && docker compose ps)
  else
    echo "docker-compose not installed."
  fi
else
  echo "No /opt/thehive-docker directory."
fi

echo ""
echo "API Status (host):"
echo "------------------"
# Native ports
curl -s http://127.0.0.1:9000/api/status >/dev/null 2>&1 && echo "✅ TheHive native:  http://127.0.0.1:9000/api/status" || echo "❌ TheHive native:  not reachable"
curl -s http://127.0.0.1:9001/api/status >/dev/null 2>&1 && echo "✅ Cortex native:   http://127.0.0.1:9001/api/status" || echo "❌ Cortex native:   not reachable"
curl -s http://127.0.0.1:9200            >/dev/null 2>&1 && echo "✅ ES native:       http://127.0.0.1:9200"            || echo "❌ ES native:       not reachable"

# Docker published ports
HOST_IP=$(hostname -I | awk '{print $1}')
curl -s "http://${HOST_IP}:19000/api/status" >/dev/null 2>&1 && echo "✅ TheHive docker:  http://${HOST_IP}:19000/api/status" || echo "❌ TheHive docker:  not reachable"
curl -s "http://${HOST_IP}:19001/api/status" >/dev/null 2>&1 && echo "✅ Cortex docker:   http://${HOST_IP}:19001/api/status" || echo "❌ Cortex docker:   not reachable"
curl -s "http://${HOST_IP}:19200"            >/dev/null 2>&1 && echo "✅ ES docker:       http://${HOST_IP}:19200"            || echo "❌ ES docker:       not reachable"

echo ""
echo "Top processes by memory (java, cassandra, elasticsearch, thehive, cortex):"
echo "-------------------------------------------------------------------------"
ps aux --sort=-%mem | head -n 25 | awk 'NR==1 || /java|cassandra|elasticsearch|thehive|cortex/ {print $1, $2, $4, $11}'

echo ""
echo "Disk Space (/, /opt, /var/lib):"
echo "-------------------------------"
df -h / /opt /var/lib | grep -v tmpfs
EOF

  chmod +x /usr/local/bin/check-thehive-status
  log_ok "Health check script created at /usr/local/bin/check-thehive-status"
}

# ---------------------------------------------------------------------------
# FINAL SUMMARY
# ---------------------------------------------------------------------------
final_summary_native() {
  local ip
  ip=$(hostname -I | awk '{print $1}')

  cat > /root/thehive-installation-summary.txt << EOF
=== THEHIVE & CORTEX NATIVE INSTALLATION SUMMARY ===

Installation Date: $(date)
Mode: Native packages (.deb)

Versions (expected):
  TheHive:  5.2.16
  Cortex:   3.1.8
  Elastic:  7.17.29
  Cassandra: single-node

ACCESS
------
TheHive: http://${ip}:9000
  Default user: admin@thehive.local / secret

Cortex:  http://${ip}:9001
  Default user: admin / admin

KEY FILES
---------
TheHive config : /etc/thehive/application.conf
TheHive secret : /etc/thehive/secret.conf
Cortex config  : /etc/cortex/application.conf
Cortex logback : /etc/cortex/logback.xml

Systemd units  : /etc/systemd/system/thehive.service
                 /etc/systemd/system/cortex.service

Health check   : /usr/local/bin/check-thehive-status

NEXT STEPS
----------
1. Change all default passwords in TheHive and Cortex.
2. Run: check-thehive-status
3. Integrate TheHive with Cortex by adding Cortex API key into:
   /etc/thehive/application.conf (cortex.servers[0].auth)
4. Optionally configure HTTPS reverse proxy (Nginx) in front of ports 9000/9001.
EOF

  log_ok "Installation summary written to /root/thehive-installation-summary.txt"
  echo ""
  cat /root/thehive-installation-summary.txt || true
}

final_summary_docker() {
  log_ok "Docker deployment completed. Use 'check-thehive-status' for a quick check."
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
main() {
  print_banner
  validate_root
  validate_os
  check_system_resources
  choose_deploy_mode
  ensure_no_package_manager_running
  pre_cleanup
  create_health_check_script

  if [[ "${DEPLOY_MODE}" == "native" ]]; then
    log_step "Starting native deployment pipeline..."
    prepare_base_dirs
    install_dependencies
    install_elasticsearch_if_missing
    install_cassandra_if_missing
    setup_elasticsearch
    setup_cassandra
    install_thehive
    install_cortex
    configure_thehive
    configure_cortex
    setup_systemd_services
    start_services_native
    wait_for_services_native
    final_summary_native
  else
    log_step "Starting Docker-based deployment pipeline..."
    install_dependencies
    ensure_docker_and_compose
    write_docker_compose
    deploy_docker_stack
    wait_for_services_docker
    final_summary_docker
  fi

  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║                    DEPLOYMENT COMPLETED                        ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Quick ops:"
  echo "  check-thehive-status"
  echo ""
}

main "$@"
