# frozen_string_literal: true

UbiCli.base("vm") do
  banner "ubi vm command [...]"

  post_options("ubi vm (location/vm-name | vm-id) [post-options] post-command [...]", key: :vm_ssh) do
    on("-4", "--ip4", "use IPv4 address")
    on("-6", "--ip6", "use IPv6 address")
    on("-u", "--user user", "override username")
  end
end

Unreloader.record_dependency(__FILE__, "cli-commands/vm")
