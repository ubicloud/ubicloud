#  frozen_string_literal: true

require_relative "../../model"

class KubernetesNode < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :vm, read_only: true
  many_to_one :kubernetes_cluster, read_only: true
  many_to_one :kubernetes_nodepool, read_only: true

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :retire
  include HealthMonitorMethods

  MESH_STATUS_FILE_PATH = "/var/lib/ubicsi/mesh_status.json"

  def sshable
    vm.sshable
  end

  def init_health_monitor_session
    {
      ssh_session: sshable.start_fresh_session
    }
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      file_content = session[:ssh_session].exec!("cat :MESH_STATUS_FILE_PATH 2>/dev/null || echo -n", MESH_STATUS_FILE_PATH:)
      if file_content.empty?
        "up" # File doesn't exist yet - CSI not updated, consider healthy
      else
        status = JSON.parse(file_content)
        pods_status = status["pods"]
        unreachable_pods = pods_status.select { |_, v| v["reachable"] == false }
        if unreachable_pods.any?
          errors = unreachable_pods.transform_values { |v| v["error"] }.compact
          Clog.emit("Mesh connectivity issue detected", {kubernetes_node_mesh: {ubid:, unreachable_pods: unreachable_pods.keys, errors:}})
          "down"
        else
          "up"
        end
      end
    rescue IOError, Errno::ECONNRESET
      raise
    rescue => e
      Clog.emit("Exception in KubernetesNode pulse check", Util.exception_to_hash(e, into: {ubid:}))
      "down"
    end
    aggregate_readings(previous_pulse:, reading:)
  end

  def billing_records
    if kubernetes_nodepool
      [
        {type: "KubernetesWorkerVCpu", family: vm.family, amount: BigDecimal(vm.vcpus)},
        {type: "KubernetesWorkerStorage", family: "standard", amount: BigDecimal(vm.storage_size_gib)}
      ]
    else
      [
        {type: "KubernetesControlPlaneVCpu", family: vm.family, amount: BigDecimal(vm.vcpus)}
      ]
    end
  end

  def name
    vm.name
  end
end

# Table: kubernetes_node
# Columns:
#  id                     | uuid                     | PRIMARY KEY
#  created_at             | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  vm_id                  | uuid                     | NOT NULL
#  kubernetes_cluster_id  | uuid                     | NOT NULL
#  kubernetes_nodepool_id | uuid                     |
#  state                  | text                     | NOT NULL DEFAULT 'active'::text
# Indexes:
#  kubernetes_node_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  kubernetes_node_kubernetes_cluster_id_fkey  | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
#  kubernetes_node_kubernetes_nodepool_id_fkey | (kubernetes_nodepool_id) REFERENCES kubernetes_nodepool(id)
#  kubernetes_node_vm_id_fkey                  | (vm_id) REFERENCES vm(id)
