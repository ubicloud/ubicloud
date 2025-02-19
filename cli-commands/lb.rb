# frozen_string_literal: true

UbiCli.base("lb") do
  options("ubi lb subcommand [...]")
  post_options("ubi lb location/(lb-name|_lb-ubid) subcommand [...]")
end

Unreloader.record_dependency(__FILE__, "cli-commands/lb")
