#!/bin/bash

##Mysql config
MYSQL_PORT=3306
MYSQL_USER="root"
#MYSQL_PASSWORD="${MYSQL_ROOT_PASS}"
MYSQL_PASSWORD="1234"
### IP setting:
MYSQL_HOST="192.168.30.129"
write_path=/etc/sinacomsys/backupapi/pkgpy/write_log.py
APP_DIR=/etc/sinacomsys/backupapi
PYTHON=/etc/sinacomsys/backupapi/venv/bin/python
export PYTHONPATH=/etc/sinacomsys/backupapi:${PYTHONPATH:-}

#############
LOG_PATH="/var/log/nms-log/backupserver-log"
LOG_FILE="${LOG_PATH}/nmsmysql-backup.log"
mkdir -p "$(dirname "$LOG_FILE")" && touch "$LOG_FILE"
