from fastapi import FastAPI, BackgroundTasks, HTTPException, Depends, Request, UploadFile, File, Form
from fastapi.responses import FileResponse
import uuid
import os
import json
import subprocess, shlex
from typing import Annotated
import shutil
from subprocess import run
from pathlib import Path
from datetime import datetime
import logging
import aiomysql
import time 

from .schemas import (
    ManualBackupRequest,
    ScheduleType, 
    ScheduleRequest,
    BACKUP_TOOL_MAP,
    Restore_Request,
    DatabaseRequest,
    ExecutionQuery,
    BackupType
)

from .worker import build_command, restore_command, run_backup, run_schedule, build_schedule_command
from .status_writer import write_status
from .status_reader import (
    list_schedules_jobs,
    list_executions_jobs,
    list_restored_jobs,
    list_uploaded_jobs,
    list_schedules_jobs_by_id,
    list_executions_jobs_by_id,
    #get_uploaded_status,
    #get_restore_status
)

from .config import (
    BACKUP_ROOT,
    SCRIPT_PATH,
    SCHEDULES_FILE,
    DB_CONFIG,
    API_KEYS_STATIC
)

from .secure_api import verify_api_key, generate_download_key


app = FastAPI()
SCHEDULES_FILE = Path(SCHEDULES_FILE)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


# curl http://127.0.0.1:8080/download/key
@app.get("/download/key")
async def get_download_key(dep=Depends(verify_api_key("list"))):
   """
   Endpoint to give clients the current hashed key.
   """
   return {"download_key": generate_download_key()}       
#==============
# MANUAL BACKUP
#=============
#####list manual job based on latest record per job_id 
# curl http://127.0.0.1:8080/list/executions
@app.get("/list/executions")
def get_all_executions(dep=Depends(verify_api_key("list"))):
    """Returns all executed jobs (manual and scheduled) from EXECUTION_JOBS_FILE."""
    return list_executions_jobs()

@app.post("/list/executions/{job_id}")
def list_executions_by_job(job_id: str, query: ExecutionQuery):
    return list_executions_jobs_by_id(job_id, query.latest)



#curl -X POST http://127.0.0.1:8080/backup/manual  -H "Content-Type: application/json"  -d '{"backup_type": "FULL"}'
"""
curl -X POST http://127.0.0.1:8080/backup/manual -H "Content-Type: application/json" \
-H "X-API-Key: cc241a9de8c71c1082bfe716a640a5ad252d4f562d9ccb070269f31395049223" -d '{"backup_type": "FULL"}'
"""
@app.post("/backup/manual")
def manual_backup(
     req: ManualBackupRequest,
     bg: BackgroundTasks,
     dep = Depends(verify_api_key("list"))
     ):
     
    job_id = str(uuid.uuid4())
    run_id = f"manual_{int(time.time() * 1000)}"

    backup_tool = BACKUP_TOOL_MAP[req.backup_type]

    # Build db_names and table_list
    db_names = [d.db for d in req.dbs] if req.dbs else []
    table_list = [t for d in req.dbs if d.tables for t in d.tables] if req.dbs else []

    # Build request_payload
    request_payload = {"backup_type": req.backup_type, "dbs": req.dbs}
    if req.backup_type == BackupType.FULL:
        request_payload["dbs"] = None

    try:
        cmd = build_command(req)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    if req.dbs:
       request_payload = req.model_dump()
       
    # Write execution status
    write_status("execution", {
        "job_id": job_id,
        "run_id": run_id,
        "status": "RUNNING", 
        "origin": "MANUAL_API",
        "backup_type": req.backup_type.value,
        "backup_tool": backup_tool,
        "dbs_names": db_names if req.backup_type != BackupType.FULL else None,
        "table_names": table_list if req.backup_type != BackupType.FULL else None,
    })
    
    print("cmd",cmd)
    
    bg.add_task(
        run_backup,
        job_id,
        run_id,
        cmd,
        req.backup_type.value,
        backup_tool,
        job_origin="MANUAL_API",
        db_names=db_names,
        table_list=table_list,
    )

    return {
        "job_id": job_id,
        "status": "RUNNING",
        "request": request_payload 
    }

