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
#     5) Ensure /etc/hosts contains an entry for the FQDN.
#     6) Create a CLEAN thehive_cortex_instances.csv lookup file for TA-thehive-cortex
#        (backing up any existing one).
#     7) Extract the LIVE certificate from Nginx and append it to TA certifi/cacert.pem
#        so that SSL verification works (no hostname/CN mismatch, no wrong cert).
#     8) Fix ownership on TA app and restart Splunk.
#
# IMPORTANT:
#   - You must install TheHive and Splunk (and TA-thehive-cortex) beforehand.
#   - Run this script as root.
#   - All TA instance/config fields (id, api_key, etc.) are still created via Splunk UI,
#     but this script guarantees a clean lookup and working TLS trust.

set -euo pipefail

################################
# Basic safety checks          #
################################

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: This script must be run as root." >&2
  exit 1
fi

################################
# Ask for basic information    #
################################

read -rp "Enter TheHive FQDN (default: thehive.example.com): " SERVER_NAME_INPUT
SERVER_NAME="${SERVER_NAME_INPUT:-thehive.example.com}"

# Reject obviously invalid FQDNs (like ones containing '@' or spaces).
if [[ "${SERVER_NAME}" == *"@"* || "${SERVER_NAME}" == *" "* ]]; then
  echo "ERROR: Invalid FQDN '${SERVER_NAME}'. Do NOT use '@' or spaces. Use something like 'thehive.example.com'." >&2
  exit 1
fi

read -rp "Enter TheHive org admin name (default: orgadmin): " ORG_ADMIN_INPUT
ORG_ADMIN="${ORG_ADMIN_INPUT:-orgadmin}"

echo "==> Using SERVER_NAME=${SERVER_NAME}"
echo "==> Using ORG_ADMIN=${ORG_ADMIN}"

########################
# NGINX / TheHive      #
########################

CERT_PATH="/etc/ssl/certs/thehive.crt"
KEY_PATH="/etc/ssl/private/thehive.key"

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

SPLUNK_USER="splunk"
SPLUNK_GROUP="splunk"
SPLUNK_HOME="/opt/splunk"

APP_NAME="TA-thehive-cortex"
APP_DIR="${SPLUNK_HOME}/etc/apps/${APP_NAME}"
LOOKUP_DIR="${APP_DIR}/lookups"
LOOKUP_FILE="${LOOKUP_DIR}/thehive_cortex_instances.csv"

# Path to certifi bundle used by the TA Python environment.
CERTIFI_CACERT="${APP_DIR}/bin/ta_thehive_cortex/aob_py3/certifi/cacert.pem"

#########################################
# 0) Generate (or reuse) TLS cert/key   #
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

######################################
# 1) Configure /etc/hosts for FQDN  #
######################################

echo "==> Ensuring /etc/hosts has an entry for ${SERVER_NAME} ..."

if ! grep -qE "[[:space:]]${SERVER_NAME}([[:space:]]|\$)" /etc/hosts; then
  echo "127.0.0.1   ${SERVER_NAME}" >> /etc/hosts
  echo "==> Added '127.0.0.1 ${SERVER_NAME}' to /etc/hosts"
else
  echo "==> /etc/hosts already contains an entry for ${SERVER_NAME}"
fi

##################################
# 2) Configure Nginx for TheHive #
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
# 3) Configure Splunk TA lookup #
#################################

echo "==> Configuring TA-thehive-cortex on Splunk ..."

if [[ ! -d "${APP_DIR}" ]]; then
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

# If an old lookup file exists, back it up and recreate a CLEAN header-only CSV.
if [[ -f "${LOOKUP_FILE}" ]]; then
  TS="$(date +%Y%m%d%H%M%S)"
  echo "==> Backing up existing lookup file to ${LOOKUP_FILE}.${TS}.bak"
  mv "${LOOKUP_FILE}" "${LOOKUP_FILE}.${TS}.bak"
fi

echo "==> Creating CLEAN instance lookup CSV with header only: ${LOOKUP_FILE}"
cat > "${LOOKUP_FILE}" <<'EOF'
"account_name","authentication_type","client_cert",comment,environment,host,id,organisation,port,"proxy_account","proxy_url",type,uri
EOF

chown "${SPLUNK_USER}:${SPLUNK_GROUP}" "${LOOKUP_FILE}"
chmod 644 "${LOOKUP_FILE}"

##########################################################
# 4) Sync TA certifi bundle with LIVE Nginx certificate  #
##########################################################

if [[ -f "${CERTIFI_CACERT}" ]]; then
  echo "==> Updating TA certifi bundle with LIVE Nginx certificate ..."

  TMP_LIVE_CERT="/tmp/thehive_live.crt.$$"

  # Extract the live certificate served by Nginx for SERVER_NAME.
  openssl s_client -connect "${SERVER_NAME}:443" -servername "${SERVER_NAME}" </dev/null 2>/dev/null \
    | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > "${TMP_LIVE_CERT}"

  if [[ ! -s "${TMP_LIVE_CERT}" ]]; then
    echo "ERROR: Failed to retrieve LIVE certificate from Nginx for ${SERVER_NAME}." >&2
    rm -f "${TMP_LIVE_CERT}"
    exit 1
  fi

  # Optional: show fingerprint for logging/debugging.
  echo "==> LIVE certificate fingerprint (from Nginx):"
  openssl x509 -in "${TMP_LIVE_CERT}" -noout -fingerprint -sha256

  # Append LIVE cert to certifi bundle (no harm if duplicated).
  cat "${TMP_LIVE_CERT}" >> "${CERTIFI_CACERT}"

  rm -f "${TMP_LIVE_CERT}"

  echo "==> LIVE certificate appended to:"
  echo "    ${CERTIFI_CACERT}"
else
  echo "WARNING: TA certifi bundle not found at:"
  echo "  ${CERTIFI_CACERT}"
  echo "You may be using a different TA version/path; adjust the script accordingly."
fi

########################################
# 5) Restart Splunk                    #
########################################

echo "==> Restarting Splunk ..."
"${SPLUNK_HOME}/bin/splunk" restart

echo "==> All done."
echo
echo "Post-checks:"
echo "  1) From this host: curl -v https://${SERVER_NAME}/api/v1/status"
echo "  2) In Splunk UI: TA-thehive-cortex > Configuration > Add TheHive instance"
echo "     (saving the instance will populate thehive_cortex_instances.csv with a clean row)."
echo "  3) Then run your alert and check:"
echo "     index=_internal sourcetype=modular_alerts:thehive_create_a_new_case"
