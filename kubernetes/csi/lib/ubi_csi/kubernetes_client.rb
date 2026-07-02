# frozen_string_literal: true

require "open3"
require "yaml"
require_relative "errors"

module Csi
  class KubernetesClient
    include ServiceHelper

    DRIVER_NAME = "csi.ubicloud.com"
    CSI_NAMESPACE = "ubicsi"
    PROVISIONER_DEPLOYMENT_NAME = "ubicsi-provisioner"

    def initialize(req_id:, logger:, log_level: :info)
      @req_id = req_id
      @logger = logger
      @log_level = log_level
    end

    def run_kubectl(*args, yaml_data: nil)
      cmd = ["kubectl", *args]
      stdin_data = yaml_data ? YAML.dump(yaml_data) : nil
      output, status = run_cmd(*cmd, req_id: @req_id, stdin_data:)
      unless status.success?
        if output.strip.end_with?("not found")
          raise ObjectNotFoundError, output
        end

        if output.strip.end_with?("already exists")
          raise AlreadyExistsError, output
        end

        raise "Command failed: #{cmd.join(" ")}\nOutput: #{output}"
      end
      output
    end

    def yaml_load_kubectl(*)
      YAML.safe_load(run_kubectl(*, "-oyaml"))
    end

    def get_node(name)
      yaml_load_kubectl("get", "node", name)
    end

    def get_node_ip(name)
      node_yaml = get_node(name)
      node_yaml.dig("status", "addresses", 0, "address")
    end

    def get_pv(name)
      yaml_load_kubectl("get", "pv", name)
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
      yaml_load_kubectl("-n", namespace, "get", "pvc", name)
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

    def patch_resource(resource, name, annotation_key, annotation_value, namespace: "")
      patch = {metadata: {annotations: {annotation_key => annotation_value}}}.to_json
      cmd = ["patch", resource, name, "--type=merge", "-p", patch]
      cmd = ["-n", namespace] + cmd unless namespace.empty?
      run_kubectl(*cmd)
    end

    # This function will first try to get the pvc in order to make sure pvc exists
    def remove_pvc_finalizers(namespace, name)
      get_pvc(namespace, name)
      patch = {metadata: {finalizers: nil}}.to_json
      run_kubectl("-n", namespace, "patch", "pvc", name, "--type=merge", "-p", patch)
    rescue ObjectNotFoundError
    end

    def remove_pvc_annotation(namespace, name, annotation_key)
      patch = {metadata: {annotations: {annotation_key => nil}}}.to_json
      run_kubectl("-n", namespace, "patch", "pvc", name, "--type=merge", "-p", patch)
    end

    def node_schedulable?(name)
      !get_node(name).dig("spec", "unschedulable")
    end

    def find_pv_by_volume_id(volume_id)
      pv_list = yaml_load_kubectl("get", "pv")
      pv = pv_list["items"].find { |pv| pv.dig("spec", "csi", "volumeHandle") == volume_id }

      raise ObjectNotFoundError, "PersistentVolume with volumeHandle '#{volume_id}' not found" unless pv

      pv
    end

    def find_retained_pv_for_pvc(namespace, name)
      pv_list = yaml_load_kubectl("get", "pv")
      pv_list["items"].find do |pv|
        pv.dig("metadata", "annotations", "csi.ubicloud.com/old-pvc-object") &&
          pv.dig("spec", "persistentVolumeReclaimPolicy") == "Retain" &&
          pv.dig("spec", "claimRef", "namespace") == namespace &&
          pv.dig("spec", "claimRef", "name") == name
      end
    end

    def get_nodeplugin_pods
      pods_yaml = yaml_load_kubectl("-n", "ubicsi", "get", "pods", "-l", "app=ubicsi,component=nodeplugin")
      pods_yaml["items"].filter_map do |pod|
        next unless pod.dig("status", "phase") == "Running"
        {
          "name" => pod.dig("metadata", "name"),
          "ip" => pod.dig("status", "podIP"),
          "node" => pod.dig("spec", "nodeName"),
        }
      end
    end

    def get_coredns_pods
      pods_yaml = yaml_load_kubectl("-n", "kube-system", "get", "pods", "-l", "k8s-app=kube-dns")
      pods_yaml["items"].filter_map do |pod|
        next unless pod.dig("status", "phase") == "Running"
        {
          "name" => pod.dig("metadata", "name"),
          "ip" => pod.dig("status", "podIP"),
        }
      end
    end

    # Returns the names of StorageClasses whose provisioner is our driver.
    def list_storage_classes_for_driver
      list = yaml_load_kubectl("get", "storageclasses")
      list["items"].filter_map do |sc|
        next unless sc["provisioner"] == DRIVER_NAME
        sc.dig("metadata", "name")
      end
    end

    # Returns the names of nodes whose CSINode lists our driver as
    # registered (i.e. nodes where our node plugin is running).
    def list_csi_nodes_with_driver
      list = yaml_load_kubectl("get", "csinodes")
      list["items"].filter_map do |csinode|
        next unless csinode.dig("spec", "drivers")&.any? { |d| d["name"] == DRIVER_NAME }
        csinode.dig("metadata", "name")
      end
    end

    # Returns CSIStorageCapacity objects in the controller's namespace
    # that belong to a StorageClass for our driver.
    def list_csi_storage_capacities
      ubi_scs = list_storage_classes_for_driver
      return [] if ubi_scs.empty?
      list = yaml_load_kubectl("-n", CSI_NAMESPACE, "get", "csistoragecapacities")
      list["items"].select { |obj| ubi_scs.include?(obj["storageClassName"]) }
    end

    def create_csi_storage_capacity(name:, hostname:, storage_class:, capacity_bytes:, max_volume_size:, owner_ref: nil)
      obj = {
        "apiVersion" => "storage.k8s.io/v1",
        "kind" => "CSIStorageCapacity",
        "metadata" => {
          "name" => name,
          "namespace" => CSI_NAMESPACE,
        },
        "nodeTopology" => {
          "matchLabels" => {"kubernetes.io/hostname" => hostname},
        },
        "storageClassName" => storage_class,
        "capacity" => capacity_bytes.to_s,
        "maximumVolumeSize" => max_volume_size.to_s,
      }
      obj["metadata"]["ownerReferences"] = [owner_ref] if owner_ref
      run_kubectl("create", "-f", "-", yaml_data: obj)
    end

    def patch_csi_storage_capacity(name:, capacity_bytes:, max_volume_size:)
      patch = {capacity: capacity_bytes.to_s, maximumVolumeSize: max_volume_size.to_s}.to_json
      run_kubectl("-n", CSI_NAMESPACE, "patch", "csistoragecapacity", name, "--type=merge", "-p", patch)
    end

    def delete_csi_storage_capacity(name:)
      run_kubectl("-n", CSI_NAMESPACE, "delete", "csistoragecapacity", name, "--ignore-not-found=true")
    end

    # Builds an ownerReference pointing at the controller's Deployment so
    # the CSIStorageCapacity objects we create are garbage-collected when
    # the driver is uninstalled. Equivalent to the sidecar's
    # --capacity-ownerref-level=2 behavior, but driven by us.
    def get_provisioner_deployment_owner_ref
      deploy = yaml_load_kubectl("-n", CSI_NAMESPACE, "get", "deployment", PROVISIONER_DEPLOYMENT_NAME)
      {
        "apiVersion" => deploy["apiVersion"],
        "kind" => deploy["kind"],
        "name" => deploy.dig("metadata", "name"),
        "uid" => deploy.dig("metadata", "uid"),
        "controller" => true,
      }
    end
  end
end
