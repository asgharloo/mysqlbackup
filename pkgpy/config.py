from pathlib import Path
import os 

MYSQL_HOST = os.getenv("MYSQL_HOST", "127.0.0.1")
APP_DIR = os.getenv("APP_BASE_DIR", "/etc/xxxx/backupapi")

SCRIPT_PATH = f"{APP_DIR}/mysqlbackup.sh"
STATE_DIR = f"{APP_DIR}/state"
EXECUTION_JOBS_FILE = f"{STATE_DIR}/execution_jobs.json"
SCHEDULES_FILE = f"{STATE_DIR}/schedules_backup.json"
RESTORES_FILE = f"{STATE_DIR}/restores_backup.json"
UPLOADS_FILE = f"{STATE_DIR}/uploads_backup.json"

_script = Path(SCRIPT_PATH)
if not _script.exists():
    raise FileNotFoundError(f"Backup script not found: '{SCRIPT_PATH}'")
if not os.access(_script, os.X_OK):
    raise PermissionError(f"Backup script is not executable: '{SCRIPT_PATH}'")

BACKUP_ROOT = Path("/RemoteBackup")

DB_CONFIG = {
    "host": os.getenv("MYSQL_HOST", "localhost"),
    "port": int(os.getenv("MYSQL_PORT", 3306)),
    "user": os.getenv("MYSQL_USER", "root"),
    "password": os.getenv("MYSQL_PASSWORD", "")
}

enable_secret = int(os.getenv("ENABLE_SECRET", 1))

API_KEYS_STATIC = {
    "list": os.getenv("API_KEY_LIST", "default_static_key")
}

DOWNLOAD_BASE_SECRET = os.getenv("DOWNLOAD_BASE_SECRET", "default_secret")
ROTATE_INTERVAL_MINUTES = int(os.getenv("ROTATE_INTERVAL_MINUTES", 30))

