  /**
    * Lock down the privileges of the pgbouncer role.
    */
  REVOKE ALL PRIVILEGES ON SCHEMA public FROM pgbouncer;

  /**
    * Create the pgbouncer schema if it does not exist. All of the
    * administrative functions for pgbouncer will live in its own schema.
    */
  CREATE SCHEMA IF NOT EXISTS pgbouncer;

  /**
    * Lock down the privileges of the pgbouncer schema.
    */
  REVOKE ALL PRIVILEGES ON SCHEMA pgbouncer FROM pgbouncer;
  GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer;

  /**
    * The "get_auth" function is used by pgbouncer to authenticate users.
    * See: https://www.pgbouncer.org/config.html#auth_query
    */
  CREATE OR REPLACE FUNCTION pgbouncer.get_auth (
    INOUT p_user     name,
    OUT   p_password text
  ) RETURNS record
    LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS
  $$SELECT usename, passwd FROM pg_shadow WHERE usename = p_user$$;

  REVOKE ALL ON FUNCTION pgbouncer.get_auth(name) FROM PUBLIC, pgbouncer;
  GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(name) TO pgbouncer;
