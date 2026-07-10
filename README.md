# Oracle GoldenGate 26ai Sizing Assessment

Author: Alex Lima

Single-file customer assessment for Oracle GoldenGate 26ai self-managed Hub sizing.

The project now centers on one shareable shell script:

```text
ogg_26ai_sizing_assessment.sh
sample_ogg_26ai_sizing_report.txt
```

The script connects through SQL*Plus or SQLcl, gathers Oracle Database metadata and workload signals, writes CSV evidence files, and generates a first-pass GoldenGate Hub sizing baseline report.

`sample_ogg_26ai_sizing_report.txt` shows an example of the generated text report format.

## Scope

This assessment is intended for Oracle Database 19c and later, matching the supported GoldenGate 26ai Oracle Database source baseline used by the sizing guide.

It is focused on self-managed GoldenGate Microservices deployments. OCI GoldenGate uses a different sizing model and should be sized with OCI GoldenGate service guidance.

Autonomous Database is supported by the same `ogg_26ai_sizing_assessment.sh` script using the `-a` option. There is no second script file. This mode exists because customers cannot use SYSDBA or run the assessment on the Autonomous Database host. Autonomous mode is intended to run from a client machine with SQL*Plus or SQLcl and the ADB wallet/TNS alias.

## Requirements

- Unix-like shell environment.
- SQL*Plus available in `PATH`, or set `SQLPLUS_BIN`.
- SQLcl is also supported; still use `SQLPLUS_BIN` to point to the `sql` executable.
- Oracle client connectivity to the source database.
- A database account with read access to required `DBA_*` and `V$` views.
- Access to `DBA_HIST_CON_SYSSTAT` and `DBA_HIST_SNAPSHOT` if historical PDB redo by hour/day should be gathered.
- For Autonomous Database: a wallet/TNS connection and a database user with catalog access to the schemas being assessed. Do not use SYSDBA.
- For Autonomous Database wallets, set `TNS_ADMIN` to the wallet directory or pass `-w /path/to/wallet`.

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
./ogg_26ai_sizing_assessment.sh -a -w "/path/to/Wallet_ADB" -c 'admin/password@myadb_high' -s "HR"
```

Run against Autonomous Database with SQLcl:

```sh
export SQLPLUS_BIN=/opt/sqlcl/bin/sql
export TNS_ADMIN=/path/to/Wallet_ADB
./ogg_26ai_sizing_assessment.sh -a -c 'admin/password@myadb_high' -s "HR"
```

Options:

```text
-c CONNECT   SQL*Plus/SQLcl connect string. Default: ORACLE_CONNECT or "/ as sysdba"
-s PATTERN   Schema SQL LIKE filter for replicated objects. Default: %
-p PATTERN   PDB name or SQL LIKE filter for CDB/PDB redo scope. Default: %
-r HOURS     Trail retention hours for storage estimate. Default: 24
-o DIR       Output directory. Default: ogg_sizing_YYYYMMDD_HH24MISS
-w DIR       ADB wallet directory. Sets TNS_ADMIN for this execution.
-a           Autonomous Database mode. Use a client/wallet connection; do not use SYSDBA.
-h           Show help.
```

You can also set:

```sh
export ORACLE_CONNECT="/ as sysdba"
export SQLPLUS_BIN=/path/to/sqlplus
```

For SQLcl, keep using `SQLPLUS_BIN`:

```sh
export SQLPLUS_BIN=/path/to/sql
```

When `-p` is an exact PDB name, for example `-p "FREEPDB1"`, the script switches the SQL session into that PDB before assessing schema and object metadata. When `-p` contains a wildcard such as `%`, it is used as a filter only.

Autonomous mode does not gather archived-log or host-local metrics. Its report is intentionally lower confidence and asks for ADB workload metrics, GoldenGate throughput, network path, target count, and initial-load details before final sizing.

For Autonomous Database wallet connections, either export `TNS_ADMIN` before running the script or pass the wallet directory with `-w`:

```sh
export TNS_ADMIN=/path/to/Wallet_ADB
./ogg_26ai_sizing_assessment.sh -a -c 'admin/password@myadb_high' -s "HR"
```

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
- SQL*Plus/SQLcl execution log

Autonomous mode creates a reduced output set focused on:

- `ogg_26ai_sizing_report_<timestamp>.txt`
- Autonomous database inventory CSV
- schema summary CSV
- table detail CSV
- tables without key CSV
- column review CSV
- supplemental logging CSV
- workload inputs needed CSV
- SQL*Plus/SQLcl execution log

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
- Extract count and Cache Manager / bounded recovery planning prompts
- a dedicated Parallel Replicat section with starting guidance for `MAP_PARALLELISM`, `MIN_APPLY_PARALLELISM`, `MAX_APPLY_PARALLELISM`, `APPLY_PARALLELISM`, `SPLIT_TRANS_RECS`, `COMMIT_SERIALIZATION`, `LOOK_AHEAD_TRANSACTIONS`, and `CHUNK_SIZE`

## Sizing Method

The baseline recommendation is selected primarily from peak sustained hourly redo and source table count. When the workload signals fall across two tiers, the script chooses the larger tier for headroom.

Trail storage is calculated as:

```text
Peak redo GB per hour x retention hours x 1.5 safety factor
```

The report also shows the guide-level trail disk baseline for the selected tier. Use the larger of the calculated trail requirement and the tier baseline.

The process and recovery prompts are starting points:

- Integrated Extract guidance starts with one Extract per source database or per source PDB in scope.
- Cache Manager guidance uses peak redo to estimate an initial `CACHEMGR` review point and bounded-recovery/spill headroom. Validate this with long-running transactions and actual `CACHEMGR` spill statistics.

Parallel Replicat guidance is reported in its own section so customers can distinguish apply-thread planning from Extract and recovery sizing. It uses the basic Oracle Parallel Replicat parameters documented here:

```text
https://docs.oracle.com/en/middleware/goldengate/core/21.3/coredoc/replicat-basic-parameters-parallel-replicat.html
```

The script recommends auto-tuned apply parallelism with `MIN_APPLY_PARALLELISM` and `MAX_APPLY_PARALLELISM` as the starting point. If a customer prefers fixed apply parallelism, use `APPLY_PARALLELISM` instead and do not set it together with `MIN_APPLY_PARALLELISM` / `MAX_APPLY_PARALLELISM`.

## Important Disclaimer

The generated sizing is only a starting recommendation. It is not a performance guarantee and is not a substitute for a proof of concept, workload replay, operational monitoring, or validation with production-representative workload.

Before production, customers must validate CPU, memory, trail storage, I/O, network throughput, Extract lag, Replicat lag, Cache Manager behavior, trail backlog growth, and process stability under realistic workload.
