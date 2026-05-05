#!/bin/bash
#CRON_RUN_LOG="/var/log/backup/cron-run.log"
#echo "[$(date -u)] START job_id=${JOB_ID:-none}" >> "$CRON_RUN_LOG"
set -x
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
#
# Backup & Restore Automation (XtraBackup + MyDumper per-DB, Multiple DB/Multiple Table added to configuration)
# Version: 4.1
# Date: 2025-12-16
#
# Full physical backups: Percona XtraBackup
# Per-DB / per-table logical backups: mydumper/myloader
# 
#  one DB , multipl table backup as below
#./mysqlbackup.sh --table-backup alarm_db --tables t1,t2 ✅ works (converted to alarm_db:t1,t2)
## Multiple DB ,Multiple table as below ...
#./mysqlbackup.sh --table-backup --spec "alarm_db:t1,t2;north_db:t3" ✅ works (multi-db, single tar)
                                               ###multiple backup and restore
## Test command for multiple db /Multiple table check: ./mysqlbackup.sh --table-backup --spec "alarm_db:alarm_config,sina_events,;north_db:audit_log"
### Restore is just based on switch and file name  ./mysqlbackup.sh --table-restore MULTI__tables_2025-12-16_08-02-10.tar.gz

set -euo pipefail

############################################
# ==== USER CONFIG / ENV ====================
############################################
###name the  service name for docker swarm 
service_name="dwdm"

MYSQL_VOLUME_NAME="dwdm_mysql_data"
config_path=$(find /etc/path to your swarm config/ -maxdepth 1 -type f -name "*.yaml" | head -n1)



#### to prevent error if not passed varibale 
JOB_ID="${JOB_ID:-}"
# Generate unique run ID for eatch execution
#CONFIG_FILE="$(dirname "$0")/config.sh"
CONFIG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
  else
    echo "Config file not found: $CONFIG_FILE"
    exit 1
  fi


SCHEDULE_TYPE="${SCHEDULE_TYPE:-}"
BACKUP_TYPE="${BACKUP_TYPE:-}"
BACKUP_TOOL="${BACKUP_TOOL:-}"
STARTED_AT="${STARTED_AT:-}"
ERROR_MSG=""
EXIT_CODE=0 

###
JOB_ORIGIN="${JOB_ORIGIN:-MANUAL_SHELL}"

if [[ "${JOB_ORIGIN:-}" == "SCHEDULED" ]]; then
    RUN_ID="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
elif [[ "${JOB_ORIGIN:-}" == "MANUAL_API" || "${JOB_ORIGIN:-}" == "RESTORE_API" ]]; then
    RUN_ID="${RUN_ID:-}"
else
    RUN_ID=""
fi

SCHEDULE_TYPE="${SCHEDULE_TYPE:-null}"
###inside Create_full_backup and table backup become true 
EXECUTION_STARTED=false
BACKUP_DIR="/RemoteBackup"

## /var/log/nms-log/backupserver-log/

mkdir -p "${BACKUP_DIR}/full" "${BACKUP_DIR}/pertbl" 

MYSQL_DATA_DIR="/var/lib/docker/volumes/dwdm_mysql_data/_data"
DOCKER_XB_IMAGE="perconalab/percona-xtrabackup:8.0"
MYSQL_CLIENT_IMAGE="${MYSQL_CLIENT_IMAGE:-mysql:8.0}"

# MyDumper image & tuning
MYDUMPER_IMAGE="mydumper/mydumper:latest"
DUMP_THREADS=${DUMP_THREADS:-8}
LOAD_THREADS=${LOAD_THREADS:-8}
PERDB_KEEP=${PERDB_KEEP:-5}  # number of per-DB backup archives to keep per schema

#MYSQL_PORT=3306
#MYSQL_USER="root"
#MYSQL_PASSWORD="${MYSQL_ROOT_PASS}"


PRIMARY_IFACE=$(/usr/sbin/ip route | awk '/default/ {print $5}')
MYSQL_HOST=$(/usr/sbin/ip -o -4 addr show dev "$PRIMARY_IFACE" | awk 'NR==1 {split($4,a,"/"); print a[1]}')

#MIP="${L2_MAIN_SERVER_IP}"
#SIP="${L2_STANDBY_SERVER_IP}"

# df -P 1K blocks threshold (kept as in your original)
FREE_SPACE_THRESHOLD=10
DELAY_MINUTES=1
ENABLE_LOCK=false

############################################
# ==== ERROR CODES ==========================
############################################
ERR_SCRIPT_LOCKED=100
ERR_NO_SPACE=101
ERR_DOCKER_BACKUP=102
ERR_COMPRESSION=103
ERR_REMOTE_TRANSFER=104
ERR_UNKNOWN_MODE=105
ERR_TIME_FORMAT=106
ERR_INVALID_HOUR=107
ERR_INVALID_MINUTE=108
ERR_INVALID_WEEKDAY=109
ERR_INVALID_MONTH_DAY=110
ERR_DAILY_USAGE=111
ERR_WEEKLY_USAGE=112
ERR_MONTHLY_USAGE=113
ERR_MANUAL_USAGE=114
ERR_USAGE=115
ERR_CRON_FAIL=116
ERR_DETECT_IP=117
ERR_BACKUP_PERDB=118
ERR_MYSQL_DOWN=119
# restore
ERR_RESTORE_MISSING_ARG=200
ERR_RESTORE_FILE_NOT_FOUND=201
ERR_RESTORE_SCALE_FAIL=202
ERR_RESTORE_TIMEOUT_STOP=204
ERR_RESTORE_UNSAFE_DATADIR=205
ERR_RESTORE_CLEAN_FAIL=206
ERR_RESTORE_EXTRACT_FAIL=207
ERR_RESTORE_UNSUPPORTED=208
ERR_RESTORE_DIR_NOT_FOUND=209
ERR_RESTORE_COPYBACK_FAIL=210
ERR_RESTORE_FIXPERM_FAIL=211
ERR_RESTORE_STACK_FAIL=212

# mydumper/myloader
ERR_MYDUMPER=150
ERR_MYLOADER=151
ERR_MYDUMPER_BACKUP=152
ERR_MYDUMPER_RESTORE=153
ERR_RESTORE_SCALE_FAIL=160


         ###########
# ==== LOGGING HELPERS ======================
############################################

logrepl() {
  local ts; ts="$(date '+%F %T')"
  echo "${ts} $*" | tee -a "${LOG_FILE}" # >/dev/null
} 
           logrepl "JOB_ORIGIN: $JOB_ORIGIN"
           logrepl "JOB_ID: $JOB_ID" 
           logrepl "BACKUP_TYPE: $BACKUP_TYPE" 
           logrepl "BACKUP_TOOL: $BACKUP_TOOL" 
           logrepl "MYSQL_HOST: $MYSQL_HOST" 
           logrepl "RUN_ID:   $RUN_ID"
#################################
run_logged() {
  local ts; ts="$(date '+%F %T')"
  echo "${ts} [RUN] $*" | tee -a "${LOG_FILE}"
  "$@" >> "${LOG_FILE}" 2>&1
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "${ts} [ERROR] exit_code=$rc cmd=$*" | tee -a "${LOG_FILE}"
  fi
  return $rc
}

