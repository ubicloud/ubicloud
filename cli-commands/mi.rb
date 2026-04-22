# frozen_string_literal: true

UbiCli.base("mi") do
  banner "ubi mi command [...]"
  post_banner "ubi mi (location/mi-name | mi-id) post-command [...]"
end

Unreloader.record_dependency(__FILE__, "cli-commands/mi")
