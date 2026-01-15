# frozen_string_literal: true

UbiCli.on("lb").run_on("disable-ssl-certificate") do
  desc "Disable the SSL certificate for a load balancer"

  banner "ubi lb (location/lb-name | lb-id) disable-ssl-certificate"

  run do
    id = sdk_object.toggle_ssl_certificate(cert_enabled: false).id
    response("Disabled SSL certificate for load balancer with id #{id}")
  end
end
