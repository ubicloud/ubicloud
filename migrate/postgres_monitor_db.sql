CREATE UNLOGGED TABLE public.postgres_lsn_monitor (
    postgres_server_id uuid NOT NULL,
    last_known_lsn pg_lsn
);

ALTER TABLE ONLY public.postgres_lsn_monitor
    ADD CONSTRAINT postgres_lsn_monitor_pkey PRIMARY KEY (postgres_server_id);

CREATE UNLOGGED TABLE public.postgres_disk_usage_monitor (
    postgres_server_id uuid NOT NULL,
    data_disk_usage_percent smallint,
    observed_at timestamp with time zone
);

ALTER TABLE ONLY public.postgres_disk_usage_monitor
    ADD CONSTRAINT postgres_disk_usage_monitor_pkey PRIMARY KEY (postgres_server_id);
