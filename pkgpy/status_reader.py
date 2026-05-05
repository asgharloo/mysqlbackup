import json
from pathlib import Path
from typing import List, Dict, Optional
from .config import  SCHEDULES_FILE, RESTORES_FILE, UPLOADS_FILE, EXECUTION_JOBS_FILE

SCHEDULES_FILE = Path(SCHEDULES_FILE)
RESTORES_FILE = Path (RESTORES_FILE)
UPLOADS_FILE = Path (UPLOADS_FILE)
EXECUTION_JOBS_FILE = Path (EXECUTION_JOBS_FILE)

def _load_all_records(path: Path) -> List[Dict]:
    """Reads and returns all JSON records from the given file path."""
    if not path.exists():
        return []
    records = []
    with path.open("r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            print ("line:", line)
            try:
                # Corrected: append to the 'records' list, not 'path'
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
                
    # Corrected: return the list of records, not the 'path' object
    return records

def list_schedules_jobs() -> List[Dict]:
    return _load_all_records(SCHEDULES_FILE)

def list_restored_jobs() -> List[Dict]:
    return _load_all_records(RESTORES_FILE)

def list_uploaded_jobs() -> List[Dict]:
     return _load_all_records(UPLOADS_FILE)

def list_executions_jobs() -> List[Dict]:
    return _load_all_records(EXECUTION_JOBS_FILE)

def _load_records_by_job_id(path: Path, job_id: str, latest: bool = False) -> List[Dict]:
    """Load all records matching the given job_id."""
    all_records = _load_all_records(path)
    matched = [r for r in all_records if r.get("job_id") == job_id]
    
    if latest and matched:
        # Sort by updated_at or created_at descending and return only the last one
        matched.sort(key=lambda x: x.get("updated_at", x.get("created_at", "")), reverse=True)
        return [matched[0]]
    
    return matched

def list_executions_jobs_by_id(job_id, latest: bool = False) -> List[Dict]:
    return _load_records_by_job_id(EXECUTION_JOBS_FILE,job_id,latest)

def list_schedules_jobs_by_id(job_id:str) -> List[Dict]:
    return __load_records_by_job_id(SCHEDULES_FILE,job_id,latest)

def list_restored_jobs_by_id() -> List[Dict]:
    return _load_records_by_job_id(RESTORES_FILE,job_id,latest)

def list_uploaded_jobs_by_id() -> List[Dict]:
     return _load_records_by_job_id(UPLOADS_FILE,job_id,latest)

#def get_uploaded_status():
def get_uploaded_status(job_id: str):
    ast_record = None
    try:
        with open(UPLOADS_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue

                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if rec.get("job_id") != job_id:
                    continue

                # Since the log file is append-only, the latest EXECUTION record is the effective one
                last_record = rec

    except FileNotFoundError:
        return None

    return last_record

'''
def get_restore_status(job_id: str):
    last_record = None

    try:
        with open(RESTORES_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue

                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if rec.get("job_id") != job_id:
                    continue
            
                # Since the log file is append-only, the latest EXECUTION record is the effective one
                last_record = rec

    except FileNotFoundError:
        return None

    return last_record
'''