err_exit() {
  local code="$1"; shift || true
  logrepl "ERROR[${code}] $*"
  
 logrepl "BEFORE COME IN IF: $JOB_ORIGIN"       
 if [[ "${JOB_ORIGIN:-}" != "MANUAL_SHELL" ]]; then
    STATUS="FAILED"
    EXIT_CODE="$code"
    ERROR_MSG="$*"
    write_log_file_api " " "FAILD"
  
    chattr -i "$0" 2>/dev/null || true
    logrepl "Unlocked script $0 due to error"
    exit "$code"
 fi
}

logpipe(){
  local stream="${1:-OUT}"
  local level
  while IFS= read -r line; do
    level=""
    if [[ "$line" =~ \[(ERROR|Err|ERR)\] ]] || [[ "$line" =~ ^(FATAL|ERROR|CRITICAL)\b ]]; then level="ERROR";
    elif [[ "$line" =~ \[(Warning|WARN|Warn)\] ]] || [[ "$line" =~ \b(deprecated|deprecation)\b ]]; then level="WARN";
    elif [[ "$line" =~ \[(Note|INFO|Info)\] ]]; then level="INFO"; fi
    logrepl "[${level}] ${line}"
  done
}

#This  Bash helper function that runs a command, logs its output streams separately, and reports errors
 
run(){
  logrepl "[CMD] $*"
  "$@" > >(logpipe OUT) 2> >(logpipe ERR)
  local rc=$?
  if (( rc != 0 )); then logrepl "[ERROR] rc=${rc}: $*"; fi
  return ${rc}
}
######

write_log_file_api() {

 local relpath=$1
 STATUS=$2
 BACKUP_TOOL="${3:-}"

 logrepl "$relpath"
 logrepl "$STATUS"

 #local spec=$3
 FINISHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
 
if [[ "$JOB_ORIGIN" == "MANUAL_SHELL" ]] ; then
      logrepl "Manaull Backup JOB with orgination from $JOB_ORIGIN was finished scuccessfully" 
       return 0
fi 
           logrepl "STATUS: $STATUS" 
           logrepl "write_path=$write_path , hit here"
           logrepl "JOB_ORIGIN: $JOB_ORIGIN"
           logrepl "JOB_ID: $JOB_ID" 
           logrepl "SCHEDULE_TYPE: $SCHEDULE_TYPE" 
           logrepl "BACKUP_TYPE: $BACKUP_TYPE" 
           logrepl "BACKUP_TOOL: $BACKUP_TOOL" 
           logrepl "MYSQL_HOST: $MYSQL_HOST" 
           logrepl "STARTED_AT: $STARTED_AT" 
           logrepl "backup-file: $relpath" 
           logrepl "FINISHED_AT: $FINISHED_AT" 
           logrepl "EXIT_CODE: $EXIT_CODE" 
              CMD=(
                   
                    "$PYTHON" -m pkgpy.write_log
                    --status "$STATUS"
                    --job-id "$JOB_ID"
                    --record-type "EXECUTION"
                    --schedule-type "$SCHEDULE_TYPE"
                    --backup-type "$BACKUP_TYPE"
                    --backup-tool "$BACKUP_TOOL"
                    --mysql-host "$MYSQL_HOST"
                    --run-id "$RUN_ID"
                    --backup-file "$relpath"
                    --started-at "$STARTED_AT"
                    --finished-at "$FINISHED_AT"
                    --error-code "$EXIT_CODE"
                    --error-message "$ERROR_MSG"
                    --job-origin "$JOB_ORIGIN"
                  )

        #if [[ "$BACKUP_TYPE" != "FULL" ]]; then
        #  CMD+=( --dbs-names "$spec" )
        #fi

        run_logged "${CMD[@]}"


} 


############################################
# ==== PRE-CHECKS ===========================
############################################
# figure out remote peer for rsync mirror
# if [[ -n "${MIP}" && -n "${SIP}" ]]; then
#   if [[ "${MYSQL_HOST}" == "${MIP}" ]]; then
#     REMOTE_HOST="${SIP}"
#   elif [[ "${MYSQL_HOST}" == "${SIP}" ]]; then
#     REMOTE_HOST="${MIP}"
#   else
#     err_exit ${ERR_DETECT_IP} "Invalid IP assignment: MYSQL_HOST=${MYSQL_HOST} MIP=${MIP} SIP=${SIP}"
#   fi
# else
#   REMOTE_HOST="${REMOTE_HOST:-}"
# fi

# immutable lock?
if lsattr -d "$0" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
  err_exit ${ERR_SCRIPT_LOCKED} "Script locked for ${DELAY_MINUTES} minute(s)."
fi

############################################
# ==== UTILS ================================
############################################
find_mysqlid(){ docker ps --format '{{.ID}} {{.Names}}' | grep -E '\bdwdm_mysql($|\.)' | awk '{print $1}' | head -n1; }
is_mysql_healthy() {
    local cid

    cid=$(docker ps \
        --format '{{.ID}} {{.Names}}' \
        | awk '$2 ~ /^dwdm_mysql(\.|$)/ {print $1; exit}')

    [[ -z "$cid" ]] && return 1

    docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null \
        | grep -qi '^healthy$'
}

#is_mysql_running() {
#    docker ps --format '{{.Names}}' | grep -q '^dwdm_mysql'
#}

get_free_space(){ df -P "$BACKUP_DIR" | awk 'NR==2 {print $4}'; }
generate_backup_name(){ local type="$1"; echo "${type}_${MYSQL_HOST}_$(date +%F_%H-%M-%S)"; }

