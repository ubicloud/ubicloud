# frozen_string_literal: true

UbiCli.pg_cmd("pg_dumpall") do |argv|
  conn_string = argv.pop
  argv.pop # --
  argv << "-d#{conn_string}"
end
