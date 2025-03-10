# frozen_string_literal: true

UbiCli.pg_cmd("pg_dumpall", "Dump a entire PostgreSQL database cluster using `pg_dumpall`") do |argv|
  conn_string = argv.pop
  argv.pop # --
  argv << "-d#{conn_string}"
end
