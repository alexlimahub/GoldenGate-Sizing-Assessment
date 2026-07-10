#!/bin/sh
#
# Oracle GoldenGate 26ai Sizing Assessment and Baseline Reporter
#
# Author: Alex Lima
#
# This single-file assessment gathers Oracle Database metadata used for a
# first-pass GoldenGate Hub sizing discussion. It supports Oracle Database
# 19c and later, which aligns with the GoldenGate 26ai Oracle Database source
# scope in the customer sizing guide.
#
# Example:
#   ./ogg_26ai_sizing_assessment.sh -c "/ as sysdba"
#   ./ogg_26ai_sizing_assessment.sh -c "system@mydb" -s "APP%" -p "SALES%" -r 24
#

set -eu

SCRIPT_NAME=$(basename "$0")
RUN_STAMP=$(date '+%Y%m%d_%H%M%S')
CONNECT_STRING=${ORACLE_CONNECT:-"/ as sysdba"}
OWNER_LIKE="%"
PDB_LIKE="%"
RETENTION_HOURS=24
OUTPUT_BASE="ogg_sizing_${RUN_STAMP}"
SQLPLUS_BIN=${SQLPLUS_BIN:-sqlplus}
AUTONOMOUS_MODE="N"
WALLET_DIR=""
PEAK_REDO_GB_PER_HOUR="UNKNOWN"
AVG_REDO_GB_PER_HOUR="UNKNOWN"

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [options]

Options:
  -c CONNECT   SQL*Plus/SQLcl connect string. Default: ORACLE_CONNECT or "/ as sysdba"
  -s PATTERN   Schema SQL LIKE filter for replicated objects. Default: %
  -p PATTERN   PDB name or SQL LIKE filter for CDB/PDB redo scope. Default: %
  -r HOURS     Trail retention hours for storage estimate. Default: 24
  -o DIR       Output directory. Default: ogg_sizing_YYYYMMDD_HH24MISS
  -w DIR       ADB wallet directory. Sets TNS_ADMIN for this execution.
  -g GB        Peak redo/change-rate GB per hour. Optional override/input.
  -b GB        Average redo/change-rate GB per hour. Optional override/input.
  -a           Autonomous Database mode. Run from a client/wallet connection;
               do not use SYSDBA, OS-local views, or container switching.
  -h           Show this help.

Examples:
  ${SCRIPT_NAME} -c "/ as sysdba"
  ${SCRIPT_NAME} -c "system@prod" -s "ERP%" -p "ERP_PDB" -r 48
  ${SCRIPT_NAME} -a -w "/path/to/Wallet_ADB" -c "admin/password@myadb_high" -s "HR"
  ${SCRIPT_NAME} -a -w "/path/to/Wallet_ADB" -c "admin/password@myadb_high" -s "HR" -g 80 -b 25

Required privileges:
  The connected user needs read access to DBA_* and V$ views. AWR PDB redo
  history uses DBA_HIST_CON_SYSSTAT and DBA_HIST_SNAPSHOT when available.
  If -p is an exact PDB name, the script switches into that PDB before
  querying schema and object metadata.
  Autonomous mode is designed for Oracle Autonomous Database where SYSDBA and
  database-host execution are not available. Run it from a machine with
  SQL*Plus/SQLcl and the ADB wallet/TNS configuration. If using SQLcl, set
  SQLPLUS_BIN to the sql executable path, for example SQLPLUS_BIN=/opt/sqlcl/bin/sql.
  For ADB wallets, either export TNS_ADMIN=/path/to/wallet or pass -w /path/to/wallet.
USAGE
}

while getopts "c:s:p:r:o:w:g:b:ah" opt; do
  case "$opt" in
    c) CONNECT_STRING=$OPTARG ;;
    s) OWNER_LIKE=$OPTARG ;;
    p) PDB_LIKE=$OPTARG ;;
    r) RETENTION_HOURS=$OPTARG ;;
    o) OUTPUT_BASE=$OPTARG ;;
    w) WALLET_DIR=$OPTARG ;;
    g) PEAK_REDO_GB_PER_HOUR=$OPTARG ;;
    b) AVG_REDO_GB_PER_HOUR=$OPTARG ;;
    a) AUTONOMOUS_MODE="Y" ;;
    h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$RETENTION_HOURS" in
  ''|*[!0-9]*)
    echo "ERROR: retention hours must be a positive integer." >&2
    exit 2
    ;;
esac

if [ "$RETENTION_HOURS" -lt 4 ]; then
  echo "ERROR: retention hours must be at least 4." >&2
  exit 2
fi

validate_decimal() {
  value=$1
  label=$2
  if [ "$value" = "UNKNOWN" ]; then
    return 0
  fi
  if ! awk -v v="$value" 'BEGIN { exit(v ~ /^[0-9]+([.][0-9]+)?$/ ? 0 : 1) }'; then
    echo "ERROR: $label must be a non-negative number, for example 80 or 80.5." >&2
    exit 2
  fi
}

validate_decimal "$PEAK_REDO_GB_PER_HOUR" "peak redo/change-rate GB/hour"
validate_decimal "$AVG_REDO_GB_PER_HOUR" "average redo/change-rate GB/hour"

if ! command -v "$SQLPLUS_BIN" >/dev/null 2>&1; then
  echo "ERROR: SQL*Plus/SQLcl was not found. Set SQLPLUS_BIN to sqlplus or sql, or add it to PATH." >&2
  exit 1
fi

if [ -n "$WALLET_DIR" ]; then
  if [ ! -d "$WALLET_DIR" ]; then
    echo "ERROR: wallet directory does not exist: $WALLET_DIR" >&2
    exit 2
  fi
  TNS_ADMIN=$WALLET_DIR
  export TNS_ADMIN
fi

PDB_CONTAINER_COMMAND="prompt Staying in current container for object assessment."
PDB_UPPER=$(printf '%s' "$PDB_LIKE" | tr '[:lower:]' '[:upper:]')
case "$PDB_UPPER" in
  ''|'%'|'CDB$ROOT'|'PDB$SEED'|*'%'*)
    ;;
  *[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_\$#]*)
    echo "WARNING: PDB value '$PDB_LIKE' is not a simple exact PDB name. It will be used as a filter only." >&2
    ;;
  *)
    PDB_CONTAINER_COMMAND="alter session set container = ${PDB_UPPER};"
    ;;
esac

mkdir -p "$OUTPUT_BASE"
OUTPUT_DIR=$(cd "$OUTPUT_BASE" && pwd)
ASSESSMENT_SQL="${OUTPUT_DIR}/ogg_26ai_sizing_assessment_${RUN_STAMP}.sql"
RUN_LOG="${OUTPUT_DIR}/ogg_26ai_sizing_assessment_${RUN_STAMP}.log"

if [ "$AUTONOMOUS_MODE" = "Y" ]; then
cat > "$ASSESSMENT_SQL" <<'SQL'
set echo off
set define on
set feedback off
set verify off
set heading on
set pagesize 50000
set linesize 32767
set trimspool on
set termout on
set serveroutput on size unlimited
whenever sqlerror continue

define out_dir = '&1'
define owner_like = '&2'
define pdb_name_like = '&3'
define trail_retention_hours = '&4'
define run_stamp = '&5'
define client_wallet_dir = '&6'
define peak_redo_gb_per_hour = '&7'
define avg_redo_gb_per_hour = '&8'

column report_file new_value report_file noprint
select '&out_dir/ogg_26ai_sizing_report_&run_stamp..txt' report_file from dual;

prompt GoldenGate 26ai Autonomous Database sizing assessment started.
prompt Output directory: &out_dir
prompt Schema filter: &owner_like
prompt Trail retention hours: &trail_retention_hours

set markup csv on delimiter , quote on

spool "&out_dir/gg_&run_stamp._adb_inventory.csv"
select sys_context('USERENV', 'DB_NAME') as db_name,
       sys_context('USERENV', 'CON_NAME') as con_name,
       sys_context('USERENV', 'SERVICE_NAME') as service_name,
       sys_context('USERENV', 'CLOUD_SERVICE') as cloud_service,
       (select max(version_full)
          from product_component_version
         where upper(product) like '%DATABASE%') as version_full,
       case
         when to_number(regexp_substr((select max(version_full)
                                         from product_component_version
                                        where upper(product) like '%DATABASE%'), '^[0-9]+')) >= 19
         then 'SUPPORTED_BASELINE'
         else 'OUTSIDE_19C_PLUS_BASELINE'
       end as gg_26ai_db_version_scope,
       (select value
          from v$parameter
         where name = 'enable_goldengate_replication') as enable_goldengate_replication,
       systimestamp as captured_at
  from dual;
spool off

spool "&out_dir/gg_&run_stamp._adb_workload_inputs_needed.csv"
select 'MISSING_REDO_HISTORY' as input_name,
       'Provide ADB hourly redo/change volume, GoldenGate extract throughput, or equivalent workload metrics from OCI metrics/AWR/customer monitoring.' as guidance
  from dual
union all
select 'MISSING_NETWORK_PATH',
       'Provide network path, latency, bandwidth, target count, and GoldenGate deployment location.'
  from dual
union all
select 'MISSING_INITIAL_LOAD_SIZE',
       'Validate initial load size and method for schemas/tables in scope.'
  from dual;
spool off

