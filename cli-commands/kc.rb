# frozen_string_literal: true

UbiCli.base("kc") do
  banner "ubi kc command [...]"
end

Unreloader.record_dependency(__FILE__, "cli-commands/kc")
