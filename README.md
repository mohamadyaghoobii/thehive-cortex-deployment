# TheHive & Cortex Enterprise Deployment Platform

![Platform](https://img.shields.io/badge/Platform-SOC%20Incident%20Response-blue)
![Version](https://img.shields.io/badge/Version-2.5--Enterprise-green)
![Stack](https://img.shields.io/badge/Stack-TheHive%205.2.16%20%7C%20Cortex%203.1.8%20%7C%20ES%207.17.29%20%7C%20Cassandra%204.1.x-purple)
![License](https://img.shields.io/badge/License-MIT-orange)

A deployment blueprint for **TheHive 5.2.16** and **Cortex 3.1.8** designed for Security Operations Centers (SOC).  
This environment supports incident response, automated enrichment, collaboration, and large-scale case management.

You can deploy the platform in **two ways**:

1. **Automated deployment** using `deploy.sh` (with **Native** or **Docker** mode)  
2. **Manual installation** (fully documented step-by-step)  
3. Optional **Splunk integration** using `setup_thehive.sh`

---

## 📚 Table of Contents

1. [Architecture Overview](#-architecture-overview)  
2. [Installed Components](#-installed-components)  
3. [Requirements](#-requirements)  
4. [Option A – Automated Deployment](#-option-a--automated-deployment-deploysh)  
   - [Deployment Modes (Native vs Docker)](#deployment-modes-native-vs-docker)  
5. [Option B – Manual Deployment](#-option-b--manual-deployment-step-by-step)  
   - [1. System Preparation](#1-system-preparation)  
   - [2. Install Elasticsearch 71729](#2-install-elasticsearch-71729)  
   - [3. Install Cassandra 41x](#3-install-cassandra-41x)  
   - [4. Install TheHive-5216](#4-install-thehive-5216)  
   - [5. Install Cortex-318](#5-install-cortex-318)  
   - [6. Configure TheHive](#6-configure-thehive)  
   - [7. Configure Cortex](#7-configure-cortex)  
   - [8. Create systemd Units](#8-create-systemd-units-for-thehive-and-cortex)  
   - [9. Initial Access & Credentials](#9-initial-access--default-credentials)  
   - [10. Connect TheHive & Cortex](#10-connect-thehive-and-cortex-api-key-integration)  
6. [Health Checks](#-health-checks)  
7. [Key Directories](#-key-directories)  
8. [Production Recommendations](#-production-recommendations)  
9. [Optional: Splunk Integration (setup_thehive.sh)](#-optional-splunk-integration-setup_thehivesh)  
10. [License](#-license)

---

## 🏗️ Architecture Overview

This deployment consists of four core services (plus optional reverse proxy):

### 1. TheHive (Port 9000)
- Incident Response platform (cases, alerts, tasks, observables, workflows, collaboration)
- Stores graph data in **Cassandra** and uses **Elasticsearch** for search and indexing.

### 2. Cortex (Port 9001)
- Analysis & response engine for observables and automated actions.
- TheHive talks to Cortex via REST API and uses an **API key** for authentication.

### 3. Cassandra (Port 9042)
- Distributed NoSQL database for TheHive case data, observables, and metadata.
- Single-node lab configuration (no authentication, `AllowAllAuthenticator`).

### 4. Elasticsearch (Port 9200)
- Search and analytics engine used by both TheHive and Cortex.
- Version **7.17.29** (last 7.x LTS line) for TheHive 5.x compatibility.

### 5. Nginx Reverse Proxy (Optional, 80/443)
- Optional component for:
  - HTTPS termination
  - Publishing TheHive/Cortex securely (TLS, WAF, etc.)
  - Centralized access control

---

## 📦 Installed Components

| Component       | Version   | Purpose                      | Port |
|----------------|-----------|------------------------------|------|
| TheHive        | 5.2.16    | Incident Response Platform   | 9000 |
| Cortex         | 3.1.8     | Analysis Engine              | 9001 |
| Elasticsearch  | 7.17.29   | Search & Analytics           | 9200 |
| Cassandra      | 4.1.x     | Distributed Database         | 9042 |
| Java (OpenJDK) | 11        | Runtime Environment          | –    |

> **Note:** In Docker mode the internal service ports remain the same, but are mapped to different host ports (see Docker section below).

---

## 📋 Requirements

- **OS:** Ubuntu 20.04 / 22.04 (recommended) or Debian 11 / 12  
- **RAM:** 8 GB minimum (3–4 GB is OK for lab/PoC only)  
- **CPU:** 4 vCPUs recommended  
- **Disk:** 50 GB+ (more for production)  
- **Network:**
  - Outbound internet access (for packages/analyzers) or local mirrors
  - Inbound access to ports: `9000` (TheHive), `9001` (Cortex), optionally `443` (Nginx)  
    - Or their mapped Docker host ports in Docker mode (`19000`, `19001`, `19200`, `19042`)

---

## 🚀 Option A – Automated Deployment (`deploy.sh`)

> Use this if you trust and maintain the script in your own repository.

### Download and run the deployment script

```bash
wget -O deploy.sh https://raw.githubusercontent.com/mohamadyaghoobii/thehive-cortex-deploy/master/deploy.sh
chmod +x deploy.sh
sudo ./deploy.sh
```

The script will:

- Stop and clean any existing TheHive/Cortex/ES/Cassandra data on the host  
- Install (in **Native** mode):
  - Elasticsearch **7.17.29** (using `.deb`, e.g. Aliyun mirror in restricted networks)
  - Cassandra **4.1.x**
  - TheHive **5.2.16**
  - Cortex **3.1.8**
- Or deploy (in **Docker** mode):
  - A full containerized stack (Elasticsearch, Cassandra, Cortex, TheHive) using `docker-compose`
- Configure services (systemd in Native mode, Docker stack in Docker mode)
- Start all components
- (Optionally) create helper scripts such as:
  - `configure-integration.sh` – for TheHive ↔ Cortex API integration
  - `check-thehive-status` – basic health check for Native mode

If you prefer not to rely on scripts at all, follow **Option B – Manual Deployment** below.

### Deployment Modes (Native vs Docker)

When you run `deploy.sh`, it will first detect your OS/resources, then ask how you want to deploy:

```text
[STEP]  Choose deployment mode for TheHive/Cortex on THIS host
  1) Native  (OS packages: Elasticsearch, Cassandra, TheHive, Cortex)
  2) Docker  (all services as containers via docker compose)
Enter choice [1/2] (default: 1):
```

- **Option 1 – Native**
  - Installs packages directly on the host (Elasticsearch, Cassandra, TheHive, Cortex).
  - Uses `systemd` services:
    - `elasticsearch`, `cassandra`, `cortex`, `thehive`
  - Uses the **manual configuration paths** documented later in this README:
    - `/etc/thehive/application.conf`
    - `/etc/cortex/application.conf`
    - etc.

- **Option 2 – Docker**
  - Uses Docker and `docker-compose` to deploy everything under `/opt/thehive-docker`.
  - Generates `docker-compose.yml` similar to:

    ```yaml
    version: "3.8"

    services:
      elasticsearch:
        image: "elasticsearch:7.17.9"
        ports:
          - "19200:9200"

      cassandra:
        image: cassandra:3.11
        ports:
          - "19042:9042"

      cortex:
        image: thehiveproject/cortex:3.1.8
        ports:
          - "19001:9001"

      thehive:
        image: strangebee/thehive:5.2.16
        ports:
          - "19000:9000"

    volumes:
      esdata_lab:
      cassdata_lab:
      cortex-jobs_lab:
      cortex-logs_lab:
      thehive-data_lab:
    ```

  - Resulting **access URLs** (Docker mode):

    | Service    | URL                              | Notes                         |
    |-----------|-----------------------------------|-------------------------------|
    | TheHive   | `http://<server-ip>:19000`       | admin@thehive.local / secret |
    | Cortex    | `http://<server-ip>:19001`       | admin / admin                |
    | ES (HTTP) | `http://<server-ip>:19200`       | Elasticsearch API            |
    | Cassandra | `tcp://<server-ip>:19042`        | CQL native transport         |

  - To manage the Docker stack:

    ```bash
    cd /opt/thehive-docker

    # See running containers
    docker compose ps        # or: docker-compose ps

    # View logs
    docker compose logs thehive
    docker compose logs cortex

    # Stop and remove stack
    docker compose down
    ```

In **Docker mode**, TheHive ↔ Cortex integration is still configured via the **UIs**:

- Cortex: create an `orgAdmin` user and generate an API key  
- TheHive: Administration → Connectors → Cortex → edit `local-cortex` and paste the API key

In **Native mode**, you can either use the UI or add the API key directly to `/etc/thehive/application.conf` as described in  
[10. Connect TheHive & Cortex](#10-connect-thehive-and-cortex-api-key-integration).

---

## 🧩 Option B – Manual Deployment (Step-by-Step)

This section describes how to install and configure **everything manually**, without relying on `deploy.sh`.  
Use this as a reference document for audits, manual rebuilds, or environments where scripts are restricted.

> **Important:** All commands assume you are running as `root` (or via `sudo -i`).

---

### 1. System Preparation

```bash
sudo -i

apt-get update
apt-get upgrade -y

apt-get install -y \
  curl wget gnupg2 software-properties-common \
  apt-transport-https ca-certificates \
  openjdk-11-jdk haveged \
  python3 python3-pip \
  git tree jq net-tools lsof
```

Optional: verify resources:

```bash
free -h
df -h /
nproc
```

---

### 2. Install Elasticsearch 7.17.29

#### 2.1. Download Elasticsearch `.deb`

If `artifacts.elastic.co` is blocked, use a trusted mirror (example: Aliyun):

```bash
cd /tmp
wget https://mirrors.aliyun.com/elasticstack/apt/7.x/pool/main/e/elasticsearch/elasticsearch-7.17.29-amd64.deb
```

#### 2.2. Install the package

```bash
cd /tmp
dpkg -i elasticsearch-7.17.29-amd64.deb || true
apt-get install -f -y

dpkg -l | grep elasticsearch
```

#### 2.3. Configure `elasticsearch.yml`

```bash
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
```

#### 2.4. Tune JVM heap (lab mode)

```bash
if [ -f /etc/elasticsearch/jvm.options ]; then
  sed -i 's/^-Xms[0-9]\+[mgMG]/-Xms1g/' /etc/elasticsearch/jvm.options
  sed -i 's/^-Xmx[0-9]\+[mgMG]/-Xmx1g/' /etc/elasticsearch/jvm.options
fi
```

#### 2.5. Permissions and service start

```bash
mkdir -p /var/lib/elasticsearch /var/log/elasticsearch
chown -R elasticsearch:elasticsearch /var/lib/elasticsearch /var/log/elasticsearch

systemctl daemon-reload
systemctl enable elasticsearch
systemctl start elasticsearch
```

Test:

```bash
curl -s http://127.0.0.1:9200 | jq . || curl -s http://127.0.0.1:9200
```

---

### 3. Install Cassandra 4.1.x

Assuming official Cassandra APT repos are already configured (e.g. `apache.jfrog.io`).

#### 3.1. Install the package

```bash
apt-get update
apt-get install -y cassandra
```

#### 3.2. Configure single-node `/etc/cassandra/cassandra.yaml`

```bash
systemctl stop cassandra || true

if [ -f /etc/cassandra/cassandra.yaml ] && [ ! -f /etc/cassandra/cassandra.yaml.orig ]; then
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
```

#### 3.3. Tune Cassandra heap

```bash
if [ -f /etc/cassandra/jvm-server.options ]; then
  sed -i -E 's/^-Xms[0-9]+[mMgG]/-Xms512M/' /etc/cassandra/jvm-server.options
  sed -i -E 's/^-Xmx[0-9]+[mMgG]/-Xmx512M/' /etc/cassandra/jvm-server.options
fi
```

#### 3.4. Directories and permissions

```bash
mkdir -p /var/lib/cassandra/data /var/lib/cassandra/commitlog /var/lib/cassandra/saved_caches /var/log/cassandra
chown -R cassandra:cassandra /var/lib/cassandra /var/log/cassandra
```

#### 3.5. Start and validate

```bash
systemctl enable cassandra || true
systemctl start cassandra

ss -lntp | grep 9042 || echo "Cassandra not listening on 9042 yet"
journalctl -u cassandra -n 50 --no-pager
```

#### 3.6. Create `thehive` keyspace

```bash
cqlsh -e "CREATE KEYSPACE IF NOT EXISTS thehive WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};"
```

---

### 4. Install TheHive 5.2.16

#### 4.1. Download deb

```bash
cd /tmp
wget https://thehive.download.strangebee.com/5.2/deb/thehive_5.2.16-1_all.deb
```

#### 4.2. Install deb

```bash
dpkg -i thehive_5.2.16-1_all.deb || true
apt-get install -f -y

dpkg -l | grep thehive
```

---

### 5. Install Cortex 3.1.8

#### 5.1. Download deb

```bash
cd /tmp
wget https://cortex.download.strangebee.com/3.1/deb/cortex_3.1.8-1_all.deb
```

#### 5.2. Install deb

```bash
dpkg -i cortex_3.1.8-1_all.deb || true
apt-get install -f -y

dpkg -l | grep cortex
```

---

### 6. Configure TheHive

#### 6.1. Secret key

```bash
mkdir -p /etc/thehive

cat > /etc/thehive/secret.conf << 'EOF'
# IMPORTANT: Change this in production.
play.http.secret.key="changeme_in_production_make_THIS_very_long_and_secure_12345"
EOF
```

#### 6.2. Main configuration (`/etc/thehive/application.conf`)

```bash
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
```

#### 6.3. Directories and permissions

```bash
mkdir -p /opt/thp/thehive/{database,index,files,thumbnails} /var/log/thehive
chown -R thehive:thehive /opt/thp/thehive /var/log/thehive
```

---

### 7. Configure Cortex

#### 7.1. Main configuration (`/etc/cortex/application.conf`)

```bash
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
```

#### 7.2. Logging config and permissions

```bash
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
chown -R cortex:cortex /var/log/cortex
```

---

### 8. Create systemd Units for TheHive and Cortex

#### 8.1. TheHive service

```bash
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
```

#### 8.2. Cortex service

```bash
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
```

#### 8.3. Reload and start

```bash
systemctl daemon-reload

systemctl restart elasticsearch
sleep 10

systemctl restart cassandra
sleep 20

systemctl enable cortex thehive
systemctl restart cortex
sleep 10

systemctl restart thehive
```

---

### 9. Initial Access & Default Credentials

| Service | URL                          | Default Username       | Default Password |
|--------|-------------------------------|------------------------|------------------|
| TheHive | `http://<server-ip>:9000`   | `admin@thehive.local` | `secret`         |
| Cortex  | `http://<server-ip>:9001`   | `admin`               | `admin`          |

> ⚠️ Change all default credentials immediately after first login.

In **Docker mode**, use:

| Service | URL                            | Default Username       | Default Password |
|--------|----------------------------------|------------------------|------------------|
| TheHive | `http://<server-ip>:19000`     | `admin@thehive.local` | `secret`         |
| Cortex  | `http://<server-ip>:19001`     | `admin`               | `admin`          |

---

### 10. Connect TheHive and Cortex (API Key Integration)

This is the **final manual step** (for Native mode): using a Cortex API key (from an `org-admin` user) inside TheHive configuration and restarting TheHive.

> In **Docker mode**, the recommended way is to configure the API key fully via the **TheHive UI**  
> (Administration → Connectors → Cortex) after generating it in Cortex.

#### 10.1. Create an org admin user and API key in Cortex

1. Open Cortex: `http://<server-ip>:9001` (or `19001` in Docker mode)  
2. Login with `admin / admin`  
3. Go to **Organization → Users**  
4. Create a new user:
   - Login: `thehive-integration`
   - Roles: `orgAdmin`, `read`, `analyze`
5. Generate an **API key** for this user and copy it.

#### 10.2. Add the API key to TheHive configuration (Native mode)

Edit `/etc/thehive/application.conf` and update the `cortex.servers` block:

```hocon
cortex {
  servers = [
    {
      name = "local-cortex"
      url = "http://127.0.0.1:9001"

      auth {
        type = "bearer"
        key  = "PASTE_YOUR_CORTEX_API_KEY_HERE"
      }

      wsConfig {
        timeout.connection = 1 minute
        timeout.idle = 10 minutes
        timeout.request = 5 minutes
        user-agent = "TheHive/5.2.16"
      }
    }
  ]
}
```

Then restart TheHive:

```bash
systemctl restart thehive
```

Now open TheHive → **Administration → Connectors → Cortex** and verify that `local-cortex` is **connected**.  
Create a test case, add an observable, and run an Analyzer to confirm integration works.

In **Docker mode**, instead of editing a file in the container image, you usually:

1. Log in to TheHive UI (`http://<server-ip>:19000`).
2. Go to **Administration → Connectors → Cortex**.
3. Edit the existing Cortex server (`local-cortex`) and paste the API key into the UI form.
4. Save and validate the connection.

---

## 🧪 Health Checks

### Basic systemd status (Native mode)

```bash
systemctl status elasticsearch cassandra cortex thehive --no-pager
```

### API endpoints (Native mode)

```bash
curl -s http://127.0.0.1:9200 | jq .     # Elasticsearch
curl -s http://127.0.0.1:9001/api/status # Cortex
curl -s http://127.0.0.1:9000/api/status # TheHive
```

### API endpoints (Docker mode, from host)

```bash
curl -s http://<server-ip>:19200 | jq .          # Elasticsearch
curl -s http://<server-ip>:19001/api/status       # Cortex
curl -s http://<server-ip>:19000/api/status       # TheHive
```

### Useful logs

```bash
# Native mode
journalctl -u elasticsearch -n 50 --no-pager
journalctl -u cassandra    -n 50 --no-pager
journalctl -u cortex       -n 50 --no-pager
journalctl -u thehive      -n 50 --no-pager

# Docker mode
cd /opt/thehive-docker
docker compose logs thehive
docker compose logs cortex
docker compose logs elasticsearch
docker compose logs cassandra
```

---

## 🗂️ Key Directories

**Native mode**

| Path                               | Description                    |
|------------------------------------|--------------------------------|
| `/etc/thehive/application.conf`    | TheHive main configuration    |
| `/etc/thehive/secret.conf`         | TheHive secret key            |
| `/etc/cortex/application.conf`     | Cortex main configuration     |
| `/etc/cortex/logback.xml`          | Cortex logging                |
| `/var/lib/cassandra/`              | Cassandra data                |
| `/var/lib/elasticsearch/`          | Elasticsearch data            |
| `/opt/thp/thehive/`                | TheHive data & attachments    |
| `/var/log/thehive/`                | TheHive logs                  |
| `/var/log/cortex/`                 | Cortex logs                   |

**Docker mode**

| Path / Object                          | Description                           |
|----------------------------------------|---------------------------------------|
| `/opt/thehive-docker/docker-compose.yml` | Docker stack definition             |
| `esdata_lab` volume                    | Elasticsearch data volume             |
| `cassdata_lab` volume                  | Cassandra data volume                 |
| `cortex-jobs_lab` volume               | Cortex jobs/workspace                 |
| `cortex-logs_lab` volume               | Cortex logs                           |
| `thehive-data_lab` volume              | TheHive data & attachments            |

---

## 📈 Production Recommendations

- Use **HTTPS** (Nginx/Traefik + TLS certificates)
- Change all default passwords and rotate keys regularly
- Configure strict firewall rules for ports 9000/9001/9200/9042 (or Docker ports 19000/19001/19200/19042)
- Move from single-node Cassandra to a multi-node cluster for HA
- Tune JVM heap sizes based on real memory & load
- Configure backup for:
  - Cassandra data
  - Elasticsearch indices
  - TheHive files (`/opt/thp/thehive`) or Docker volumes (`thehive-data_lab`, `esdata_lab`, `cassdata_lab`)

---

## 🔌 Optional: Splunk Integration (`setup_thehive.sh`)

The repository also provides an optional helper script named `setup_thehive.sh` to integrate **TheHive** with **Splunk** using the official `TA-thehive-cortex` add-on.

### What `setup_thehive.sh` does

When executed on the **Splunk / TheHive host**, `setup_thehive.sh` will:

1. Ask you for the **TheHive FQDN** (for example: `thehive.example.com`).
2. Ask you for the **TheHive org admin name** (used only in the TLS certificate subject).
3. Check for an existing TLS certificate and key:
   - Certificate: `/etc/ssl/certs/thehive.crt`  
   - Key: `/etc/ssl/private/thehive.key`
4. If those files do not exist, generate a **self-signed TLS certificate** and key for Nginx and save them to the paths above.
5. Configure an **Nginx reverse proxy** for TheHive:
   - Listens on `443` (HTTPS).
   - Proxies all traffic to `http://127.0.0.1:9000`.
   - Sets common proxy headers and HSTS.
6. Prepare the **TA-thehive-cortex** app on Splunk:
   - Ensures the app directory under `/opt/splunk/etc/apps/TA-thehive-cortex` exists.
   - Fixes ownership to `splunk:splunk`.
   - Creates the `lookups/` directory if it does not exist.
   - Creates an **empty** lookup file:

     ```text
     /opt/splunk/etc/apps/TA-thehive-cortex/lookups/thehive_cortex_instances.csv
     ```

     > The file is intentionally created **without header or rows**.  
     > The Splunk TA UI will populate this CSV when you define a TheHive instance.
7. Restart Splunk via `/opt/splunk/bin/splunk restart`.

> The script does **not**:
> - Create any `inputs.conf` stanzas.  
> - Create alerts or saved searches.  
> - Configure API keys, accounts, or credentials.  
> These are all done manually in the Splunk and TheHive UIs.

### Prerequisites for `setup_thehive.sh`

- Splunk installed at `/opt/splunk`.
- `TA-thehive-cortex` already installed under:

  ```text
  /opt/splunk/etc/apps/TA-thehive-cortex
  ```

- Nginx installed and enabled (script will skip Nginx configuration if `nginx` is not found in `PATH`).
- TheHive running on `http://127.0.0.1:9000` on the same host (for the reverse proxy).
- Script must be run as `root` (or with `sudo`).

### How to run `setup_thehive.sh`

```bash
wget -O setup_thehive.sh https://your-repo-url.example.com/setup_thehive.sh
chmod +x setup_thehive.sh
sudo ./setup_thehive.sh
```

During execution, you will see prompts similar to:

```text
Enter TheHive FQDN (default: thehive.example.com):
Enter TheHive org admin name (default: orgadmin):
```

Use the same FQDN that Splunk and your browsers will use to reach TheHive  
(for example: `thehive.yourcompany.local`).

---

### Manual steps after running `setup_thehive.sh`

The script only prepares Nginx and the TA lookup path.  
The following **must be done manually** from the UIs:

#### 1. Install and configure the TA in Splunk

1. Log into Splunk Web.
2. Go to **Apps → Manage Apps → Install app from file**.
3. Upload and install the `TA-thehive-cortex_*.tgz` package.
4. After installation, go to: **Apps → TA-thehive-cortex → Configuration → Account**.
5. Click **Add new** and create an account:
   - **Account name**: e.g. `thehive`
   - **Username**: arbitrary label (not used if you use API key)
   - **Password**: TheHive API key (generated from TheHive UI)
6. Save.

#### 2. Define a TheHive instance in the TA (populates the CSV)

1. In Splunk Web, within **TA-thehive-cortex**, open the page for TheHive instances (e.g. **Configuration → TheHive Instances**).
2. Add a new instance and fill in:
   - **Host / URL**: `https://<your-hive-fqdn>`
   - **Port**: `443`
   - **Protocol**: `https`
   - **Account name**: the one you created in step 1 (e.g. `thehive`)
   - **Verify TLS**: as needed (`true` for trusted certs, `false` for lab only)
3. Save the instance.

After saving, the TA writes a row into:

```text
/opt/splunk/etc/apps/TA-thehive-cortex/lookups/thehive_cortex_instances.csv
```

You can verify from Splunk Search:

```spl
| inputlookup thehive_cortex_instances
```

You should now see one row describing your TheHive instance.

#### 3. Create the “TheHive: Alerts & Cases” Data Input (UI)

1. In Splunk Web, go to **Settings → Data inputs**.
2. Find and click **TheHive: Alerts & Cases**.
3. Click **New Local Input** (or similar).
4. Configure:
   - **Name**: e.g. `thehive_alerts_cases`
   - **Instance ID**: use the same ID the TA assigned to your instance (visible in the instance page or in the lookup).
   - **Type**: `alerts_cases`
   - **Index**: `thehive` (or any index you prefer)
   - **Sourcetype**: `thehive:alerts_cases`
5. Save and enable the input.

At this point, Splunk will start pulling alerts and cases from TheHive according to the TA’s polling logic.

#### 4. Create alerts in Splunk (optional, manual)

If you want Splunk to **push** alerts to TheHive:

1. Run a test search in Splunk, for example:

   ```spl
   index=_internal | head 1
   ```

2. Click **Save As → Alert**.
3. Set:
   - Title: e.g. `test_splunk_to_thehive`
   - Alert type: `Once` or `Scheduled` (e.g. every 5 minutes for testing)
   - Trigger condition: `Always` (for a simple test)
4. Under **Trigger Actions**, enable **TheHive - Create a new alert**.
5. Select the appropriate TheHive instance and fill any required fields (title, description, severity).
6. Save the alert.

After it fires:

- Log into TheHive.
- Go to **Alerts** and check that `test_splunk_to_thehive` (or your chosen name) appears.

---

## 📄 License

Licensed under the **MIT License** (or your organization’s license policy).
