# PLP Database Management — Week 6
## Hands-On Lab: Backups, Point-in-Time Recovery (PITR), and Streaming Replication

This lab demonstrates PostgreSQL logical backups with `pg_dump`/`pg_restore`, WAL archiving, physical base backups, point-in-time recovery, and a streaming standby.

> **Important:** Run this in a disposable local PostgreSQL lab, not on production data. PITR requires a base backup taken before the incident and every required WAL segment from that backup through the recovery target. Do not run the simulated `DELETE` against a database containing important data.

## Prerequisites
- PostgreSQL server and client tools installed (`psql`, `pg_dump`, `pg_restore`, `pg_basebackup`).
- A database named `bootcamp` and a `students` table for the exercises.
- A PostgreSQL superuser or appropriate database/OS permissions for server configuration and replication.
- Enough disk space for backups and WAL files.

Check versions and connectivity:

```bash
psql --version
pg_dump --version
pg_restore --version
pg_basebackup --version
psql -d bootcamp -c 'SELECT version();'
```

## Step 1 — Logical backup and restore verification

Run as the OS user that can connect to the database:

```bash
mkdir -p "$HOME/backups"
chmod 700 "$HOME/backups"

pg_dump -Fc -f "$HOME/backups/bootcamp.dump" bootcamp
pg_restore --list "$HOME/backups/bootcamp.dump" | head

# Create a separate test database; it must not already exist.
createdb bootcamp_check
pg_restore --verbose --exit-on-error -d bootcamp_check "$HOME/backups/bootcamp.dump"

# Verify objects/data, then optionally remove the test database.
psql -d bootcamp_check -c '\\dt'
# dropdb bootcamp_check
```

A successful `pg_restore` exit status and expected tables/data in `bootcamp_check` verify the logical backup can be restored. If `bootcamp_check` already exists, inspect it first rather than dropping or overwriting it.

## Step 2 — Enable WAL archiving and take a base backup

1. Choose an **absolute path** for the archive directory. The PostgreSQL server OS account must be able to write to it. Example on a typical Linux package install:

```bash
sudo install -d -o postgres -g postgres -m 700 /var/lib/postgresql/wal_archive
```

2. Edit the active `postgresql.conf` (find it with `SHOW config_file;`) and set:

```conf
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/wal_archive/%f && cp %p /var/lib/postgresql/wal_archive/%f'
```

The command avoids overwriting an archived WAL file. If archiving fails, PostgreSQL will retry; monitor the server log and archive status. `archive_mode` requires a server restart.

3. Restart the correct PostgreSQL service, then verify:

```bash
sudo systemctl restart postgresql
psql -d bootcamp -c 'SHOW wal_level;'
psql -d bootcamp -c 'SHOW archive_mode;'
psql -d bootcamp -c 'SHOW archive_command;'
psql -d bootcamp -c 'SELECT * FROM pg_stat_archiver;'
```

4. Take a physical base backup to a **new or empty destination**. For a local lab, the simplest option is:

```bash
mkdir -p "$HOME/backups"
pg_basebackup -D "$HOME/backups/base" -Fp -Xs -P
```

The OS user running this command needs appropriate database access and filesystem permissions. For remote/production-like setups, configure a dedicated backup/replication role and connection authentication. Do not put passwords directly in shell history.

## Step 3 — Simulate data loss and recover to a point in time

**Only do this on a disposable lab database.** First confirm WAL archiving is working and that the base backup has completed. The target time must be **before** the destructive transaction commits.

1. In a `psql` session connected to the lab database, record a target time and keep it for the recovery exercise:

```sql
SELECT clock_timestamp() AS recovery_target_time;
```

For more reliable timing, use a timestamp captured **before** the deletion and note its timezone. Then simulate the incident:

```sql
BEGIN;
DELETE FROM students;
COMMIT;
```

2. Stop PostgreSQL cleanly. Identify the actual data directory first with `SHOW data_directory;` and use the correct service name for your system.

