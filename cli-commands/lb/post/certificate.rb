# frozen_string_literal: true

UbiCli.on("lb").run_on("certificate") do
  desc "Print active certificate for a load balancer"

  banner "ubi lb (location/lb-name | lb-id) certificate"

  run do
    response(sdk_object.active_certificate)
  end
end
