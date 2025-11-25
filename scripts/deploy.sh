#!/bin/bash
# TheHive & Cortex Ultimate Deployment Script
# Version: 3.0 - Full Reset, Single-Node, Native or Docker
#
# WARNING: THIS SCRIPT IS DESTRUCTIVE ON THIS HOST
# -----------------------------------------------
# It will (in both modes):
#   - Stop TheHive, Cortex, Elasticsearch, Cassandra (if present)
#   - Kill any process listening on ports: 9000, 9001, 9200, 9042
#   - Remove config, data and log directories for:
#       * TheHive
#       * Cortex
#       * Elasticsearch
#       * Cassandra
#
# Use this only on a dedicated lab/PoC/single-node box where these services
# are not shared with other applications.
#
# DEPLOYMENT MODES
# ----------------
#   1) native:
#       - Installs and configures:
#           * TheHive 5.2.16
#           * Cortex 3.1.8
#           * Elasticsearch 7.17.29
#           * Cassandra 3.11/4.x
#       - Creates systemd units, health check and integration helper scripts.
#
#   2) docker:
#       - Installs Docker + docker-compose-plugin (if missing)
#       - Deploys a single-node stack via docker-compose:
#           * TheHive 5.2.x (container)
#           * Cortex 3.1.8 (container)
#           * Elasticsearch 7.17.29 (container)
#           * Cassandra 3.11 (container)
#
# In both cases you end up with TheHive on port 9000 and Cortex on port 9001.

set -euo pipefail

# ---------------------------------------------------------------------------
# COLORS & LOGGING HELPERS
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC}  $1"; }
log_debug()   { echo -e "${BLUE}[DEBUG]${NC} $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
log_step()    { echo -e "${CYAN}[STEP]${NC}  $1"; }

# Global RAM variable (detected in check_system_resources)
RAM_GB=0

# Cassandra credentials are kept for future use when auth is enabled
CASSANDRA_USER="${CASSANDRA_USER:-cassandra}"
CASSANDRA_PASS="${CASSANDRA_PASS:-cassandra}"

# Script directory (used to look for local .deb packages)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Deployment mode: native (packages) or docker (containers)
DEPLOY_MODE="native"

# ---------------------------------------------------------------------------
# BANNER
# ---------------------------------------------------------------------------
print_banner() {
    clear || true
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                                                                ║"
    echo "║           THEHIVE & CORTEX ENTERPRISE DEPLOYMENT              ║"
    echo "║              Version 3.0 - Full Reset (Native/Docker)         ║"
    echo "║                                                                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "This script can deploy on this host:"
    echo "  • TheHive 5.2.16  (native) or 5.2.x (docker image)"
    echo "  • Cortex 3.1.8"
    echo "  • Elasticsearch 7.17.29"
    echo "  • Cassandra 3.11/4.x"
    echo "  • Java 11 (native mode)"
    echo ""
    echo "!!! WARNING: All existing TheHive/Cortex/ES/Cassandra data on this host"
    echo "!!! will be wiped before installation (full reset)."
    echo ""
}

# ---------------------------------------------------------------------------
# DEPLOYMENT MODE SELECTION
# ---------------------------------------------------------------------------
select_deploy_mode() {
    echo
    log_step "Choose deployment mode for TheHive/Cortex on THIS host"
    echo "  1) Native  (OS packages: Elasticsearch, Cassandra, TheHive, Cortex)"
    echo "  2) Docker  (all services as containers via docker compose)"
    read -rp "Enter choice [1/2] (default: 1): " choice

    case "$choice" in
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
# VALIDATION
# ---------------------------------------------------------------------------
validate_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root. Abort."
        exit 1
    fi
    log_ok "Running as root user."
}

validate_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot determine OS distribution (/etc/os-release missing)."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        log_error "This script supports only Ubuntu/Debian. Detected: $PRETTY_NAME"
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
        log_warn "This setup will still work for lab / PoC, but services may be slow."
    fi

    if [[ $cpu_cores -lt 2 ]]; then
        log_warn "Multiple CPU cores recommended for better performance."
    fi
}

# ---------------------------------------------------------------------------
# APT/DPKG LOCK HANDLING
# ---------------------------------------------------------------------------
ensure_no_package_manager_running() {
    log_step "Ensuring no other package manager (apt/dpkg) is running..."

    local attempts=0
    while pgrep -x apt >/dev/null 2>&1 \
       || pgrep -x apt-get >/dev/null 2>&1 \
       || pgrep -x apt-cache >/dev/null 2>&1 \
       || pgrep -x dpkg >/dev/null 2>&1 \
       || pgrep -x unattended-upgrade >/dev/null 2>&1; do

        attempts=$((attempts + 1))
        if [[ $attempts -eq 1 ]]; then
            log_warn "Another apt/dpkg process is currently running. Waiting for it to finish..."
        fi

        if [[ $attempts -gt 30 ]]; then
            log_error "apt/dpkg is still running after several minutes."
            log_error "Please finish or stop any running package operations and re-run this script."
            exit 1
        fi

        sleep 10
    done

    if [[ -f /var/lib/dpkg/lock-frontend ]]; then
        log_warn "dpkg frontend lock file exists but no apt/dpkg processes are running."
        log_warn "If you previously had a crashed apt/dpkg, you may need to clean it manually."
    fi

    log_info "Running 'dpkg --configure -a' to fix any half-configured packages (if any)..."
    if ! dpkg --configure -a >/dev/null 2>&1; then
        log_warn "dpkg --configure -a returned non-zero; continuing anyway."
    fi

    log_ok "Package manager state looks sane enough to continue."
}

