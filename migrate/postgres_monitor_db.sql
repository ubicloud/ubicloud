CREATE UNLOGGED TABLE public.postgres_lsn_monitor (
    postgres_server_id uuid NOT NULL,
    last_known_lsn pg_lsn
);

ALTER TABLE ONLY public.postgres_lsn_monitor
    ADD CONSTRAINT postgres_lsn_monitor_pkey PRIMARY KEY (postgres_server_id);