#==============
# restore BACKUP
#=============
# curl http://127.0.0.1:8080/list/restored/
@app.get("/list/restored")
def list_restored_jobs(dep=Depends(verify_api_key("list"))):
    return {
        "count": len(list_restored_jobs()),
        "jobs": list_restored_jobs(),
    }

# LIST RESTORED JOBS
# curl http://127.0.0.1:8080/list/restored/$JOB_ID
@app.get("/list/restored/{job_id}")
def get_scheduled_job_status(job_id: str, dep = Depends(verify_api_key("list"))):
    record = get_restore_status(job_id)
    if not record:
        raise HTTPException(
            status_code=404,
            detail=f"Scheduled job not found: {job_id}"
        )

    return record
 
#curl -X POST http://127.0.0.1:8080/restore/$FILE_NAME  -H "Content-Type: application/json"  -d '{"backup_type": "DB | FULL |TABLE"}'
@app.post("/restore/{filename}")
def restore(filename: str, req: Restore_Request, bg: BackgroundTasks, dep = Depends(verify_api_key("list"))):
    file_path = BACKUP_ROOT / filename
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Backup file not found")  
    try:
        cmd = restore_command(req, filename)
        print ("cmdd",cmd)

    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    job_id = str(uuid.uuid4())
    run_id = f"restore_{int(time.time() * 1000)}"  
    backup_tool = BACKUP_TOOL_MAP[req.backup_type]

    write_status("restore", {
        "status": "QUEUED",
        "job_id": job_id,
        "run_id": run_id, 
        "origin": "RESTORE_API",
        "backup_type": req.backup_type.value,
        "backup_tool": backup_tool,
        "cmd": cmd,
    })

    bg.add_task(
        run_backup,
        job_id,
        run_id,
        cmd,
        req.backup_type.value,
        backup_tool,
        job_origin="RESTORE_API",
    
    )
   
    return {"job_id": job_id, "status": "QUEUED"}
#==============
# Download/Upload BACKUP
#=============
#curl -L http://127.0.0.1:8080/download/$FILE_NAME --output  Filename
@app.get("/download/{filename}")
def download_backup(filename: str, dep = Depends(verify_api_key("list"))):
   
    file_path = BACKUP_ROOT / filename
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Backup file not found")

    return FileResponse(
        path=file_path,
        filename=filename,
        media_type="application/octet-stream"
    )



