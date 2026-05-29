# frozen_string_literal: true

class UbiCli
  base("kc") do
    banner "ubi kc command [...]"
    post_banner "ubi kc (location/kc-name | kc-id) post-command [...]"
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/kc")
