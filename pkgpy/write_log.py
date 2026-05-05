#!/usr/bin/env python3
# write_log.py
import argparse
from datetime import datetime
from .status_writer import write_status

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--job-id", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--job-origin", required=True, help="e.g., MANUAL_API, SCHEDULED, RESTORE_API")
    parser.add_argument("--record-type")
    parser.add_argument("--run-id")
    parser.add_argument("--schedule-type")
    parser.add_argument("--backup-type")
    parser.add_argument("--backup-tool")
    parser.add_argument("--mysql-host")
    parser.add_argument("--started-at")
    parser.add_argument("--finished-at")
    parser.add_argument("--backup-file")
    parser.add_argument("--error-code", type=int, default=0)
    parser.add_argument("--error-message", default="")
    parser.add_argument("--dbs-names")

    args = parser.parse_args()

    if args.job_origin in ["MANUAL_API", "SCHEDULED"]:
       log_kind = "execution"  # Routes to EXECUTION_JOBS_FILE
    elif args.job_origin == "RESTORE_API":
       log_kind = "restore"    # Routes to RESTORES_FILE
    else:
         raise ValueError(f"Unknown job origin: {args.job_origin}")

    # Map all parsed arguments to the dictionary
    raw_log_data = {
        "status": args.status,
        "job_id": args.job_id,
        "origin": args.job_origin,
        "backup_type": args.backup_type,
        "backup_tool": args.backup_tool,
        "dbs_names": args.dbs_names,
        "run_id": args.run_id,
        "record_type": args.record_type,  # Fixed
        "schedule_type": args.schedule_type,      
        "mysql_host": args.mysql_host,
        "started_at": args.started_at,
        "finished_at": args.finished_at,
        "backup_file": args.backup_file,
        "error_code": args.error_code,
        "error_message": args.error_message,
        
    }
    # Clean the dictionary by removing any keys where the value is None
    # This keeps your JSON log files tidy if some flags aren't passed by the bash script
    log_data = {k: v for k, v in raw_log_data.items() if v is not None}
    
    # Call the writer with the correct kind
    write_status(kind=log_kind, record=log_data)
    #write_status(kind=log_kind, **log_data)

if __name__ == "__main__":
    main()
