# frozen_string_literal: true

require "open3"

module Csi
  class KubernetesClient
    def read_token
      File.read("/var/run/secrets/kubernetes.io/serviceaccount/token").strip
    end

    def run_cmd(*cmd, **options)
      Open3.capture2e(*cmd, **options)
    end

    def run_kubectl(*args, stdin_data: nil)
      token = read_token
      cmd = [
        "kubectl",
        "--server=https://kubernetes.default",
        "--certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
        "--token=#{token}",
        *args
      ]
      output, status = run_cmd(*cmd, stdin_data:)
      unless status.success?
        raise "Command failed: #{cmd.join(" ")}\nOutput: #{output}"
      end
      output
    end

    def get_node(name)
      run_kubectl("get", "node", name, "-o", "yaml")
    end

    def get_pv(name)
      run_kubectl("get", "pv", name, "-o", "yaml")
    end

    def create_pv(yaml_data)
      run_kubectl("create", "-f", "-", stdin_data: yaml_data)
    end

    def update_pv(yaml_data)
      run_kubectl("apply", "-f", "-", stdin_data: yaml_data)
    end

    def get_pvc(namespace, name)
      run_kubectl("get", "-n", namespace, "pvc", name, "-o", "yaml")
    end

    def create_pvc(yaml_data)
      run_kubectl("create", "-f", "-", stdin_data: yaml_data)
    end

    def delete_pvc(namespace, name)
      run_kubectl("delete", "-n", namespace, "pvc", name)
    end

    def node_schedulable?(name)
      node_data = YAML.safe_load(get_node(name))
      !node_data["spec"]&.fetch("unschedulable", false)
    end

    def find_pv_by_volume_id(volume_id)
      pv_list = YAML.safe_load(run_kubectl("get", "pv", "-o", "yaml"))
      pv_list["items"].find { |pv| pv.dig("spec", "csi", "volumeHandle") == volume_id }
    end
  end
end
