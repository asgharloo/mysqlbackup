# Database Backup Automation Platform

An API-driven database backup orchestration platform designed to automate MySQL backup, restore, scheduling, and backup lifecycle management.

The platform uses **FastAPI as the control plane** and **Bash scripts as the execution engine** to run database backup workflows using tools such as **Percona XtraBackup** and **MyDumper**.

## Architecture
            +----------------+
            |   Client/API   |
            +--------+-------+
                     |
                     |
            +--------v-------+
            |    FastAPI     |
            | Control Plane  |
            +--------+-------+
                     |
                     |
            +--------v-------+
            | Bash Execution |
            | Backup Engine  |
            +--------+-------+
                     |
      +--------------+--------------+
      |                             |
      v                             v
      
## Features

### Backup Operations
- Manual backup execution through REST API
- Support for:
  - Full MySQL backup
  - Database-level backup
  - Table-level backup
- Integration with:
  - Percona XtraBackup
  - MyDumper

### Restore Management
- Restore backup files through API
- Background execution for long-running restore operations
- Restore job tracking and status reporting

### Backup Scheduling
- Cron-based automated backup scheduling
- Create, monitor, and deactivate scheduled backup jobs
- Support for recurring backup tasks

### Backup Lifecycle Management
- Upload external backup files
- Download backup archives
- List stored backups
- Delete backup files
- Track backup metadata

### Job Monitoring
- Unique Job ID and Run ID generation
- Execution status tracking:
  - QUEUED
  - RUNNING
  - SUCCESS
  - FAILED
- Backup execution history

### Database Information
Provides MySQL operational information:

- MySQL version
- Active connections
- InnoDB buffer pool usage
- Database and table discovery
- Linux memory statistics


## Technology Stack

- Python
- FastAPI
- Bash
- MySQL
- Percona XtraBackup
- MyDumper
- AsyncIO
- aiomysql
- Linux Cron
- REST API
- Docker


## Example Workflow

1. Client sends backup request to FastAPI API.
2. API validates request and creates a backup job.
3. FastAPI generates the required backup command.
4. Bash execution layer runs the backup process.
5. Job status and execution logs are stored.
6. Client can monitor the backup progress through API endpoints.


## Security

Implemented security controls:

- API key authentication
- Input validation
- Safe filename handling
- Protection against directory traversal attacks


## Use Cases

- Database backup automation
- Infrastructure backup management
- Managed database services
- DevOps backup workflows
- Disaster recovery preparation
