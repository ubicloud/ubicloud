# frozen_string_literal: true

require "open3"
require "yaml"
require_relative "errors"

module Csi
  class KubernetesClient
    include ServiceHelper

    def initialize(req_id:, logger:)
      @req_id = req_id
      @logger = logger
    end

    def run_kubectl(*args, yaml_data: nil)
      cmd = ["kubectl", *args]
      stdin_data = yaml_data ? YAML.dump(yaml_data) : nil
      output, status = run_cmd(*cmd, req_id: @req_id, stdin_data:)
      unless status.success?
        if output.strip.end_with?("not found")
          raise ObjectNotFoundError, output
        end
        raise "Command failed: #{cmd.join(" ")}\nOutput: #{output}"
      end
      output
    end

    def yaml_load_kubectl(*)
      YAML.safe_load(run_kubectl(*))
    end

    def get_node(name)
      yaml_load_kubectl("get", "node", name, "-oyaml")
    end

    def get_node_ip(name)
      node_yaml = get_node(name)
      node_yaml.dig("status", "addresses", 0, "address")
    end

    def get_pv(name)
      yaml_load_kubectl("get", "pv", name, "-oyaml")
    end

    def extract_node_from_pv(pv)
      pv.dig("spec", "nodeAffinity", "required", "nodeSelectorTerms", 0, "matchExpressions", 0, "values", 0)
    end

    def create_pv(yaml_data)
      run_kubectl("create", "-f", "-", yaml_data:)
    end

    def update_pv(yaml_data)
      run_kubectl("apply", "-f", "-", yaml_data:)
    end

    def get_pvc(namespace, name)
      yaml_load_kubectl("-n", namespace, "get", "pvc", name, "-oyaml")
    end

    def create_pvc(yaml_data)
      run_kubectl("create", "-f", "-", yaml_data:)
    end

    def update_pvc(yaml_data)
      run_kubectl("apply", "-f", "-", yaml_data:)
    end

    def delete_pvc(namespace, name)
      run_kubectl("-n", namespace, "delete", "pvc", name, "--wait=false", "--ignore-not-found=true")
    end

    # This function will first try to get the pvc in order to make sure pvc exists
    def remove_pvc_finalizers(namespace, name)
      get_pvc(namespace, name)
      run_kubectl("-n", namespace, "patch", "pvc", name, "--type=merge", "-p", "{\"metadata\":{\"finalizers\":null}}")
    rescue ObjectNotFoundError
    end

    def node_schedulable?(name)
      !get_node(name).dig("spec", "unschedulable")
    end

    def find_pv_by_volume_id(volume_id)
      pv_list = yaml_load_kubectl("get", "pv", "-oyaml")
      pv = pv_list["items"].find { |pv| pv.dig("spec", "csi", "volumeHandle") == volume_id }

      raise ObjectNotFoundError, "PersistentVolume with volumeHandle '#{volume_id}' not found" unless pv

      pv
    end
  end
end
