#!/bin/bash

if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

## Mysql config
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-""}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"

APP_DIR="${APP_BASE_DIR:-/etc/sinacomsys/backupapi}"

write_path="${APP_DIR}/pkgpy/write_log.py"
PYTHON="${APP_DIR}/venv/bin/python"
export PYTHONPATH="${APP_DIR}:${PYTHONPATH:-}"

#############
LOG_PATH="/var/log/nms-log/backupserver-log"
LOG_FILE="${LOG_PATH}/nmsmysql-backup.log"
mkdir -p "$(dirname "$LOG_FILE")" && touch "$LOG_FILE"

