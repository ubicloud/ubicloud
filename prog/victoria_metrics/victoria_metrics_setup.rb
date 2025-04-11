# frozen_string_literal: true

class Prog::VictoriaMetrics::VictoriaMetricsSetup < Prog::Base
  subject_is :victoria_metrics_server

  label def install
    case victoria_metrics_server.vm.sshable.cmd("common/bin/daemonizer --check install_victoriametrics")
    when "Succeeded"
      pop "victoriametrics is installed"
    when "Failed", "NotStarted"
      victoria_metrics_server.vm.sshable.cmd("common/bin/daemonizer 'victoriametrics/bin/install #{Config.victoriametrics_version}' install_victoriametrics")
    end
    nap 5
  end

  label def configure
    case victoria_metrics_server.vm.sshable.cmd("common/bin/daemonizer --check configure_victoriametrics")
    when "Succeeded"
      victoria_metrics_server.vm.sshable.cmd("common/bin/daemonizer --clean configure_victoriametrics")
      pop "victoriametrics is configured"
    when "Failed", "NotStarted"
      config_json = JSON.generate({
        admin_user: victoria_metrics_server.resource.admin_user,
        admin_password: victoria_metrics_server.resource.admin_password,
        cert: victoria_metrics_server.cert,
        cert_key: victoria_metrics_server.cert_key,
        ca_bundle: victoria_metrics_server.resource.root_certs
      })

      victoria_metrics_server.vm.sshable.cmd("common/bin/daemonizer 'sudo victoriametrics/bin/configure' configure_victoriametrics", stdin: config_json)
    end

    nap 5
  end
end
