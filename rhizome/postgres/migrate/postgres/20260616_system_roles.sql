  /**
    * Create system roles.
    */
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ubi_replication') THEN CREATE ROLE ubi_replication WITH REPLICATION LOGIN; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ubi_monitoring') THEN CREATE ROLE ubi_monitoring WITH LOGIN IN ROLE pg_monitor; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgbouncer') THEN CREATE ROLE pgbouncer LOGIN; END IF; END $$;