spool "&out_dir/gg_&run_stamp._schema_summary.csv"
with table_keys as (
  select owner,
         table_name,
         max(case when constraint_type = 'P' then 1 else 0 end) as has_pk,
         max(case when constraint_type = 'U' then 1 else 0 end) as has_uk
    from dba_constraints
   where owner like upper('&owner_like')
     and status = 'ENABLED'
     and constraint_type in ('P','U')
   group by owner, table_name
),
lob_tables as (
  select owner, table_name, count(*) as lob_column_count
    from dba_lobs
   where owner like upper('&owner_like')
   group by owner, table_name
),
segments as (
  select owner, segment_name as table_name, sum(bytes) / 1024 / 1024 as segment_mb
    from dba_segments
   where owner like upper('&owner_like')
     and segment_type in ('TABLE','TABLE PARTITION','TABLE SUBPARTITION')
   group by owner, segment_name
)
select t.owner,
       count(*) as table_count,
       sum(case when t.partitioned = 'YES' then 1 else 0 end) as partitioned_tables,
       sum(nvl(t.num_rows, 0)) as estimated_rows,
       round(sum(nvl(s.segment_mb, 0)), 2) as segment_mb,
       sum(nvl(k.has_pk, 0)) as pk_tables,
       sum(case when nvl(k.has_pk, 0) = 0 and nvl(k.has_uk, 0) = 1 then 1 else 0 end) as unique_key_tables,
       sum(case when nvl(k.has_pk, 0) = 0 and nvl(k.has_uk, 0) = 0 then 1 else 0 end) as no_key_tables,
       sum(case when nvl(l.lob_column_count, 0) > 0 then 1 else 0 end) as lob_tables
  from dba_tables t
  left join table_keys k on k.owner = t.owner and k.table_name = t.table_name
  left join lob_tables l on l.owner = t.owner and l.table_name = t.table_name
  left join segments s on s.owner = t.owner and s.table_name = t.table_name
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
 group by t.owner
 order by round(sum(nvl(s.segment_mb, 0)), 2) desc;
spool off

spool "&out_dir/gg_&run_stamp._table_detail.csv"
with table_keys as (
  select owner,
         table_name,
         max(case when constraint_type = 'P' then 1 else 0 end) as has_pk,
         max(case when constraint_type = 'U' then 1 else 0 end) as has_uk
    from dba_constraints
   where owner like upper('&owner_like')
     and status = 'ENABLED'
     and constraint_type in ('P','U')
   group by owner, table_name
),
lob_cols as (
  select owner, table_name, count(*) as lob_column_count
    from dba_lobs
   where owner like upper('&owner_like')
   group by owner, table_name
),
review_cols as (
  select owner, table_name, count(*) as review_column_count
    from dba_tab_cols
   where owner like upper('&owner_like')
     and (
       data_type in ('LONG','LONG RAW','BFILE','ROWID','UROWID','ANYDATA','ANYTYPE','ANYDATASET','URITYPE','XMLTYPE')
       or data_type like '%LOB'
       or data_type_owner is not null
       or hidden_column = 'YES'
       or virtual_column = 'YES'
     )
   group by owner, table_name
),
segments as (
  select owner, segment_name as table_name, sum(bytes) / 1024 / 1024 as segment_mb
    from dba_segments
   where owner like upper('&owner_like')
     and segment_type in ('TABLE','TABLE PARTITION','TABLE SUBPARTITION')
   group by owner, segment_name
)
select t.owner,
       t.table_name,
       t.num_rows,
       t.avg_row_len,
       t.blocks,
       round(nvl(s.segment_mb, 0), 2) as segment_mb,
       t.partitioned,
       t.temporary,
       t.nested,
       t.iot_type,
       t.logging,
       t.compression,
       case when nvl(k.has_pk, 0) = 1 then 'Y' else 'N' end as has_primary_key,
       case when nvl(k.has_uk, 0) = 1 then 'Y' else 'N' end as has_unique_key,
       nvl(l.lob_column_count, 0) as lob_column_count,
       nvl(r.review_column_count, 0) as review_column_count
  from dba_tables t
  left join table_keys k on k.owner = t.owner and k.table_name = t.table_name
  left join lob_cols l on l.owner = t.owner and l.table_name = t.table_name
  left join review_cols r on r.owner = t.owner and r.table_name = t.table_name
  left join segments s on s.owner = t.owner and s.table_name = t.table_name
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
 order by nvl(s.segment_mb, 0) desc, t.owner, t.table_name;
spool off

spool "&out_dir/gg_&run_stamp._no_key_tables.csv"
with table_keys as (
  select owner,
         table_name,
         max(case when constraint_type = 'P' then 1 else 0 end) as has_pk,
         max(case when constraint_type = 'U' then 1 else 0 end) as has_uk
    from dba_constraints
   where owner like upper('&owner_like')
     and status = 'ENABLED'
     and constraint_type in ('P','U')
   group by owner, table_name
)
select t.owner,
       t.table_name,
       t.num_rows,
       t.avg_row_len,
       t.partitioned,
       t.iot_type,
       case when nvl(k.has_pk, 0) = 1 then 'Y' else 'N' end as has_primary_key,
       case when nvl(k.has_uk, 0) = 1 then 'Y' else 'N' end as has_unique_key
  from dba_tables t
  left join table_keys k on k.owner = t.owner and k.table_name = t.table_name
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
   and nvl(k.has_pk, 0) = 0
   and nvl(k.has_uk, 0) = 0
 order by nvl(t.num_rows, 0) desc, t.owner, t.table_name;
spool off

spool "&out_dir/gg_&run_stamp._column_review.csv"
select owner,
       table_name,
       column_name,
       data_type,
       data_length,
       data_precision,
       data_scale,
       nullable,
       hidden_column,
       virtual_column,
       trim(
         case when data_type in ('LONG','LONG RAW') then 'LONG_OR_LONG_RAW; ' end ||
         case when data_type in ('BFILE','ROWID','UROWID','ANYDATA','ANYTYPE','ANYDATASET','URITYPE','XMLTYPE') then 'SPECIAL_DATATYPE_REVIEW; ' end ||
         case when data_type like '%LOB' then 'LOB_REVIEW; ' end ||
         case when data_type_owner is not null then 'USER_OR_SYSTEM_DEFINED_TYPE_REVIEW; ' end ||
         case when hidden_column = 'YES' then 'HIDDEN_COLUMN; ' end ||
         case when virtual_column = 'YES' then 'VIRTUAL_COLUMN; ' end
       ) as review_reason
  from dba_tab_cols
 where owner like upper('&owner_like')
   and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
   and (
     data_type in ('LONG','LONG RAW','BFILE','ROWID','UROWID','ANYDATA','ANYTYPE','ANYDATASET','URITYPE','XMLTYPE')
     or data_type like '%LOB'
     or data_type_owner is not null
     or hidden_column = 'YES'
     or virtual_column = 'YES'
   )
 order by owner, table_name, column_id;
spool off

spool "&out_dir/gg_&run_stamp._supplemental_logging.csv"
select owner,
       table_name,
       log_group_name,
       log_group_type,
       always,
       generated
  from dba_log_groups
 where owner like upper('&owner_like')
 order by owner, table_name, log_group_name;
spool off

set markup csv off
set heading off
set feedback off
set pagesize 0
set linesize 32767
set trimspool on

spool "&report_file"

prompt Oracle GoldenGate 26ai Autonomous Database Sizing Baseline Report
prompt ================================================================
prompt
prompt This report is a first-pass sizing baseline for an Autonomous Database source.
prompt Autonomous Database does not allow SYSDBA or database-host execution, so this mode is designed
prompt to run from a client machine using SQL*Plus/SQLcl and the ADB wallet or TNS alias.
prompt
prompt The sizing recommendation is low confidence until workload metrics are supplied.
prompt Validate with production-representative workload before go-live.
prompt
prompt Scope filters used by assessment
prompt ===============================
prompt Schema LIKE filter: &owner_like
prompt Trail retention hours: &trail_retention_hours
prompt Client wallet/TNS_ADMIN path: &client_wallet_dir
prompt Peak redo/change-rate GB/hour input: &peak_redo_gb_per_hour
prompt Average redo/change-rate GB/hour input: &avg_redo_gb_per_hour
prompt
prompt Autonomous database inventory
prompt =============================
select 'Database: ' || sys_context('USERENV', 'DB_NAME') ||
       ' / Container: ' || sys_context('USERENV', 'CON_NAME') ||
       ' / Service: ' || sys_context('USERENV', 'SERVICE_NAME') ||
       ' / Cloud service: ' || nvl(sys_context('USERENV', 'CLOUD_SERVICE'), 'UNKNOWN')
  from dual;
select 'Version: ' || max(version_full) ||
       case
         when to_number(regexp_substr(max(version_full), '^[0-9]+')) >= 19
         then ' (within Oracle Database 19c+ baseline for this GoldenGate sizing assessment)'
         else ' (outside Oracle Database 19c+ baseline; review GoldenGate support before proceeding)'
       end
  from product_component_version
 where upper(product) like '%DATABASE%';
select 'ENABLE_GOLDENGATE_REPLICATION: ' || nvl((select value
                                                   from v$parameter
                                                  where name = 'enable_goldengate_replication'), 'UNKNOWN')
  from dual;
prompt
prompt Autonomous mode notes
prompt =====================
prompt SYSDBA, OS-local assessment, archived log mining views, and host-level sizing signals are not assumed available.
prompt Use this report for schema/object readiness and a low-confidence starting point only.
prompt SQLcl is supported by setting SQLPLUS_BIN to the sql executable path.
prompt For ADB wallet connections, set TNS_ADMIN to the wallet directory or run this script with -w WALLET_DIR.
prompt Provide ADB service metrics, redo/change volume or change-rate equivalent, GoldenGate throughput,
prompt network path, target count, and initial-load plan before final sizing.
prompt
prompt Readiness checks
prompt ================
select case
         when upper(nvl((select value from v$parameter where name = 'enable_goldengate_replication'), 'UNKNOWN')) = 'TRUE'
         then 'PASS: ENABLE_GOLDENGATE_REPLICATION is TRUE.'
         else 'REVIEW: ENABLE_GOLDENGATE_REPLICATION is not TRUE or is not visible to this user. Enable/review this setting before configuring GoldenGate capture from Autonomous Database.'
       end
  from dual;
select 'REVIEW: Tables without enabled primary key or unique key: ' || count(*)
  from (
    select t.owner, t.table_name
      from dba_tables t
      left join (
        select owner, table_name,
               max(case when constraint_type = 'P' then 1 else 0 end) as has_pk,
               max(case when constraint_type = 'U' then 1 else 0 end) as has_uk
          from dba_constraints
         where owner like upper('&owner_like')
           and status = 'ENABLED'
           and constraint_type in ('P','U')
         group by owner, table_name
      ) k on k.owner = t.owner and k.table_name = t.table_name
     where t.owner like upper('&owner_like')
       and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
       and nvl(k.has_pk, 0) = 0
       and nvl(k.has_uk, 0) = 0
  );
