cd /opt/splunk/etc/apps/TA-thehive-cortex/bin

cat << 'EOF' > fix_thehive_user_api.sh
APP_DIR="/opt/splunk/etc/apps/TA-thehive-cortex/bin"
cd "$APP_DIR"

TARGET_DIR="ta_thehive_cortex/aob_py3"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${TARGET_DIR}_before_user_api_change_${STAMP}"

cp -a "$TARGET_DIR" "$BACKUP_DIR"

USER_PY="$TARGET_DIR/thehive4py/endpoints/user.py"
if [ -f "$USER_PY" ]; then
  sed -i 's#/api/v1/user/#/api/user/#g' "$USER_PY"
fi

BAK_FILE="$TARGET_DIR/thehive4py/endpoints/user.py.bak"
if [ -f "$BAK_FILE" ]; then
  rm "$BAK_FILE"
fi

PYC_DIR="$TARGET_DIR/thehive4py/endpoints/__pycache__"
if [ -d "$PYC_DIR" ]; then
  rm -f "$PYC_DIR"/user*.pyc
fi

grep -R --line-number "/api/v1/user" "$TARGET_DIR/thehive4py" || echo "No /api/v1/user under thehive4py"
EOF

chmod +x fix_thehive_user_api.sh
