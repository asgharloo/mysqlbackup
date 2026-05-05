import os
import subprocess
import logging
from datetime import datetime
from .status_writer import write_status
from .config import SCRIPT_PATH, MYSQL_HOST

from .schemas import (
    ManualBackupRequest,
    ScheduleType, 
    ScheduleRequest,
    BACKUP_TOOL_MAP,
    Restore_Request,
    DatabaseRequest,
    BackupType
)

def build_command(req):
    # ... (Keep your existing build_command logic) ...
    db_json = req
    bt = req.backup_type.value
    if bt == "FULL":
        return [SCRIPT_PATH, "--manually"]

    if bt == "DB":
        if not req.dbs:
            raise ValueError("dbs required for DB backup")
        db_names = ",".join(d.db for d in req.dbs)
        return [SCRIPT_PATH, "--table-backup", db_names]
    
    if bt == "TABLE":
        if not req.dbs:
            raise ValueError("dbs required for TABLE backup")
        specs = []
        for item in req.dbs:
            if not item.tables:
                raise ValueError(f"tables required for TABLE backup (db={item.db})")
            table_list = ",".join(item.tables)
            specs.append(f"{item.db}:{table_list}")
        spec_arg = ";".join(specs)
        return [SCRIPT_PATH, "--table-backup", "--spec", spec_arg]

    raise ValueError("Invalid backup_type")

def build_schedule_command(req) -> list[str]:
    """Builds the shell command for setting up a scheduled backup."""
    cmd = [SCRIPT_PATH]

    is_weekly_or_monthly = req.schedule_type in (ScheduleType.WEEKLY, ScheduleType.MONTHLY)
    tb_flag = f"--tb-{req.schedule_type.value.lower()}"   
    full_flag = f"--{req.schedule_type.value.lower()}"    

    # ---- Command Building ----
    if req.backup_type == BackupType.FULL:
        cmd.append(full_flag)
        if is_weekly_or_monthly:
            cmd.append(str(req.schedule_days[0]))
        cmd.append(req.schedule_value)

    else:
        cmd.append(tb_flag)
        if len(req.dbs_tbls) == 1:
            entry = req.dbs_tbls[0]
            if ":" in entry:
                db_name, tables = entry.split(":", 1)
                cmd.append(db_name)
                cmd.extend(["--tables", tables])
            else:
                cmd.append(entry)
        else:
            spec = ";".join(req.dbs_tbls)
            cmd.extend(["--spec", spec])

        if is_weekly_or_monthly:
            cmd.append(str(req.schedule_days[0]))
        cmd.append(req.schedule_value)

    return cmd

def restore_command(req, filename):
    # ... (Keep your existing restore_command logic) ...
    bt = req.backup_type.value
    if bt == "FULL":
        return [SCRIPT_PATH, "--restore", filename]
    if bt == "DB" or bt == "TABLE":
        return [SCRIPT_PATH, "--table-restore", filename]
    raise ValueError("Invalid backup_type")

# --- NEW: Specific function for SCHEDULED jobs ---
def run_schedule(job_id: str, cmd: list[str], req_dict: dict, backup_tool: str):
    logger = logging.getLogger(__name__)
    logger.warning(f"RUN_SCHEDULE CALLED: {cmd}")
    env = os.environ.copy()
    env["JOB_ID"] = job_id
    env["JOB_ORIGIN"] = "SCHEDULED"
    env["SCHEDULE_TYPE"] = req_dict.get("schedule_type")
    env["BACKUP_TYPE"] = req_dict.get("backup_type")
    
    try:
        result = subprocess.run(cmd, env=env, check=True, capture_output=True, text=True)
        logger.info(f"Schedule applied successfully: {result.stdout}")
        
        # Write ACTIVE status exclusively to SCHEDULES_FILE via the router
        write_status("schedule", {
            "status": "ACTIVE",
            "job_id": job_id,
            "backup_type": req_dict.get("backup_type"),
            "backup_tool": backup_tool,
            "request": req_dict,
            "created_at": datetime.utcnow().isoformat() + "Z",
        })
        
    except subprocess.CalledProcessError as e:
        logger.error(f"CMD FAILED: {e.cmd} | STDOUT: {e.stdout} | STDERR: {e.stderr}")
        raise # Reraise to let main.py handle the 500 HTTP Exception if called synchronously
# --- UPDATED: For MANUAL_API and RESTORE_API jobs ---
def run_backup(
    job_id: str,
    run_id: str,
    cmd: list[str],
    backup_type: str,
    backup_tool: str,
    job_origin: str,
    db_names: list = [],
    table_list: list = [],
):
    logger = logging.getLogger(__name__)
    logger.warning(f"RUN_BACKUP CALLED: {cmd}")
    
    db_names=db_names,
    table_list=table_list,
    
    env = os.environ.copy()
    env["JOB_ID"] = job_id
    env["RUN_ID"] = run_id
    env["JOB_ORIGIN"] = job_origin
    env["BACKUP_TYPE"] = backup_type
    env["BACKUP_TOOL"] = backup_tool
    env["MYSQL_HOST"] = MYSQL_HOST
  
    print("env:",env)

    # Map origin to correct file router kind
    kind = "execution" if job_origin == "MANUAL_API" else "RESTORE_API"

    # NOTE: The RUNNING write logic was removed from here. 
    # main.py should write the RUNNING status *before* adding this to BackgroundTasks.

    try:
        p = subprocess.run(
            cmd,
            env=env,
            capture_output=True,
            text=True,
            timeout=3600,
            check=False,
        )
        
        print("env:", env)
        # Shell script's write_log.py handles SUCCESS, but we handle subprocess failures here
        if p.returncode != 0:
            write_status(kind, {
                "job_id": job_id,
                "status": "FAILED",
                "job_origin": job_origin,
                "backup_type": backup_type,
                "error_code": p.returncode,
                "error_message": p.stderr.strip()[-500:],
                "finished_at": datetime.utcnow().isoformat() + "Z",
            })

    except Exception as e:
            write_status(kind, {
                "job_id": job_id,
                "status": "FAILED",
                "job_origin": job_origin,
                "backup_type": backup_type,
                "backup_tool": backup_tool,
                "error_code": 999,
                "error_message": str(e),
                "finished_at": datetime.utcnow().isoformat() + "Z",
            })