select 'REVIEW: Columns requiring GoldenGate datatype or object-shape review: ' || count(*)
  from dba_tab_cols
 where owner like upper('&owner_like')
   and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
   and (
     data_type in ('LONG','LONG RAW','BFILE','ROWID','UROWID','ANYDATA','ANYTYPE','ANYDATASET','URITYPE','XMLTYPE')
     or data_type like '%LOB'
     or data_type_owner is not null
     or hidden_column = 'YES'
     or virtual_column = 'YES'
   );
prompt
prompt Replication object scope
prompt ========================
with table_keys as (
  select owner,
         table_name,
         max(case when constraint_type = 'P' then 1 else 0 end) as has_pk,
         max(case when constraint_type = 'U' then 1 else 0 end) as has_uk
    from dba_constraints
   where owner like upper('&owner_like')
     and status = 'ENABLED'
     and constraint_type in ('P','U')
   group by owner, table_name
),
segments as (
  select owner, segment_name as table_name, sum(bytes) / 1024 / 1024 / 1024 as segment_gb
    from dba_segments
   where owner like upper('&owner_like')
     and segment_type in ('TABLE','TABLE PARTITION','TABLE SUBPARTITION')
   group by owner, segment_name
)
select '- Tables: ' || count(*)
  from dba_tables t
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
union all
select '- Estimated rows: ' || nvl(to_char(sum(nvl(t.num_rows, 0))), '0')
  from dba_tables t
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
union all
select '- Table segment GB: ' || nvl(to_char(round(sum(nvl(s.segment_gb, 0)), 2)), '0')
  from dba_tables t
  left join segments s on s.owner = t.owner and s.table_name = t.table_name
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
union all
select '- Tables without PK/UK: ' ||
       nvl(to_char(sum(case when nvl(k.has_pk, 0) = 0 and nvl(k.has_uk, 0) = 0 then 1 else 0 end)), '0')
  from dba_tables t
  left join table_keys k on k.owner = t.owner and k.table_name = t.table_name
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS');
prompt
prompt ADB workload inputs
prompt ===================
with workload_input as (
  select case
           when regexp_like('&peak_redo_gb_per_hour', '^[0-9]+(\.[0-9]+)?$')
           then to_number('&peak_redo_gb_per_hour')
         end as peak_change_gb_per_hour,
         case
           when regexp_like('&avg_redo_gb_per_hour', '^[0-9]+(\.[0-9]+)?$')
           then to_number('&avg_redo_gb_per_hour')
         end as avg_change_gb_per_hour
    from dual
)
select '- Peak redo/change-rate: ' || nvl(to_char(peak_change_gb_per_hour), 'not supplied') || ' GB/hour'
  from workload_input
union all
select '- Average redo/change-rate: ' || nvl(to_char(avg_change_gb_per_hour), 'not supplied') || ' GB/hour'
  from workload_input
union all
select '- Note: provide ADB service metrics, AWR/OCI metrics, or measured GoldenGate throughput to improve confidence.'
  from workload_input;
prompt
prompt GoldenGate Hub baseline recommendation
prompt ======================================
with workload_input as (
  select case
           when regexp_like('&peak_redo_gb_per_hour', '^[0-9]+(\.[0-9]+)?$')
           then to_number('&peak_redo_gb_per_hour')
         end as peak_change_gb_per_hour
    from dual
),
workload_score as (
  select case
           when peak_change_gb_per_hour is null then 0
           when peak_change_gb_per_hour < 1 then 1
           when peak_change_gb_per_hour <= 250 then 2
           when peak_change_gb_per_hour <= 500 then 3
           else 5
         end as score
    from workload_input
),
table_scope as (
  select count(*) as table_count,
         case
           when count(*) < 500 then 1
           when count(*) <= 2000 then 2
           when count(*) <= 5000 then 3
           else 5
         end as score
    from dba_tables
   where owner like upper('&owner_like')
     and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
),
recommendation as (
  select greatest(t.score, w.score) as score,
         w.score as workload_score
    from table_scope t cross join workload_score w
)
select 'Preliminary starting tier: ' ||
       case score when 1 then 'Small' when 2 then 'Medium' when 3 then 'Large' else 'Custom' end
  from recommendation;
prompt - Confidence: low until workload metrics are supplied.
with workload_input as (
  select case
           when regexp_like('&peak_redo_gb_per_hour', '^[0-9]+(\.[0-9]+)?$')
           then to_number('&peak_redo_gb_per_hour')
         end as peak_change_gb_per_hour
    from dual
),
workload_score as (
  select case
           when peak_change_gb_per_hour is null then 0
           when peak_change_gb_per_hour < 1 then 1
           when peak_change_gb_per_hour <= 250 then 2
           when peak_change_gb_per_hour <= 500 then 3
           else 5
         end as score
    from workload_input
),
table_scope as (
  select case
           when count(*) < 500 then 1
           when count(*) <= 2000 then 2
           when count(*) <= 5000 then 3
           else 5
         end as score
    from dba_tables
   where owner like upper('&owner_like')
     and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
),
recommendation as (
  select greatest(t.score, w.score) as score,
         w.score as workload_score
    from table_scope t cross join workload_score w
)
select '- Basis: ' ||
       case
         when workload_score = 0 then 'preliminary object-count baseline only because redo/change history is not gathered in Autonomous mode.'
         else 'larger of supplied redo/change-rate input and object-count scope.'
       end
  from recommendation
union all
select '- Rule: move to a larger tier only after reviewing ADB change volume, GoldenGate throughput, target count, and apply lag.' from recommendation
union all
select '- vCPU: ' || case score when 1 then '8' when 2 then '16' when 3 then '32' else 'Custom sizing required' end from recommendation
union all
select '- RAM: ' || case score when 1 then '64 GB' when 2 then '128 GB' when 3 then '256 GB' else 'Custom sizing required' end from recommendation
union all
select '- Trail/working disk guide: ' || case score when 1 then '200 GB' when 2 then '500 GB' when 3 then '1-2 TB' else 'Custom sizing required' end from recommendation
union all
select '- Calculated trail storage for retention: ' ||
       case
         when regexp_like('&peak_redo_gb_per_hour', '^[0-9]+(\.[0-9]+)?$')
         then to_char(greatest(8, ceil(to_number('&peak_redo_gb_per_hour') * to_number('&trail_retention_hours') * 1.5))) || ' GB'
         else 'not calculated; provide -g peak redo/change-rate GB/hour'
       end
  from recommendation
union all
select '- Next step: replace or confirm this baseline after reviewing ADB workload metrics and GoldenGate throughput.' from recommendation;
prompt
prompt Process and recovery sizing prompts
prompt ===================================
prompt - PDB scope: Autonomous Database service connection.
prompt - PDB count: not exposed as a host/container sizing input in this mode.
with workload_input as (
  select case
           when regexp_like('&peak_redo_gb_per_hour', '^[0-9]+(\.[0-9]+)?$')
           then to_number('&peak_redo_gb_per_hour')
         end as peak_change_gb_per_hour
    from dual
),
workload_score as (
  select case
           when peak_change_gb_per_hour is null then 0
           when peak_change_gb_per_hour < 1 then 1
           when peak_change_gb_per_hour <= 250 then 2
           when peak_change_gb_per_hour <= 500 then 3
           else 5
         end as score
    from workload_input
),
table_scope as (
  select case
           when count(*) < 500 then 1
           when count(*) <= 2000 then 2
           when count(*) <= 5000 then 3
           else 5
         end as score
    from dba_tables
   where owner like upper('&owner_like')
     and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
),
recommendation as (
  select greatest(t.score, w.score) as score
    from table_scope t cross join workload_score w
)
select '- Starting Extract paths: 1 for this ADB source service' from recommendation
union all
select '- Add capture/apply paths only after reviewing GoldenGate throughput, target count, and table grouping.' from recommendation
union all
select '- Process tier guide: ' ||
       case score when 1 then '1' when 2 then '1-2' when 3 then '2-4' else 'custom design review' end
  from recommendation;
prompt - Cache Manager: Autonomous mode does not gather redo history.
prompt - CACHEMGR input: use ADB change volume or GoldenGate Extract throughput.
prompt - Bounded recovery: size spill headroom from workload metrics and validate with long-running transactions.
prompt - Validation: review CACHEMGR spill statistics during workload testing.
prompt
prompt Parallel Replicat starting parameters
prompt ======================================
prompt Use this section to start the target apply design. Validate with target database capacity,
prompt transaction dependencies, constraints, indexes, triggers, and representative workload.
prompt Oracle reference: https://docs.oracle.com/en/middleware/goldengate/core/21.3/coredoc/replicat-basic-parameters-parallel-replicat.html
with workload_input as (
  select case
           when regexp_like('&peak_redo_gb_per_hour', '^[0-9]+(\.[0-9]+)?$')
           then to_number('&peak_redo_gb_per_hour')
         end as peak_change_gb_per_hour
    from dual
),
workload_score as (
  select case
           when peak_change_gb_per_hour is null then 0
           when peak_change_gb_per_hour < 1 then 1
           when peak_change_gb_per_hour <= 250 then 2
           when peak_change_gb_per_hour <= 500 then 3
           else 5
         end as score
    from workload_input
),
table_scope as (
  select case
           when count(*) < 500 then 1
           when count(*) <= 2000 then 2
           when count(*) <= 5000 then 3
           else 5
         end as score
    from dba_tables
   where owner like upper('&owner_like')
     and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
),
recommendation as (
  select greatest(t.score, w.score) as score
    from table_scope t cross join workload_score w
)
select '- MAP_PARALLELISM starting point: ' ||
       case score when 1 then '2' when 2 then '3' when 3 then '4' else 'custom' end ||
       ' mapper thread(s). Default is 2; valid documented range is 1-100.'
  from recommendation
union all
select '- Auto-tuned apply mode: use MIN_APPLY_PARALLELISM and MAX_APPLY_PARALLELISM together.' from recommendation
union all
select '- MIN_APPLY_PARALLELISM starting point: ' ||
       case score when 1 then '1' when 2 then '2' when 3 then '4' else 'custom' end
  from recommendation
