# frozen_string_literal: true

UbiCli.base("ps") do
  options("ubi ps subcommand [...]")
  post_options("ubi ps location/(ps-name|_ps-ubid) subcommand [...]")
end

Unreloader.record_dependency(__FILE__, "cli-commands/ps")
