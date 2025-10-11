# frozen_string_literal: true

UbiCli.on("lb").run_on("enable-ssl-certificate") do
  desc "Enable the SSL certificate for a load balancer"

  banner "ubi lb (location/lb-name | lb-id) enable-ssl-certificate"

  run do
    id = sdk_object.toggle_ssl_certificate(cert_enabled: true).id
    response("Enabled SSL certificate for load balancer with id #{id}")
  end
end