union all
select '- MAX_APPLY_PARALLELISM starting point: ' ||
       case score when 1 then '4' when 2 then '8' when 3 then '16' else 'custom' end
  from recommendation
union all
select '- Fixed apply mode alternative: APPLY_PARALLELISM starting point: ' ||
       case score when 1 then '4' when 2 then '8' when 3 then '16' else 'custom' end ||
       '. Use only if you do not use MIN/MAX apply parallelism.'
  from recommendation
union all
select '- SPLIT_TRANS_RECS: leave disabled initially; consider only for large transactions after dependency and recovery testing.' from recommendation
union all
select '- COMMIT_SERIALIZATION: use FULL only when target commit order must be forced; validate throughput impact.' from recommendation
union all
select '- LOOK_AHEAD_TRANSACTIONS: keep the default starting point unless scheduling tests show a bottleneck.' from recommendation
union all
select '- CHUNK_SIZE: keep the default starting point; increasing it can consume more Replicat memory.' from recommendation
union all
select '- Replace after reviewing target apply capacity, ADB service metrics, and GoldenGate lag.' from recommendation;
prompt
prompt Missing inputs before final sizing
prompt ==================================
prompt Required: peak and average change volume or redo equivalent by hour/day for the ADB workload.
prompt Required: ADB service metrics for CPU, sessions, SQL throughput, storage growth, and wait profile during peak windows.
prompt Required: GoldenGate Extract, Distribution, and Replicat throughput or lag from a representative test when available.
prompt Required: initial load size and method.
prompt Required: target count, network path, latency, bandwidth, and GoldenGate deployment location.
prompt Required: GoldenGate service choice, such as OCI GoldenGate or self-managed GoldenGate.
prompt
prompt Validation requirements before production
prompt =========================================
prompt Validate this baseline with production-representative workload before go-live.
prompt For ADB sources, include OCI service metrics, GoldenGate Extract/Distribution/Replicat lag,
prompt network throughput, target apply rate, trail growth, and end-to-end recovery procedures.
prompt
prompt Appendix A - Tables without primary or unique key
prompt =================================================
with table_keys as (
  select owner, table_name,
         max(case when constraint_type = 'P' then 1 else 0 end) as has_pk,
         max(case when constraint_type = 'U' then 1 else 0 end) as has_uk
    from dba_constraints
   where owner like upper('&owner_like')
     and status = 'ENABLED'
     and constraint_type in ('P','U')
   group by owner, table_name
),
no_key_tables as (
  select t.owner, t.table_name, nvl(t.num_rows, 0) as num_rows,
         t.partitioned, nvl(t.iot_type, 'HEAP') as table_type
    from dba_tables t
    left join table_keys k on k.owner = t.owner and k.table_name = t.table_name
   where t.owner like upper('&owner_like')
     and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
     and nvl(k.has_pk, 0) = 0
     and nvl(k.has_uk, 0) = 0
)
select case when count(*) = 0 then 'No tables without enabled primary key or unique key were found for this scope.' end
  from no_key_tables
having count(*) = 0
union all
select '- ' || owner || '.' || table_name || ' | rows=' || to_char(num_rows) ||
       ' | partitioned=' || partitioned || ' | type=' || table_type
  from no_key_tables
 order by 1;
prompt
prompt Appendix B - Columns requiring datatype or object-shape review
prompt =============================================================
with review_columns as (
  select owner, table_name, column_name, data_type,
         trim(
           case when data_type in ('LONG','LONG RAW') then 'LONG_OR_LONG_RAW; ' end ||
           case when data_type in ('BFILE','ROWID','UROWID','ANYDATA','ANYTYPE','ANYDATASET','URITYPE','XMLTYPE') then 'SPECIAL_DATATYPE_REVIEW; ' end ||
           case when data_type like '%LOB' then 'LOB_REVIEW; ' end ||
           case when data_type_owner is not null then 'USER_OR_SYSTEM_DEFINED_TYPE_REVIEW; ' end ||
           case when hidden_column = 'YES' then 'HIDDEN_COLUMN; ' end ||
           case when virtual_column = 'YES' then 'VIRTUAL_COLUMN; ' end
         ) as review_reason
    from dba_tab_cols
   where owner like upper('&owner_like')
     and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
     and (
       data_type in ('LONG','LONG RAW','BFILE','ROWID','UROWID','ANYDATA','ANYTYPE','ANYDATASET','URITYPE','XMLTYPE')
       or data_type like '%LOB'
       or data_type_owner is not null
       or hidden_column = 'YES'
       or virtual_column = 'YES'
     )
)
select case when count(*) = 0 then 'No datatype or object-shape review columns were found for this scope.' end
  from review_columns
having count(*) = 0
union all
select '- ' || owner || '.' || table_name || '.' || column_name ||
       ' | type=' || data_type || ' | reason=' || review_reason
  from review_columns
 order by 1;
prompt
prompt Files generated
prompt ===============
select '&out_dir' from dual;
prompt
prompt End of report.

spool off
exit
SQL

echo "Running GoldenGate Autonomous Database sizing assessment..."
echo "Output directory: $OUTPUT_DIR"

set +e
"$SQLPLUS_BIN" -s "$CONNECT_STRING" @"$ASSESSMENT_SQL" "$OUTPUT_DIR" "$OWNER_LIKE" "$PDB_LIKE" "$RETENTION_HOURS" "$RUN_STAMP" "${TNS_ADMIN:-not set}" "$PEAK_REDO_GB_PER_HOUR" "$AVG_REDO_GB_PER_HOUR" > "$RUN_LOG" 2>&1
SQLPLUS_STATUS=$?
set -e

REPORT_FILE="${OUTPUT_DIR}/ogg_26ai_sizing_report_${RUN_STAMP}.txt"

if [ "$SQLPLUS_STATUS" -ne 0 ]; then
  echo "ERROR: SQL*Plus/SQLcl returned status $SQLPLUS_STATUS. See log: $RUN_LOG" >&2
  exit "$SQLPLUS_STATUS"
fi

echo
echo "Assessment complete."
echo "Report: $REPORT_FILE"
echo "CSV/log output: $OUTPUT_DIR"
echo

if [ -f "$REPORT_FILE" ]; then
  sed -n '1,220p' "$REPORT_FILE"
else
  echo "WARNING: Report file was not created. Review log: $RUN_LOG" >&2
fi

exit 0
fi

cat > "$ASSESSMENT_SQL" <<'SQL'
set echo off
set define on
set feedback off
set verify off
set heading on
set pagesize 50000
set linesize 32767
set trimspool on
set termout on
set serveroutput on size unlimited
whenever sqlerror continue

define out_dir = '&1'
define owner_like = '&2'
define pdb_name_like = '&3'
define trail_retention_hours = '&4'
define run_stamp = '&5'
define peak_redo_gb_per_hour = '&6'
define avg_redo_gb_per_hour = '&7'

column report_file new_value report_file noprint
select '&out_dir/ogg_26ai_sizing_report_&run_stamp..txt' report_file from dual;

prompt GoldenGate 26ai sizing assessment started.
prompt Output directory: &out_dir
prompt Schema filter: &owner_like
prompt PDB filter: &pdb_name_like
prompt Trail retention hours: &trail_retention_hours
prompt Peak redo/change-rate input: &peak_redo_gb_per_hour
prompt Average redo/change-rate input: &avg_redo_gb_per_hour

set markup csv on delimiter , quote on

spool "&out_dir/gg_&run_stamp._db_inventory.csv"
select d.name as db_name,
       d.db_unique_name,
       d.database_role,
       d.platform_name,
       i.version,
       i.version_full,
       regexp_substr(i.version, '^[0-9]+') as database_major_version,
       case
         when to_number(regexp_substr(i.version, '^[0-9]+')) >= 19 then 'SUPPORTED_BASELINE'
         else 'OUTSIDE_19C_PLUS_BASELINE'
       end as gg_26ai_db_version_scope,
       d.cdb,
       d.log_mode,
       d.force_logging,
       d.supplemental_log_data_min,
       d.supplemental_log_data_pk,
       d.supplemental_log_data_ui,
       p.value as block_size,
       g.value as enable_goldengate_replication,
       case
         when d.cdb = 'YES' then (select count(*) from v$containers where con_id > 2)
         else 0
       end as pdb_count_in_container_db,
       round((select sum(bytes) from dba_data_files) / 1024 / 1024, 2) as db_size_mb,
       systimestamp as captured_at
  from v$database d
 cross join v$instance i
  left join v$parameter p on p.name = 'db_block_size'
  left join v$parameter g on g.name = 'enable_goldengate_replication';
spool off

set markup csv off
set heading off
set feedback off
__PDB_CONTAINER_COMMAND__
prompt Current SQL container: 
select sys_context('USERENV', 'CON_NAME') from dual;
set heading on
set feedback off
set markup csv on delimiter , quote on

spool "&out_dir/gg_&run_stamp._archived_log_daily.csv"
select trunc(first_time) as metric_day,
       round(sum(blocks * block_size) / 1024 / 1024, 2) as archived_log_mb,
       count(*) as archived_logs
  from v$archived_log
 where first_time >= trunc(sysdate) - 31
   and standby_dest = 'NO'
 group by trunc(first_time)
 order by metric_day;
spool off

spool "&out_dir/gg_&run_stamp._archived_log_hourly.csv"
select trunc(first_time, 'HH24') as metric_hour,
       round(sum(blocks * block_size) / 1024 / 1024, 2) as archived_log_mb,
       count(*) as archived_logs
  from v$archived_log
 where first_time >= sysdate - 7
   and standby_dest = 'NO'
 group by trunc(first_time, 'HH24')
 order by metric_hour;
spool off

spool "&out_dir/gg_&run_stamp._pdb_redo_current.csv"
select s.con_id,
       nvl(c.name, case when s.con_id = 0 then 'CDB_OR_NON_CDB_TOTAL' else 'UNKNOWN' end) as pdb_name,
       round(s.value / 1024 / 1024, 2) as redo_mb_since_startup,
       i.startup_time,
       systimestamp as captured_at
  from v$con_sysstat s
  left join v$containers c on c.con_id = s.con_id
 cross join v$instance i
 where s.name = 'redo size'
   and nvl(c.name, 'CDB_OR_NON_CDB_TOTAL') like upper('&pdb_name_like')
 order by s.con_id;
