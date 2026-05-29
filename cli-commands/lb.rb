# frozen_string_literal: true

class UbiCli
  base("lb") do
    banner "ubi lb command [...]"
    post_banner "ubi lb (location/lb-name | lb-id) post-command [...]"
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/lb")
