# Oracle GoldenGate 26ai Sizing Assessment

Author: Alex Lima

Single-file customer assessment for Oracle GoldenGate 26ai self-managed Hub sizing.

The project now centers on one shareable shell script:

```text
ogg_26ai_sizing_assessment.sh
sample_ogg_26ai_sizing_report.txt
```

The script connects through SQL*Plus, gathers Oracle Database metadata and workload signals, writes CSV evidence files, and generates a first-pass GoldenGate Hub sizing baseline report.

`sample_ogg_26ai_sizing_report.txt` shows an example of the generated text report format.

## Scope

This assessment is intended for Oracle Database 19c and later, matching the supported GoldenGate 26ai Oracle Database source baseline used by the sizing guide.

It is focused on self-managed GoldenGate Microservices deployments. OCI GoldenGate uses a different sizing model and should be sized with OCI GoldenGate service guidance.

Autonomous Database is supported by the same `ogg_26ai_sizing_assessment.sh` script using the `-a` option. There is no second script file. This mode exists because customers cannot use SYSDBA or run the assessment on the Autonomous Database host. Autonomous mode is intended to run from a client machine with SQL*Plus or SQLcl and the ADB wallet/TNS alias.

## Requirements

- Unix-like shell environment.
- SQL*Plus available in `PATH`, or set `SQLPLUS_BIN`.
- Oracle client connectivity to the source database.
- A database account with read access to required `DBA_*` and `V$` views.
- Access to `DBA_HIST_CON_SYSSTAT` and `DBA_HIST_SNAPSHOT` if historical PDB redo by hour/day should be gathered.
- For Autonomous Database: a wallet/TNS connection and a database user with catalog access to the schemas being assessed. Do not use SYSDBA.

Typical execution is done by a DBA or assessment user with sufficient catalog privileges.

## Usage

Run with the default local SYSDBA connection:

```sh
./ogg_26ai_sizing_assessment.sh -c "/ as sysdba"
```

Run with schema and PDB filters:

```sh
./ogg_26ai_sizing_assessment.sh -c "system@prod" -s "APP%" -p "APP_PDB" -r 48
```

Run against Autonomous Database from a client machine:

```sh
./ogg_26ai_sizing_assessment.sh -a -c 'admin/password@myadb_high' -s "HR"
```

Options:

```text
-c CONNECT   SQL*Plus connect string. Default: ORACLE_CONNECT or "/ as sysdba"
-s PATTERN   Schema SQL LIKE filter for replicated objects. Default: %
-p PATTERN   PDB name or SQL LIKE filter for CDB/PDB redo scope. Default: %
-r HOURS     Trail retention hours for storage estimate. Default: 24
-o DIR       Output directory. Default: ogg_sizing_YYYYMMDD_HH24MISS
-a           Autonomous Database mode. Use a client/wallet connection; do not use SYSDBA.
-h           Show help.
```

You can also set:

```sh
export ORACLE_CONNECT="/ as sysdba"
export SQLPLUS_BIN=/path/to/sqlplus
```

When `-p` is an exact PDB name, for example `-p "FREEPDB1"`, the script switches the SQL session into that PDB before assessing schema and object metadata. When `-p` contains a wildcard such as `%`, it is used as a filter only.

Autonomous mode does not gather archived-log or host-local metrics. Its report is intentionally lower confidence and asks for ADB workload metrics, GoldenGate throughput, network path, target count, and initial-load details before final sizing.

## Output

Self-managed mode creates a timestamped output directory containing:

- `ogg_26ai_sizing_report_<timestamp>.txt`
- database inventory CSV
- archived log daily and hourly CSVs
- current PDB redo CSV
- AWR PDB redo daily and hourly CSVs, when accessible
- schema summary CSV
- table detail CSV
- tables without key CSV
- column review CSV
- supplemental logging CSV
- GoldenGate support mode CSV
- SQL*Plus execution log

Autonomous mode creates a reduced output set focused on:

- `ogg_26ai_sizing_report_<timestamp>.txt`
- Autonomous database inventory CSV
- schema summary CSV
- table detail CSV
- tables without key CSV
- column review CSV
- supplemental logging CSV
- workload inputs needed CSV
- SQL*Plus execution log

The text report includes:

- database version and 19c+ baseline status
- `ENABLE_GOLDENGATE_REPLICATION` value
- number of PDBs in the container database
- ARCHIVELOG, force logging, and supplemental logging checks
- counts of tables without primary or unique keys
- counts of objects requiring GoldenGate support review
- archived-log workload summary
- replicated object scope summary
- recommended starting Hub tier
- starting vCPU, RAM, trail storage, I/O, network, and process-count guidance
- Extract count, Parallel Replicat thread, and Cache Manager / bounded recovery planning prompts

## Sizing Method

The baseline recommendation is selected primarily from peak sustained hourly redo and source table count. When the workload signals fall across two tiers, the script chooses the larger tier for headroom.

Trail storage is calculated as:

```text
Peak redo GB per hour x retention hours x 1.5 safety factor
```

The report also shows the guide-level trail disk baseline for the selected tier. Use the larger of the calculated trail requirement and the tier baseline.

The process and recovery prompts are starting points:

- Integrated Extract guidance starts with one Extract per source database or per source PDB in scope.
- Parallel Replicat guidance starts `MAX_APPLY_PARALLELISM` near half of baseline vCPU and `MIN_APPLY_PARALLELISM` near one quarter of max.
- Cache Manager guidance uses peak redo to estimate an initial `CACHEMGR` review point and bounded-recovery/spill headroom. Validate this with long-running transactions and actual `CACHEMGR` spill statistics.

## Important Disclaimer

The generated sizing is only a starting recommendation. It is not a performance guarantee and is not a substitute for a proof of concept, workload replay, operational monitoring, or validation with production-representative workload.

Before production, customers must validate CPU, memory, trail storage, I/O, network throughput, Extract lag, Replicat lag, Cache Manager behavior, trail backlog growth, and process stability under realistic workload.