# generic retention for typed folders (Daily/Weekly/...)
enforce_retention(){
  local type="$1" limit="$2"; local -a backups
  mapfile -t backups < <(ls -dt "${BACKUP_DIR}/${type}/"*.tar.gz 2>/dev/null || true)
  logrepl "Total ${type} backups: ${#backups[@]} (limit: ${limit})"
  if (( ${#backups[@]} > limit )); then
    local to_delete=("${backups[@]:limit}")
    for f in "${to_delete[@]}"; do logrepl "Pruning old ${type}: $f"; rm -f -- "$f"; done
  fi
}
# retention per schema in /perdb
_enforce_retention_perdb(){
  local schema="$1" limit="$2"; local -a backups
  mapfile -t backups < <(ls -dt "${BACKUP_DIR}/perdb/${schema}_"*.tar.gz 2>/dev/null || true)
  logrepl "Total perdb ${schema}: ${#backups[@]} (limit: ${limit})"
  if (( ${#backups[@]} > limit )); then
    local to_delete=("${backups[@]:limit}")
    for f in "${to_delete[@]}"; do logrepl "Pruning perdb ${schema}: $f"; rm -f -- "$f"; done
  fi
}

      # transfer_to_remote(){
      #   local tar_file="$1"
      #   if [[ ! -f "$tar_file" ]]; then logrepl "Transfer: file not found $tar_file"; return 1; fi
      #   if [[ -z "${REMOTE_HOST:-}" ]]; then logrepl "REMOTE_HOST not set; skipping rsync"; return 0; fi
      #   logrepl "Rsync mirror ${BACKUP_DIR} -> ${MYSQL_USER}@${REMOTE_HOST}:/"
      #   run rm -rf "${BACKUP_DIR}"/restore_* || true
      #   run rsync -avzh --delete "${BACKUP_DIR}" "${MYSQL_USER}@${REMOTE_HOST}:/"
      # }

extract_archive(){
  local tar_file="$1" dest_dir="$2"
  logrepl "Extracting $tar_file"
  if [[ "$tar_file" == *.tar.gz || "$tar_file" == *.tgz ]]; then
    if command -v pigz >/dev/null 2>&1; then run tar -xf "$tar_file" -C "$dest_dir" --use-compress-program=pigz; else run tar -xzf "$tar_file" -C "$dest_dir"; fi
  elif [[ "$tar_file" == *.tar ]]; then run tar -xf "$tar_file" -C "$dest_dir";
  else err_exit ${ERR_RESTORE_UNSUPPORTED} "Unsupported archive: $tar_file"; fi
}

scale_down_replicated_services() {
    logrepl "Scaling down replicated Docker services"

    # Build the service list safely (newline-separated)
    local services
    services="$(docker service ls --format '{{.Name}}\t{{.Mode}}' 2>/dev/null \
        | awk -F'\t' '$2=="replicated" {print $1}' \
        | grep -v '^portainer$' || true)"

    if [[ -z "$services" ]]; then
        logrepl "No replicated services found to scale down"
        return 0
    fi

    # Scale each service to 0
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue

        logrepl "Scaling service '${service}' to 0 replicas"

        if ! docker service scale "${service}=0" --detach >/dev/null 2>&1; then
            err_exit "$ERR_RESTORE_SCALE_FAIL" \
                "Failed to scale service '${service}' to 0 replicas"
        fi
    done <<< "$services"

    logrepl "Waiting for replicated services to be down..."
    sleep 20

    logrepl "All replicated services scaled down successfully"
}

scale_up_replicated_services() {
    local replicas="${1:-1}"

    logrepl "Scaling UP replicated Docker services to ${replicas} replica(s)"

    # Build the service list safely (newline-separated)
    local services
    services="$(docker service ls --format '{{.Name}}\t{{.Mode}}' 2>/dev/null \
        | awk -F'\t' '$2=="replicated" {print $1}' \
        | grep -v '^portainer$' || true)"

    if [[ -z "$services" ]]; then
        logrepl "No replicated services found to scale up"
        return 0
    fi

    # Scale each service
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue

        logrepl "Scaling service '${service}' to ${replicas} replica(s)"

        if ! docker service scale "${service}=${replicas}" --detach >/dev/null 2>&1; then
            err_exit "$ERR_RESTORE_SCALE_FAIL" \
                "Failed to scale service '${service}' to ${replicas} replica(s)"
        fi
    done <<< "$services"

    # Optional wait (keep your sleep if you want a simple fixed delay)
    logrepl "Waiting for replicated services to be up..."
    sleep 20

    logrepl "All replicated services scaled up successfully"
    logrepl "sdddddddddddddddddddddddddddddddddddd"
}


############################################
# ==== FULL BACKUP (XtraBackup) =============
############################################
create_full_backup(){
 
  local type="${1:?missing backup type}"
  local limit_var; limit_var="Keep${type}"
  local limit;     limit="${!limit_var:-3}"
  local free; free=$(get_free_space)
  
  EXECUTION_STARTED=true

    if [[ "$JOB_ORIGIN" == "SCHEDULED" ]] ; then
      write_log_file_api "" "Running" "XTRABACKUP"
    fi 
 
   
  if ! is_mysql_healthy ; then 
     err_exit ${ERR_MYSQL_DOWN} "Mysql is not running "
  fi    
        
  if (( free < FREE_SPACE_THRESHOLD )); then
    err_exit ${ERR_NO_SPACE} "Free blocks ${free} < threshold ${FREE_SPACE_THRESHOLD}"
  fi

  if [[ "${ENABLE_LOCK}" == true ]]; then
    logrepl "Locking ${0} for ${DELAY_MINUTES}m"
    chattr +i "$0" 2>/dev/null || true
  fi

  local name; name=$(generate_backup_name "$type")
  #local path; path="${BACKUP_DIR}/${type}"; mkdir -p "$path"
  #local path; path="${BACKUP_DIR}/full"; mkdir -p "$path"
  local path; path="${BACKUP_DIR}/"; mkdir -p "$path"
  logrepl "Starting ${type} backup (XtraBackup)"
  run docker run --rm --user root \
    -v "${path}:/backup" \
    -v "${MYSQL_DATA_DIR}:/var/lib/mysql" \
    "${DOCKER_XB_IMAGE}" bash -c "\
      xtrabackup --backup \
        --datadir=/var/lib/mysql \
        --target-dir=/backup/${name} \
        --host=${MYSQL_HOST} --port=${MYSQL_PORT} \
        --user=${MYSQL_USER} --password=${MYSQL_PASSWORD} && \
      xtrabackup --prepare --target-dir=/backup/${name}"

  local full; full="${path}/${name}"
  local tarf; tarf="${full}.tar.gz"

  logrepl "Compressing ${full} -> ${tarf}"
  run tar -C "$(dirname "$full")" -czf "$tarf" "$(basename "$full")" || err_exit ${ERR_COMPRESSION} "Compression failed"
   rm -rf "$full"
  # transfer_to_remote "$tarf" || err_exit ${ERR_REMOTE_TRANSFER} "Rsync mirror failed"
  enforce_retention "$type" "$limit"

  if lsattr -d "$0" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
    ( sleep $((DELAY_MINUTES*60)) && chattr -i "$0" && logrepl "Unlocked $0 after ${DELAY_MINUTES}m" ) &
  fi
  logrepl "${type} full backup finished"
  
  ##### write with python Scheduled job and manuall job information   
  EXIT_CODE=$?
  
  #relpath="/full/$(basename $tarf)"
  #####if job request come from api, you should log proper file  
  write_log_file_api "$(basename $tarf)" "SUCCESS" "XTRABACKUP"
 
  
}
  
db_exists() {
  local db="$1"
  [[ -n "$db" ]] || return 1

  # mysql8 should return 0 if query runs; we check output for existence
  local out
  out="$(mysql8 -N -B -e \
    "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${db}' LIMIT 1;" \
    2>/dev/null || true)"

  [[ "$out" == "$db" ]]
}


mysql8() {
  docker run --rm --network host \
    -e MYSQL_PWD="${MYSQL_PASSWORD}" \
    "${MYSQL_CLIENT_IMAGE}" \
    mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" "$@" \
  
}

verify_tables_exist() {
  local schema="$1"
  local tables_csv="$2"

  [[ -n "$schema" && -n "$tables_csv" ]] || err_exit ${ERR_USAGE} "verify_tables_exist: schema and tables_csv required"

  # normalize tables list into array (trim spaces, drop empties)
  local cleaned
  cleaned="$(echo "$tables_csv" | tr -d '[:space:]')"
  IFS=',' read -r -a req <<< "$cleaned"

  local -a req2=()
  local t
  for t in "${req[@]}"; do
    [[ -n "$t" ]] && req2+=("$t")
  done

  ((${#req2[@]} > 0)) || err_exit ${ERR_USAGE} "No tables provided for ${schema}"

  # build IN ('t1','t2',...)
  local in_list=""
  for t in "${req2[@]}"; do
    # simple safety: allow only typical identifier chars
    [[ "$t" =~ ^[A-Za-z0-9_]+$ ]] || err_exit ${ERR_USAGE} "Invalid table name: '$t'"
    in_list+="'${t}',"
  done
  in_list="${in_list%,}"

  local sql="
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema='${schema}'
      AND table_name IN (${in_list})
    ORDER BY table_name;
  "

  mapfile -t found < <(mysql8 -N -B -e "$sql" 2>/dev/null || true)

  # compare
  local -A have=()
  for t in "${found[@]}"; do
    t="$(echo "$t" | tr -d '[:space:]')"
    [[ -n "$t" ]] && have["$t"]=1
  done

  local -a missing=()
  for t in "${req2[@]}"; do
    [[ -z "${have[$t]:-}" ]] && missing+=("$t")
  done

  if ((${#missing[@]} > 0)); then
    err_exit ${ERR_MYDUMPER_RESTORE:-153} "Some tables requested for backup were not found: $(IFS=,; echo "${missing[*]}")"
  fi
}

backup_tables() {

  local spec="$1"
  local spec_out="$1"
  
  [[ -n "$spec" ]] || err_exit ${ERR_USAGE} \
    "--table-backup spec required. Examples:
     --table-backup db1
     --table-backup db1,db2
     --table-backup db1 --tables t1,t2
     --table-backup --spec \"db1:t1,t2;db2:t3\""

   EXECUTION_STARTED=true

   if [[ "$JOB_ORIGIN" == "SCHEDULED" ]] ; then
      write_log_file_api " " "Running" "MYDUMPER"
      
   fi 
 

  local ts; ts="$(date +%F_%H-%M-%S)"
  #local root_dir="${BACKUP_DIR}/pertbl/DB_tables_${ts}"
  local name="DB_tables_${ts}"
  local root_dir="${BACKUP_DIR}/pertbl/DB_tables_${ts}"
  mkdir -p "$root_dir"

  logrepl "Starting table backup: spec='${spec}'"
  logrepl "checking Databases and tables validity"
 

  # Normalize ONLY db-list form (db1,db2,db3) => ';'
  # If spec contains ':' we assume it uses ';' between items already.
  local items_str="$spec"
  if [[ "$items_str" != *":"* && "$items_str" == *","* ]]; then
    items_str="${items_str//,/;}"
  fi

  local IFS=';'
  read -r -a items <<<"$items_str"
   # ---------- PRECHECK: validate all DBs and TABLES exist BEFORE scaling down ----------
  declare -A need_dbs=()
  declare -A need_tables=()   # key: schema  value: "t1,t2" aggregated

  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "$item" ]] || continue

    if [[ "$item" == *:* ]]; then
      local schema="${item%%:*}"
      local tables_csv="${item#*:}"

      [[ -n "$schema" && -n "$tables_csv" && "$schema" != "$tables_csv" ]] \
        || err_exit ${ERR_USAGE} "Bad spec item: '$item' (expected db:t1,t2)"

      need_dbs["$schema"]=1

      # aggregate tables for same schema across multiple spec items
      if [[ -n "${need_tables[$schema]:-}" ]]; then
        need_tables["$schema"]+=",${tables_csv}"
      else
        need_tables["$schema"]="${tables_csv}"
      fi
    else
      local schema="$item"
      [[ -n "$schema" ]] || err_exit ${ERR_USAGE} "Invalid spec item: '$item'"
      need_dbs["$schema"]=1
    fi
  done

  # DB existence first
  for db in "${!need_dbs[@]}"; do
    db_exists "$db" || err_exit ${ERR_USAGE} "Database not found: '${db}'"
  done

  # TABLE existence next (only for schemas that had :tables)
  for db in "${!need_tables[@]}"; do
    verify_tables_exist "$db" "${need_tables[$db]}"
  done
  # -----------------------------------------------------------------------------------------------------------------------
  # scale down replicated services ONLY after validation succeeds
  scale_down_replicated_services

  # (Optional optimization) avoid re-checking same DB multiple times inside loop
  declare -A checked_dbs=()

  for item in "${items[@]}"; do
    item="$(echo "$item" | tr -d '[:space:]')"
    [[ -n "$item" ]] || continue
    local schema tables_csv out_sub
    local mydumper_args=(
      -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}"
      -t "${DUMP_THREADS}" --compress --trx-tables
    )

    if [[ "$item" == *:* ]]; then
      # ---------- TABLE-LEVEL BACKUP ----------
      schema="${item%%:*}"
      tables_csv="${item#*:}"

      [[ -n "$schema" && -n "$tables_csv" && "$schema" != "$tables_csv" ]] \
        || err_exit ${ERR_USAGE} "Bad spec item: '$item' (expected db:t1,t2)"

      # DB exists check (cached)
      if [[ -z "${checked_dbs[$schema]:-}" ]]; then
        db_exists "$schema" || err_exit ${ERR_USAGE} "Database not found: '${schema}'"
        checked_dbs[$schema]=1
      fi

      verify_tables_exist "$schema" "$tables_csv"

      local qualified=""
      IFS=',' read -r -a arr <<<"$(echo "$tables_csv" | tr -d '[:space:]')"
      for t in "${arr[@]}"; do
        [[ -n "$t" ]] || continue
        qualified+="${schema}.${t},"
      done
      qualified="${qualified%,}"

      local sub="__tables_$(echo "$tables_csv" | tr ',' '+')"
      out_sub="${root_dir}/${schema}${sub}"

      mydumper_args+=(
        -B "${schema}"
        -T "${qualified}"
        -o "/backup/pertbl/$(basename "$root_dir")/$(basename "$out_sub")"
      )

      logrepl "Backing up ${schema} tables: ${tables_csv}"

    else
      # ---------- FULL DB (ALL TABLES) ----------
      schema="$item"
      [[ -n "$schema" ]] || err_exit ${ERR_USAGE} "Invalid database name in spec"

      # DB exists check (cached)
      if [[ -z "${checked_dbs[$schema]:-}" ]]; then
        db_exists "$schema" || err_exit ${ERR_USAGE} "Database not found: '${schema}'"
        checked_dbs[$schema]=1
      fi

      out_sub="${root_dir}/${schema}__ALL_TABLES"
      mydumper_args+=(
        -B "${schema}"
        -o "/backup/pertbl/$(basename "$root_dir")/$(basename "$out_sub")"
      )

      logrepl "Backing up ALL tables from database: ${schema}"
    fi

    run docker run --rm \
      -e MYSQL_PWD="${MYSQL_PASSWORD}" \
      -v "${BACKUP_DIR}:/backup" \
      "${MYDUMPER_IMAGE}" mydumper "${mydumper_args[@]}" \
      || err_exit ${ERR_MYDUMPER} "mydumper failed for ${schema}"
  done

  local tarf="${root_dir}.tar.gz"
  run tar -C "$(dirname "$root_dir")" -czf "$tarf" "$(basename "$root_dir")" \
    || err_exit ${ERR_COMPRESSION} "tar failed for multi-table backup"

  
  #mv "$root_dir" $BACKUP_DIR
  logrepl "filename and path: $tarf"
  local filename="$(basename $tarf)"
  mv "$tarf" $BACKUP_DIR
  rm -rf "$BACKUP_DIR/pertbl/"

  scale_up_replicated_services 1
  
  logrepl "Done: table backup -> $(basename "$tarf")"
  EXIT_CODE=$?
  
  write_log_file_api "$filename" "SUCCESS" "MYDUMPER"
  #logrepel "${SCHEDULE_TYPE} JOB with JOBID of:${JOB_ID} FINISHED form origin:${$JOB_ORIGIN} FILENAME${TAR_FILE}"
  
}

restore_mydumper_backup() {
  
  local backup_file="${1:-}"
  [[ -n "$backup_file" ]] || err_exit ${ERR_USAGE} "Usage: $0 --restore <file.tar.gz>"

  local kind="" backup_path="" base_dir=""
  local tmpdir=""          # set -u safe
  local -a dump_roots=()

  ###in partial table restore we have this approach, so use wip_table_data 
    # ✅ Don’t drop tables
    # ✅ Don’t restore schemas (because schema restore tries CREATE TABLE)
    # ✅ Restore data only, and (optionally) truncate the target tables first

  logrepl "Starting restoring with mydumper: $backup_file"

  wipe_table_data() {
  local schema="$1" t="$2"

  # Try TRUNCATE first (fast)
  if mysql8 -e "SET FOREIGN_KEY_CHECKS=0; TRUNCATE TABLE \`${schema}\`.\`${t}\`; SET FOREIGN_KEY_CHECKS=1;" >/dev/null 2>&1; then
    logrepl "Truncated: ${schema}.${t}"
    return 0
  fi

  # Fallback to DELETE (slower but more compatible)
  if mysql8 -e "SET FOREIGN_KEY_CHECKS=0; DELETE FROM \`${schema}\`.\`${t}\`; SET FOREIGN_KEY_CHECKS=1;" >/dev/null 2>&1; then
    logrepl "Deleted rows: ${schema}.${t}"
    return 0
  fi

  return 1
}

  kind="tables"
  base_dir="${BACKUP_DIR}"
  backup_path="${BACKUP_DIR}/${backup_file}"

   logrepl "Trying to restore (${kind}) from ${backup_file}"

  # --- Always cleanup + scale back up ---
  #trap 'rc=$?;
  #      if [[ -n "${tmpdir:-}" && -d "${tmpdir:-}" ]]; then rm -rf "$tmpdir" 2>/dev/null || true; fi
  #      scale_up_replicated_services 1 >/dev/null 2>&1 || true;
  #      trap - EXIT;
  #      exit $rc' EXIT

  # --- Extract into temp dir UNDER BACKUP_DIR so container sees it ---
  tmpdir="$(mktemp -d "${base_dir}/restore_${kind}.XXXXXX")" \
    || err_exit ${ERR_MYDUMPER_RESTORE} "mktemp failed under: ${base_dir}"

  tar -xf "$backup_path" -C "$tmpdir" \
    || err_exit ${ERR_MYDUMPER_RESTORE} "Failed to extract ${backup_file}"

  # -------------------------
  # Helper parsers
  # -------------------------
  parse_schema_from_schemafile() {
    local f="$1"
    local s="${f%%.*}"            # topology_db-schema-create
    s="${s%-schema-create}"       # topology_db
    s="${s%-schema}"              # topology_db
    echo "$s"
  }

  parse_table_from_schemafile() {
    # input is something like: topology_db.node-schema.sql.zst  OR  topology_db.node-schema-create.sql.zst
    local schema="$1"
    local f="$2"
    local rest base t
    rest="${f#${schema}.}"        # node-schema.sql.zst
    base="${rest%%.*}"            # node-schema
    t="${base%-schema-create}"    # node-schema
    t="${t%-schema}"              # node
    echo "$t"
  }

  # ------------------------------------------------------------
  # Discover dump roots robustly:
  # - Prefer dirs that contain metadata + at least one *.sql* file
  # - If only one shared metadata exists, treat each sql-containing subdir
  #   as a root and copy the shared metadata into it.
  # ------------------------------------------------------------
  mapfile -t candidates < <(find "$tmpdir" -type f -name "*.sql*" -printf '%h\n' | sort -u)
  ((${#candidates[@]} > 0)) || err_exit ${ERR_MYDUMPER_RESTORE} "No *.sql* files found inside ${backup_file}"

  mapfile -t meta_dirs < <(find "$tmpdir" -type f -name metadata -printf '%h\n' | sort -u)

  # roots where metadata is colocated with sql files
  local d
  for d in "${meta_dirs[@]}"; do
    if find "$d" -maxdepth 1 -type f -name "*.sql*" | grep -q .; then
      dump_roots+=("$d")
    fi
  done

  # shared-metadata layout: copy shared metadata into each candidate dir
  if ((${#dump_roots[@]} == 0)); then
    local shared_meta
    shared_meta="$(find "$tmpdir" -type f -name metadata -print -quit || true)"
    [[ -n "$shared_meta" ]] || err_exit ${ERR_MYDUMPER_RESTORE} "No mydumper metadata found in ${backup_file}"

    for d in "${candidates[@]}"; do
      [[ "$d" == "$tmpdir" ]] && continue
      [[ -f "$d/metadata" ]] || cp -f "$shared_meta" "$d/metadata" \
        || err_exit ${ERR_MYDUMPER_RESTORE} "Failed to copy shared metadata into: $d"
      dump_roots+=("$d")
    done
  fi

  # de-duplicate roots
  mapfile -t dump_roots < <(printf "%s\n" "${dump_roots[@]}" | sort -u)
  ((${#dump_roots[@]} > 0)) || err_exit ${ERR_MYDUMPER_RESTORE} "No usable dump roots detected in ${backup_file}"

  # Scale down ONCE
  scale_down_replicated_services
  mysql8 -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;" >/dev/null 2>&1 || true

  # =====================================================================
  # TABLES restore mode (pertbl)
  # =====================================================================
  if [[ "$kind" == "tables" ]]; then
    local root fname schema container_dump_dir
    local -a tables
    declare -A dropped_once=()   # key: "schema.table" => 1, prevents double-drop across roots

    for root in "${dump_roots[@]}"; do
      # Find schema file for DB in this root
      fname="$(find "$root" -maxdepth 1 -type f \
                \( -name "*-schema.sql*" -o -name "*-schema-create.sql*" \) \
                -printf '%f\n' | head -n1)"
      [[ -n "$fname" ]] || err_exit ${ERR_MYDUMPER_RESTORE} "Cannot detect schema name in: $root"

      schema="$(parse_schema_from_schemafile "$fname")"
      [[ -n "$schema" ]] || err_exit ${ERR_MYDUMPER_RESTORE} "Schema parse failed for: $fname"

      container_dump_dir="/backup${root#${BACKUP_DIR}}"
      logrepl "Restoring tables root: $(basename "$root") -> schema=${schema}"

      # Full DB dump marker
      if [[ "$(basename "$root")" == *"__ALL_TABLES"* ]]; then
        logrepl "ALL_TABLES detected -> dropping and recreating database '${schema}'"
        mysql8 -e "DROP DATABASE IF EXISTS \`${schema}\`;" >/dev/null 2>&1 \
          || err_exit ${ERR_MYDUMPER_RESTORE} "Failed to drop database ${schema}"
        mysql8 -e "CREATE DATABASE \`${schema}\`;" >/dev/null 2>&1 \
          || err_exit ${ERR_MYDUMPER_RESTORE} "Failed to create database ${schema}"

      else
        # ----- Robust table list: ONLY from table schema files -----
        tables=()
        while IFS= read -r f; do
          [[ "$f" == "${schema}."* ]] || continue
          [[ "$f" == *"-schema.sql"* || "$f" == *"-schema-create.sql"* ]] || continue

          local t
          t="$(parse_table_from_schemafile "$schema" "$f")"
          [[ -n "$t" ]] && tables+=("$t")
        done < <(find "$root" -maxdepth 1 -type f -printf '%f\n')

        if (( ${#tables[@]} == 0 )); then
          err_exit ${ERR_MYDUMPER_RESTORE} "No table schema files found in $(basename "$root") (cannot determine tables to drop)"
        fi

        mapfile -t tables < <(printf "%s\n" "${tables[@]}" | sort -u)

        mysql8 -e "SET FOREIGN_KEY_CHECKS=0;" >/dev/null 2>&1 || true

        local t key cnt

        for t in "${tables[@]}"; do
          logrepl "Clearing data before restore: ${schema}.${t}"
           wipe_table_data "$schema" "$t" || err_exit ${ERR_MYDUMPER_RESTORE} "Failed to clear data for ${schema}.${t}"
        done
        
        mysql8 -e "SET FOREIGN_KEY_CHECKS=1;" >/dev/null 2>&1 || true
      fi
      # Restore this root
      run docker run --rm \
       -e MYSQL_PWD="${MYSQL_PASSWORD}" \
       -v "${BACKUP_DIR}:/backup" \
           "${MYDUMPER_IMAGE}" myloader \
       -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" \
       -d "${container_dump_dir}" \
       -B "${schema}" \
       --threads="${LOAD_THREADS}" \
       --overwrite-tables \
       --no-schema \
       || err_exit ${ERR_MYDUMPER_RESTORE} "myloader failed for schema=${schema} (dir=${container_dump_dir})"

      logrepl "Done restoring tables for ${schema}"
    done
    logrepl "cleanup temp directory"
    rm -fr "${tmpdir}"
    logrepl "Table restore complete: ${backup_file}"
    
  fi

  # =====================================================================
  # DBS restore mode (perdb)
  # =====================================================================
  if [[ "$kind" == "dbs" ]]; then
    local root container_dump_dir
    for root in "${dump_roots[@]}"; do
      container_dump_dir="/backup${root#${BACKUP_DIR}}"
      logrepl "Starting myloader restore from ${root}"

      run docker run --rm \
        -e MYSQL_PWD="${MYSQL_PASSWORD}" \
        -v "${BACKUP_DIR}:/backup" \
        "${MYDUMPER_IMAGE}" myloader \
          -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" \
          -d "${container_dump_dir}" \
          --threads="${LOAD_THREADS}" \
          --overwrite-tables \
        || err_exit ${ERR_MYDUMPER_RESTORE} "myloader failed for dump root: ${root}"

      logrepl "Finished myloader restore from ${root}"
    done
    

    logrepl "cleanup temp directory"
    rm -fr "${tmpdir}"
    logrepl "DB restore complete: ${backup_file}"
    
  fi
   logrepl "cleanup temp directory"
    rm -fr "${tmpdir}" 
     run docker stack deploy -c "${config_path}" "${service_name}"

  COUNT=0; MAX_RETRIES=5
  until cid="$(find_mysqlid)" && [[ -n "${cid:-}" ]] && is_mysql_healthy "${cid}"; do
    (( COUNT++ >= MAX_RETRIES )) && err_exit ${ERR_RESTORE_STACK_FAIL} "MySQL not healthy"
    logrepl "Waiting for dwdm_mysql to be healthy ($COUNT/$MAX_RETRIES)"; sleep 10
  done

  ###Final verification that stack is up 
  if ! is_mysql_healthy "${cid}"; then
    logrepl "[ERROR] Stack ${cid} is not healthy after resotration "
    err_exit ${ERR_RESTORE_STACK_FAIL}
  fi  
  
  scale_up_replicated_services
  
  ###cleanup temp directory
  rm -fr "${BACKUP_DIR}/xtrabackup-restore*"

  logrepl "partial backup via mydumper done  and stack healthy"
  write_log_file_api "$backup_file" "SUCCESS" "MYDUMPER"
   
}


############################################
# ==== FULL RESTORE (XtraBackup) ============
############################################
restore_full(){
  #local input="$1"
   local tar_file

  tar_file="$1"
  
  #[[ -n "$input" ]] || err_exit ${ERR_RESTORE_MISSING_ARG} "Provide tar(.gz) file or name"
  [[ -n "$tar_file" ]] || err_exit ${ERR_RESTORE_MISSING_ARG} "Provide tar(.gz) file or name"
 
  #if [[ -f "$input" ]]; then tar_file="$input"; else
    #local Btype; Btype=$(basename "$input" | awk -F '_' '{print $1;}')
    local filename=$1
    tar_file="${BACKUP_DIR}/${tar_file}"

  [[ -f "$tar_file" ]] || err_exit ${ERR_RESTORE_FILE_NOT_FOUND} "Not found: $tar_file"
  logrepl "Starting Full Backup Restore filename: $tar_file"
  logrepl "Stopping stack ${service_name}"
  run docker stack rm "${service_name}" || true
  local COUNT=0 MAX_RETRIES=5
  while docker ps --format '{{.Names}}' | grep -qE '\bdwdm_mysql($|\.)'; do
    (( COUNT++ >= MAX_RETRIES )) && err_exit ${ERR_RESTORE_SCALE_FAIL} "MySQL did not stop"
    logrepl "Waiting MySQL container to terminate ($COUNT/$MAX_RETRIES)"; sleep 10
  done

  logrepl "Removing volume ${MYSQL_VOLUME_NAME}"
  run docker volume rm --force "${MYSQL_VOLUME_NAME}" || true
  COUNT=0; MAX_RETRIES=5
  while docker volume inspect "${MYSQL_VOLUME_NAME}" >/dev/null 2>&1; do
    (( COUNT++ >= MAX_RETRIES )) && err_exit ${ERR_RESTORE_CLEAN_FAIL} "Volume remove failed"
    sleep 10
  done

  local tmp_restore_dir; tmp_restore_dir=$(mktemp -d "${BACKUP_DIR}/xtrabackup-restore.XXXXXX")
  extract_archive "$tar_file" "$tmp_restore_dir"
  local target_dir; target_dir=$(find "$tmp_restore_dir" -type f -name 'xtrabackup_info' -printf '%h\n' | head -n1 || true)
  [[ -n "$target_dir" ]] || err_exit ${ERR_RESTORE_DIR_NOT_FOUND} "xtrabackup directory not found"

  logrepl "Copy-back with ${DOCKER_XB_IMAGE}"
  run docker run --rm --user root \
    -v "${MYSQL_DATA_DIR}:/var/lib/mysql" \
    -v "${target_dir}:/backup:ro" \
    "${DOCKER_XB_IMAGE}" \
    bash -c "xtrabackup --copy-back --target-dir=/backup --datadir=/var/lib/mysql"
  run chown -R 999:999 "${MYSQL_DATA_DIR}"

  logrepl "Deploying stack ${service_name}"

  run docker stack deploy -c "${config_path}" "${service_name}"
  COUNT=0; MAX_RETRIES=5
  until cid="$(find_mysqlid)" && [[ -n "${cid:-}" ]] && is_mysql_healthy "${cid}"; do
    (( COUNT++ >= MAX_RETRIES )) && err_exit ${ERR_RESTORE_STACK_FAIL} "MySQL not healthy"
    logrepl "Waiting for dwdm_mysql to be healthy ($COUNT/$MAX_RETRIES)"; sleep 10
  done

  ###Final verification that stack is up 

  if ! is_mysql_healthy "${cid}"; then
    logrepl "[ERROR] Stack ${cid} is not healthy after resotration "
    err_exit ${ERR_RESTORE_STACK_FAIL}
  fi   
  
  scale_up_replicated_services 1
  
  #rm -fr "${BACKUP_DIR}/xtrabackup-restore*"
  rm -fr "${tmp_restore_dir}"
  logrepl "Full restore completed and stack healthy"

    write_log_file_api "${filename}" "SUCCESS"

}

check_hour_format() {
  local time=${1}
  if ! [[ "${time}" =~ ^([0-9]{1,2}):([0-9]{1,2})$ ]]; then
    err_exit "${ERR_TIME_FORMAT}" "Invalid time format: ${time}. Must be HH:MM"
  fi
  local hour=${BASH_REMATCH[1]}
  local minute=${BASH_REMATCH[2]}
  if (( hour < 0 || hour > 23 )); then
    err_exit "${ERR_TIME_FORMAT}" "Invalid hour: ${hour} (0-23)."
  fi
  if (( minute < 0 || minute > 59 )); then
    err_exit "${ERR_TIME_FORMAT}" "Invalid minute: ${minute} (0-59)."
  fi
}


############################################
# ==== CRON HELPERS =========================
############################################
update_cron_job(){
  local mode="${1:?mode required}"
  local schedule
  local label
  local COMMAND
  
  case "$mode" in
    daily)   
      local time="$2"
      check_hour_format "$time"
      local hour="${time%%:*}" min="${time##*:}"
      schedule="${min} ${hour} * * *"
      ;;
    weekly)
      local day="$2" time="$3"
      [[ "$day" =~ ^[0-6]$ ]] || err_exit ${ERR_INVALID_WEEKDAY} "Weekday 0..6"
      check_hour_format "$time"
      local hour="${time%%:*}" min="${time##*:}"
      schedule="${min} ${hour} * * ${day}"
      ;;
    monthly)
      local day="$2" time="$3"
      [[ "$day" =~ ^([1-9]|[12][0-9]|30)$ ]] || err_exit ${ERR_INVALID_MONTH_DAY} "Day 1..30"
      check_hour_format "$time"
      local hour="${time%%:*}" min="${time##*:}"
      schedule="${min} ${hour} ${day} * *"
      ;;
    *) err_exit ${ERR_UNKNOWN_MODE} "Unknown mode: $mode" ;;
  esac
  
  label="# nbackup-${mode}:${JOB_ID}"
  COMMAND="$(realpath "$0")"
  
  local ENV_VARS="JOB_ORIGIN=SCHEDULED JOB_ID=${JOB_ID} SCHEDULE_TYPE=${mode^^} BACKUP_TYPE=FULL"
  
  local cron_line="${schedule} ${ENV_VARS} ${COMMAND} --${mode} ${label}"
  
  (crontab -l 2>/dev/null | grep -v -F "${label}"; echo "${cron_line}") | crontab - \
    || err_exit ${ERR_CRON_FAIL} "Update cron failed"
    
  logrepl "Cron updated: ${cron_line}"
}


update_db_cron_job() {
  local mode="${1:?mode required}"
  local db_csv="${2:?db list required}"
  local schedule
  local label
  local time day

  case "$mode" in
    daily)
      time="${3:?HH:MM required}"
      check_hour_format "$time"
      local hour="${time%%:*}" min="${time##*:}"
      schedule="${min} ${hour} * * *"
      ;;
    weekly)
      day="${3:?weekday 0..6 required}"
      [[ "$day" =~ ^[0-6]$ ]] || err_exit ${ERR_INVALID_WEEKDAY} "Weekday 0..6"
      time="${4:?HH:MM required}"
      check_hour_format "$time"
      local hour="${time%%:*}" min="${time##*:}"
      schedule="${min} ${hour} * * ${day}"
      ;;
    monthly)
      day="${3:?day 1..30 required}"
      [[ "$day" =~ ^([1-9]|[12][0-9]|30)$ ]] || err_exit ${ERR_INVALID_MONTH_DAY} "Day 1..30"
      time="${4:?HH:MM required}"
      check_hour_format "$time"
      local hour="${time%%:*}" min="${time##*:}"
      schedule="${min} ${hour} ${day} * *"
      ;;
    *) err_exit ${ERR_UNKNOWN_MODE} "Unknown mode: $mode" ;;
  esac

  local safe_set="${db_csv//,/+}"
  label="# nbackup-db-${mode}:${JOB_ID}"   # ← use JOB_ID like the multi function

  local COMMAND="$(realpath "$0")"
  #local ENV_VARS="JOB_ORIGIN=SCHEDULED JOB_ID=${JOB_ID} SCHEDULE_TYPE=${mode^^} BACKUP_TYPE=TABLE BACKUP_TOOL=MYDUMPER MYSQL_HOST=${MYSQL_HOST}"
  local ENV_VARS="JOB_ORIGIN=SCHEDULED JOB_ID=${JOB_ID}"

  local cron_line="${schedule} ${ENV_VARS} ${COMMAND} --table-backup ${db_csv} ${label}"

  (crontab -l 2>/dev/null | grep -v -F "${label}"; echo "${cron_line}") | crontab - \
    || err_exit ${ERR_CRON_FAIL} "Update cron failed"

  logrepl "Cron updated: ${cron_line}"
}



update_Multi_db_tb_cron_job() {
  local mode="${1:?mode required}"       # daily | weekly | monthly
  local spec="${2:?spec required}"       # db1:t1,t2;db2:t3
  local schedule time day

  case "$mode" in
    daily)
      time="$3"
      schedule="$(echo "$time" | awk -F: '{print $2" "$1" * * *"}')"
      ;;
    weekly)
      day="$3"; time="$4"
      schedule="$(echo "$time" | awk -F: '{print $2" "$1" * * '"$day"'"}')"
      ;;
    monthly)
      day="$3"; time="$4"
      schedule="$(echo "$time" | awk -F: '{print $2" "$1" '"$day"' * *"}')"
      ;;
    *)
      err_exit 105 "Unknown mode $mode"
      ;;
  esac

  local COMMAND
  COMMAND="$(realpath "$0")"

  # put here Job id to send out to crontab
  local ENV_VARS
 
  #ENV_VARS="JOB_ORIGIN="SCHEDULED" JOB_ID=${JOB_ID} SCHEDULE_TYPE=${mode^^} BACKUP_TYPE=TABLE BACKUP_TOOL=MYDUMPER MYSQL_HOST=${MYSQL_HOST}"
  ENV_VARS="JOB_ORIGIN="SCHEDULED" JOB_ID=${JOB_ID} SCHEDULE_TYPE=${mode^^}"
  
  local label="# nbackup-${mode}:${JOB_ID}"

  #local cron_line="  ${schedule} ${ENV_VARS} ${COMMAND} --table-backup --spec \"${spec}\" ${label}"
  local cron_line="${schedule} ${ENV_VARS} ${COMMAND} --table-backup --spec \"${spec}\" ${label}"

  (crontab -l 2>/dev/null | grep -v -F "${label}"; echo "${cron_line}") | crontab - \
    || err_exit 116 "Update cron failed"

  logrepl "Cron updated: ${cron_line}"
}


############################################
# ==== MAIN =================================
############################################
KeepDaily=2; KeepWeekly=4; KeepMonthly=2; KeepManual=3

logrepl "HI ${JOB_ORIGIN}"

is_type=0; [[ "$#" == 2 ]] && is_type=1; [[ "$#" == 3 ]] && is_type=2
case "${1:-}" in
  --daily)
    if [[ $is_type -eq 1 ]]; then check_hour_format "$2"; update_cron_job daily "$2"; else create_full_backup Daily; fi ;;
  --weekly)
    if [[ $is_type -eq 2 ]]; then [[ "$2" =~ ^[0-6]$ ]] || err_exit ${ERR_INVALID_WEEKDAY} "Weekday 0..6"; check_hour_format "$3"; update_cron_job weekly "$2" "$3"; else create_full_backup Weekly; fi ;;
  --monthly)
    if [[ $is_type -eq 2 ]]; then [[ "$2" =~ ^([1-9]|[12][0-9]|30)$ ]] || err_exit ${ERR_INVALID_MONTH_DAY} "Day 1..30"; check_hour_format "$3"; update_cron_job monthly "$2" "$3"; else create_full_backup Monthly; fi ;;
  --manually)
    [[ $is_type -eq 0 ]] || err_exit ${ERR_MANUAL_USAGE} "Usage: $0 --manually"; create_full_backup Manual 
    ;;

  
 --table-backup)
  # Option 1: explicit spec string (supports db-only items too: "db1;db2:t1,t2;db3")
  if [[ "${2:-}" == "--spec" ]]; then
    
    [[ -n "${3:-}" ]] || err_exit ${ERR_USAGE} \
      "Usage: $0 --table-backup --spec \"db1:t1,t2;db2:t3\" (also supports db-only items like \"db1;db2\")"
    backup_tables "$3"

  # Option 2: shorthand: --table-backup <db[,db2,...]> [--tables t1,t2]
  else
    [[ -n "${2:-}" ]] || err_exit ${ERR_USAGE} \
      "Usage: $0 --table-backup <db[,db2,...]> [--tables t1,t2]"

    if [[ "${3:-}" == "--tables" ]]; then
      [[ -n "${4:-}" ]] || err_exit ${ERR_USAGE} \
        "Usage: $0 --table-backup <db> --tables t1,t2"
      # db + tables
      
      backup_tables "${2}:${4}"
    else
      # db list only => ALL TABLES (backup_tables handles db1,db2,db3)
      backup_tables "${2}"
    fi
  fi
  ;;

  --tb-daily)
    # Usage: --db-daily db1,db2 HH:MM   (schedule)
    [[ $# -gt 2 ]] || err_exit ${ERR_USAGE} "Usage: $0 --db-daily db1 [--tables] [t1,t2,t3] HH:MM"

     if [[ $2 == "--spec" ]]; then 
          [[ $# -eq 4 ]] || err_exit ${ERR_USAGE} \
              "Usage: $0 --tb-daily <--spec>  <db1:t1,db2:t2,db3:t3,t4> <HH:MM>"  
         update_Multi_db_tb_cron_job daily "$3" "$4"
        
    elif [[ $3 == "--tables" ]]; then 
        [[ $# -eq 5 ]] || err_exit ${ERR_USAGE} \
         "Usage: $0 --tb-daily <db> [--tables] [t1,t2] <HH:MM>"
         daily_parm="$2 --tables $4" 
         update_db_cron_job daily "${daily_parm}" "$5"

     elif [[ $# == 3 ]]; then
        update_db_cron_job daily "$2" "$3"
      
     else
           err_exit ${ERR_USAGE} "Usage: $0 --db-daily db1 [--tables] [t1,t2,t3] HH:MM"
      fi      
    ;;

  --tb-weekly)
    # Usage: --db-weekly db1,db2 D HH:MM   (0=Sun..6=Sat)
   # [[ $# -gt 3 ]] ||  err_exit ${ERR_USAGE} "Usage: $0 --db-weekly db1[db2,db3] [--tables] [t1,t2,t3]  D HH:MM"
     if [[ $2 == "--spec" ]]; then 
          [[ $# -eq 5 ]] || err_exit ${ERR_USAGE} \
              "Usage: $0 --tb-weekly <--spec>  <db1:t1,db2:t2,db3:t3,t4> <0-6><HH:MM>"  
         update_Multi_db_tb_cron_job weekly "$3" "$4" "$5"
    elif [[ $3 == "--tables" ]]; then 
        [[ $# -eq 6 ]] || err_exit ${ERR_USAGE} \
         "Usage: $0 --tb-weekly <db> [--tables] [t1,t2] <0-6 ><HH:MM> "
         daily_parm="$2 --tables $4" 
         update_db_cron_job weekly "${daily_parm}" "$5" "$6"

     elif [[ $# == 4 ]]; then
        update_db_cron_job weekly "$2" "$3" "$4"
      
     else
           err_exit ${ERR_USAGE} "Usage: $0 --db-weekly db1 [--tables] [t1,t2,t3] <0-6> HH:MM"
      fi      
    ;;
   
  --tb-monthly)
    # Usage: --db-monthly db1,db2 D HH:MM  (D=1..30)
      
    if [[ $2 == "--spec" ]]; then 
          [[ $# -eq 5 ]] || err_exit ${ERR_USAGE} \
              "Usage: $0 --tb-monthly <--spec>  <db1:t1,db2:t2,db3:t3,t4> <1-30> <HH:MM>"  
         update_Multi_db_tb_cron_job monthly "$3" "$4" "$5"
    elif [[ $3 == "--tables" ]]; then 
        [[ $# -eq 6 ]] || err_exit ${ERR_USAGE} \
         "Usage: $0 --tb-monthly <db> [--tables] [t1,t2] <1-30 ><HH:MM> "
         daily_parm="$2 --tables $4" 
         update_db_cron_job monthly "${daily_parm}" "$5" "$6"

     elif [[ $# == 4 ]]; then
        update_db_cron_job monthly "$2" "$3" "$4"
      
     else
           err_exit ${ERR_USAGE} "Usage: $0 --db-weekly db1 [--tables] [t1,t2,t3] <0-6> HH:MM"
      fi      
    ;;
  
  --table-restore)
     [[ -n "${2:-}" ]] || err_exit ${ERR_USAGE} "Usage: $0 --restore <file.tar.gz>"
     restore_mydumper_backup "$2"
     ;;

  
  --restore)
    [[ $# -eq 2 ]] || err_exit ${ERR_RESTORE_MISSING_ARG} "Usage: $0 --restore <backup.tar[.gz]|/path/to/backup>"
    restore_full "$2"
    ;;
  *)
    err_exit ${ERR_USAGE} "Usage: $0 [--daily HH:MM | --weekly D HH:MM | --monthly D HH:MM | --manually | --restore FILE | --table-backup db1,db2,...| --table-backup --spec 'db1:t1,t2;db2:t2,t3' | --table-restore FILE"
    ;;
esac




