from enum import Enum
from typing import List, Optional
from pydantic import BaseModel, field_validator


# ======================
# ENUMS  (defined ONCE)
# ======================
class BackupType(str, Enum):
    FULL  = "FULL"
    DB    = "DB"
    TABLE = "TABLE"

class ExecutionQuery(BaseModel):
    latest: bool = False

class ScheduleType(str, Enum):
    DAILY   = "DAILY"
    WEEKLY  = "WEEKLY"
    MONTHLY = "MONTHLY"


# ======================
# BACKUP TOOL MAP
# ======================
BACKUP_TOOL_MAP = {
    BackupType.FULL:  "XTRABACKUP",
    BackupType.DB:    "MYDUMPER",
    BackupType.TABLE: "MYDUMPER",
}


# ======================
# SHARED MODELS
# ======================
class DBS(BaseModel):
    db: str
    tables: Optional[List[str]] = None   # None = whole database


class DatabaseRequest(BaseModel):
    databases: List[str]


class Restore_Request(BaseModel):
    backup_type: BackupType


# ======================
# MANUAL BACKUP REQUEST
# ======================
class ManualBackupRequest(BaseModel):
    backup_type: BackupType
    dbs: Optional[List[DBS]] = None


# ======================
# SCHEDULE REQUEST
# ======================
class ScheduleRequest(BaseModel):
    backup_type:   BackupType
    schedule_type: ScheduleType
    schedule_value: str                        # HH:MM
    schedule_days:  Optional[List[int]] = None # WEEKLY=0..6 | MONTHLY=1..31
    dbs_tbls: Optional[List[str]] = None       # ["db1", "db2:t1,t2"]

    @field_validator("schedule_value")
    @classmethod
    def validate_time(cls, v: str) -> str:
        parts = v.split(":")
        if len(parts) != 2:
            raise ValueError("schedule_value must be HH:MM")
        h, m = parts
        if not (h.isdigit() and m.isdigit()):
            raise ValueError("schedule_value must contain digits only")
        h_i, m_i = int(h), int(m)
        if not (0 <= h_i <= 23 and 0 <= m_i <= 59):
            raise ValueError("Invalid time range")
        return f"{h_i:02d}:{m_i:02d}"

    @field_validator("dbs_tbls")
    @classmethod
    def validate_dbs_tbls(cls, v, info):
        backup_type = info.data.get("backup_type")
        if backup_type == BackupType.FULL and v:
            raise ValueError("FULL backup does not accept dbs_tbls")
        if backup_type in (BackupType.DB, BackupType.TABLE) and not v:
            raise ValueError("DB and TABLE backups require dbs_tbls")
        return v

    @field_validator("schedule_days")
    @classmethod
    def validate_days(cls, v, info):
        schedule_type = info.data.get("schedule_type")
        if schedule_type in (ScheduleType.WEEKLY, ScheduleType.MONTHLY):
            if not v:
                raise ValueError("schedule_days is required for WEEKLY/MONTHLY")
            for d in v:
                if schedule_type == ScheduleType.WEEKLY and d not in range(0, 7):
                    raise ValueError("WEEKLY days must be 0..6")
                if schedule_type == ScheduleType.MONTHLY and d not in range(1, 32):
                    raise ValueError("MONTHLY days must be 1..31")
        return v