@app.post("/upload/backup", summary="Upload Backup")
async def upload_backup(
    backup_type: BackupType = Form(...),
    file: UploadFile = File(...),
    dep=Depends(verify_api_key("list"))
):

    if backup_type.value not in ["FULL", "TABLE"]:
        raise HTTPException(status_code=400, detail="Invalid backup_type")

    # 🔹 Generate job_id
    job_id = str(uuid.uuid4())

    # 🔹 Detect tool
    backup_tool = "XTRABACKUP" if backup_type.value == "FULL" else "MYDUMPER"

    # Map type
    type_name = backup_type.value.lower()

    date_str = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    new_filename = f"userupdate_{type_name}_{date_str}"

    if file.filename and "." in file.filename:
        ext = file.filename.split(".")[-1]
        new_filename += f".{ext}"

    BACKUP_ROOT.mkdir(parents=True, exist_ok=True)
    file_path = BACKUP_ROOT / new_filename

    # 🔹 Write UPLOADING status
    write_status("upload", {
        "status": "UPLOADING",
        "job_id": job_id,
        "backup_type": backup_type.value,
        "backup_tool": backup_tool,
        "original_filename": file.filename,
        "target_filename": new_filename,
        "job_origin": "UPLOAD_API"
    })

    try:
        with file_path.open("wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        file_size_mb = round(file_path.stat().st_size / (1024 * 1024), 2)
        # 🔹 Write SUCCESS
        write_status("upload", {
            "status": "UPLOADED",
            "job_id": job_id,
            "backup_type": backup_type.value,
            "backup_tool": backup_tool,
            "backup_file": new_filename,
            "file_size": file_size_mb,
            "job_origin": "UPLOAD_API"
        })

    except Exception as e:
        write_status("upload", {
            "status": "FAILED",
            "job_id": job_id,
            "backup_type": backup_type.value,
            "backup_tool": backup_tool,
            "error_message": str(e),
            "job_origin": "UPLOAD_API"
        })
        raise HTTPException(status_code=500, detail=str(e))

    return {
        "status": "UPLOADED",
        "job_id": job_id,
        "backup_type": backup_type.value,
        "saved_as": new_filename,
        "path": str(file_path)
    }


@app.get("/list/uploaded")
def list_uploaded(dep=Depends(verify_api_key("list"))):
    return {
        "count": len(list_uploaded_jobs()),
        "jobs": list_uploaded_jobs()
    }

@app.get("/list/uploaded/{job_id}")
def get_uploaded_status(job_id: str, dep = Depends(verify_api_key("list"))):
    jobs = list_uploaded_jobs()
    for job in reversed(jobs):  # reverse to get latest first
        if job.get("job_id") == job_id:
            return job
    raise HTTPException(status_code=404, detail="Uploaded job not found")

# ======================
# SCHEDULE BACKUP
# ======================
#LIST BACKUP SCHEDULES (JOBS)
# curl http://127.0.0.1:8080/list/schedules 
@app.get("/list/schedules")
def list_all_schedules_jobs():
    """Return only ACTIVE/INACTIVE schedule definitions, not execution logs"""
    return list(list_schedules_jobs())
    

###curl -X POST http://127.0.0.1:8080/schedule   -H "Content-Type: application/json"   -d '{ "backup_type": "TABLE", "dbs_tbls": ["alarm_db:sina_events"] \
# , "schedule_type": "WEEKLY", "schedule_value": "12:02","schedule_days": [5]}'
@app.post("/schedule")
def schedule_backup(req: ScheduleRequest, dep=Depends(verify_api_key("list"))):
    #prints  incoming request to server’s console for debuging 
    print("REQ =", req.model_dump())
    
    job_id = str(uuid.uuid4())
    backup_tool = BACKUP_TOOL_MAP[req.backup_type]
    
    # Delegate command building to worker
    cmd = build_schedule_command(req)
    ###prints builtup command for debuging
    print("CMD =", cmd)
    
    # ---- Delegate to Worker ----
    req_dict = {
        "backup_type": req.backup_type.value,
        "schedule_type": req.schedule_type.value,
        "schedule_value": req.schedule_value,
        "schedule_days": req.schedule_days or [],
        "dbs_tbls": req.dbs_tbls or [],
    }

    try:
         run_schedule(job_id, cmd, req_dict, backup_tool)
    except subprocess.CalledProcessError as e:
        raise HTTPException(500, detail=f"Script failed: {e.stderr}")
    except FileNotFoundError:
        raise HTTPException(500, detail=f"Script not found: {SCRIPT_PATH}")
    except Exception as e:
        raise HTTPException(500, detail=f"Internal error setting up schedule: {str(e)}")

    return {
        "job_id": job_id,
        "status": "SCHEDULED", # Standard response to API caller
        "dbs_tbls": req.dbs_tbls or [],
    }


   
#curl -X POST http://127.0.0.1:8080/backup/scheduled/8b74607b-fc5f-45a1-ac02-edb2a992c203/deactivate   -H 'Content-Type: application/json'
@app.post("/backup/scheduled/{job_id}/deactivate")
def deactivate_scheduled_job(job_id: str, dep = Depends(verify_api_key("list"))):
    # 1️⃣ remove cron entry
    try:
        cmd = f"crontab -l | grep -v '{job_id}' | crontab -"
        subprocess.run(cmd, shell=True, check=True)
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to remove cron job: {e}"
        )

    # 2️⃣ mark schedule record as INACTIVE (do not delete)
    if not SCHEDULES_FILE.exists():
        raise HTTPException(status_code=404, detail="Scheduled file not found")

    updated = False
    records = []

    with SCHEDULES_FILE.open() as f:
        for line in f:
            if not line.strip():
                continue

            rec = json.loads(line)

            # only touch SCHEDULE record
            if (
                rec.get("job_id") == job_id
                and rec.get("status") == "ACTIVE"
            ):
                rec["status"] = "INACTIVE"
                rec["updated_at"] = datetime.utcnow().isoformat() + "Z"
                updated = True

            records.append(rec)

    if not updated:
        raise HTTPException(status_code=404, detail="Scheduled job not found")

    with SCHEDULES_FILE.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")

    return {
        "job_id": job_id,
        "status": "INACTIVE",
        "cron": "REMOVED"
    }

