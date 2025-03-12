# frozen_string_literal: true

UbiCli.base("ps") do
  banner "ubi ps command [...]"
  post_banner "ubi ps (location/ps-name | ps-id) post-command [...]"
end

Unreloader.record_dependency(__FILE__, "cli-commands/ps")
