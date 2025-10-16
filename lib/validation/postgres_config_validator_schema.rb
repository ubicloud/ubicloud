# frozen_string_literal: true

module Validation
  class PostgresConfigValidatorSchema
    PG_16_CONFIG_SCHEMA = {
      "DateStyle" => {
        description: "Sets the display format for date and time values.",
        type: :string,
        default: "ISO, MDY"
      },
      "IntervalStyle" => {
        description: "Sets the display format for interval values.",
        type: :enum,
        allowed_values: ["postgres", "postgres_verbose", "sql_standard", "iso_8601"],
        default: "postgres"
      },
      "TimeZone" => {
        description: "Sets the time zone for displaying and interpreting time stamps.",
        type: :string,
        default: "UTC"
      },
      "allow_in_place_tablespaces" => {
        description: "Allows tablespaces directly inside pg_tblspc, for testing.",
        type: :bool,
        default: "off"
      },
      "allow_system_table_mods" => {
        description: "Allows modifications of the structure of system tables.",
        type: :bool,
        default: "off"
      },
      "application_name" => {
        description: "Sets the application name for the session.",
        type: :string,
        default: ""
      },
      "archive_cleanup_command" => {
        description: "Sets the shell command that will be executed at every restart point.",
        type: :string
      },
      "archive_command" => {
        description: "Sets the shell command that will be called to archive a WAL file.",
        type: :string,
        default: "/usr/bin/wal-g wal-push %p --config /etc/postgresql/wal-g.env"
      },
      "archive_library" => {
        description: "Sets the library that will be called to archive a WAL file.",
        type: :string
      },
      "archive_mode" => {
        description: 'Allows archiving of WAL files using "archive_command".',
        type: :enum,
        allowed_values: ["always", "on", "off"],
        default: "on"
      },
      "archive_timeout" => {
        description: "Sets the amount of time to wait before forcing a switch to the next WAL file.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "1min"
      },
      "array_nulls" => {
        description: "Enable input of NULL elements in arrays.",
        type: :bool,
        default: "on"
      },
      "authentication_timeout" => {
        description: "Sets the maximum allowed time to complete client authentication.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "1min"
      },
      "autovacuum" => {
        description: "Starts the autovacuum subprocess.",
        type: :bool,
        default: "on"
      },
      "autovacuum_analyze_scale_factor" => {
        description: "Number of tuple inserts, updates, or deletes prior to analyze as a fraction of reltuples.",
        type: :float,
        default: 0.1,
        min: 0.0,
        max: 100.0
      },
      "autovacuum_analyze_threshold" => {
        description: "Minimum number of tuple inserts, updates, or deletes prior to analyze.",
        type: :integer,
        default: 50,
        min: 0,
        max: 2147483647
      },
      "autovacuum_freeze_max_age" => {
        description: "Age at which to autovacuum a table to prevent transaction ID wraparound.",
        type: :integer,
        default: 200000000,
        min: 100000,
        max: 2000000000
      },
      "autovacuum_max_workers" => {
        description: "Sets the maximum number of simultaneously running autovacuum worker processes.",
        type: :integer,
        default: 3,
        min: 1,
        max: 262143
      },
      "autovacuum_multixact_freeze_max_age" => {
        description: "Multixact age at which to autovacuum a table to prevent multixact wraparound.",
        type: :integer,
        default: 400000000,
        min: 10000,
        max: 2000000000
      },
      "autovacuum_naptime" => {
        description: "Time to sleep between autovacuum runs.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "1min"
      },
      "autovacuum_vacuum_cost_delay" => {
        description: "Vacuum cost delay in milliseconds, for autovacuum.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "2ms"
      },
      "autovacuum_vacuum_cost_limit" => {
        description: "Vacuum cost amount available before napping, for autovacuum.",
        type: :string,
        default: "-1"
      },
      "autovacuum_vacuum_insert_scale_factor" => {
        description: "Number of tuple inserts prior to vacuum as a fraction of reltuples.",
        type: :float,
        default: 0.2,
        min: 0,
        max: 100
      },
      "autovacuum_vacuum_insert_threshold" => {
        description: "Minimum number of tuple inserts prior to vacuum, or -1 to disable insert vacuums.",
        type: :integer,
        default: 1000,
        min: -1,
        max: 2147483647
      },
      "autovacuum_vacuum_scale_factor" => {
        description: "Number of tuple updates or deletes prior to vacuum as a fraction of reltuples.",
        type: :float,
        default: 0.2,
        min: 0,
        max: 100
      },
      "autovacuum_vacuum_threshold" => {
        description: "Minimum number of tuple updates or deletes prior to vacuum.",
        type: :integer,
        default: 50,
        min: 0,
        max: 2147483647
      },
      "autovacuum_work_mem" => {
        description: "Sets the maximum memory to be used by each autovacuum worker process.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "-1"
      },
      "backend_flush_after" => {
        description: "Number of pages after which previously performed writes are flushed to disk.",
        type: :integer,
        default: 0,
        min: 0,
        max: 256
      },
      "backslash_quote" => {
        description: 'Sets whether "\'" is allowed in string literals.',
        type: :enum,
        allowed_values: ["on", "off", "safe_encoding"],
        default: "safe_encoding"
      },
      "backtrace_functions" => {
        description: "Log backtrace for errors in these functions.",
        type: :string
      },
      "bgwriter_delay" => {
        description: "Background writer sleep time between rounds.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "200ms"
      },
      "bgwriter_flush_after" => {
        description: "Number of pages after which previously performed writes are flushed to disk.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "512kB"
      },
      "bgwriter_lru_maxpages" => {
        description: "Background writer maximum number of LRU pages to flush per round.",
        type: :integer,
        default: 100,
        min: 0,
        max: 1073741823
      },
      "bgwriter_lru_multiplier" => {
        description: "Multiple of the average buffer usage to free per round.",
        type: :integer,
        default: 2,
        min: 0,
        max: 10
      },
      "bonjour" => {
        description: "Enables advertising the server via Bonjour.",
        type: :bool,
        default: "off"
      },
      "bonjour_name" => {
        description: "Sets the Bonjour service name.",
        type: :string
      },
      "bytea_output" => {
        description: "Sets the output format for bytea.",
        type: :enum,
        allowed_values: ["hex", "escape"],
        default: "hex"
      },
      "check_function_bodies" => {
        description: "Check routine bodies during CREATE FUNCTION and CREATE PROCEDURE.",
        type: :bool,
        default: "on"
      },
      "checkpoint_completion_target" => {
        description: "Time spent flushing dirty buffers during checkpoint, as fraction of checkpoint interval.",
        type: :float,
        default: 0.9,
        min: 0.0,
        max: 1.0
      },
      "checkpoint_flush_after" => {
        description: "Number of pages after which previously performed writes are flushed to disk.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "256kB"
      },
      "checkpoint_timeout" => {
        description: "Sets the maximum time between automatic WAL checkpoints.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "5min"
      },
      "checkpoint_warning" => {
        description: "Sets the maximum time before warning if checkpoints triggered by WAL volume happen too frequently.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "30s"
      },
      "client_connection_check_interval" => {
        description: "Sets the time interval between checks for disconnection while running queries.",
        type: :integer,
        min: 0,
        max: 2147483647,
        default: 0
      },
      "client_encoding" => {
        description: "Sets the client's character set encoding.",
        type: :string,
        default: "UTF8"
      },
      "client_min_messages" => {
        description: "Sets the message levels that are sent to the client.",
        type: :enum,
        allowed_values: ["debug5", "debug4", "debug3", "debug2", "debug1", "log", "notice", "warning", "error"],
        default: "notice"
      },
      "commit_delay" => {
        description: "Sets the delay in microseconds between transaction commit and flushing WAL to disk.",
        type: :integer,
        min: 0,
        max: 100000,
        default: 0
      },
      "commit_siblings" => {
        description: 'Sets the minimum number of concurrent open transactions required before performing "commit_delay".',
        type: :integer,
        min: 0,
        max: 1000,
        default: 5
      },
      "compute_query_id" => {
        description: "Enables in-core computation of query identifiers.",
        type: :enum,
        allowed_values: ["auto", "regress", "on", "off"],
        default: "auto"
      },
      "constraint_exclusion" => {
        description: "Enables the planner to use constraints to optimize queries.",
        type: :enum,
        allowed_values: ["partition", "on", "off"],
        default: "partition"
      },
      "cpu_index_tuple_cost" => {
        description: "Sets the planner's estimate of the cost of processing each index entry during an index scan.",
        type: :float,
        default: 0.005,
        min: 0,
        max: 1.79769e+308
      },
      "cpu_operator_cost" => {
        description: "Sets the planner's estimate of the cost of processing each operator or function call.",
        type: :float,
        default: 0.0025,
        min: 0,
        max: 1.79769e+308
      },
      "cpu_tuple_cost" => {
        description: "Sets the planner's estimate of the cost of processing each tuple (row).",
        type: :float,
        default: 0.01,
        min: 0,
        max: 1.79769e+308
      },
      "createrole_self_grant" => {
        description: "Sets whether a CREATEROLE user automatically grants the role to themselves, and with which options.",
        type: :string
      },
      "cron.database_name" => {
        description: "Database in which pg_cron metadata is kept.",
        type: :string,
        default: "postgres"
      },
      "cron.enable_superuser_jobs" => {
        description: "Allow jobs to be scheduled as superuser",
        type: :enum,
        allowed_values: ["on", "off"],
        default: "on"
      },
      "cron.host" => {
        description: "Hostname to connect to postgres.",
        type: :string,
        default: "localhost"
      },
      "cron.launch_active_jobs" => {
        description: "Launch jobs that are defined as active.",
        type: :enum,
        allowed_values: ["on", "off"],
        default: "on"
      },
      "cron.log_min_messages" => {
        description: "log_min_messages for the launcher bgworker.",
        type: :string,
        default: "warning"
      },
      "cron.log_run" => {
        description: "Log all jobs runs into the job_run_details table",
        type: :enum,
        allowed_values: ["on", "off"],
        default: "on"
      },
      "cron.log_statement" => {
        description: "Log all cron statements prior to execution.",
        type: :enum,
        allowed_values: ["on", "off"],
        default: "on"
      },
      "cron.max_running_jobs" => {
        description: "Maximum number of jobs that can run concurrently.",
        type: :integer,
        default: 32,
        min: 1,
        max: 32
      },
      "cron.timezone" => {
        description: "Specify timezone used for cron schedule.",
        type: :string,
        default: "GMT"
      },
      "cron.use_background_workers" => {
        description: "Use background workers instead of client sessions.",
        type: :enum,
        allowed_values: ["on", "off"],
        default: "off"
      },
      "cursor_tuple_fraction" => {
        description: "Sets the planner's estimate of the fraction of a cursor's rows that will be retrieved.",
        type: :float,
        default: 0.1,
        min: 0,
        max: 1
      },
      "data_sync_retry" => {
        description: "Whether to continue running after a failure to sync data files.",
        type: :bool,
        default: "off"
      },
      "db_user_namespace" => {
        description: "Enables per-database user names.",
        type: :bool,
        default: "off"
      },
      "deadlock_timeout" => {
        description: "Sets the time to wait on a lock before checking for deadlock.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "1s"
      },
      "debug_discard_caches" => {
        description: "Aggressively flush system caches for debugging purposes.",
        type: :integer,
        min: 0,
        max: 0,
        default: 0
      },
      "debug_io_direct" => {
        description: "Use direct I/O for file access.",
        type: :string
      },
      "debug_logical_replication_streaming" => {
        description: "Forces immediate streaming or serialization of changes in large transactions.",
        type: :enum,
        allowed_values: ["buffered", "immediate"],
        default: "buffered"
      },
      "debug_parallel_query" => {
        description: "Forces the planner's use parallel query nodes.",
        type: :enum,
        allowed_values: ["on", "off", "regress"],
        default: "off"
      },
      "debug_pretty_print" => {
        description: "Indents parse and plan tree displays.",
        type: :bool,
        default: "on"
      },
      "debug_print_parse" => {
        description: "Logs each query's parse tree.",
        type: :bool,
        default: "off"
      },
      "debug_print_plan" => {
        description: "Logs each query's execution plan.",
        type: :bool,
        default: "off"
      },
      "debug_print_rewritten" => {
        description: "Logs each query's rewritten parse tree.",
        type: :bool,
        default: "off"
      },
      "default_statistics_target" => {
        description: "Sets the default statistics target.",
        type: :integer,
        min: 1,
        max: 10000,
        default: 100
      },
      "default_table_access_method" => {
        description: "Sets the default table access method for new tables.",
        type: :string,
        default: "heap"
      },
      "default_tablespace" => {
        description: "Sets the default tablespace to create tables and indexes in.",
        type: :string
      },
      "default_text_search_config" => {
        description: "Sets default text search configuration.",
        type: :string,
        default: "pg_catalog.english"
      },
      "default_toast_compression" => {
        description: "Sets the default compression method for compressible values.",
        type: :enum,
        allowed_values: ["pglz", "lz4"],
        default: "pglz"
      },
      "default_transaction_deferrable" => {
        description: "Sets the default deferrable status of new transactions.",
        type: :bool,
        default: "off"
      },
      "default_transaction_isolation" => {
        description: "Sets the transaction isolation level of each new transaction.",
        type: :enum,
        allowed_values: ["read uncommitted", "read committed", "repeatable read", "serializable"],
        default: "read committed"
      },
      "default_transaction_read_only" => {
        description: "Sets the default read-only status of new transactions.",
        type: :bool,
        default: "off"
      },
      "dynamic_library_path" => {
        description: "Sets the path for dynamically loadable modules.",
        type: :string,
        default: "$libdir"
      },
      "dynamic_shared_memory_type" => {
        description: "Selects the dynamic shared memory implementation used.",
        type: :enum,
        allowed_values: ["posix", "sysv", "mmap"],
        default: "posix"
      },
      "effective_cache_size" => {
        description: "Sets the planner's assumption about the total size of the data caches.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "(75% of total memory)"
      },
      "effective_io_concurrency" => {
        description: "Number of simultaneous requests that can be handled efficiently by the disk subsystem.",
        type: :integer,
        min: 0,
        max: 1000,
        default: 200
      },
      "enable_async_append" => {
        description: "Enables the planner's use of async append plans.",
        type: :bool,
        default: "on"
      },
      "enable_bitmapscan" => {
        description: "Enables the planner's use of bitmap-scan plans.",
        type: :bool,
        default: "on"
      },
      "enable_gathermerge" => {
        description: "Enables the planner's use of gather merge plans.",
        type: :bool,
        default: "on"
      },
      "enable_hashagg" => {
        description: "Enables the planner's use of hashed aggregation plans.",
        type: :bool,
        default: "on"
      },
      "enable_hashjoin" => {
        description: "Enables the planner's use of hash join plans.",
        type: :bool,
        default: "on"
      },
      "enable_incremental_sort" => {
        description: "Enables the planner's use of incremental sort steps.",
        type: :bool,
        default: "on"
      },
      "enable_indexonlyscan" => {
        description: "Enables the planner's use of index-only-scan plans.",
        type: :bool,
        default: "on"
      },
      "enable_indexscan" => {
        description: "Enables the planner's use of index-scan plans.",
        type: :bool,
        default: "on"
      },
      "enable_material" => {
        description: "Enables the planner's use of materialization.",
        type: :bool,
        default: "on"
      },
      "enable_memoize" => {
        description: "Enables the planner's use of memoization.",
        type: :bool,
        default: "on"
      },
      "enable_mergejoin" => {
        description: "Enables the planner's use of merge join plans.",
        type: :bool,
        default: "on"
      },
      "enable_nestloop" => {
        description: "Enables the planner's use of nested-loop join plans.",
        type: :bool,
        default: "on"
      },
      "enable_parallel_append" => {
        description: "Enables the planner's use of parallel append plans.",
        type: :bool,
        default: "on"
      },
      "enable_parallel_hash" => {
        description: "Enables the planner's use of parallel hash plans.",
        type: :bool,
        default: "on"
      },
      "enable_partition_pruning" => {
        description: "Enables plan-time and execution-time partition pruning.",
        type: :bool,
        default: "on"
      },
      "enable_partitionwise_aggregate" => {
        description: "Enables partitionwise aggregation and grouping.",
        type: :bool,
        default: "off"
      },
      "enable_partitionwise_join" => {
        description: "Enables partitionwise join.",
        type: :bool,
        default: "off"
      },
      "enable_presorted_aggregate" => {
        description: "Enables the planner's ability to produce plans that provide presorted input for ORDER BY / DISTINCT aggregate functions.",
        type: :bool,
        default: "on"
      },
      "enable_seqscan" => {
        description: "Enables the planner's use of sequential-scan plans.",
        type: :bool,
        default: "on"
      },
      "enable_sort" => {
        description: "Enables the planner's use of explicit sort steps.",
        type: :bool,
        default: "on"
      },
      "enable_tidscan" => {
        description: "Enables the planner's use of TID scan plans.",
        type: :bool,
        default: "on"
      },
      "escape_string_warning" => {
        description: "Warn about backslash escapes in ordinary string literals.",
        type: :bool,
        default: "on"
      },
      "event_source" => {
        description: "Sets the application name used to identify PostgreSQL messages in the event log.",
        type: :string,
        default: "PostgreSQL"
      },
      "exit_on_error" => {
        description: "Terminate session on any error.",
        type: :bool,
        default: "off"
      },
      "extension_destdir" => {
        description: "Path to prepend for extension loading.",
        type: :string
      },
      "extra_float_digits" => {
        description: "Sets the number of digits displayed for floating-point values.",
        type: :integer,
        min: -15,
        max: 3,
        default: 1
      },
      "from_collapse_limit" => {
        description: "Sets the FROM-list size beyond which subqueries are not collapsed.",
        type: :string,
        default: "8"
      },
      "fsync" => {
        description: "Forces synchronization of updates to disk.",
        type: :bool,
        default: "on"
      },
      "full_page_writes" => {
        description: "Writes full pages to WAL when first modified after a checkpoint.",
        type: :bool,
        default: "on"
      },
      "geqo" => {
        description: "Enables genetic query optimization.",
        type: :bool,
        default: "on"
      },
      "geqo_effort" => {
        description: "GEQO: effort is used to set the default for other GEQO parameters.",
        type: :integer,
        min: 1,
        max: 10,
        default: 5
      },
      "geqo_generations" => {
        description: "GEQO: number of iterations of the algorithm.",
        type: :integer,
        min: 0,
        max: 2147483647,
        default: 0
      },
      "geqo_pool_size" => {
        description: "GEQO: number of individuals in the population.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "0"
      },
      "geqo_seed" => {
        description: "GEQO: seed for random path selection.",
        type: :integer,
        min: 0,
        max: 1,
        default: 0
      },
      "geqo_selection_bias" => {
        description: "GEQO: selective pressure within the population.",
        type: :integer,
        min: 1,
        max: 2,
        default: 2
      },
      "geqo_threshold" => {
        description: "Sets the threshold of FROM items beyond which GEQO is used.",
        type: :integer,
        min: 2,
        max: 2147483647,
        default: 12
      },
      "gin_fuzzy_search_limit" => {
        description: "Sets the maximum allowed result for exact search by GIN.",
        type: :string,
        default: "0"
      },
      "gin_pending_list_limit" => {
        description: "Sets the maximum size of the pending list for GIN index.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "4MB"
      },
      "gss_accept_delegation" => {
        description: "Sets whether GSSAPI delegation should be accepted from the client.",
        type: :bool,
        default: "off"
      },
      "hash_mem_multiplier" => {
        description: 'Multiple of "work_mem" to use for hash tables.',
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "2"
      },
      "hot_standby" => {
        description: "Allows connections and queries during recovery.",
        type: :bool,
        default: "on"
      },
      "hot_standby_feedback" => {
        description: "Allows feedback from a hot standby to the primary that will avoid query conflicts.",
        type: :bool,
        default: "off"
      },
      "huge_page_size" => {
        description: "The size of huge page that should be requested.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "0"
      },
      "huge_pages" => {
        description: "Use of huge pages on Linux or Windows.",
        type: :enum,
        allowed_values: ["try", "on", "off"],
        default: "on"
      },
      "icu_validation_level" => {
        description: "Log level for reporting invalid ICU locale strings.",
        type: :enum,
        allowed_values: ["disabled", "debug5", "debug4", "debug3", "debug2", "debug1", "log", "notice", "warning", "error"],
        default: "warning"
      },
      "idle_in_transaction_session_timeout" => {
        description: "Sets the maximum allowed idle time between queries, when in a transaction.",
        type: :integer,
        min: 0,
        max: 2147483647,
        default: 0
      },
      "idle_session_timeout" => {
        description: "Sets the maximum allowed idle time between queries, when not in a transaction.",
        type: :integer,
        min: 0,
        max: 2147483647,
        default: 0
      },
      "ignore_checksum_failure" => {
        description: "Continues processing after a checksum failure.",
        type: :bool,
        default: "off"
      },
      "ignore_invalid_pages" => {
        description: "Continues recovery after an invalid pages failure.",
        type: :bool,
        default: "off"
      },
      "ignore_system_indexes" => {
        description: "Disables reading from system indexes.",
        type: :bool,
        default: "off"
      },
      "jit" => {
        description: "Allow JIT compilation.",
        type: :bool,
        default: "on"
      },
      "jit_above_cost" => {
        description: "Perform JIT compilation if query is more expensive.",
        type: :integer,
        min: -1,
        max: 1,
        default: 100000
      },
      "jit_debugging_support" => {
        description: "Register JIT-compiled functions with debugger.",
        type: :bool,
        default: "off"
      },
      "jit_dump_bitcode" => {
        description: "Write out LLVM bitcode to facilitate JIT debugging.",
        type: :bool,
        default: "off"
      },
      "jit_expressions" => {
        description: "Allow JIT compilation of expressions.",
        type: :bool,
        default: "on"
      },
      "jit_inline_above_cost" => {
        description: "Perform JIT inlining if query is more expensive.",
        type: :integer,
        min: -1,
        max: 1,
        default: 500000
      },
      "jit_optimize_above_cost" => {
        description: "Optimize JIT-compiled functions if query is more expensive.",
        type: :integer,
        min: -1,
        max: 1,
        default: 500000
      },
      "jit_profiling_support" => {
        description: "Register JIT-compiled functions with perf profiler.",
        type: :bool,
        default: "off"
      },
      "jit_provider" => {
        description: "JIT provider to use.",
        type: :string,
        default: "llvmjit"
      },
      "jit_tuple_deforming" => {
        description: "Allow JIT compilation of tuple deforming.",
        type: :bool,
        default: "on"
      },
      "join_collapse_limit" => {
        description: "Sets the FROM-list size beyond which JOIN constructs are not flattened.",
        type: :string,
        default: "8"
      },
      "krb_caseins_users" => {
        description: "Sets whether Kerberos and GSSAPI user names should be treated as case-insensitive.",
        type: :bool,
        default: "off"
      },
      "krb_server_keyfile" => {
        description: "Sets the location of the Kerberos server key file.",
        type: :string,
        default: "FILE:/etc/postgresql-common/krb5.keytab"
      },
      "lc_messages" => {
        description: "Sets the language in which messages are displayed.",
        type: :string,
        default: "C.UTF-8"
      },
      "lc_monetary" => {
        description: "Sets the locale for formatting monetary amounts.",
        type: :string,
        default: "C.UTF-8"
      },
      "lc_numeric" => {
        description: "Sets the locale for formatting numbers.",
        type: :string,
        default: "C.UTF-8"
      },
      "lc_time" => {
        description: "Sets the locale for formatting date and time values.",
        type: :string,
        default: "C.UTF-8"
      },
      "listen_addresses" => {
        description: "Sets the host name or IP address(es) to listen to.",
        type: :string,
        default: "*"
      },
      "lo_compat_privileges" => {
        description: "Enables backward compatibility mode for privilege checks on large objects.",
        type: :bool,
        default: "off"
      },
      "local_preload_libraries" => {
        description: "Lists unprivileged shared libraries to preload into each backend.",
        type: :string
      },
      "lock_timeout" => {
        description: "Sets the maximum allowed duration of any wait for a lock.",
        type: :integer,
        min: 0,
        max: 2147483647,
        default: 0
      },
      "log_autovacuum_min_duration" => {
        description: "Sets the minimum execution time above which autovacuum actions will be logged.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "10min"
      },
      "log_checkpoints" => {
        description: "Logs each checkpoint.",
        type: :bool,
        default: "on"
      },
      "log_connections" => {
        description: "Logs each successful connection.",
        type: :bool,
        default: "off"
      },
      "log_destination" => {
        description: "Sets the destination for server log output.",
        type: :string,
        default: "stderr"
      },
      "log_directory" => {
        description: "Sets the destination directory for log files.",
        type: :string,
        default: "pg_log"
      },
      "log_disconnections" => {
        description: "Logs end of a session, including duration.",
        type: :bool,
        default: "off"
      },
      "log_duration" => {
        description: "Logs the duration of each completed SQL statement.",
        type: :bool,
        default: "off"
      },
      "log_error_verbosity" => {
        description: "Sets the verbosity of logged messages.",
        type: :enum,
        allowed_values: ["default", "verbose", "terse"],
        default: "default"
      },
      "log_executor_stats" => {
        description: "Writes executor performance statistics to the server log.",
        type: :bool,
        default: "off"
      },
      "log_file_mode" => {
        description: "Sets the file permissions for log files.",
        type: :integer,
        min: 0,
        max: 511,
        default: 600
      },
      "log_filename" => {
        description: "Sets the file name pattern for log files.",
        type: :string,
        default: "postgresql.log"
      },
      "log_hostname" => {
        description: "Logs the host name in the connection logs.",
        type: :bool,
        default: "off"
      },
      "log_line_prefix" => {
        description: "Controls information prefixed to each log line.",
        type: :string,
        default: "%m [%p] %q%u@%d "
      },
      "log_lock_waits" => {
        description: "Logs long lock waits.",
        type: :bool,
        default: "off"
      },
      "log_min_duration_sample" => {
        description: "Sets the minimum execution time above which a sample of statements will be logged. Sampling is determined by log_statement_sample_rate.",
        type: :integer,
        max: 2147483647,
        min: -1,
        default: -1
      },
      "log_min_duration_statement" => {
        description: "Sets the minimum execution time above which all statements will be logged.",
        type: :integer,
        max: 2147483647,
        min: -1,
        default: -1
      },
      "log_min_error_statement" => {
        description: "Causes all statements generating error at or above this level to be logged.",
        type: :enum,
        allowed_values: ["debug5", "debug4", "debug3", "debug2", "debug1", "info", "notice", "warning", "error", "log", "fatal", "panic"],
        default: "error"
      },
      "log_min_messages" => {
        description: "Sets the message levels that are logged.",
        type: :enum,
        allowed_values: ["debug5", "debug4", "debug3", "debug2", "debug1", "info", "notice", "warning", "error", "log", "fatal", "panic"],
        default: "warning"
      },
      "log_parameter_max_length" => {
        description: "Sets the maximum length in bytes of data logged for bind parameter values when logging statements.",
        type: :integer,
        max: 1073741823,
        min: -1,
        default: -1
      },
      "log_parameter_max_length_on_error" => {
        description: "Sets the maximum length in bytes of data logged for bind parameter values when logging statements, on error.",
        type: :integer,
        min: -1,
        max: 1073741823,
        default: 0
      },
      "log_parser_stats" => {
        description: "Writes parser performance statistics to the server log.",
        type: :bool,
        default: "off"
      },
      "log_planner_stats" => {
        description: "Writes planner performance statistics to the server log.",
        type: :bool,
        default: "off"
      },
      "log_recovery_conflict_waits" => {
        description: "Logs standby recovery conflict waits.",
        type: :bool,
        default: "off"
      },
      "log_replication_commands" => {
        description: "Logs each replication command.",
        type: :bool,
        default: "off"
      },
      "log_rotation_age" => {
        description: "Sets the amount of time to wait before forcing log file rotation.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "1d"
      },
      "log_rotation_size" => {
        description: "Sets the maximum size a log file can reach before being rotated.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "10MB"
      },
      "log_startup_progress_interval" => {
        description: "Time between progress updates for long-running startup operations.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "10s"
      },
      "log_statement" => {
        description: "Sets the type of statements logged.",
        type: :enum,
        allowed_values: ["none", "ddl", "mod", "all"],
        default: "none"
      },
      "log_statement_sample_rate" => {
        description: 'Fraction of statements exceeding "log_min_duration_sample" to be logged.',
        type: :integer,
        min: 0,
        max: 1,
        default: 1
      },
      "log_statement_stats" => {
        description: "Writes cumulative performance statistics to the server log.",
        type: :bool,
        default: "off"
      },
      "log_temp_files" => {
        description: "Log the use of temporary files larger than this number of kilobytes.",
        type: :integer,
        max: 2147483647,
        min: -1,
        default: -1
      },
      "log_timezone" => {
        description: "Sets the time zone to use in log messages.",
        type: :string,
        default: "UTC"
      },
      "log_transaction_sample_rate" => {
        description: "Sets the fraction of transactions from which to log all statements.",
        type: :integer,
        min: 0,
        max: 1,
        default: 0
      },
      "log_truncate_on_rotation" => {
        description: "Truncate existing log files of same name during log rotation.",
        type: :bool,
        default: "on"
      },
      "logging_collector" => {
        description: "Start a subprocess to capture stderr output and/or csvlogs into log files.",
        type: :bool,
        default: "on"
      },
      "logical_decoding_work_mem" => {
        description: "Sets the maximum memory to be used for logical decoding.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "64MB"
      },
      "maintenance_io_concurrency" => {
        description: 'A variant of "effective_io_concurrency" that is used for maintenance work.',
        type: :integer,
        min: 0,
        max: 1000,
        default: 10
      },
      "maintenance_work_mem" => {
        description: "Sets the maximum memory to be used for maintenance operations.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "(8.25% of total memory)"
      },
      "max_connections" => {
        description: "Sets the maximum number of concurrent connections.",
        type: :integer,
        default: 500,
        min: 1,
        max: 10000
      },
      "max_files_per_process" => {
        description: "Sets the maximum number of simultaneously open files for each server process.",
        type: :integer,
        min: 64,
        max: 2147483647,
        default: 1000
      },
      "max_locks_per_transaction" => {
        description: "Sets the maximum number of locks per transaction.",
        type: :integer,
        min: 10,
        max: 2147483647,
        default: 64
      },
      "max_logical_replication_workers" => {
        description: "Maximum number of logical replication worker processes.",
        type: :integer,
        min: 0,
        max: 262143,
        default: 4
      },
      "max_parallel_apply_workers_per_subscription" => {
        description: "Maximum number of parallel apply workers per subscription.",
        type: :integer,
        min: 0,
        max: 1024,
        default: 2
      },
      "max_parallel_maintenance_workers" => {
        description: "Sets the maximum number of parallel processes per maintenance operation.",
        type: :integer,
        min: 0,
        max: 1024,
        default: 2
      },
      "max_parallel_workers" => {
        description: "Sets the maximum number of parallel workers that can be active at one time.",
        type: :integer,
        min: 0,
        max: 1024,
        default: 4
      },
      "max_parallel_workers_per_gather" => {
        description: "Sets the maximum number of parallel processes per executor node.",
        type: :integer,
        min: 0,
        max: 1024,
        default: 2
      },
      "max_pred_locks_per_page" => {
        description: "Sets the maximum number of predicate-locked tuples per page.",
        type: :integer,
        min: 0,
        max: 2147483647,
        default: 2
      },
      "max_pred_locks_per_relation" => {
        description: "Sets the maximum number of predicate-locked pages and tuples per relation.",
        type: :integer,
        max: 2147483647,
        min: -2147483648,
        default: -2
      },
      "max_pred_locks_per_transaction" => {
        description: "Sets the maximum number of predicate locks per transaction.",
        type: :integer,
        min: 10,
        max: 2147483647,
        default: 64
      },
      "max_prepared_transactions" => {
        description: "Sets the maximum number of simultaneously prepared transactions.",
        type: :integer,
        min: 0,
        max: 262143,
        default: 0
      },
      "max_replication_slots" => {
        description: "Sets the maximum number of simultaneously defined replication slots.",
        type: :integer,
        min: 0,
        max: 262143,
        default: 10
      },
      "max_slot_wal_keep_size" => {
        description: "Sets the maximum WAL size that can be reserved by replication slots.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "-1"
      },
      "max_stack_depth" => {
        description: "Sets the maximum stack depth, in kilobytes.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "2MB"
      },
      "max_standby_archive_delay" => {
        description: "Sets the maximum delay before canceling queries when a hot standby server is processing archived WAL data.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "30s"
      },
      "max_standby_streaming_delay" => {
        description: "Sets the maximum delay before canceling queries when a hot standby server is processing streamed WAL data.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "30s"
      },
      "max_sync_workers_per_subscription" => {
        description: "Maximum number of table synchronization workers per subscription.",
        type: :integer,
        min: 0,
        max: 262143,
        default: 2
      },
      "max_wal_senders" => {
        description: "Sets the maximum number of simultaneously running WAL sender processes.",
        type: :integer,
        min: 0,
        max: 262143,
        default: 10
      },
      "max_wal_size" => {
        description: "Sets the WAL size that triggers a checkpoint.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "5GB"
      },
      "max_worker_processes" => {
        description: "Maximum number of concurrent worker processes.",
        type: :integer,
        min: 0,
        max: 262143,
        default: 8
      },
      "min_dynamic_shared_memory" => {
        description: "Amount of dynamic shared memory reserved at startup.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "0"
      },
      "min_parallel_index_scan_size" => {
        description: "Sets the minimum amount of index data for a parallel scan.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "512kB"
      },
      "min_parallel_table_scan_size" => {
        description: "Sets the minimum amount of table data for a parallel scan.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "8MB"
      },
      "min_wal_size" => {
        description: "Sets the minimum size to shrink the WAL to.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "80MB"
      },
      "old_snapshot_threshold" => {
        description: "Time before a snapshot is too old to read pages changed after the snapshot was taken.",
        type: :integer,
        max: 86400,
        min: -1,
        default: -1
      },
      "parallel_leader_participation" => {
        description: "Controls whether Gather and Gather Merge also run subplans.",
        type: :bool,
        default: "on"
      },
      "parallel_setup_cost" => {
        description: "Sets the planner's estimate of the cost of starting up worker processes for parallel query.",
        type: :float,
        default: 1000,
        min: 0,
        max: 1.79769e+308
      },
      "parallel_tuple_cost" => {
        description: "Sets the planner's estimate of the cost of passing each tuple (row) from worker to leader backend.",
        type: :float,
        default: 0.1,
        min: 0,
        max: 1.79769e+308
      },
      "password_encryption" => {
        description: "Chooses the algorithm for encrypting passwords.",
        type: :enum,
        allowed_values: ["md5", "scram-sha-256"],
        default: "scram-sha-256"
      },
      "pg_stat_statements.max" => {
        description: "Sets the maximum number of statements tracked by pg_stat_statements.",
        type: :integer,
        default: 5000,
        min: 100,
        max: 2147483647
      },
      "pg_stat_statements.save" => {
        description: "Save pg_stat_statements statistics across server shutdowns.",
        type: :enum,
        allowed_values: ["on", "off"],
        default: "on"
      },
      "pg_stat_statements.track" => {
        description: "Selects which statements are tracked by pg_stat_statements.",
        type: :string,
        default: "top"
      },
      "pg_stat_statements.track_planning" => {
        description: "Selects whether planning duration is tracked by pg_stat_statements.",
        type: :enum,
        allowed_values: ["on", "off"],
        default: "off"
      },
      "pg_stat_statements.track_utility" => {
        description: "Selects whether utility commands are tracked by pg_stat_statements.",
        type: :enum,
        allowed_values: ["on", "off"],
        default: "on"
      },
      "plan_cache_mode" => {
        description: "Controls the planner's selection of custom or generic plan.",
        type: :enum,
        allowed_values: ["auto", "force_generic_plan", "force_custom_plan"],
        default: "auto"
      },
      "port" => {
        description: "Sets the TCP port the server listens on.",
        type: :integer,
        min: 1,
        max: 65535,
        default: 5432
      },
      "post_auth_delay" => {
        description: "Sets the amount of time to wait after authentication on connection startup.",
        type: :integer,
        min: 0,
        max: 2147,
        default: 0
      },
      "pre_auth_delay" => {
        description: "Sets the amount of time to wait before authentication on connection startup.",
        type: :integer,
        min: 0,
        max: 60,
        default: 0
      },
      "primary_conninfo" => {
        description: "Sets the connection string to be used to connect to the sending server.",
        type: :string
      },
      "primary_slot_name" => {
        description: "Sets the name of the replication slot to use on the sending server.",
        type: :string
      },
      "quote_all_identifiers" => {
        description: "When generating SQL fragments, quote all identifiers.",
        type: :bool,
        default: "off"
      },
      "random_page_cost" => {
        description: "Sets the planner's estimate of the cost of a nonsequentially fetched disk page.",
        type: :float,
        default: 1.1,
        min: 0,
        max: 1.79769e+308
      },
      "recovery_end_command" => {
        description: "Sets the shell command that will be executed once at the end of recovery.",
        type: :string
      },
      "recovery_init_sync_method" => {
        description: "Sets the method for synchronizing the data directory before crash recovery.",
        type: :enum,
        default: "fsync",
        allowed_values: ["fsync", "syncfs"]
      },
      "recovery_min_apply_delay" => {
        description: "Sets the minimum delay for applying changes during recovery.",
        type: :integer,
        min: 0,
        max: 2147483647,
        default: 0
      },
      "recovery_prefetch" => {
        description: "Prefetch referenced blocks during recovery.",
        type: :enum,
        allowed_values: ["on", "off", "try"],
        default: "try"
      },
      "recovery_target" => {
        description: 'Set to "immediate" to end recovery as soon as a consistent state is reached.',
        type: :string
      },
      "recovery_target_action" => {
        description: "Sets the action to perform upon reaching the recovery target.",
        type: :enum,
        allowed_values: ["pause", "promote", "shutdown"],
        default: "pause"
      },
      "recovery_target_inclusive" => {
        description: "Sets whether to include or exclude transaction with recovery target.",
        type: :bool,
        default: "on"
      },
      "recovery_target_lsn" => {
        description: "Sets the LSN of the write-ahead log location up to which recovery will proceed.",
        type: :string
      },
      "recovery_target_name" => {
        description: "Sets the named restore point up to which recovery will proceed.",
        type: :string
      },
      "recovery_target_time" => {
        description: "Sets the time stamp up to which recovery will proceed.",
        type: :string
      },
      "recovery_target_timeline" => {
        description: "Specifies the timeline to recover into.",
        type: :string,
        default: "latest"
      },
      "recovery_target_xid" => {
        description: "Sets the transaction ID up to which recovery will proceed.",
        type: :string
      },
      "recursive_worktable_factor" => {
        description: "Sets the planner's estimate of the average size of a recursive query's working table.",
        type: :float,
        default: 10,
        min: 0.001,
        max: 1e6
      },
      "remove_temp_files_after_crash" => {
        description: "Remove temporary files after backend crash.",
        type: :bool,
        default: "on"
      },
      "reserved_connections" => {
        description: "Sets the number of connection slots reserved for roles with privileges of pg_use_reserved_connections.",
        type: :integer,
        min: 0,
        max: 262143,
        default: 0
      },
      "restart_after_crash" => {
        description: "Reinitialize server after backend crash.",
        type: :bool,
        default: "on"
      },
      "restore_command" => {
        description: "Sets the shell command that will be called to retrieve an archived WAL file.",
        type: :string
      },
      "restrict_nonsystem_relation_kind" => {
        description: "Prohibits access to non-system relations of specified kinds.",
        type: :string
      },
      "row_security" => {
        description: "Enable row security.",
        type: :bool,
        default: "on"
      },
      "scram_iterations" => {
        description: "Sets the iteration count for SCRAM secret generation.",
        type: :integer,
        min: 1,
        max: 2147483647,
        default: 4096
      },
      "search_path" => {
        description: "Sets the schema search order for names that are not schema-qualified.",
        type: :string,
        default: '"$user", public'
      },
      "send_abort_for_crash" => {
        description: "Send SIGABRT not SIGQUIT to child processes after backend crash.",
        type: :bool,
        default: "off"
      },
      "send_abort_for_kill" => {
        description: "Send SIGABRT not SIGKILL to stuck child processes.",
        type: :bool,
        default: "off"
      },
      "seq_page_cost" => {
        description: "Sets the planner's estimate of the cost of a sequentially fetched disk page.",
        type: :float,
        default: 1,
        min: 0,
        max: 1.79769e+308
      },
      "session_preload_libraries" => {
        description: "Lists shared libraries to preload into each backend.",
        type: :string
      },
      "session_replication_role" => {
        description: "Sets the session's behavior for triggers and rewrite rules.",
        type: :enum,
        allowed_values: ["origin", "replica", "local"],
        default: "origin"
      },
      "shared_buffers" => {
        description: "Sets the number of shared memory buffers used by the server.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "(25% of total memory)"
      },
      "shared_memory_type" => {
        description: "Selects the shared memory implementation used for the main shared memory region.",
        type: :enum,
        allowed_values: ["mmap", "sysv"],
        default: "mmap"
      },
      "shared_preload_libraries" => {
        description: "Lists shared libraries to preload into server.",
        type: :string,
        default: "pg_cron,pg_stat_statements"
      },
      "ssl" => {
        description: "Enables SSL connections.",
        type: :bool,
        default: "on"
      },
      "ssl_ca_file" => {
        description: "Location of the SSL certificate authority file.",
        type: :string,
        default: "/etc/ssl/certs/ca.crt"
      },
      "ssl_cert_file" => {
        description: "Location of the SSL server certificate file.",
        type: :string,
        default: "/etc/ssl/certs/server.crt"
      },
      "ssl_ciphers" => {
        description: "Sets the list of allowed SSL ciphers.",
        type: :string,
        default: "HIGH:MEDIUM:+3DES:!aNULL"
      },
      "ssl_crl_dir" => {
        description: "Location of the SSL certificate revocation list directory.",
        type: :string
      },
      "ssl_crl_file" => {
        description: "Location of the SSL certificate revocation list file.",
        type: :string
      },
      "ssl_dh_params_file" => {
        description: "Location of the SSL DH parameters file.",
        type: :string
      },
      "ssl_ecdh_curve" => {
        description: "Sets the curve to use for ECDH.",
        type: :string,
        default: "prime256v1"
      },
      "ssl_key_file" => {
        description: "Location of the SSL server private key file.",
        type: :string,
        default: "/etc/ssl/certs/server.key"
      },
      "ssl_max_protocol_version" => {
        description: "Sets the maximum SSL/TLS protocol version to use.",
        type: :enum,
        allowed_values: ["", "TLSv1", "TLSv1.1", "TLSv1.2", "TLSv1.3"],
        default: ""
      },
      "ssl_min_protocol_version" => {
        description: "Sets the minimum SSL/TLS protocol version to use.",
        type: :enum,
        allowed_values: ["TLSv1", "TLSv1.1", "TLSv1.2", "TLSv1.3"],
        default: "TLSv1.2"
      },
      "ssl_passphrase_command" => {
        description: "Command to obtain passphrases for SSL.",
        type: :string
      },
      "ssl_passphrase_command_supports_reload" => {
        description: 'Controls whether "ssl_passphrase_command" is called during server reload.',
        type: :bool,
        default: "off"
      },
      "ssl_prefer_server_ciphers" => {
        description: "Give priority to server ciphersuite order.",
        type: :bool,
        default: "on"
      },
      "standard_conforming_strings" => {
        description: "Causes '...' strings to treat backslashes literally.",
        type: :bool,
        default: "on"
      },
      "statement_timeout" => {
        description: "Sets the maximum allowed duration of any statement.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "0"
      },
      "stats_fetch_consistency" => {
        description: "Sets the consistency of accesses to statistics data.",
        type: :enum,
        allowed_values: ["none", "cache", "snapshot"],
        default: "cache"
      },
      "superuser_reserved_connections" => {
        description: "Sets the number of connection slots reserved for superusers.",
        type: :integer,
        min: 0,
        max: 262143,
        default: 3
      },
      "synchronize_seqscans" => {
        description: "Enable synchronized sequential scans.",
        type: :bool,
        default: "on"
      },
      "synchronous_commit" => {
        description: "Sets the current transaction's synchronization level.",
        type: :enum,
        allowed_values: ["on", "off", "remote_apply", "remote_write", "local"],
        default: "on"
      },
      "synchronous_standby_names" => {
        description: "Number of synchronous standbys and list of names of potential synchronous ones.",
        type: :string
      },
      "syslog_facility" => {
        description: 'Sets the syslog "facility" to be used when syslog enabled.',
        type: :enum,
        allowed_values: ["local0", "local1", "local2", "local3", "local4", "local5", "local6", "local7"],
        default: "local0"
      },
      "syslog_ident" => {
        description: "Sets the program name used to identify PostgreSQL messages in syslog.",
        type: :string,
        default: "postgres"
      },
      "syslog_sequence_numbers" => {
        description: "Add sequence number to syslog messages to avoid duplicate suppression.",
        type: :bool,
        default: "on"
      },
      "syslog_split_messages" => {
        description: "Split messages sent to syslog by lines and to fit into 1024 bytes.",
        type: :bool,
        default: "on"
      },
      "tcp_keepalives_count" => {
        description: "Maximum number of TCP keepalive retransmits.",
        type: :integer,
        min: 0,
        max: 2147483647,
        default: 4
      },
      "tcp_keepalives_idle" => {
        description: "Time between issuing TCP keepalives.",
        type: :integer,
        min: 0,
        max: 2147483647,
        default: 2
      },
      "tcp_keepalives_interval" => {
        description: "Time between TCP keepalive retransmits.",
        type: :integer,
        min: 0,
        max: 2147483647,
        default: 2
      },
      "tcp_user_timeout" => {
        description: "TCP user timeout.",
        type: :integer,
        min: 0,
        max: 2147483647,
        default: 0
      },
      "temp_buffers" => {
        description: "Sets the maximum number of temporary buffers used by each session.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "8MB"
      },
      "temp_file_limit" => {
        description: "Limits the total size of all temporary files used by each process.",
        type: :string,
        default: "-1"
      },
      "temp_tablespaces" => {
        description: "Sets the tablespace(s) to use for temporary tables and sort files.",
        type: :string
      },
      "timezone_abbreviations" => {
        description: "Selects a file of time zone abbreviations.",
        type: :string,
        default: "Default"
      },
      "trace_notify" => {
        description: "Generates debugging output for LISTEN and NOTIFY.",
        type: :bool,
        default: "off"
      },
      "trace_recovery_messages" => {
        description: "Enables logging of recovery-related debugging information.",
        type: :string,
        default: "log"
      },
      "trace_sort" => {
        description: "Emit information about resource usage in sorting.",
        type: :bool,
        default: "off"
      },
      "track_activities" => {
        description: "Collects information about executing commands.",
        type: :bool,
        default: "on"
      },
      "track_activity_query_size" => {
        description: "Sets the size reserved for pg_stat_activity.query, in bytes.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "1kB"
      },
      "track_commit_timestamp" => {
        description: "Collects transaction commit time.",
        type: :bool,
        default: "off"
      },
      "track_counts" => {
        description: "Collects statistics on database activity.",
        type: :bool,
        default: "on"
      },
      "track_functions" => {
        description: "Collects function-level statistics on database activity.",
        type: :enum,
        allowed_values: ["none", "all", "pl"],
        default: "none"
      },
      "track_io_timing" => {
        description: "Collects timing statistics for database I/O activity.",
        type: :bool,
        default: "off"
      },
      "track_wal_io_timing" => {
        description: "Collects timing statistics for WAL I/O activity.",
        type: :bool,
        default: "off"
      },
      "transaction_deferrable" => {
        description: "Whether to defer a read-only serializable transaction until it can be executed with no possible serialization failures.",
        type: :bool,
        default: "off"
      },
      "transaction_isolation" => {
        description: "Sets the current transaction's isolation level.",
        type: :enum,
        allowed_values: ["read uncommitted", "read committed", "repeatable read", "serializable"],
        default: "read committed"
      },
      "transaction_read_only" => {
        description: "Sets the current transaction's read-only status.",
        type: :bool,
        default: "off"
      },
      "transform_null_equals" => {
        description: 'Treats "expr=NULL" as "expr IS NULL".',
        type: :bool,
        default: "off"
      },
      "unix_socket_directories" => {
        description: "Sets the directories where Unix-domain sockets will be created.",
        type: :string,
        default: "/var/run/postgresql"
      },
      "unix_socket_group" => {
        description: "Sets the owning group of the Unix-domain socket.",
        type: :string
      },
      "unix_socket_permissions" => {
        description: "Sets the access permissions of the Unix-domain socket.",
        type: :integer,
        min: 0,
        max: 511,
        default: 777
      },
      "update_process_title" => {
        description: "Updates the process title to show the active SQL command.",
        type: :bool,
        default: "on"
      },
      "vacuum_buffer_usage_limit" => {
        description: "Sets the buffer pool size for VACUUM, ANALYZE, and autovacuum.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "2MB"
      },
      "vacuum_cost_delay" => {
        description: "Vacuum cost delay in milliseconds.",
        type: :integer,
        min: 0,
        max: 100,
        default: 0
      },
      "vacuum_cost_limit" => {
        description: "Vacuum cost amount available before napping.",
        type: :string,
        default: "200"
      },
      "vacuum_cost_page_dirty" => {
        description: "Vacuum cost for a page dirtied by vacuum.",
        type: :integer,
        min: 0,
        max: 10000,
        default: 20
      },
      "vacuum_cost_page_hit" => {
        description: "Vacuum cost for a page found in the buffer cache.",
        type: :integer,
        min: 0,
        max: 10000,
        default: 1
      },
      "vacuum_cost_page_miss" => {
        description: "Vacuum cost for a page not found in the buffer cache.",
        type: :integer,
        min: 0,
        max: 10000,
        default: 2
      },
      "vacuum_failsafe_age" => {
        description: "Age at which VACUUM should trigger failsafe to avoid a wraparound outage.",
        type: :integer,
        min: 0,
        max: 2100000000,
        default: 1600000000
      },
      "vacuum_freeze_min_age" => {
        description: "Minimum age at which VACUUM should freeze a table row.",
        type: :integer,
        min: 0,
        max: 1000000000,
        default: 50000000
      },
      "vacuum_freeze_table_age" => {
        description: "Age at which VACUUM should scan whole table to freeze tuples.",
        type: :integer,
        min: 0,
        max: 2000000000,
        default: 150000000
      },
      "vacuum_multixact_failsafe_age" => {
        description: "Multixact age at which VACUUM should trigger failsafe to avoid a wraparound outage.",
        type: :integer,
        min: 0,
        max: 2100000000,
        default: 1600000000
      },
      "vacuum_multixact_freeze_min_age" => {
        description: "Minimum age at which VACUUM should freeze a MultiXactId in a table row.",
        type: :integer,
        min: 0,
        max: 1000000000,
        default: 5000000
      },
      "vacuum_multixact_freeze_table_age" => {
        description: "Multixact age at which VACUUM should scan whole table to freeze tuples.",
        type: :integer,
        min: 0,
        max: 2000000000,
        default: 150000000
      },
      "wal_buffers" => {
        description: "Sets the number of disk-page buffers in shared memory for WAL.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "16MB"
      },
      "wal_compression" => {
        description: "Compresses full-page writes written in WAL file with specified method.",
        type: :enum,
        allowed_values: ["on", "off", "pglz", "lz4", "zstd"],
        default: "off"
      },
      "wal_consistency_checking" => {
        description: "Sets the WAL resource managers for which WAL consistency checks are done.",
        type: :string
      },
      "wal_decode_buffer_size" => {
        description: "Buffer size for reading ahead in the WAL during recovery.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "512kB"
      },
      "wal_init_zero" => {
        description: "Writes zeroes to new WAL files before first use.",
        type: :bool,
        default: "on"
      },
      "wal_keep_size" => {
        description: "Sets the size of WAL files held for standby servers.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "0"
      },
      "wal_level" => {
        description: "Sets the level of information written to the WAL.",
        type: :enum,
        allowed_values: ["minimal", "replica", "logical"],
        default: "replica"
      },
      "wal_log_hints" => {
        description: "Writes full pages to WAL when first modified after a checkpoint, even for a non-critical modification.",
        type: :bool,
        default: "off"
      },
      "wal_receiver_create_temp_slot" => {
        description: "Sets whether a WAL receiver should create a temporary replication slot if no permanent slot is configured.",
        type: :bool,
        default: "off"
      },
      "wal_receiver_status_interval" => {
        description: "Sets the maximum interval between WAL receiver status reports to the sending server.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "10s"
      },
      "wal_receiver_timeout" => {
        description: "Sets the maximum wait time to receive data from the sending server.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "1min"
      },
      "wal_recycle" => {
        description: "Recycles WAL files by renaming them.",
        type: :bool,
        default: "on"
      },
      "wal_retrieve_retry_interval" => {
        description: "Sets the time to wait before retrying to retrieve WAL after a failed attempt.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "5s"
      },
      "wal_sender_timeout" => {
        description: "Sets the maximum time to wait for WAL replication.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "1min"
      },
      "wal_skip_threshold" => {
        description: "Minimum size of new file to fsync instead of writing WAL.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "2MB"
      },
      "wal_sync_method" => {
        description: "Selects the method used for forcing WAL updates to disk.",
        type: :enum,
        allowed_values: ["fsync", "fdatasync", "open_sync", "open_datasync"],
        default: "fdatasync"
      },
      "wal_writer_delay" => {
        description: "Time between WAL flushes performed in the WAL writer.",
        type: :string,
        pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
        default: "200ms"
      },
      "wal_writer_flush_after" => {
        description: "Amount of WAL written out by WAL writer that triggers a flush.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "1MB"
      },
      "work_mem" => {
        description: "Sets the maximum memory to be used for query workspaces.",
        type: :string,
        pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
        default: "(12.5% of total memory)"
      },
      "xmlbinary" => {
        description: "Sets how binary values are to be encoded in XML.",
        type: :enum,
        allowed_values: ["base64", "hex"],
        default: "base64"
      },
      "xmloption" => {
        description: "Sets whether XML data in implicit parsing and serialization operations is to be considered as documents or content fragments.",
        type: :enum,
        allowed_values: ["content", "document"],
        default: "content"
      },
      "zero_damaged_pages" => {
        description: "Continues processing past damaged page headers.",
        type: :bool,
        default: "off"
      }
    }.freeze

    PGBOUNCER_CONFIG_SCHEMA = {
      "logfile" => {
        description: "Log file to send log messages to.",
        type: :string
      },
      "pidfile" => {
        description: "File to write the process ID to.",
        type: :string
      },
      "listen_addr" => {
        description: "IP address to listen on.",
        type: :string,
        default: "127.0.0.1"
      },
      "listen_port" => {
        description: "Port to listen on.",
        type: :integer,
        default: 6432,
        min: 1,
        max: 65535
      },
      "unix_socket_dir" => {
        description: "Directory to create the Unix socket in.",
        type: :string
      },
      "unix_socket_mode" => {
        description: "File system permissions for the Unix socket.",
        type: :string
      },
      "unix_socket_group" => {
        description: "Group ownership for the Unix socket.",
        type: :string
      },
      "user" => {
        description: "System user to run as.",
        type: :string
      },
      "pool_mode" => {
        description: "When server connection can be reused by other clients.",
        type: :enum,
        allowed_values: ["session", "transaction", "statement"],
        default: "session"
      },
      "max_client_conn" => {
        description: "Maximum number of client connections allowed.",
        type: :integer,
        default: 5000,
        min: 1,
        max: 65535
      },
      "default_pool_size" => {
        description: "How many server connections to allow per user/database pair.",
        type: :integer,
        default: 20,
        min: 1,
        max: 65535
      },
      "min_pool_size" => {
        description: "Minimum number of server connections to keep in pool per user/database.",
        type: :integer,
        default: 0,
        min: 0,
        max: 65535
      },
      "reserve_pool_size" => {
        description: "How many additional connections to allow to a pool.",
        type: :integer,
        default: 0,
        min: 0,
        max: 65535
      },
      "reserve_pool_timeout" => {
        description: "If a client has not been serviced in this many seconds, use the reserve pool.",
        type: :float,
        default: 5.0,
        min: 0.0,
        max: 65535.0
      },
      "max_db_connections" => {
        description: "Do not allow more server connections than this to a database.",
        type: :integer,
        default: 500,
        min: 0,
        max: 65535
      },
      "max_db_client_connections" => {
        description: "Do not allow more client connections than this to a database.",
        type: :integer,
        default: 0,
        min: 0,
        max: 65535
      },
      "max_user_connections" => {
        description: "Do not allow more than this many server connections per user.",
        type: :integer,
        default: 0,
        min: 0,
        max: 65535
      },
      "max_user_client_connections" => {
        description: "Do not allow more than this many client connections per user.",
        type: :integer,
        default: 0,
        min: 0,
        max: 65535
      },
      "server_round_robin" => {
        description: "Load balance connections in a round-robin fashion.",
        type: :enum,
        allowed_values: ["0", "1"],
        default: "0"
      },
      "track_extra_parameters" => {
        description: "Track extra parameters beyond the ones needed for connection.",
        type: :string
      },
      "ignore_startup_parameters" => {
        description: "List of parameters to ignore in the connection string.",
        type: :string,
        default: "extra_float_digits"
      },
      "disable_pqexec" => {
        description: "Disable the Simple Query protocol.",
        type: :enum,
        allowed_values: ["0", "1"],
        default: "0"
      },
      "application_name_add_host" => {
        description: "Add client host address to application_name parameter.",
        type: :enum,
        allowed_values: ["0", "1"],
        default: "0"
      },
      "conffile" => {
        description: "Load configuration from this file.",
        type: :string
      },
      "service_name" => {
        description: "Service name to use for systemd.",
        type: :string
      },
      "job_name" => {
        description: "Job name to use for systemd.",
        type: :string
      },
      "stats_period" => {
        description: "How often to log statistics, in seconds.",
        type: :integer,
        default: 60,
        min: 5,
        max: 65535
      },
      "max_prepared_statements" => {
        description: "Maximum number of prepared statements per connection.",
        type: :integer,
        default: 200,
        min: 1,
        max: 65535
      },
      "auth_type" => {
        description: "How to authenticate users.",
        type: :enum,
        allowed_values: ["trust", "plain", "md5", "scram-sha-256", "cert", "hba", "pam"],
        default: "trust"
      },
      "auth_hba_file" => {
        description: "Path to the HBA configuration file.",
        type: :string
      },
      "auth_ident_file" => {
        description: "Path to the ident configuration file.",
        type: :string
      },
      "auth_file" => {
        description: "Path to the authentication file.",
        type: :string
      },
      "auth_user" => {
        description: "User to use for authentication queries.",
        type: :string
      },
      "auth_query" => {
        description: "Query to use to fetch user passwords.",
        type: :string
      },
      "auth_dbname" => {
        description: "Database to connect to for authentication queries.",
        type: :string
      },
      "syslog" => {
        description: "Log to syslog instead of stderr.",
        type: :enum,
        allowed_values: ["0", "1"],
        default: "0"
      },
      "syslog_ident" => {
        description: "Program name to identify as in syslog.",
        type: :string,
        default: "pgbouncer"
      },
      "syslog_facility" => {
        description: "Syslog facility to use.",
        type: :string,
        default: "daemon"
      },
      "log_connections" => {
        description: "Log successful logins.",
        type: :enum,
        allowed_values: ["0", "1"],
        default: "1"
      },
      "log_disconnections" => {
        description: "Log disconnections with reason.",
        type: :enum,
        allowed_values: ["0", "1"],
        default: "1"
      },
      "log_pooler_errors" => {
        description: "Log error messages from the connection pooler.",
        type: :enum,
        allowed_values: ["0", "1"],
        default: "1"
      },
      "log_stats" => {
        description: "Log statistics periodically.",
        type: :enum,
        allowed_values: ["0", "1"],
        default: "1"
      },
      "verbose" => {
        description: "Increase verbosity.",
        type: :enum,
        allowed_values: ["0", "1", "2", "3"],
        default: "0"
      },
      "admin_users" => {
        description: "Comma-separated list of database users to treat as administrators.",
        type: :string
      },
      "stats_users" => {
        description: "Comma-separated list of database users that are allowed to run SHOW commands.",
        type: :string
      },
      "server_reset_query" => {
        description: "Query to execute on a server after a client disconnects.",
        type: :string
      },
      "server_reset_query_always" => {
        description: "Whether to run server_reset_query after every transaction.",
        type: :enum,
        allowed_values: ["0", "1"],
        default: "0"
      },
      "server_check_delay" => {
        description: "How long to wait between connection checks, in seconds.",
        type: :float,
        default: 30.0,
        min: 0.0,
        max: 65535.0
      },
      "server_check_query" => {
        description: "Query to execute to check if a server is alive.",
        type: :string,
        default: "SELECT 1"
      }
    }.freeze

    PG_17_CONFIG_SCHEMA = begin
      removed = ["db_user_namespace", "old_snapshot_threshold", "trace_recovery_messages"]
      added_or_modified = {
        "allow_alter_system" => {
          description: "Allows running the ALTER SYSTEM command.",
          type: :bool,
          default: "on"
        },
        "commit_timestamp_buffers" => {
          description: "Sets the size of the dedicated buffer pool used for the commit timestamp cache.",
          type: :string,
          pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
          default: "4MB"
        },
        "enable_group_by_reordering" => {
          description: "Enables reordering of GROUP BY keys.",
          type: :bool,
          default: "on"
        },
        "event_triggers" => {
          description: "Enables event triggers.",
          type: :bool,
          default: "on"
        },
        "io_combine_limit" => {
          description: "Limit on the size of data reads and writes.",
          type: :string,
          pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
          default: "128kB"
        },
        "max_notify_queue_pages" => {
          description: "Sets the maximum number of allocated pages for NOTIFY / LISTEN queue.",
          type: :integer,
          max: 2147483647,
          min: 64,
          default: 1048576
        },
        "multixact_member_buffers" => {
          description: "Sets the size of the dedicated buffer pool used for the MultiXact member cache.",
          type: :string,
          pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
          default: "256kB"
        },
        "multixact_offset_buffers" => {
          description: "Sets the size of the dedicated buffer pool used for the MultiXact offset cache.",
          type: :string,
          pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
          default: "128kB"
        },
        "notify_buffers" => {
          description: "Sets the size of the dedicated buffer pool used for the LISTEN/NOTIFY message cache.",
          type: :string,
          pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
          default: "128kB"
        },
        "serializable_buffers" => {
          description: "Sets the size of the dedicated buffer pool used for the serializable transaction cache.",
          type: :string,
          pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
          default: "256kB"
        },
        "subtransaction_buffers" => {
          description: "Sets the size of the dedicated buffer pool used for the subtransaction cache.",
          type: :string,
          pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
          default: "4MB"
        },
        "summarize_wal" => {
          description: "Starts the WAL summarizer process to enable incremental backup.",
          type: :bool,
          default: "off"
        },
        "sync_replication_slots" => {
          description: "Enables a physical standby to synchronize logical failover replication slots from the primary server.",
          type: :bool,
          default: "off"
        },
        "synchronized_standby_slots" => {
          description: "Lists streaming replication standby server replication slot names that logical WAL sender processes will wait for.",
          type: :string
        },
        "trace_connection_negotiation" => {
          description: "Logs details of pre-authentication connection handshake.",
          type: :bool,
          default: "off"
        },
        "transaction_buffers" => {
          description: "Sets the size of the dedicated buffer pool used for the transaction status cache.",
          type: :string,
          pattern: /\A[0-9]+(kB|MB|GB|TB)?\z/,
          default: "4MB"
        },
        "transaction_timeout" => {
          description: "Sets the maximum allowed duration of any transaction within a session (not a prepared transaction).",
          type: :integer,
          max: 2147483647,
          min: 0,
          default: 0
        },
        "wal_summary_keep_time" => {
          description: "Time for which WAL summary files should be kept.",
          type: :string,
          pattern: /\A[0-9]+(us|ms|s|min|h|d)?\z/,
          default: "10d"
        }
      }

      schema = PG_16_CONFIG_SCHEMA.dup
      removed.each { |key| schema.delete(key) }
      schema.merge!(added_or_modified)
    end.freeze
  end
end