####curl -X POST http://127.0.0.1:8080/list/db | jq



@app.post("/list/db")
async def mysql_db_list(dep = Depends(verify_api_key("list"))):
    conn = await aiomysql.connect(**DB_CONFIG)
    
    try:
        cursor = await conn.cursor()
        await cursor.execute("SHOW DATABASES")
        rows = await cursor.fetchall()
        databases = [row[0] for row in rows]
        return {"databases": databases}
    finally:
        conn.close()


@app.post("/list/tables")
async def get_tables(request: DatabaseRequest, dep = Depends(verify_api_key("list"))):
    conn = await aiomysql.connect(**DB_CONFIG)
    cursor = await conn.cursor()

    result = {}

    try:
        for db in request.databases:
            try:
                await cursor.execute(f"SHOW TABLES FROM `{db}`")
                tables = await cursor.fetchall()
                result[db] = [table[0] for table in tables]
            except aiomysql.OperationalError as e:
                # MySQL error code 1049: Unknown database
                if e.args[0] == 1049:
                    result[db] = f"Database '{db}' does not exist"
                else:
                    raise HTTPException(status_code=500, detail=str(e))
    finally:
        await cursor.close()
        conn.close()

    return result

def format_bytes(b: int) -> str:
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if b < 1024:
            return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} PB"

def format_uptime(seconds: int) -> str:
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60
    return f"{days}d {hours}h {minutes}m"