spool off

spool "&out_dir/gg_&run_stamp._pdb_redo_hourly_awr.csv"
with redo_stat as (
  select h.snap_id,
         h.dbid,
         h.instance_number,
         h.con_id,
         h.con_dbid,
         h.value,
         s.end_interval_time,
         lag(h.value) over (
           partition by h.dbid, h.instance_number, h.con_dbid, h.con_id, h.stat_name
           order by h.snap_id
         ) as prior_value
    from dba_hist_con_sysstat h
    join dba_hist_snapshot s
      on s.snap_id = h.snap_id
     and s.dbid = h.dbid
     and s.instance_number = h.instance_number
   where h.stat_name = 'redo size'
     and s.end_interval_time >= cast(systimestamp as timestamp) - interval '7' day
),
redo_delta as (
  select con_id,
         con_dbid,
         end_interval_time,
         case
           when prior_value is null then null
           when value >= prior_value then value - prior_value
           else null
         end as redo_bytes
    from redo_stat
)
select d.con_id,
       nvl(c.name, case when d.con_id = 0 then 'CDB_OR_NON_CDB_TOTAL' else 'UNKNOWN' end) as pdb_name,
       trunc(cast(d.end_interval_time as timestamp), 'HH24') as metric_hour,
       round(sum(d.redo_bytes) / 1024 / 1024, 2) as redo_mb
  from redo_delta d
  left join v$containers c on c.con_id = d.con_id
 where d.redo_bytes is not null
   and nvl(c.name, 'CDB_OR_NON_CDB_TOTAL') like upper('&pdb_name_like')
 group by d.con_id,
          nvl(c.name, case when d.con_id = 0 then 'CDB_OR_NON_CDB_TOTAL' else 'UNKNOWN' end),
          trunc(cast(d.end_interval_time as timestamp), 'HH24')
 order by metric_hour, d.con_id;
spool off

spool "&out_dir/gg_&run_stamp._pdb_redo_daily_awr.csv"
with redo_stat as (
  select h.snap_id,
         h.dbid,
         h.instance_number,
         h.con_id,
         h.con_dbid,
         h.value,
         s.end_interval_time,
         lag(h.value) over (
           partition by h.dbid, h.instance_number, h.con_dbid, h.con_id, h.stat_name
           order by h.snap_id
         ) as prior_value
    from dba_hist_con_sysstat h
    join dba_hist_snapshot s
      on s.snap_id = h.snap_id
     and s.dbid = h.dbid
     and s.instance_number = h.instance_number
   where h.stat_name = 'redo size'
     and s.end_interval_time >= cast(systimestamp as timestamp) - interval '31' day
),
redo_delta as (
  select con_id,
         con_dbid,
         end_interval_time,
         case
           when prior_value is null then null
           when value >= prior_value then value - prior_value
           else null
         end as redo_bytes
    from redo_stat
)
select d.con_id,
       nvl(c.name, case when d.con_id = 0 then 'CDB_OR_NON_CDB_TOTAL' else 'UNKNOWN' end) as pdb_name,
       trunc(cast(d.end_interval_time as timestamp)) as metric_day,
       round(sum(d.redo_bytes) / 1024 / 1024, 2) as redo_mb
  from redo_delta d
  left join v$containers c on c.con_id = d.con_id
 where d.redo_bytes is not null
   and nvl(c.name, 'CDB_OR_NON_CDB_TOTAL') like upper('&pdb_name_like')
 group by d.con_id,
          nvl(c.name, case when d.con_id = 0 then 'CDB_OR_NON_CDB_TOTAL' else 'UNKNOWN' end),
          trunc(cast(d.end_interval_time as timestamp))
 order by metric_day, d.con_id;
spool off

spool "&out_dir/gg_&run_stamp._schema_summary.csv"
with table_keys as (
  select owner,
         table_name,
         max(case when constraint_type = 'P' then 1 else 0 end) as has_pk,
         max(case when constraint_type = 'U' then 1 else 0 end) as has_uk
    from dba_constraints
   where owner like upper('&owner_like')
     and status = 'ENABLED'
     and constraint_type in ('P','U')
   group by owner, table_name
),
lob_tables as (
  select owner, table_name, count(*) as lob_column_count
    from dba_lobs
   where owner like upper('&owner_like')
   group by owner, table_name
),
segments as (
  select owner, segment_name as table_name, sum(bytes) / 1024 / 1024 as segment_mb
    from dba_segments
   where owner like upper('&owner_like')
     and segment_type in ('TABLE','TABLE PARTITION','TABLE SUBPARTITION')
   group by owner, segment_name
)
select t.owner,
       count(*) as table_count,
       sum(case when t.partitioned = 'YES' then 1 else 0 end) as partitioned_tables,
       sum(nvl(t.num_rows, 0)) as estimated_rows,
       round(sum(nvl(s.segment_mb, 0)), 2) as segment_mb,
       sum(nvl(k.has_pk, 0)) as pk_tables,
       sum(case when nvl(k.has_pk, 0) = 0 and nvl(k.has_uk, 0) = 1 then 1 else 0 end) as unique_key_tables,
       sum(case when nvl(k.has_pk, 0) = 0 and nvl(k.has_uk, 0) = 0 then 1 else 0 end) as no_key_tables,
       sum(case when nvl(l.lob_column_count, 0) > 0 then 1 else 0 end) as lob_tables
  from dba_tables t
  left join table_keys k on k.owner = t.owner and k.table_name = t.table_name
  left join lob_tables l on l.owner = t.owner and l.table_name = t.table_name
  left join segments s on s.owner = t.owner and s.table_name = t.table_name
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
 group by t.owner
 order by round(sum(nvl(s.segment_mb, 0)), 2) desc;
spool off

spool "&out_dir/gg_&run_stamp._table_detail.csv"
with table_keys as (
  select owner,
         table_name,
         max(case when constraint_type = 'P' then 1 else 0 end) as has_pk,
         max(case when constraint_type = 'U' then 1 else 0 end) as has_uk
    from dba_constraints
   where owner like upper('&owner_like')
     and status = 'ENABLED'
     and constraint_type in ('P','U')
   group by owner, table_name
),
lob_cols as (
  select owner, table_name, count(*) as lob_column_count
    from dba_lobs
   where owner like upper('&owner_like')
   group by owner, table_name
),
review_cols as (
  select owner, table_name, count(*) as review_column_count
    from dba_tab_cols
   where owner like upper('&owner_like')
     and (
       data_type in ('LONG','LONG RAW','BFILE','ROWID','UROWID','ANYDATA','ANYTYPE','ANYDATASET','URITYPE','XMLTYPE')
       or data_type like '%LOB'
       or data_type_owner is not null
       or hidden_column = 'YES'
       or virtual_column = 'YES'
     )
   group by owner, table_name
),
segments as (
  select owner, segment_name as table_name, sum(bytes) / 1024 / 1024 as segment_mb
    from dba_segments
   where owner like upper('&owner_like')
     and segment_type in ('TABLE','TABLE PARTITION','TABLE SUBPARTITION')
   group by owner, segment_name
)
select t.owner,
       t.table_name,
       t.num_rows,
       t.avg_row_len,
       t.blocks,
       round(nvl(s.segment_mb, 0), 2) as segment_mb,
       t.partitioned,
       t.temporary,
       t.nested,
       t.iot_type,
       t.logging,
       t.compression,
       case when nvl(k.has_pk, 0) = 1 then 'Y' else 'N' end as has_primary_key,
       case when nvl(k.has_uk, 0) = 1 then 'Y' else 'N' end as has_unique_key,
       nvl(l.lob_column_count, 0) as lob_column_count,
       nvl(r.review_column_count, 0) as review_column_count
  from dba_tables t
  left join table_keys k on k.owner = t.owner and k.table_name = t.table_name
  left join lob_cols l on l.owner = t.owner and l.table_name = t.table_name
  left join review_cols r on r.owner = t.owner and r.table_name = t.table_name
  left join segments s on s.owner = t.owner and s.table_name = t.table_name
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
 order by nvl(s.segment_mb, 0) desc, t.owner, t.table_name;
spool off

spool "&out_dir/gg_&run_stamp._no_key_tables.csv"
with table_keys as (
  select owner,
         table_name,
         max(case when constraint_type = 'P' then 1 else 0 end) as has_pk,
         max(case when constraint_type = 'U' then 1 else 0 end) as has_uk
    from dba_constraints
   where owner like upper('&owner_like')
     and status = 'ENABLED'
     and constraint_type in ('P','U')
   group by owner, table_name
)
select t.owner,
       t.table_name,
       t.num_rows,
       t.avg_row_len,
       t.partitioned,
       t.iot_type,
       case when nvl(k.has_pk, 0) = 1 then 'Y' else 'N' end as has_primary_key,
       case when nvl(k.has_uk, 0) = 1 then 'Y' else 'N' end as has_unique_key
  from dba_tables t
  left join table_keys k on k.owner = t.owner and k.table_name = t.table_name
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
   and nvl(k.has_pk, 0) = 0
   and nvl(k.has_uk, 0) = 0
 order by nvl(t.num_rows, 0) desc, t.owner, t.table_name;
spool off

