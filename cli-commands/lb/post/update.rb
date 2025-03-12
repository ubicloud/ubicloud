# frozen_string_literal: true

UbiCli.on("lb").run_on("update") do
  desc "Update a load balancer"

  banner "ubi lb (location/lb-name | lb-id) update algorithm src-port dst-port health-check-endpoint [vm-id [...]]"

  args(4...)

  run do |argv|
    algorithm, src_port, dst_port, health_check_endpoint, *vms = argv
    patch(lb_path, {algorithm:, src_port:, dst_port:, health_check_endpoint:, vms:}.transform_keys(&:to_s)) do |data|
      ["Updated load balancer with id #{data["id"]}"]
    end
  end
end