@app.post("/dbinfo")
async def get_db_info(dep = Depends(verify_api_key("list"))):
    conn = await aiomysql.connect(**DB_CONFIG)
    cursor = None

    try:
        cursor = await conn.cursor(aiomysql.DictCursor)

        # MySQL version
        await cursor.execute("SELECT VERSION() AS mysql_version")
        mysql_version = (await cursor.fetchone())["mysql_version"]

        # Status variables
        await cursor.execute("SHOW STATUS")
        status = {row["Variable_name"]: row["Value"] for row in await cursor.fetchall()}

        # Config variables
        await cursor.execute("""
            SHOW VARIABLES WHERE Variable_name IN (
                'innodb_buffer_pool_size', 'max_connections',
                'key_buffer_size', 'table_open_cache'
            )
        """)
        variables = {row["Variable_name"]: row["Value"] for row in await cursor.fetchall()}

        # InnoDB pages
        innodb_total = int(status.get("Innodb_buffer_pool_pages_total", 0))
        innodb_free  = int(status.get("Innodb_buffer_pool_pages_free", 0))
        innodb_used  = innodb_total - innodb_free
        innodb_pct   = round((innodb_used / innodb_total * 100), 1) if innodb_total else 0

        # System memory from /proc/meminfo (Linux only)
        mem = {}
        try:
            with open("/proc/meminfo") as f:
                for line in f:
                    key, val = line.split(":")
                    mem[key.strip()] = int(val.strip().split()[0]) * 1024  # kB -> bytes
        except Exception:
            pass

        mem_total     = mem.get("MemTotal", 0)
        mem_free      = mem.get("MemFree", 0)
        mem_available = mem.get("MemAvailable", 0)
        mem_shared    = mem.get("Shmem", 0)
        buff_cache    = mem.get("Buffers", 0) + mem.get("Cached", 0) + mem.get("SReclaimable", 0)
        mem_used      = mem_total - mem_free - buff_cache

        return {
            "mysql_version": mysql_version,
            "uptime": format_uptime(int(status.get("Uptime", 0))),
            "connections": {
                "current":     int(status.get("Threads_connected", 0)),
                "running":     int(status.get("Threads_running", 0)),
                "max_allowed": int(variables.get("max_connections", 0)),
            },
            "innodb": {
                "buffer_pool_size": format_bytes(int(variables.get("innodb_buffer_pool_size", 0))),
                "pages_total":      innodb_total,
                "pages_used":       innodb_used,
                "pages_free":       innodb_free,
                "usage":            f"{innodb_pct}%",
                "read_requests":    int(status.get("Innodb_buffer_pool_read_requests", 0)),
                "disk_reads":       int(status.get("Innodb_buffer_pool_reads", 0)),
            },
            "system_memory": {
                "total":      format_bytes(mem_total),
                "used":       format_bytes(mem_used),
                "free":       format_bytes(mem_free),
                "shared":     format_bytes(mem_shared),
                "buff_cache": format_bytes(buff_cache),
                "available":  format_bytes(mem_available),
            }
        }

    finally:
        if cursor:
            await cursor.close()
        conn.close()


@app.get("/list/files")
async def list_backup_files(dep = Depends(verify_api_key("list"))):
    """List all backup files in the storage location"""
    try:
        backup_dir = BACKUP_ROOT

        if not backup_dir.exists():
            return {"files": [], "message": "Backup directory does not exist"}
        
        files = []
        for file_path in backup_dir.iterdir():
            if file_path.is_file():
                stat = file_path.stat()
                files.append({
                    "filename": file_path.name,
                    "size": stat.st_size,
                    "size_human": format_bytes(stat.st_size),
                    "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
                    "created": datetime.fromtimestamp(stat.st_ctime).isoformat()
                })
        
        # Sort by modified time, newest first
        files.sort(key=lambda x: x["modified"], reverse=True)
        
        return {
            "files": files,
            "count": len(files),
            "total_size": sum(f["size"] for f in files),
            "total_size_human": format_bytes(sum(f["size"] for f in files))
        }
        
    except Exception as e:
        logging.error(f"Error listing backup files: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to list files: {str(e)}")


@app.delete("/delete/{filename}")
async def delete_backup_file(filename: str, dep = Depends(verify_api_key("list"))):
    """Delete a backup file from storage"""
    try:
        # Sanitize filename to prevent directory traversal
        safe_filename = Path(filename).name
        if safe_filename != filename:
            raise HTTPException(status_code=400, detail="Invalid filename")
        
        file_path = BACKUP_ROOT / safe_filename
        
        # Check if file exists
        if not file_path.exists():
            raise HTTPException(status_code=404, detail="File not found")
        
        # Ensure it's a file, not a directory
        if not file_path.is_file():
            raise HTTPException(status_code=400, detail="Not a file")
        
        # Get file info before deletion
        file_size = file_path.stat().st_size
        
        # Delete the file
        file_path.unlink()
        
        logging.info(f"Deleted backup file: {safe_filename} ({format_bytes(file_size)})")
        
        return {
            "message": "File deleted successfully",
            "filename": safe_filename,
            "size": file_size,
            "size_human": format_bytes(file_size)
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logging.error(f"Error deleting file {filename}: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to delete file: {str(e)}")