spool "&out_dir/gg_&run_stamp._column_review.csv"
select owner,
       table_name,
       column_name,
       data_type,
       data_length,
       data_precision,
       data_scale,
       nullable,
       hidden_column,
       virtual_column,
       trim(
         case when data_type in ('LONG','LONG RAW') then 'LONG_OR_LONG_RAW; ' end ||
         case when data_type in ('BFILE','ROWID','UROWID','ANYDATA','ANYTYPE','ANYDATASET','URITYPE','XMLTYPE') then 'SPECIAL_DATATYPE_REVIEW; ' end ||
         case when data_type like '%LOB' then 'LOB_REVIEW; ' end ||
         case when data_type_owner is not null then 'USER_OR_SYSTEM_DEFINED_TYPE_REVIEW; ' end ||
         case when hidden_column = 'YES' then 'HIDDEN_COLUMN; ' end ||
         case when virtual_column = 'YES' then 'VIRTUAL_COLUMN; ' end
       ) as review_reason
  from dba_tab_cols
 where owner like upper('&owner_like')
   and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
   and (
     data_type in ('LONG','LONG RAW','BFILE','ROWID','UROWID','ANYDATA','ANYTYPE','ANYDATASET','URITYPE','XMLTYPE')
     or data_type like '%LOB'
     or data_type_owner is not null
     or hidden_column = 'YES'
     or virtual_column = 'YES'
   )
 order by owner, table_name, column_id;
spool off

spool "&out_dir/gg_&run_stamp._supplemental_logging.csv"
select owner,
       table_name,
       log_group_name,
       log_group_type,
       always,
       generated
  from dba_log_groups
 where owner like upper('&owner_like')
 order by owner, table_name, log_group_name;
spool off

spool "&out_dir/gg_&run_stamp._goldengate_support_mode.csv"
select owner,
       object_name,
       support_mode,
       cast(null as varchar2(4000)) as explanation
  from dba_goldengate_support_mode
 where owner like upper('&owner_like')
   and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
 order by case support_mode
            when 'NONE' then 1
            when 'PLSQL' then 2
            when 'ID KEY' then 3
            when 'INTERNAL' then 4
            when 'FULL' then 9
            else 5
          end,
          owner,
          object_name;
spool off

spool "&out_dir/gg_&run_stamp._dba_goldengate_not_unique.csv"
select owner,
       table_name
  from dba_goldengate_not_unique
 where owner like upper('&owner_like')
 order by owner, table_name;
spool off

set markup csv off
set heading off
set feedback off
set pagesize 0
set linesize 32767
set trimspool on

spool "&report_file"

prompt Oracle GoldenGate 26ai Hub Sizing Baseline Report
prompt =================================================
prompt
prompt This report is a first-pass sizing baseline for self-managed Oracle GoldenGate 26ai Microservices deployments.
prompt It is not a performance guarantee and is not a substitute for a proof of concept, workload replay,
prompt operational monitoring, or validation with production-representative workload before go-live.
prompt
prompt Scope filters used by assessment
prompt ===============================
prompt Schema LIKE filter: &owner_like
prompt PDB LIKE filter: &pdb_name_like
prompt Trail retention hours: &trail_retention_hours
prompt
prompt Database inventory
prompt ==================
select 'Database: ' || d.name || ' / DB_UNIQUE_NAME: ' || d.db_unique_name ||
       ' / Role: ' || d.database_role ||
       ' / Platform: ' || d.platform_name
  from v$database d;
select 'Version: ' || i.version_full ||
       case
         when to_number(regexp_substr(i.version, '^[0-9]+')) >= 19
         then ' (within Oracle Database 19c+ baseline for this GoldenGate sizing assessment)'
         else ' (outside Oracle Database 19c+ baseline; review GoldenGate support before proceeding)'
       end
  from v$instance i;
select 'CDB: ' || d.cdb ||
       ' / LOG_MODE: ' || d.log_mode ||
       ' / FORCE_LOGGING: ' || d.force_logging ||
       ' / MIN_SUPPLEMENTAL_LOGGING: ' || d.supplemental_log_data_min ||
       ' / PK_SUPPLEMENTAL_LOGGING: ' || d.supplemental_log_data_pk ||
       ' / UI_SUPPLEMENTAL_LOGGING: ' || d.supplemental_log_data_ui
  from v$database d;
select 'ENABLE_GOLDENGATE_REPLICATION: ' || nvl((select value
                                                   from v$parameter
                                                  where name = 'enable_goldengate_replication'), 'UNKNOWN')
  from dual;
select 'PDBs in container database: ' ||
       case
         when d.cdb = 'YES' then to_char((select count(*) from v$containers where con_id > 2))
         else '0 (non-CDB source)'
       end
  from v$database d;
select 'Current SQL container for object assessment: ' || sys_context('USERENV', 'CON_NAME')
  from dual;
prompt
prompt Readiness checks
prompt ================
select case when d.log_mode = 'ARCHIVELOG'
            then 'PASS: ARCHIVELOG is enabled.'
            else 'BLOCKER: ARCHIVELOG is not enabled. GoldenGate capture requires redo availability.'
       end
  from v$database d;
select case when d.supplemental_log_data_min = 'YES'
            then 'PASS: Minimal supplemental logging is enabled.'
            else 'BLOCKER: Minimal supplemental logging is not enabled.'
       end
  from v$database d;
select case when d.force_logging = 'YES'
            then 'PASS: FORCE LOGGING is enabled.'
            else 'REVIEW: FORCE LOGGING is not enabled. Review unrecoverable operation risk for the source workload.'
       end
  from v$database d;
select case
         when upper(nvl((select value from v$parameter where name = 'enable_goldengate_replication'), 'UNKNOWN')) = 'TRUE'
         then 'PASS: ENABLE_GOLDENGATE_REPLICATION is TRUE.'
         else 'REVIEW: ENABLE_GOLDENGATE_REPLICATION is not TRUE. Enable/review this setting before configuring GoldenGate capture.'
       end
  from dual;
select 'REVIEW: Tables without enabled primary key or unique key: ' || count(*)
  from (
    select t.owner, t.table_name
      from dba_tables t
      left join (
        select owner, table_name,
               max(case when constraint_type = 'P' then 1 else 0 end) as has_pk,
               max(case when constraint_type = 'U' then 1 else 0 end) as has_uk
          from dba_constraints
         where owner like upper('&owner_like')
           and status = 'ENABLED'
           and constraint_type in ('P','U')
         group by owner, table_name
      ) k on k.owner = t.owner and k.table_name = t.table_name
     where t.owner like upper('&owner_like')
       and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
       and nvl(k.has_pk, 0) = 0
       and nvl(k.has_uk, 0) = 0
  );
select 'REVIEW: Objects where DBA_GOLDENGATE_SUPPORT_MODE is not FULL: ' || count(*)
  from dba_goldengate_support_mode
 where owner like upper('&owner_like')
   and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
   and nvl(support_mode, 'UNKNOWN') <> 'FULL';
select 'REVIEW: Columns requiring GoldenGate datatype or object-shape review: ' || count(*)
  from dba_tab_cols
 where owner like upper('&owner_like')
   and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
   and (
     data_type in ('LONG','LONG RAW','BFILE','ROWID','UROWID','ANYDATA','ANYTYPE','ANYDATASET','URITYPE','XMLTYPE')
     or data_type like '%LOB'
     or data_type_owner is not null
     or hidden_column = 'YES'
     or virtual_column = 'YES'
   );
prompt
prompt Workload summary
prompt ================
with supplied as (
  select case
           when regexp_like('&peak_redo_gb_per_hour', '^[0-9]+(\.[0-9]+)?$')
           then to_number('&peak_redo_gb_per_hour')
         end as supplied_peak_gb,
         case
           when regexp_like('&avg_redo_gb_per_hour', '^[0-9]+(\.[0-9]+)?$')
           then to_number('&avg_redo_gb_per_hour')
         end as supplied_avg_gb
    from dual
),
hourly as (
  select round(sum(blocks * block_size) / 1024 / 1024 / 1024, 3) as redo_gb
    from v$archived_log
   where first_time >= sysdate - 7
     and standby_dest = 'NO'
   group by trunc(first_time, 'HH24')
),
daily as (
  select round(sum(blocks * block_size) / 1024 / 1024 / 1024, 3) as redo_gb
    from v$archived_log
   where first_time >= trunc(sysdate) - 31
     and standby_dest = 'NO'
   group by trunc(first_time)
),
hourly_agg as (
  select max(redo_gb) as peak_hourly_gb,
         round(avg(redo_gb), 3) as avg_hourly_gb
    from hourly
),
daily_agg as (
  select max(redo_gb) as peak_daily_gb
    from daily
)
select '- Archived-log peak hourly: ' || nvl(to_char(h.peak_hourly_gb), '0') || ' GB/hour'
  from hourly_agg h cross join daily_agg d cross join supplied s
union all
select '- Archived-log average hourly: ' || nvl(to_char(h.avg_hourly_gb), '0') || ' GB/hour'
  from hourly_agg h cross join daily_agg d cross join supplied s
union all
select '- Archived-log peak daily: ' || nvl(to_char(d.peak_daily_gb), '0') || ' GB/day'
  from hourly_agg h cross join daily_agg d cross join supplied s
union all
select '- Supplied peak redo/change-rate: ' || nvl(to_char(s.supplied_peak_gb), 'not supplied') || ' GB/hour'
  from hourly_agg h cross join daily_agg d cross join supplied s
union all
select '- Supplied average redo/change-rate: ' || nvl(to_char(s.supplied_avg_gb), 'not supplied') || ' GB/hour'
  from hourly_agg h cross join daily_agg d cross join supplied s
union all
select '- Effective peak redo basis: ' || nvl(to_char(nvl(s.supplied_peak_gb, h.peak_hourly_gb)), '0') || ' GB/hour'
  from hourly_agg h cross join daily_agg d cross join supplied s;
prompt - Note: archived logs are a database-level fallback and may overstate selected-PDB/schema scope; supplied values override archived-log values when provided.
prompt
prompt Replication object scope
prompt ========================
with table_keys as (
  select owner,
         table_name,
         max(case when constraint_type = 'P' then 1 else 0 end) as has_pk,
         max(case when constraint_type = 'U' then 1 else 0 end) as has_uk
    from dba_constraints
   where owner like upper('&owner_like')
     and status = 'ENABLED'
     and constraint_type in ('P','U')
   group by owner, table_name
),
segments as (
  select owner, segment_name as table_name, sum(bytes) / 1024 / 1024 / 1024 as segment_gb
    from dba_segments
   where owner like upper('&owner_like')
     and segment_type in ('TABLE','TABLE PARTITION','TABLE SUBPARTITION')
   group by owner, segment_name
)
select '- Tables: ' || count(*)
  from dba_tables t
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
union all
select '- Estimated rows: ' || nvl(to_char(sum(nvl(t.num_rows, 0))), '0')
  from dba_tables t
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
union all
select '- Table segment GB: ' || nvl(to_char(round(sum(nvl(s.segment_gb, 0)), 2)), '0')
  from dba_tables t
  left join segments s on s.owner = t.owner and s.table_name = t.table_name
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
union all
select '- Tables without PK/UK: ' ||
       nvl(to_char(sum(case when nvl(k.has_pk, 0) = 0 and nvl(k.has_uk, 0) = 0 then 1 else 0 end)), '0')
  from dba_tables t
  left join table_keys k on k.owner = t.owner and k.table_name = t.table_name
 where t.owner like upper('&owner_like')
   and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS');
