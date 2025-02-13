# frozen_string_literal: true

UbiCli.base("pg") do
  options("ubi pg subcommand [...]")

  post_options("ubi pg location-name/(pg-name|_pg-ubid) [options] subcommand [...]", key: :pg_psql) do
    on("-d", "--dbname=name", "override database name")
    on("-U", "--username=name", "override username")
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/pg")
