# frozen_string_literal: true

UbiCli.base("app") do
  banner "ubi app command [...]"
  post_banner "ubi app (location/app-name | app-id) post-command [...]"
end

Unreloader.record_dependency(__FILE__, "cli-commands/app")