prompt
prompt GoldenGate Hub baseline recommendation
prompt ======================================
with supplied as (
  select case
           when regexp_like('&peak_redo_gb_per_hour', '^[0-9]+(\.[0-9]+)?$')
           then to_number('&peak_redo_gb_per_hour')
         end as supplied_peak_gb
    from dual
),
hourly as (
  select sum(blocks * block_size) / 1024 / 1024 / 1024 as redo_gb
    from v$archived_log
   where first_time >= sysdate - 7
     and standby_dest = 'NO'
   group by trunc(first_time, 'HH24')
),
redo_score as (
  select case
           when nvl(s.supplied_peak_gb, nvl(max(h.redo_gb), 0)) < 1 then 1
           when nvl(s.supplied_peak_gb, nvl(max(h.redo_gb), 0)) <= 500 then 2
           when nvl(s.supplied_peak_gb, nvl(max(h.redo_gb), 0)) <= 1024 then 3
           else 4
         end as score,
         round(nvl(s.supplied_peak_gb, nvl(max(h.redo_gb), 0)), 3) as peak_redo_gb_per_hour,
         round(nvl(avg(h.redo_gb), 0), 3) as avg_redo_gb_per_hour
    from supplied s left join hourly h on 1 = 1
   group by s.supplied_peak_gb
),
table_scope as (
  select count(*) as table_count,
         case
           when count(*) < 100 then 1
           when count(*) <= 500 then 2
           when count(*) <= 2000 then 3
           else 4
         end as score
    from dba_tables
   where owner like upper('&owner_like')
     and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
),
recommendation as (
  select greatest(r.score, t.score) as score,
         r.peak_redo_gb_per_hour,
         r.avg_redo_gb_per_hour,
         t.table_count,
         ceil(r.peak_redo_gb_per_hour * to_number('&trail_retention_hours') * 1.5) as formula_trail_gb
    from redo_score r cross join table_scope t
)
select 'Recommended starting tier: ' ||
       case score when 1 then 'Small' when 2 then 'Medium' when 3 then 'Large' else 'X-Large' end
  from recommendation;
prompt - Basis: selected from effective peak redo/change rate and table count.
prompt - Rule: when sizing signals straddle tiers, choose the larger tier.
with supplied as (
  select case
           when regexp_like('&peak_redo_gb_per_hour', '^[0-9]+(\.[0-9]+)?$')
           then to_number('&peak_redo_gb_per_hour')
         end as supplied_peak_gb
    from dual
),
hourly as (
  select sum(blocks * block_size) / 1024 / 1024 / 1024 as redo_gb
    from v$archived_log
   where first_time >= sysdate - 7
     and standby_dest = 'NO'
   group by trunc(first_time, 'HH24')
),
redo_score as (
  select case
           when nvl(s.supplied_peak_gb, nvl(max(h.redo_gb), 0)) < 1 then 1
           when nvl(s.supplied_peak_gb, nvl(max(h.redo_gb), 0)) <= 500 then 2
           when nvl(s.supplied_peak_gb, nvl(max(h.redo_gb), 0)) <= 1024 then 3
           else 4
         end as score,
         round(nvl(s.supplied_peak_gb, nvl(max(h.redo_gb), 0)), 3) as peak_redo_gb_per_hour
    from supplied s left join hourly h on 1 = 1
   group by s.supplied_peak_gb
),
table_scope as (
  select case
           when count(*) < 100 then 1
           when count(*) <= 500 then 2
           when count(*) <= 2000 then 3
           else 4
         end as score
    from dba_tables
   where owner like upper('&owner_like')
     and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
),
recommendation as (
  select greatest(r.score, t.score) as score,
         ceil(r.peak_redo_gb_per_hour * to_number('&trail_retention_hours') * 1.5) as formula_trail_gb
    from redo_score r cross join table_scope t
)
select '- vCPU: ' || case score when 1 then '8' when 2 then '16' when 3 then '32' else '64-128' end from recommendation
union all
select '- RAM: ' || case score when 1 then '64 GB' when 2 then '128 GB' when 3 then '256 GB' else '512 GB' end from recommendation
union all
select '- OS/software disk: ' || case score when 1 then '50 GB' else '100 GB' end from recommendation
union all
select '- Trail/working disk guide: ' || case score when 1 then '200 GB' when 2 then '500 GB' when 3 then '1-2 TB' else '2-5 TB' end from recommendation
union all
select '- Calculated trail storage for retention: ' || formula_trail_gb || ' GB' from recommendation
union all
select '- Storage rule: use the larger of the guide value and calculated requirement.' from recommendation;
with hourly as (
  select sum(blocks * block_size) / 1024 / 1024 / 1024 as redo_gb
    from v$archived_log
   where first_time >= sysdate - 7
     and standby_dest = 'NO'
   group by trunc(first_time, 'HH24')
),
redo_score as (
  select case
           when nvl(max(redo_gb), 0) < 1 then 1
           when nvl(max(redo_gb), 0) <= 500 then 2
           when nvl(max(redo_gb), 0) <= 1024 then 3
           else 4
         end as score
    from hourly
),
table_scope as (
  select case
           when count(*) < 100 then 1
           when count(*) <= 500 then 2
           when count(*) <= 2000 then 3
           else 4
         end as score
    from dba_tables
   where owner like upper('&owner_like')
     and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
),
recommendation as (
  select greatest(r.score, t.score) as score
    from redo_score r cross join table_scope t
)
select '- Disk guide: ' ||
       case score when 1 then 'SSD, 1,000 IOPS, 100 MB/s'
                  when 2 then 'SSD, 3,000 IOPS, 300 MB/s'
                  when 3 then 'NVMe SSD, 10,000 IOPS, 1 GB/s'
                  else 'NVMe SSD, 30,000+ IOPS, 3 GB/s'
       end
  from recommendation
union all
select '- Network minimum: ' ||
       case score when 1 then '1 GbE' when 2 then '1 GbE' when 3 then '10 GbE' else '10-25 GbE' end
  from recommendation;
prompt
prompt Process-count starting point
prompt ============================
with hourly as (
  select sum(blocks * block_size) / 1024 / 1024 / 1024 as redo_gb
    from v$archived_log
   where first_time >= sysdate - 7
     and standby_dest = 'NO'
   group by trunc(first_time, 'HH24')
),
redo_score as (
  select case
           when nvl(max(redo_gb), 0) < 1 then 1
           when nvl(max(redo_gb), 0) <= 500 then 2
           when nvl(max(redo_gb), 0) <= 1024 then 3
           else 4
         end as score
    from hourly
),
table_scope as (
  select case
           when count(*) < 100 then 1
           when count(*) <= 500 then 2
           when count(*) <= 2000 then 3
           else 4
         end as score
    from dba_tables
   where owner like upper('&owner_like')
     and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
),
recommendation as (
  select greatest(r.score, t.score) as score
    from redo_score r cross join table_scope t
)
select '- Integrated Extract: ' || case score when 1 then '1' when 2 then '1-2' when 3 then '1-2' else '2-4' end from recommendation
union all
select '- Distribution Paths: ' || case score when 1 then '1-2' when 2 then '2-4' when 3 then '4-8' else '8-16' end from recommendation
union all
select '- Parallel Replicat groups: ' || case score when 1 then '1' when 2 then '1-2' when 3 then '2-4' else '4-8' end from recommendation
union all
select '- Max concurrent GoldenGate processes: ' || case score when 1 then '4-6' when 2 then '8-14' when 3 then '16-34' else '36-70' end from recommendation;
prompt
prompt Process and recovery sizing prompts
prompt ===================================
with pdb_scope as (
  select d.cdb,
         case
           when d.cdb = 'YES'
            and upper('&pdb_name_like') not in ('%', 'CDB$ROOT', 'PDB$SEED')
            and instr('&pdb_name_like', '%') = 0
           then 1
           when d.cdb = 'YES'
           then (select count(*) from v$containers where con_id > 2)
           else 0
         end as pdbs_in_scope
    from v$database d
)
select 'PDB scope for Extract planning: ' ||
       case
         when cdb = 'YES' then to_char(pdbs_in_scope) || ' PDB(s) in scope.'
         else 'non-CDB source.'
       end
  from pdb_scope;
with hourly as (
  select sum(blocks * block_size) / 1024 / 1024 / 1024 as redo_gb
    from v$archived_log
   where first_time >= sysdate - 7
     and standby_dest = 'NO'
   group by trunc(first_time, 'HH24')
),
redo_score as (
  select case
           when nvl(max(redo_gb), 0) < 1 then 1
           when nvl(max(redo_gb), 0) <= 500 then 2
           when nvl(max(redo_gb), 0) <= 1024 then 3
           else 4
         end as score
    from hourly
),
table_scope as (
  select case
           when count(*) < 100 then 1
           when count(*) <= 500 then 2
           when count(*) <= 2000 then 3
           else 4
         end as score
    from dba_tables
   where owner like upper('&owner_like')
     and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
),
pdb_scope as (
  select d.cdb,
         case
           when d.cdb = 'YES'
            and upper('&pdb_name_like') not in ('%', 'CDB$ROOT', 'PDB$SEED')
            and instr('&pdb_name_like', '%') = 0
           then 1
           when d.cdb = 'YES'
           then (select count(*) from v$containers where con_id > 2)
           else 0
         end as pdbs_in_scope
    from v$database d
),
recommendation as (
  select greatest(r.score, t.score) as score,
         p.cdb,
         p.pdbs_in_scope
    from redo_score r cross join table_scope t cross join pdb_scope p
)
select '- Starting Extract groups: ' ||
       case
         when cdb = 'YES' then to_char(greatest(1, pdbs_in_scope))
         else '1'
       end
  from recommendation