# ---------------------------------------------------------------------------
# HARD RESET OF SERVICES, PORTS AND DIRECTORIES (DESTRUCTIVE)
# ---------------------------------------------------------------------------
pre_cleanup() {
    log_step "Stopping services and cleaning previous installation state (DESTRUCTIVE)..."

    # Stop services if they exist
    for svc in thehive cortex elasticsearch cassandra; do
        if systemctl list-unit-files | grep -q "^${svc}.service"; then
            log_info "Stopping service: ${svc}"
            systemctl stop "${svc}" 2>/dev/null || true
        fi
    done

    # Kill any process listening on the known ports
    for port in 9000 9001 9200 9042; do
        local pids
        pids=$(ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print $NF}' \
            | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u || true)
        if [[ -n "${pids:-}" ]]; then
            log_warn "Force-killing processes still listening on port ${port}: ${pids}"
            kill -9 $pids 2>/dev/null || true
        fi
    done

    log_warn "Removing previous TheHive/Cortex/Elasticsearch/Cassandra config, data and logs..."

    # TheHive & Cortex configs, binaries, data, logs
    rm -rf /etc/thehive /etc/cortex
    rm -rf /opt/thehive /opt/thp/thehive /opt/cortex
    rm -rf /var/log/thehive /var/log/cortex

    # Elasticsearch data & logs
    rm -rf /var/lib/elasticsearch/* 2>/dev/null || true
    rm -rf /var/log/elasticsearch/* 2>/dev/null || true

    # Cassandra data & logs (best effort, may be recreated later)
    rm -rf /var/lib/cassandra/data/* 2>/dev/null || true
    rm -rf /var/lib/cassandra/commitlog/* 2>/dev/null || true
    rm -rf /var/lib/cassandra/saved_caches/* 2>/dev/null || true
    rm -rf /var/log/cassandra/* 2>/dev/null || true

    log_ok "Previous installation state removed (full reset)."
}

# ---------------------------------------------------------------------------
# PREPARE BASE DIRECTORIES + PLACEHOLDER CONFIGS (NATIVE MODE)
# ---------------------------------------------------------------------------
prepare_base_dirs() {
    log_step "Preparing base directories and placeholder config files..."

    # Directories used by TheHive & Cortex packages and postinst scripts
    mkdir -p /etc/thehive /etc/cortex
    mkdir -p /var/log/thehive /var/log/cortex
    mkdir -p /opt/thehive /opt/cortex

    # Minimal placeholder config files for TheHive so postinst 'chown' will not fail
    if [[ ! -f /etc/thehive/application.conf ]]; then
        cat > /etc/thehive/application.conf << 'EOF'
# Temporary placeholder TheHive configuration - overwritten by deploy script
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
        <appender-ref ref="STDOUT" />
    </root>
</configuration>
EOF
    fi

    log_ok "Base directories and placeholder config files prepared."
}

# ---------------------------------------------------------------------------
# DEPENDENCIES (BOTH MODES)
# ---------------------------------------------------------------------------
install_dependencies() {
    log_step "Installing system dependencies..."

    if ! apt-get update; then
        log_warn "apt-get update returned non-zero. Check your APT sources if something fails later."
    fi

    apt-get install -y \
        curl \
        wget \
        gnupg2 \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        openjdk-11-jdk \
        haveged \
        python3 \
        python3-pip \
        git \
        tree \
        jq \
        net-tools \
        lsof

    log_ok "System dependencies installed."
}

# ---------------------------------------------------------------------------
# ELASTICSEARCH INSTALL (NATIVE MODE)
# ---------------------------------------------------------------------------
install_elasticsearch_if_missing() {
    if dpkg -s elasticsearch >/dev/null 2>&1; then
        log_info "Elasticsearch package already installed."
        return 0
    fi

    log_step "Installing Elasticsearch 7.17.29 (package not found)..."

    # Add Elastic official APT repo if not already present
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
        log_warn "apt-get update returned non-zero when installing Elasticsearch. Check your APT sources."
    fi

    # First try official apt package
    if apt-get install -y elasticsearch; then
        if dpkg -s elasticsearch >/dev/null 2>&1; then
            log_ok "Elasticsearch package installed from official APT repository."
            return 0
        fi
    fi

    log_warn "apt-get install elasticsearch failed (package not found or repo issue). Will try .deb fallback."

    # Fallback to direct .deb (Aliyun mirror or ES_DEB_URL override)
    log_step "Falling back to direct .deb installation of Elasticsearch 7.17.29..."

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
            log_error "You can place ${es_deb} in /tmp or in ${SCRIPT_DIR}, or set ES_DEB_URL to your own mirror."
            exit 1
        fi
        es_path="/tmp/${es_deb}"
    fi

    dpkg -i "${es_path}" || true
    apt-get install -f -y

    if dpkg -s elasticsearch >/dev/null 2>&1; then
        log_ok "Elasticsearch 7.17.29 installed via .deb."
    else
        log_error "Elasticsearch installation via .deb failed. Please fix manually and re-run this script."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# CASSANDRA INSTALL (NATIVE MODE)
# ---------------------------------------------------------------------------
install_cassandra_if_missing() {
    if dpkg -s cassandra >/dev/null 2>&1; then
        log_info "Cassandra package already installed."
        return 0
    fi

    log_step "Installing Cassandra (3.11/4.x)..."

    if ! apt-get update; then
        log_warn "apt-get update returned non-zero when installing Cassandra. Check your APT sources."
    fi

    apt-get install -y cassandra

    if dpkg -s cassandra >/dev/null 2>&1; then
        log_ok "Cassandra package installed."
        # Stop immediately to avoid first boot with default cluster_name
        systemctl stop cassandra || true
    else
        log_error "Cassandra installation failed. Please install it manually and re-run this script."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# ELASTICSEARCH SETUP (NATIVE MODE)
# ---------------------------------------------------------------------------
setup_elasticsearch() {
    log_step "Configuring Elasticsearch 7.17.29..."

    if ! dpkg -s elasticsearch >/dev/null 2>&1; then
        log_error "Elasticsearch package is NOT installed. Something went wrong earlier."
        exit 1
    fi

    cat > /etc/elasticsearch/elasticsearch.yml << 'EOF'
# ======================== Elasticsearch Configuration =========================
# Single-node configuration optimized for TheHive & Cortex

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
        log_info "Tuning Elasticsearch JVM heap in /etc/elasticsearch/jvm.options ..."
        if [[ $RAM_GB -ge 8 ]]; then
            sed -i 's/^-Xms[0-9]\+g/-Xms2g/' /etc/elasticsearch/jvm.options || true
            sed -i 's/^-Xmx[0-9]\+g/-Xmx2g/' /etc/elasticsearch/jvm.options || true
        else
            sed -i 's/^-Xms[0-9]\+g/-Xms1g/' /etc/elasticsearch/jvm.options || true
            sed -i 's/^-Xmx[0-9]\+g/-Xmx1g/' /etc/elasticsearch/jvm.options || true
        fi
    else
        log_warn "/etc/elasticsearch/jvm.options not found, skipping heap tuning."
    fi

    if ! grep -q "elasticsearch - nofile" /etc/security/limits.conf 2>/dev/null; then
        echo "elasticsearch - nofile 65536" >> /etc/security/limits.conf
    fi
    if ! grep -q "elasticsearch - memlock" /etc/security/limits.conf 2>/dev/null; then
        echo "elasticsearch - memlock unlimited" >> /etc/security/limits.conf
    fi

    mkdir -p /var/lib/elasticsearch /var/log/elasticsearch

    systemctl daemon-reload || true
    systemctl enable elasticsearch || true
    systemctl restart elasticsearch

    log_info "Waiting for Elasticsearch to start (http://127.0.0.1:9200)..."
    local tries=0
    until curl -s http://127.0.0.1:9200 >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [[ $tries -gt 30 ]]; then
            log_error "Elasticsearch did not become ready in time."
            log_error "Check logs with: journalctl -u elasticsearch -n 50 --no-pager"
            exit 1
        fi
        sleep 5
    done

    log_ok "Elasticsearch is up and running."
}

# ---------------------------------------------------------------------------
# CASSANDRA SETUP (NATIVE MODE)
# ---------------------------------------------------------------------------
setup_cassandra() {
    log_step "Configuring Cassandra database..."

    if ! dpkg -s cassandra >/dev/null 2>&1; then
        log_error "Cassandra package is NOT installed. Something went wrong earlier."
        exit 1
    fi

    # Always stop before reconfiguring
    systemctl stop cassandra || true

    # HARD RESET: wipe all Cassandra data & logs so new cluster name is accepted
    log_info "Hard-resetting Cassandra data and logs..."
    rm -rf /var/lib/cassandra/data/* \
           /var/lib/cassandra/commitlog/* \
           /var/lib/cassandra/saved_caches/* \
           /var/log/cassandra/*

    mkdir -p /var/lib/cassandra/data \
             /var/lib/cassandra/commitlog \
             /var/lib/cassandra/saved_caches \
             /var/log/cassandra

    chown -R cassandra:cassandra /var/lib/cassandra /var/log/cassandra

    # Backup original config once
    if [[ -f /etc/cassandra/cassandra.yaml && ! -f /etc/cassandra/cassandra.yaml.orig ]]; then
        cp /etc/cassandra/cassandra.yaml /etc/cassandra/cassandra.yaml.orig
        log_info "Backed up /etc/cassandra/cassandra.yaml to /etc/cassandra/cassandra.yaml.orig"
    fi

    cat > /etc/cassandra/cassandra.yaml << 'EOF'
# Cassandra configuration for a single-node TheHive / Cortex deployment
# Tuned for small lab environments.

cluster_name: 'TheHive Cluster'

partitioner: org.apache.cassandra.dht.Murmur3Partitioner
num_tokens: 16

listen_address: 127.0.0.1
rpc_address: 127.0.0.1

seed_provider:
  - class_name: org.apache.cassandra.locator.SimpleSeedProvider
    parameters:
      - seeds: "127.0.0.1"

commitlog_sync: periodic
commitlog_sync_period: 10000ms

authenticator: AllowAllAuthenticator
authorizer: AllowAllAuthorizer

data_file_directories:
  - /var/lib/cassandra/data

commitlog_directory: /var/lib/cassandra/commitlog
saved_caches_directory: /var/lib/cassandra/saved_caches

hinted_handoff_enabled: true
max_hint_window: 3h

endpoint_snitch: SimpleSnitch

start_native_transport: true
native_transport_port: 9042
EOF

    chown cassandra:cassandra /etc/cassandra/cassandra.yaml

    if [[ -f /etc/cassandra/jvm-server.options ]]; then
        log_info "Tuning Cassandra JVM heap in /etc/cassandra/jvm-server.options ..."
        if [[ $RAM_GB -lt 8 ]]; then
            sed -i -E 's/^-Xms[0-9]+[mMgG]/-Xms512M/' /etc/cassandra/jvm-server.options || true
            sed -i -E 's/^-Xmx[0-9]+[mMgG]/-Xmx512M/' /etc/cassandra/jvm-server.options || true
        else
            sed -i -E 's/^-Xms[0-9]+[mMgG]/-Xms1G/' /etc/cassandra/jvm-server.options || true
            sed -i -E 's/^-Xmx[0-9]+[mMgG]/-Xmx1G/' /etc/cassandra/jvm-server.options || true
        fi
    else
        log_warn "/etc/cassandra/jvm-server.options not found; skipping Cassandra heap tuning."
    fi

    systemctl enable cassandra || true
    systemctl start cassandra || true

    log_info "Waiting for Cassandra native transport (port 9042)..."
    local tries=0
    local port_ok=0
    while [[ $tries -lt 120 ]]; do
        if ss -lntp 2>/dev/null | awk '$4 ~ /:9042$/ {found=1} END{exit !found}'; then
            port_ok=1
            break
        fi
        tries=$((tries + 1))
        sleep 2
    done

    if [[ $port_ok -eq 1 ]]; then
        log_ok "Cassandra is listening on port 9042."
    else
        log_warn "Cassandra native transport on port 9042 was not detected within the timeout window."
        log_warn "It may still be starting slowly or bound to a specific interface. Continuing anyway."
    fi

    log_info "Waiting for Cassandra to respond to cqlsh..."
    tries=0
    local cql_ok=0
    while [[ $tries -lt 60 ]]; do
        if cqlsh -e "DESCRIBE KEYSPACES" >/dev/null 2>&1; then
            cql_ok=1
            log_ok "Cassandra responds to cqlsh."
            break
        fi
        tries=$((tries + 1))
        sleep 4
    done

    if [[ $cql_ok -eq 0 ]]; then
        log_warn "cqlsh could not connect to Cassandra within the timeout window."
        log_warn "Check system logs and /var/log/cassandra/*.log for detailed error messages. Continuing anyway."
    fi

    if cqlsh -e "CREATE KEYSPACE IF NOT EXISTS thehive WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};" >/dev/null 2>&1; then
        log_ok "TheHive keyspace created or already present in Cassandra."
    else
        log_warn "Failed to create or verify 'thehive' keyspace. You may need to create it manually later."
    fi
}

# ---------------------------------------------------------------------------
# THEHIVE INSTALL (NATIVE MODE)
# ---------------------------------------------------------------------------
install_thehive() {
    log_step "Installing TheHive 5.2.16..."

    cd /tmp

    local pkg_name="thehive_5.2.16-1_all.deb"
    local default_url="https://thehive.download.strangebee.com/5.2/deb/${pkg_name}"
    local thehive_url="${THEHIVE_DEB_URL:-$default_url}"

    if [[ -f "/tmp/${pkg_name}" ]]; then
        log_info "Using existing local TheHive package: /tmp/${pkg_name}"
    else
        log_info "Downloading TheHive package from: ${thehive_url}"
        if ! wget -q "${thehive_url}" -O "${pkg_name}"; then
            log_error "Failed to download TheHive package from ${thehive_url}."
            log_error "You can place ${pkg_name} in /tmp or set THEHIVE_DEB_URL to your own mirror."
            exit 1
        fi
    fi

    dpkg -i "${pkg_name}" || true
    apt-get install -f -y

    if dpkg -l | grep -qi "^ii\s\+thehive\s\+5.2.16"; then
        log_ok "TheHive 5.2.16 package installed."
    else
        log_warn "TheHive 5.2.16 package installation may have issues – verify with: dpkg -l | grep thehive"
    fi
}

# ---------------------------------------------------------------------------
# CORTEX INSTALL (NATIVE MODE)
# ---------------------------------------------------------------------------
install_cortex() {
    log_step "Installing Cortex 3.1.8..."

    cd /tmp

    local cortex_deb="cortex_3.1.8-1_all.deb"
    local cortex_url_default="https://cortex.download.strangebee.com/3.1/deb/${cortex_deb}"
    local cortex_url="${CORTEX_DEB_URL:-$cortex_url_default}"

    if [[ -f "/tmp/${cortex_deb}" ]]; then
        log_info "Using existing local Cortex package: /tmp/${cortex_deb}"
    else
        log_info "Downloading Cortex package from: ${cortex_url}"
        if ! wget -q "${cortex_url}" -O "${cortex_deb}"; then
            log_error "Failed to download Cortex package from ${cortex_url}."
            log_error "You can place ${cortex_deb} in /tmp or set CORTEX_DEB_URL to your own mirror."
            exit 1
        fi
    fi

    dpkg -i "${cortex_deb}" || true
    apt-get install -f -y

    if dpkg -l | grep -qi "^ii\s\+cortex\s\+3.1.8"; then
        log_ok "Cortex 3.1.8 package installed."
    else
        log_warn "Cortex 3.1.8 package installation may have issues – verify with: dpkg -l | grep cortex"
    fi

    mkdir -p /opt/cortex/data /var/log/cortex
    chown -R cortex:cortex /opt/cortex /var/log/cortex || true
    log_ok "Cortex directories /opt/cortex and /var/log/cortex prepared."
}

# ---------------------------------------------------------------------------
# CORTEX ANALYZERS REPO (NATIVE MODE)
# ---------------------------------------------------------------------------
install_cortex_analyzers_repo() {
    log_step "Preparing Cortex-Analyzers repository under /opt..."

    if [[ -d /opt/Cortex-Analyzers/.git ]]; then
        log_info "Cortex-Analyzers git repository already present. Updating..."
        (
          cd /opt/Cortex-Analyzers && \
          git pull --rebase --stat >/dev/null 2>&1
        ) || log_warn "Failed to update Cortex-Analyzers repository. Using existing copy."
    elif [[ -d /opt/Cortex-Analyzers ]]; then
        log_warn "Directory /opt/Cortex-Analyzers exists but is not a git repository. Leaving as-is."
    else
        log_info "Cloning Cortex-Analyzers into /opt/Cortex-Analyzers..."
        if ! git clone https://github.com/TheHive-Project/Cortex-Analyzers.git /opt/Cortex-Analyzers >/dev/null 2>&1; then
            log_warn "Failed to clone Cortex-Analyzers from GitHub. Analyzers will not be available unless you provide them manually in /opt/Cortex-Analyzers."
            return 0
        fi
    fi

    chown -R cortex:cortex /opt/Cortex-Analyzers 2>/dev/null || log_warn "Could not chown /opt/Cortex-Analyzers to cortex:cortex. Check permissions manually."
    log_ok "Cortex-Analyzers directory prepared at /opt/Cortex-Analyzers"
}

# ---------------------------------------------------------------------------
# THEHIVE CONFIG (NATIVE MODE)
# ---------------------------------------------------------------------------
configure_thehive() {
    log_step "Configuring TheHive application..."

    mkdir -p /etc/thehive
    cat > /etc/thehive/secret.conf << 'EOF'
# TheHive Secret Configuration
# IMPORTANT:
#   In production, you MUST change this to a long, random string.
#   This key is used to sign session cookies and other secrets.
play.http.secret.key="changeme_in_production_make_this_very_long_and_secure_12345"
EOF

    cat > /etc/thehive/application.conf << 'EOF'
# ============================================================================ #
# TheHive Enterprise Configuration
# Version: 5.2.16
# Description: Production-style configuration for TheHive on a single node
# ============================================================================ #

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

      # auth {
      #   type = "bearer"
      #   key  = "YOUR_CORTEX_API_KEY"
      # }

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

application.global = org.thp.thehive.controllers.TheHive
application.langs = "en"
EOF

    mkdir -p /opt/thp/thehive/{database,index,files,thumbnails} /var/log/thehive
    chown -R thehive:thehive /opt/thp/thehive /var/log/thehive || true

    log_ok "TheHive configuration written."
}

# ---------------------------------------------------------------------------
# CORTEX CONFIG (NATIVE MODE)
# ---------------------------------------------------------------------------
configure_cortex() {
    log_step "Configuring Cortex application..."

    mkdir -p /etc/cortex

    cat > /etc/cortex/application.conf << 'EOF'
# ============================================================================ #
# Cortex Enterprise Configuration
# Version: 3.1.8
# Description: Production-style configuration for Cortex
# ============================================================================ #

play.http.secret.key = "cortex_production_secret_change_this_make_it_long_and_secure_67890"

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
    "/opt/Cortex-Analyzers/analyzers"
  ]

  fork-join-executor {
    parallelism-min = 4
    parallelism-factor = 2.0
    parallelism-max = 16
  }

  configs = [
  ]
}

responder {
  urls = [
    "/opt/Cortex-Analyzers/responders"
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

play.modules.enabled += "play.api.libs.ws.ahc.AhcWSModule"
play.modules.enabled += "play.api.cache.ehcache.EhCacheModule"

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

    <logger name="play" level="INFO"/>
    <logger name="application" level="INFO"/>
    <logger name="analyzer" level="INFO"/>
    <logger name="responder" level="INFO"/>

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
# SYSTEMD SERVICES (NATIVE MODE)
# ---------------------------------------------------------------------------
setup_systemd_services() {
    log_step "Configuring systemd services for TheHive and Cortex..."

    # TheHive systemd service unit
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

Environment="JAVA_OPTS=-Xms1g -Xmx2g -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
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

    # Cortex systemd service unit
    cat > /etc/systemd/system/cortex.service << 'EOF'
[Unit]
Description=Cortex 3.1.8 - Observable Analysis Engine
Documentation=https://docs.thehive-project.org/cortex/
After=network.target elasticsearch.service
Wants=network.target elasticsearch.service
Requires=elasticsearch.service

[Service]
Type=simple
User=cortex
Group=cortex
WorkingDirectory=/opt/cortex

Environment="JAVA_OPTS=-Xms512m -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -Djava.awt.headless=true"
Environment="CONFIG_FILE=/etc/cortex/application.conf"

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/cortex/data /var/log/cortex /opt/Cortex-Analyzers

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

    systemctl daemon-reload
    log_ok "Systemd units created and daemon reloaded."
}

# ---------------------------------------------------------------------------
# SERVICE START & HEALTH (NATIVE MODE)
# ---------------------------------------------------------------------------
start_services() {
    log_step "Starting all services..."

    log_info "Starting Elasticsearch..."
    systemctl restart elasticsearch || {
        log_error "Failed to start Elasticsearch."
        exit 1
    }
    sleep 10

    log_info "Starting Cassandra..."
    systemctl restart cassandra || {
        log_error "Failed to start Cassandra."
        exit 1
    }
    sleep 15

    log_info "Starting Cortex..."
    systemctl enable cortex || true
    systemctl restart cortex || {
        log_error "Failed to start Cortex. Check: journalctl -u cortex -n 50 --no-pager"
        exit 1
    }
    sleep 10

    log_info "Starting TheHive..."
    systemctl enable thehive || true
    systemctl restart thehive || {
        log_error "Failed to start TheHive. Check: journalctl -u thehive -n 50 --no-pager"
        exit 1
    }

    log_ok "Start commands issued for all services."
}

wait_for_services() {
    log_step "Checking services health..."

    log_info "Checking Elasticsearch..."
    if curl -s http://127.0.0.1:9200 >/dev/null 2>&1; then
        log_ok "Elasticsearch HTTP is reachable."
    else
        log_warn "Elasticsearch HTTP is NOT reachable. Check: journalctl -u elasticsearch -n 50 --no-pager"
    fi

    log_info "Checking Cassandra via cqlsh..."
    if cqlsh -e "DESCRIBE KEYSPACES" >/dev/null 2>&1; then
        log_ok "Cassandra responds to cqlsh."
    else
        log_warn "Cassandra cqlsh check failed. Check: journalctl -u cassandra -n 50 --no-pager and /var/log/cassandra/*.log"
    fi

    log_info "Checking Cortex API..."
    if curl -s http://127.0.0.1:9001/api/status >/dev/null 2>&1; then
        log_ok "Cortex API is reachable."
    else
        log_warn "Cortex API not reachable at /api/status. Check: journalctl -u cortex -n 50 --no-pager"
    fi

    log_info "Checking TheHive API..."
    if curl -s http://127.0.0.1:9000/api/status >/dev/null 2>&1; then
        log_ok "TheHive API is reachable."
    else
        log_warn "TheHive API not reachable at /api/status yet. TheHive may still be initializing data."
        log_warn "If it stays like this, check: journalctl -u thehive -n 50 --no-pager"
    fi
}

# ---------------------------------------------------------------------------
# DOCKER-BASED STACK (TheHive + Cortex + ES + Cassandra)
# ---------------------------------------------------------------------------
install_docker_stack() {
    log_step "Installing Docker engine and deploying TheHive/Cortex stack (Docker mode)..."

    # Install Docker if missing
    if ! command -v docker >/dev/null 2>&1; then
        log_info "Docker not found, installing docker.io and docker-compose-plugin..."
        apt-get update || log_warn "apt-get update failed, continuing anyway..."
        apt-get install -y docker.io docker-compose-plugin
        systemctl enable docker || true
        systemctl start docker || true
    else
        log_info "Docker already installed."
    fi

    # Tune vm.max_map_count for Elasticsearch inside container
    if ! sysctl vm.max_map_count >/dev/null 2>&1 || \
       [ "$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)" -lt 262144 ]; then
        log_info "Setting vm.max_map_count=262144 for Elasticsearch (Docker)..."
        sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true
        if ! grep -q "vm.max_map_count" /etc/sysctl.conf 2>/dev/null; then
            echo "vm.max_map_count=262144" >> /etc/sysctl.conf
        fi
    fi

    local STACK_DIR="/opt/thehive-docker"
    mkdir -p "${STACK_DIR}"
    cd "${STACK_DIR}"

    log_info "Writing docker-compose.yml to ${STACK_DIR}"

    cat > docker-compose.yml << 'EOF'
version: "3.8"

services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:7.17.29
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    ulimits:
      memlock:
        soft: -1
        hard: -1
    ports:
      - "9200:9200"
    volumes:
      - esdata:/usr/share/elasticsearch/data

  cassandra:
    image: cassandra:3.11
    environment:
      - MAX_HEAP_SIZE=1024M
      - HEAP_NEWSIZE=256M
      - CASSANDRA_CLUSTER_NAME=TheHive Cluster
    ports:
      - "9042:9042"
    volumes:
      - cassdata:/var/lib/cassandra

  cortex:
    image: thehiveproject/cortex:3.1.8
    depends_on:
      - elasticsearch
    environment:
      - job_directory=/tmp/cortex-jobs
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - cortex-jobs:/tmp/cortex-jobs
      - cortex-logs:/var/log/cortex
    ports:
      - "9001:9001"

  thehive:
    image: strangebee/thehive:5.2.16
    depends_on:
      - elasticsearch
      - cassandra
      - cortex
    environment:
      - JAVA_OPTS=-Xms1g -Xmx2g
      - CLUSTER_NAME=TheHive Cluster
      - CQL_HOSTS=cassandra
      - CQL_KEYSPACE=thehive
      - ES_HOSTS=http://elasticsearch:9200
      - CORTEX_SERVERS_0_NAME=local-cortex
      - CORTEX_SERVERS_0_URL=http://cortex:9001
    ports:
      - "9000:9000"
    volumes:
      - thehive-data:/opt/thp/thehive

volumes:
  esdata:
  cassdata:
  cortex-jobs:
  cortex-logs:
  thehive-data:
EOF

    log_info "Pulling Docker images..."
    docker compose pull || log_warn "docker compose pull failed, continuing..."

    log_info "Starting Docker stack..."
    docker compose up -d

    log_info "Waiting for TheHive (Docker) to respond on http://127.0.0.1:9000/api/status ..."
    local tries=0
    while ! curl -s http://127.0.0.1:9000/api/status >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [[ $tries -gt 60 ]]; then
            log_warn "TheHive in Docker did not become ready within timeout."
            log_warn "Check logs with: cd ${STACK_DIR} && docker compose logs thehive"
            break
        fi
        sleep 5
    done

    log_ok "Docker-based TheHive/Cortex stack started."
    log_info "Check status with:"
    log_info "  cd ${STACK_DIR} && docker compose ps"
}

# ---------------------------------------------------------------------------
# INTEGRATION SCRIPT (NATIVE MODE)
# ---------------------------------------------------------------------------
create_integration_script() {
    log_step "Creating Cortex-TheHive integration helper script..."

    cat > /root/configure-integration.sh << 'EOF'
#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[FAIL]${NC}  $1"; }

CORTEX_URL="http://127.0.0.1:9001"
THEHIVE_URL="http://127.0.0.1:9000"

check_services() {
    log_info "Checking service accessibility..."

    if ! curl -s "${CORTEX_URL}/api/status" >/dev/null; then
        log_error "Cortex is not accessible at ${CORTEX_URL}"
        return 1
    fi

    if ! curl -s "${THEHIVE_URL}/api/status" >/dev/null; then
        log_error "TheHive is not accessible at ${THEHIVE_URL}"
        return 1
    fi

    log_info "Both services are accessible."
    return 0
}

create_cortex_user() {
    log_info "Manual step: create integration user in Cortex UI."

    echo ""
    echo "Steps:"
    echo "1. Open http://$(hostname -I | awk '{print $1}'):9001"
    echo "2. Login with: admin / admin"
    echo "3. Go to 'Organization' → 'Users'"
    echo "4. Click 'Add User'"
    echo "5. Create a user:"
    echo "   - Login: thehive-integration"
    echo "   - Name:  TheHive Integration User"
    echo "   - Roles: orgAdmin, read, analyze"
    echo "6. Save and generate an API key for this user."
    echo "7. Copy the API key for the next step."
    echo ""
    read -rp "Press Enter when you have the Cortex API key..." _
}

configure_thehive_connector() {
    log_info "Configuring TheHive Cortex connector..."

    echo ""
    read -rp "Enter the Cortex API key: " API_KEY

    if [[ -z "$API_KEY" ]]; then
        log_error "No API key provided."
        return 1
    fi

    cp /etc/thehive/application.conf "/etc/thehive/application.conf.backup.$(date +%Y%m%d_%H%M%S)"

    sed -i "/name = \"local-cortex\"/,/wsConfig/ {
        /url = \"http:\/\/127.0.0.1:9001\"/ a\\
      auth {\\
        type = \"bearer\"\\
        key = \"${API_KEY}\"\\
      }
    }" /etc/thehive/application.conf

    systemctl restart thehive

    log_info "Waiting for TheHive to restart..."
    sleep 10

    until curl -s "${THEHIVE_URL}/api/status" >/dev/null; do
        sleep 5
    done

    log_info "TheHive configuration updated and restarted."
}

test_integration() {
    log_info "Testing Cortex-TheHive integration..."

    if curl -s "${THEHIVE_URL}/api/connector/cortex/analyzer" | grep -q "name"; then
        log_info "✅ Integration successful! Cortex analyzers are accessible from TheHive."
    else
        log_warn "⚠ Integration may need additional configuration."
        log_warn "Check TheHive UI: Administration → Connectors → Cortex."
    fi
}

main() {
    log_info "Starting Cortex-TheHive integration process..."

    if check_services; then
        create_cortex_user
        configure_thehive_connector
        test_integration
    fi

    log_info "Integration process completed."
    echo ""
    echo "Next steps:"
    echo "1. Access TheHive: http://$(hostname -I | awk '{print $1}'):9000"
    echo "2. Login with: admin@thehive.local / secret"
    echo "3. Go to Administration → Connectors → Cortex"
    echo "4. Verify the Cortex server is connected."
    echo "5. Create a test case and run some analyzers."
}

main "$@"
EOF

    chmod +x /root/configure-integration.sh
    log_ok "Integration script created at /root/configure-integration.sh"
}

# ---------------------------------------------------------------------------
# HEALTH CHECK SCRIPT (NATIVE MODE)
# ---------------------------------------------------------------------------
create_health_check() {
    log_step "Creating health check helper script..."

    cat > /usr/local/bin/check-thehive-status << 'EOF'
#!/bin/bash
echo "=== TheHive & Cortex Health Check ==="
echo "Timestamp: $(date)"
echo ""

echo "Service Status:"
echo "---------------"
systemctl is-active thehive >/dev/null 2>&1 && echo "✅ TheHive: Running" || echo "❌ TheHive: Not running"
systemctl is-active cortex  >/dev/null 2>&1 && echo "✅ Cortex: Running"  || echo "❌ Cortex: Not running"
systemctl is-active elasticsearch >/dev/null 2>&1 && echo "✅ Elasticsearch: Running" || echo "❌ Elasticsearch: Not running"
systemctl is-active cassandra    >/dev/null 2>&1 && echo "✅ Cassandra: Running"    || echo "❌ Cassandra: Not running"

echo ""
echo "API Status:"
echo "-----------"
curl -s http://127.0.0.1:9000/api/status >/dev/null && echo "✅ TheHive API: Accessible" || echo "❌ TheHive API: Not accessible"
curl -s http://127.0.0.1:9001/api/status >/dev/null && echo "✅ Cortex API: Accessible"  || echo "❌ Cortex API: Not accessible"
curl -s http://127.0.0.1:9200           >/dev/null && echo "✅ Elasticsearch API: Accessible" || echo "❌ Elasticsearch API: Not accessible"

echo ""
echo "Top processes by memory:"
echo "------------------------"
ps aux --sort=-%mem | head -n 15 | awk 'NR==1 || /java|cassandra|elasticsearch|thehive|cortex/ {print $1, $2, $4, $11}'

echo ""
echo "Disk Space (/, /opt, /var/lib):"
echo "-------------------------------"
df -h / /opt /var/lib | grep -v tmpfs

echo ""
echo "Recent errors from TheHive and Cortex (last 10 lines each):"
echo "-----------------------------------------------------------"
journalctl -u thehive --since "1 hour ago" | grep -i error | tail -10 || echo "No recent TheHive errors."
journalctl -u cortex  --since "1 hour ago" | grep -i error | tail -10 || echo "No recent Cortex errors."
EOF

    chmod +x /usr/local/bin/check-thehive-status
    log_ok "Health check script created at /usr/local/bin/check-thehive-status"
}

# ---------------------------------------------------------------------------
# FINAL SUMMARY (NATIVE MODE)
# ---------------------------------------------------------------------------
finalize_installation() {
    log_step "Writing installation summary (native mode)..."

    cat > /root/thehive-installation-summary.txt << EOF
=== THEHIVE & CORTEX INSTALLATION SUMMARY (NATIVE MODE) ===

Installation Date: $(date)
TheHive Version: 5.2.16
Cortex Version: 3.1.8
Elasticsearch: 7.17.29 (single-node)
Cassandra: 3.11/4.x (single-node config, auth = AllowAllAuthenticator)

ACCESS INFORMATION
------------------
TheHive URL : http://$(hostname -I | awk '{print $1}'):9000
Default user: admin@thehive.local / secret

Cortex URL  : http://$(hostname -I | awk '{print $1}'):9001
Default user: admin / admin

IMPORTANT FILES
---------------
TheHive config : /etc/thehive/application.conf
TheHive secret : /etc/thehive/secret.conf
Cortex config  : /etc/cortex/application.conf
Cortex logback : /etc/cortex/logback.xml
TheHive unit   : /etc/systemd/system/thehive.service
Cortex unit    : /etc/systemd/system/cortex.service

HELPER SCRIPTS
--------------
Integration script : /root/configure-integration.sh
Health check       : /usr/local/bin/check-thehive-status

NEXT STEPS
----------
1. Run the integration script to link TheHive and Cortex:
   sudo /root/configure-integration.sh

2. Check overall status:
   check-thehive-status

3. Change all default passwords in TheHive and Cortex.

4. Configure firewall (if needed):
   ufw allow 9000/tcp  # TheHive
   ufw allow 9001/tcp  # Cortex

5. Configure regular backups for:
   - /opt/thp/thehive
   - /opt/cortex (if you store data there)
   - Elasticsearch and Cassandra data directories

6. If you later enable Cassandra authentication (PasswordAuthenticator),
   remember to:
   - Create a dedicated DB user for TheHive
   - Update db.janusgraph.storage.cql.username/password in
     /etc/thehive/application.conf
   - Update any cqlsh commands or scripts to use the new credentials.

EOF

    log_ok "Installation summary written to /root/thehive-installation-summary.txt"
    echo ""
    cat /root/thehive-installation-summary.txt
}

# ---------------------------------------------------------------------------
# FINAL SUMMARY (DOCKER MODE)
# ---------------------------------------------------------------------------
finalize_installation_docker() {
    log_step "Writing installation summary (Docker mode)..."

    cat > /root/thehive-installation-summary.txt << EOF
=== THEHIVE & CORTEX INSTALLATION SUMMARY (DOCKER MODE) ===

Installation Date: $(date)
Deployment mode : docker (all services in containers)
Stack directory : /opt/thehive-docker

Container endpoints on this host:
  TheHive   : http://$(hostname -I | awk '{print $1}'):9000
  Cortex    : http://$(hostname -I | awk '{print $1}'):9001
  Elastic   : http://$(hostname -I | awk '{print $1}'):9200
  Cassandra : tcp/9042

Check status:
  cd /opt/thehive-docker
  docker compose ps
  docker compose logs thehive
  docker compose logs cortex

Default credentials:
  TheHive : admin@thehive.local / secret   (first login, then change)
  Cortex  : admin / admin                  (first login, then change)

EOF

    log_ok "Installation summary written to /root/thehive-installation-summary.txt"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
main() {
    print_banner
    validate_root
    validate_os
    check_system_resources
    select_deploy_mode
    ensure_no_package_manager_running
    pre_cleanup

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        log_step "Starting Docker-based deployment pipeline..."

        # Docker mode: no native ES/Cassandra/TheHive/Cortex packages
        install_dependencies
        install_docker_stack
        finalize_installation_docker

    else
        log_step "Starting native (package-based) deployment pipeline..."

        prepare_base_dirs
        install_dependencies
        install_elasticsearch_if_missing
        install_cassandra_if_missing
        setup_elasticsearch
        setup_cassandra
        install_thehive
        install_cortex
        install_cortex_analyzers_repo
        configure_thehive
        configure_cortex
        setup_systemd_services
        start_services
        wait_for_services
        create_integration_script
        create_health_check
        finalize_installation
    fi

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                    DEPLOYMENT COMPLETED                        ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        echo "Quick start (Docker mode):"
        echo "  TheHive: http://$(hostname -I | awk '{print $1}'):9000"
        echo "  Cortex : http://$(hostname -I | awk '{print $1}'):9001"
        echo ""
    else
        echo "Quick start (native mode):"
        echo "  1) Run:  sudo /root/configure-integration.sh"
        echo "  2) Check: check-thehive-status"
        echo "  3) TheHive: http://$(hostname -I | awk '{print $1}'):9000"
        echo "  4) Cortex : http://$(hostname -I | awk '{print $1}'):9001"
        echo ""
    fi

    echo "Installation details saved to: /root/thehive-installation-summary.txt"
}

main "$@"
