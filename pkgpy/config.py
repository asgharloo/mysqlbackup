#config.py
from pathlib import Path
import os 
MYSQL_HOST = "192.168.30.129"
SCRIPT_PATH = "/etc/sinacomsys/backupapi/mysqlbackup.sh"
STATE_DIR = "/etc/sinacomsys/backupapi/state"
EXECUTION_JOBS_FILE = f"{STATE_DIR}/execution_jobs.json"
SCHEDULES_FILE = f"{STATE_DIR}/schedules_backup.json"
RESTORES_FILE = f"{STATE_DIR}/restores_backup.json"
UPLOADS_FILE = f"{STATE_DIR}/uploads_backup.json"

####check to confirm if file path exist and writable 
_script = Path(SCRIPT_PATH)
if not _script.exists():
    raise FileNotFoundError(f"Backup script not found: '{SCRIPT_PATH}'")
if not os.access(_script, os.X_OK):
    raise PermissionError(f"Backup script is not executable: '{SCRIPT_PATH}'")


BACKUP_ROOT = Path("/RemoteBackup")
DB_CONFIG = {
              "host": "localhost",
              "port": 3306,
              "user": "root",
              #"password": "${MYSQL_ROOT_PASS}"
              "password": "1234"
              }

# key and security Configuration ---
# 1 need key .Change to 0 to disable Authentication .
enable_secret = 1

# Static key for internal endpoints
API_KEYS_STATIC = {
"list": "strongkey"
}

# Base secret for generating rotating keys for clients
DOWNLOAD_BASE_SECRET = "Ananas" # never expose this
# Rotating key settings
ROTATE_INTERVAL_MINUTES = 30