union all
select '- Extract rule: one Integrated Extract per source database or per source PDB in scope.' from recommendation
union all
select '- Design review: do not split one PDB redo stream unless table-group partitioning is confirmed.' from recommendation
union all
select '- Tier guide: ' || case score when 1 then '1' when 2 then '1-2' when 3 then '1-2' else '2-4' end from recommendation;
with hourly as (
  select sum(blocks * block_size) / 1024 / 1024 / 1024 as redo_gb
    from v$archived_log
   where first_time >= sysdate - 7
     and standby_dest = 'NO'
   group by trunc(first_time, 'HH24')
),
redo_peak as (
  select nvl(max(redo_gb), 0) as peak_redo_gb_per_hour
    from hourly
)
select '- Peak redo basis: ' || round(peak_redo_gb_per_hour, 3) || ' GB/hour' from redo_peak
union all
select '- CACHEMGR review point: ' ||
       greatest(8, least(64, ceil(peak_redo_gb_per_hour * 0.25))) ||
       ' GB' from redo_peak
union all
select '- CACHEMGR rule: about 15 minutes of peak redo, capped at 64 GB for an initial review point.' from redo_peak
union all
select '- Bounded recovery / spill headroom: at least ' ||
       greatest(20, ceil(peak_redo_gb_per_hour * 0.5)) ||
       ' GB on fast trail storage' from redo_peak
union all
select '- Validation: test long-running transactions and review CACHEMGR spill statistics.' from redo_peak;
prompt
prompt Parallel Replicat starting parameters
prompt ======================================
prompt Use this section to start the target apply design. Validate with target database capacity,
prompt transaction dependencies, constraints, indexes, triggers, and representative workload.
prompt Oracle reference: https://docs.oracle.com/en/middleware/goldengate/core/21.3/coredoc/replicat-basic-parameters-parallel-replicat.html
with hourly as (
  select sum(blocks * block_size) / 1024 / 1024 / 1024 as redo_gb
    from v$archived_log
   where first_time >= sysdate - 7
     and standby_dest = 'NO'
   group by trunc(first_time, 'HH24')
),
redo_score as (
  select case
           when nvl(max(redo_gb), 0) < 1 then 1
           when nvl(max(redo_gb), 0) <= 500 then 2
           when nvl(max(redo_gb), 0) <= 1024 then 3
           else 4
         end as score
    from hourly
),
table_scope as (
  select case
           when count(*) < 100 then 1
           when count(*) <= 500 then 2
           when count(*) <= 2000 then 3
           else 4
         end as score
    from dba_tables
   where owner like upper('&owner_like')
     and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
),
recommendation as (
  select greatest(r.score, t.score) as score
    from redo_score r cross join table_scope t
)
select '- MAP_PARALLELISM starting point: ' ||
       case score when 1 then '2' when 2 then '3' when 3 then '4' else '6' end ||
       ' mapper thread(s). Default is 2; valid documented range is 1-100.'
  from recommendation
union all
select '- Auto-tuned apply mode: use MIN_APPLY_PARALLELISM and MAX_APPLY_PARALLELISM together.' from recommendation
union all
select '- MIN_APPLY_PARALLELISM starting point: ' ||
       case score when 1 then '1' when 2 then '2' when 3 then '4' else '8' end
  from recommendation
union all
select '- MAX_APPLY_PARALLELISM starting point: ' ||
       case score when 1 then '4' when 2 then '8' when 3 then '16' else '32' end
  from recommendation
union all
select '- Fixed apply mode alternative: APPLY_PARALLELISM starting point: ' ||
       case score when 1 then '4' when 2 then '8' when 3 then '16' else '32' end ||
       '. Use only if you do not use MIN/MAX apply parallelism.'
  from recommendation
union all
select '- SPLIT_TRANS_RECS: leave disabled initially; consider only for large transactions after dependency and recovery testing.' from recommendation
union all
select '- COMMIT_SERIALIZATION: use FULL only when target commit order must be forced; validate throughput impact.' from recommendation
union all
select '- LOOK_AHEAD_TRANSACTIONS: keep the default starting point unless scheduling tests show a bottleneck.' from recommendation
union all
select '- CHUNK_SIZE: keep the default starting point; increasing it can consume more Replicat memory.' from recommendation
union all
select '- Tuning note: increase gradually while watching apply lag, CPU above 80 percent, target constraints, and transaction dependencies.' from recommendation;
prompt
prompt Validation requirements before production
prompt =========================================
prompt Validate this baseline with production-representative workload before go-live.
prompt During validation, monitor Extract lag, Replicat lag, CPU utilization, CACHEMGR spill,
prompt trail backlog growth, trail filesystem utilization, swap activity, and process restarts.
prompt A generally healthy starting target is Extract lag below 5 seconds, Replicat lag below 10 seconds,
prompt sustained CPU below 70 percent, trail filesystem below 70 percent, minimal CACHEMGR spill,
prompt and no recurring resource-related GoldenGate abends.
prompt
prompt Appendix A - Tables without primary or unique key
prompt =================================================
with table_keys as (
  select owner, table_name,
         max(case when constraint_type = 'P' then 1 else 0 end) as has_pk,
         max(case when constraint_type = 'U' then 1 else 0 end) as has_uk
    from dba_constraints
   where owner like upper('&owner_like')
     and status = 'ENABLED'
     and constraint_type in ('P','U')
   group by owner, table_name
),
no_key_tables as (
  select t.owner, t.table_name, nvl(t.num_rows, 0) as num_rows,
         t.partitioned, nvl(t.iot_type, 'HEAP') as table_type
    from dba_tables t
    left join table_keys k on k.owner = t.owner and k.table_name = t.table_name
   where t.owner like upper('&owner_like')
     and t.owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
     and nvl(k.has_pk, 0) = 0
     and nvl(k.has_uk, 0) = 0
)
select case when count(*) = 0 then 'No tables without enabled primary key or unique key were found for this scope.' end
  from no_key_tables
having count(*) = 0
union all
select '- ' || owner || '.' || table_name || ' | rows=' || to_char(num_rows) ||
       ' | partitioned=' || partitioned || ' | type=' || table_type
  from no_key_tables
 order by 1;
prompt
prompt Appendix B - Columns requiring datatype or object-shape review
prompt =============================================================
with review_columns as (
  select owner, table_name, column_name, data_type,
         trim(
           case when data_type in ('LONG','LONG RAW') then 'LONG_OR_LONG_RAW; ' end ||
           case when data_type in ('BFILE','ROWID','UROWID','ANYDATA','ANYTYPE','ANYDATASET','URITYPE','XMLTYPE') then 'SPECIAL_DATATYPE_REVIEW; ' end ||
           case when data_type like '%LOB' then 'LOB_REVIEW; ' end ||
           case when data_type_owner is not null then 'USER_OR_SYSTEM_DEFINED_TYPE_REVIEW; ' end ||
           case when hidden_column = 'YES' then 'HIDDEN_COLUMN; ' end ||
           case when virtual_column = 'YES' then 'VIRTUAL_COLUMN; ' end
         ) as review_reason
    from dba_tab_cols
   where owner like upper('&owner_like')
     and owner not in ('SYS','SYSTEM','XDB','CTXSYS','MDSYS','ORDSYS','OUTLN','WMSYS')
     and (
       data_type in ('LONG','LONG RAW','BFILE','ROWID','UROWID','ANYDATA','ANYTYPE','ANYDATASET','URITYPE','XMLTYPE')
       or data_type like '%LOB'
       or data_type_owner is not null
       or hidden_column = 'YES'
       or virtual_column = 'YES'
     )
)
select case when count(*) = 0 then 'No datatype or object-shape review columns were found for this scope.' end
  from review_columns
having count(*) = 0
union all
select '- ' || owner || '.' || table_name || '.' || column_name ||
       ' | type=' || data_type || ' | reason=' || review_reason
  from review_columns
 order by 1;
prompt
prompt Files generated
prompt ===============
select '&out_dir' from dual;
prompt
prompt End of report.

spool off
exit
SQL

PDB_CONTAINER_COMMAND_ESCAPED=$(printf '%s\n' "$PDB_CONTAINER_COMMAND" | sed 's/[\/&]/\\&/g')
sed "s|__PDB_CONTAINER_COMMAND__|${PDB_CONTAINER_COMMAND_ESCAPED}|" "$ASSESSMENT_SQL" > "${ASSESSMENT_SQL}.tmp"
mv "${ASSESSMENT_SQL}.tmp" "$ASSESSMENT_SQL"

echo "Running GoldenGate sizing assessment..."
echo "Output directory: $OUTPUT_DIR"

set +e
"$SQLPLUS_BIN" -s "$CONNECT_STRING" @"$ASSESSMENT_SQL" "$OUTPUT_DIR" "$OWNER_LIKE" "$PDB_LIKE" "$RETENTION_HOURS" "$RUN_STAMP" "$PEAK_REDO_GB_PER_HOUR" "$AVG_REDO_GB_PER_HOUR" > "$RUN_LOG" 2>&1
SQLPLUS_STATUS=$?
set -e

REPORT_FILE="${OUTPUT_DIR}/ogg_26ai_sizing_report_${RUN_STAMP}.txt"

if [ "$SQLPLUS_STATUS" -ne 0 ]; then
  echo "ERROR: SQL*Plus/SQLcl returned status $SQLPLUS_STATUS. See log: $RUN_LOG" >&2
  exit "$SQLPLUS_STATUS"
fi

echo
echo "Assessment complete."
echo "Report: $REPORT_FILE"
echo "CSV/log output: $OUTPUT_DIR"
echo

if [ -f "$REPORT_FILE" ]; then
  sed -n '1,220p' "$REPORT_FILE"
else
  echo "WARNING: Report file was not created. Review log: $RUN_LOG" >&2
fi