3. Preserve the failed data directory for investigation; do not immediately delete it. Restore the base backup into the configured data directory, preserving correct ownership and permissions. Never copy a backup over a running server's data directory.

4. Configure recovery in the restored data directory's `postgresql.conf` (or the active configuration file):

```conf
restore_command = 'cp /var/lib/postgresql/wal_archive/%f %p'
recovery_target_time = '2026-10-14 09:00:00+03'
recovery_target_action = 'pause'
```

Replace the example time with the actual timestamp recorded before the deletion. Use a timezone-aware timestamp. The archive path must match the path used in Step 2.

5. Create the recovery signal file in the restored data directory:

```bash
sudo -u postgres touch /path/to/actual/data_directory/recovery.signal
```

Replace the placeholder with the real data directory and ensure its owner/permissions are correct. Start PostgreSQL. It will replay archived WAL and stop at the configured target (with `recovery_target_action = 'pause'`). Check PostgreSQL logs for recovery errors and confirm the target was reached.

6. Verify the data:

```sql
SELECT count(*) FROM students;
```

Confirm the expected rows are present. Once verified, you can resume recovery with `pg_wal_replay_resume()` if the server is paused and you intentionally want to continue, or reconfigure the target and restart as appropriate. Do not resume blindly: replaying past the target may reapply the deletion.

**PITR notes:** The base backup must predate the target, and all necessary WAL must be available. A logical `pg_dump` alone is not sufficient for physical PITR. Follow PostgreSQL's version-specific documentation for exact recovery procedures.

## Step 4 — Build a streaming standby

This is a separate exercise from PITR. Use a separate standby host or isolated data directory/server configuration; two servers cannot run from the same data directory.

On the primary, create a dedicated role (choose a strong lab password):

```sql
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replace-with-a-strong-password';
```

In the primary server's `pg_hba.conf`, permit replication only from the standby's actual IP address. For a same-machine lab, an example is:

```conf
host replication replicator 127.0.0.1/32 scram-sha-256
```

Use the authentication method supported by your PostgreSQL configuration; prefer SCRAM where supported. Reload PostgreSQL after editing `pg_hba.conf`:

```bash
sudo systemctl reload postgresql
```

From the standby environment, run the base backup using a **new/empty** directory:

```bash
pg_basebackup -h 127.0.0.1 -p 5432 -U replicator \
  -D "$HOME/standby" -R -P -X stream
```

Enter the role password securely when prompted. The `-R` option writes standby connection settings (including `standby.signal`) into the destination. Configure a distinct port and other required settings if running both servers on the same host, then start the standby using the correct service/configuration for that installation.

## Step 5 — Monitor replication health

On the primary:

```sql
SELECT application_name,
       client_addr,
       state,
       sync_state,
       sent_lsn,
       write_lsn,
       flush_lsn,
       replay_lsn,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```

A row should appear when the standby connects. `lag_bytes` is an LSN distance, not a direct time measurement; it may be NULL when LSN values are NULL. Check the standby with:

```sql
SELECT pg_is_in_recovery();
SELECT now(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
```

On the standby, `pg_is_in_recovery()` should return true while it is operating as a standby.

## Troubleshooting checklist
- **Backup connection fails:** check database name, role permissions, host/port, and `pg_hba.conf`.
- **Archive directory stays empty:** inspect `pg_stat_archiver`, server logs, path spelling, and OS permissions.
- **PITR cannot find WAL:** confirm the base backup predates the target and every required WAL segment is archived and readable.
- **Recovery goes past the target:** stop and review the target timestamp/timezone and recovery configuration before trying again.
- **Standby does not connect:** check the primary is listening, replication role credentials, `pg_hba.conf`, firewall, and standby logs.

## Deliverables
- [ ] Logical dump created and restore test completed.
- [ ] WAL archiving configured and checked.
- [ ] Physical base backup completed.
- [ ] PITR tested on disposable data and row counts verified.
- [ ] Streaming standby connected and replication status checked.

## Safety
Never commit database dumps, real credentials, private keys, or production data to GitHub. This repository should contain scripts and documentation only, not generated backup files.
