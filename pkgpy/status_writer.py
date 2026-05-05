#Status_witer.py 
import json
import os,sys
from datetime import datetime
from threading import Lock
import threading
from typing import Literal, Dict
from .config import STATE_DIR, EXECUTION_JOBS_FILE, SCHEDULES_FILE, RESTORES_FILE, UPLOADS_FILE

_lock = threading.Lock()

KIND_TO_FILE_MAP: Dict[str, str] = {
    "execution": EXECUTION_JOBS_FILE,
    "schedule": SCHEDULES_FILE,      # For definitions only (ACTIVE/INACTIVE)
    "restore": RESTORES_FILE,
    "upload": UPLOADS_FILE,
}

def _utc():
    return datetime.utcnow().isoformat() + "Z"

def write_status(kind: str, record: dict):
    record.setdefault("created_at", _utc())
    record["updated_at"] = _utc()


    path = KIND_TO_FILE_MAP.get(kind)
    if not path:
        raise ValueError(f"Unknown kind: {kind}")

    with _lock:
        records = []
        if os.path.exists(path):
            with open(path, "r") as f:
                records = [json.loads(line) for line in f if line.strip()]

        # Use run_id as unique identifier
        run_id = record.get("run_id")
        updated = False
        
        if run_id:
            for i, existing in enumerate(records):
                if existing.get("run_id") == run_id:
                    records[i] = record
                    updated = True
                    break
        
        if not updated:
            records.append(record)

        with open(path, "w") as f:
            for r in records:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")




