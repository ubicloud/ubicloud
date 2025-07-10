# frozen_string_literal: true

require "open3"
require "yaml"
require_relative "errors"

module Csi
  class KubernetesClient
    def initialize(req_id: nil)
      @req_id = req_id
      @logger = Logger.new($stdout) if req_id.nil?
    end

    def run_cmd(*cmd, **options)
      Open3.capture2e(*cmd, **options)
    end

    def run_kubectl(*args, stdin_data: nil)
      cmd = [
        "kubectl",
        *args
      ]
      @logger.info("[req_id=#{id}] [Kubernetes Client] #{cmd.join(" ")}") unless @req_id.nil?
      output, status = run_cmd(*cmd, stdin_data:)
      unless status.success?
        if output.strip.end_with?("not found")
          raise ObjectNotFoundError, output
        end
        raise "Command failed: #{cmd.join(" ")}\nOutput: #{output}"
      end
      output
    end

    def get_node(name)
      YAML.safe_load(run_kubectl("get", "node", name, "-oyaml"))
    end

    def get_node_ip(name)
      node_yaml = get_node(name)
      node_yaml.dig("status", "addresses", 0, "address")
    end

    def get_pv(name)
      YAML.safe_load(run_kubectl("get", "pv", name, "-oyaml"))
    end

    def extract_node_from_pv(pv)
      pv.dig("spec", "nodeAffinity", "required", "nodeSelectorTerms", 0, "matchExpressions", 0, "values", 0)
    end

    def create_pv(yaml_data)
      run_kubectl("create", "-f", "-", stdin_data: YAML.dump(yaml_data))
    end

    def update_pv(yaml_data)
      run_kubectl("apply", "-f", "-", stdin_data: YAML.dump(yaml_data))
    end

    def get_pvc(namespace, name)
      YAML.safe_load(run_kubectl("-n", namespace, "get", "pvc", name, "-oyaml"))
    end

    def create_pvc(yaml_data)
      run_kubectl("create", "-f", "-", stdin_data: YAML.dump(yaml_data))
    end

    def update_pvc(yaml_data)
      run_kubectl("apply", "-f", "-", stdin_data: YAML.dump(yaml_data))
    end

    def delete_pvc(namespace, name)
      run_kubectl("-n", namespace, "delete", "pvc", name, "--wait=false", "--ignore-not-found=true")
    end

    def node_schedulable?(name)
      !get_node(name)["spec"]&.fetch("unschedulable", false)
    end

    def find_pv_by_volume_id(volume_id)
      pv_list = YAML.safe_load(run_kubectl("get", "pv", "-oyaml"))
      pv_list["items"].find { |pv| pv.dig("spec", "csi", "volumeHandle") == volume_id }
    end
  end
end
