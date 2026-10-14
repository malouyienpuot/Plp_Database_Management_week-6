-- Run on the PRIMARY as a PostgreSQL administrator.
-- Replace the placeholder with a strong secret; do not commit real credentials.
CREATE ROLE replicator
  WITH LOGIN REPLICATION
  PASSWORD 'replace-with-a-strong-password';

-- After the standby connects, inspect primary-side replication state:
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
