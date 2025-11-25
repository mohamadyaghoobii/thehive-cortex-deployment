#!/bin/bash
# setup_thehive.sh
#
# Purpose:
#   Minimal bootstrap for a lab/POC where TheHive, Nginx and Splunk
#   all run on the same server.
#
#   This script will:
#     1) Ask for TheHive FQDN (server name).
#     2) Ask for TheHive org admin name (used in certificate subject).
#     3) Generate a self-signed TLS certificate/key for Nginx if missing.
#     4) Configure an Nginx reverse proxy for TheHive (HTTPS on port 443).
#     5) Create an EMPTY thehive_cortex_instances.csv lookup file for TA-thehive-cortex.
#     6) Restart Splunk.
#
# IMPORTANT:
#   - You must install TheHive and Splunk (and TA-thehive-cortex) beforehand.
#   - Run this script as root.
#   - All TA instance/config fields will be created later via Splunk UI.

set -euo pipefail

################################
# Ask for basic information    #
################################

read -rp "Enter TheHive FQDN (default: thehive.example.com): " SERVER_NAME_INPUT
SERVER_NAME="${SERVER_NAME_INPUT:-thehive.example.com}"

read -rp "Enter TheHive org admin name (default: orgadmin): " ORG_ADMIN_INPUT
ORG_ADMIN="${ORG_ADMIN_INPUT:-orgadmin}"

echo "==> Using SERVER_NAME=${SERVER_NAME}"
echo "==> Using ORG_ADMIN=${ORG_ADMIN}"

########################
# NGINX / TheHive      #
########################

# Paths to TLS certificate and key consumed by Nginx.
CERT_PATH="/etc/ssl/certs/thehive.crt"
KEY_PATH="/etc/ssl/private/thehive.key"

# Where TheHive itself is listening (HTTP).
BACKEND_HOST="127.0.0.1"
BACKEND_PORT="9000"

NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
NGINX_SITE_NAME="thehive"
NGINX_SITE_CONF="${NGINX_SITES_AVAILABLE}/${NGINX_SITE_NAME}.conf"
NGINX_ENABLED_LINK="${NGINX_SITES_ENABLED}/${NGINX_SITE_NAME}.conf"

########################
# Splunk / TA config   #
########################

# Splunk runtime paths and user.
SPLUNK_USER="splunk"
SPLUNK_GROUP="splunk"
SPLUNK_HOME="/opt/splunk"

# TA-thehive-cortex app paths.
APP_NAME="TA-thehive-cortex"
APP_DIR="${SPLUNK_HOME}/etc/apps/${APP_NAME}"
LOOKUP_DIR="${APP_DIR}/lookups"
LOOKUP_FILE="${LOOKUP_DIR}/thehive_cortex_instances.csv"

#########################################
# 0) Generate self-signed TLS cert/key  #
#########################################

echo "==> Checking TLS certificate/key for Nginx ..."

if [[ -f "${CERT_PATH}" && -f "${KEY_PATH}" ]]; then
  echo "==> Existing certificate and key found:"
  echo "    CERT_PATH=${CERT_PATH}"
  echo "    KEY_PATH=${KEY_PATH}"
else
  echo "==> No valid certificate/key found. Generating self-signed certificate ..."
  mkdir -p "$(dirname "${CERT_PATH}")" "$(dirname "${KEY_PATH}")"

  openssl req -x509 -nodes -newkey rsa:4096 \
    -keyout "${KEY_PATH}" \
    -out "${CERT_PATH}" \
    -days 365 \
    -subj "/C=IR/ST=Tehran/L=Tehran/O=${ORG_ADMIN}/OU=TheHive/CN=${SERVER_NAME}"

  chmod 600 "${KEY_PATH}"
  chmod 644 "${CERT_PATH}"

  echo "==> Self-signed certificate generated:"
  echo "    ${CERT_PATH}"
  echo "    ${KEY_PATH}"
fi

##################################
# 1) Configure Nginx for TheHive #
##################################

echo "==> Configuring Nginx reverse proxy for TheHive ..."

if ! command -v nginx >/dev/null 2>&1; then
  echo "WARNING: nginx is not installed. Skipping Nginx configuration."
else
  echo "==> Writing Nginx site configuration: ${NGINX_SITE_CONF}"
  mkdir -p "${NGINX_SITES_AVAILABLE}" "${NGINX_SITES_ENABLED}"

  cat > "${NGINX_SITE_CONF}" <<EOF
server {
    listen 443 ssl;
    server_name ${SERVER_NAME};

    ssl_certificate ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};

    location / {
        proxy_pass http://${BACKEND_HOST}:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
    }
}
EOF

  echo "==> Enabling Nginx site: ${NGINX_ENABLED_LINK}"
  ln -sf "${NGINX_SITE_CONF}" "${NGINX_ENABLED_LINK}"

  echo "==> Testing Nginx configuration ..."
  nginx -t

  echo "==> Reloading / starting Nginx ..."
  systemctl reload nginx 2>/dev/null || systemctl restart nginx || true
fi

#################################
# 2) Configure Splunk TA lookup #
#################################

echo "==> Configuring TA-thehive-cortex on Splunk ..."

if [ ! -d "${APP_DIR}" ]; then
  echo "ERROR: ${APP_DIR} does not exist."
  echo "Install ${APP_NAME} from Splunkbase first (Apps > Manage Apps)."
  exit 1
fi

echo "==> Fixing ownership of TA app directory ..."
chown -R "${SPLUNK_USER}:${SPLUNK_GROUP}" "${APP_DIR}"

echo "==> Creating lookup directory: ${LOOKUP_DIR}"
mkdir -p "${LOOKUP_DIR}"
chown "${SPLUNK_USER}:${SPLUNK_GROUP}" "${LOOKUP_DIR}"
chmod 755 "${LOOKUP_DIR}"

echo "==> Creating EMPTY instance lookup CSV (UI will populate fields): ${LOOKUP_FILE}"
# Create or truncate to empty file; no header, no rows.
: > "${LOOKUP_FILE}"

chown "${SPLUNK_USER}:${SPLUNK_GROUP}" "${LOOKUP_FILE}"
chmod 644 "${LOOKUP_FILE}"

########################################
# 3) Restart Splunk                    #
########################################

echo "==> Restarting Splunk ..."
"${SPLUNK_HOME}/bin/splunk" restart

echo "==> All done."
echo "Post-checks:"
echo "  1) curl -sk https://${SERVER_NAME}/api/v1/status"
echo "  2) In Splunk UI: TA-thehive-cortex > Configuration > Add TheHive instance"
echo "     (saving the instance will populate thehive_cortex_instances.csv)."
