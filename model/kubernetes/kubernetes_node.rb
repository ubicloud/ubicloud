#  frozen_string_literal: true

require_relative "../../model"

class KubernetesNode < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :vm, read_only: true
  many_to_one :kubernetes_cluster, read_only: true
  many_to_one :kubernetes_nodepool, read_only: true

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :retire, :checkup
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
      available_result = check_mesh_availability(session[:ssh_session])
      if available_result[:available]
        "up"
      else
        Clog.emit("Mesh connectivity issue detected", {kubernetes_node_mesh: {ubid:, **available_result}})
        "down"
      end
    rescue IOError, Errno::ECONNRESET
      raise
    rescue => e
      Clog.emit("Exception in KubernetesNode pulse check", Util.exception_to_hash(e, into: {ubid:}))
      "down"
    end
    pulse = aggregate_readings(previous_pulse:, reading:)

    if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30 && !checkup_set?
      incr_checkup
    end

    pulse
  end

  def available?
    check_mesh_availability[:available]
  rescue => e
    Clog.emit("Failed to check mesh availability", Util.exception_to_hash(e, into: {ubid:}))
    false
  end

  # ssh_session is optional to allow nexus to call available? without an active session
  def check_mesh_availability(ssh_session = nil)
    file_content = if ssh_session
      ssh_session.exec!("cat :MESH_STATUS_FILE_PATH 2>/dev/null || echo -n", MESH_STATUS_FILE_PATH:)
    else
      sshable.cmd("cat :MESH_STATUS_FILE_PATH 2>/dev/null || echo -n", MESH_STATUS_FILE_PATH:)
    end

    if file_content.empty?
      return {available: true} # File doesn't exist yet - CSI not updated, consider healthy
    end

    status = JSON.parse(file_content)
    pods_status = status["pods"]
    external_status = status["external_endpoints"]
    mtr_results = status["mtr_results"]&.map { |name, v| v.merge("name" => name) }
    api_error = status["api_error"]

    if api_error
      return {available: false, api_error:, mtr_results:}
    end

    unreachable_pods = pods_status.select { |_, v| v["reachable"] == false }
    unreachable_external = external_status.select { |_, v| v["reachable"] == false }

    if unreachable_pods.any? || unreachable_external.any?
      {
        available: false,
        unreachable_pods: unreachable_pods.keys,
        unreachable_external: unreachable_external.keys,
        pod_errors: unreachable_pods.map { |name, v| v.merge("name" => name) },
        external_errors: unreachable_external.map { |name, v| v.merge("name" => name) },
        mtr_results:
      }
    else
      {available: true}
    end
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

  def install_rhizome
    Strand.create(prog: "InstallRhizome", label: "start", stack: [{subject_id: vm.sshable.id, target_folder: "kubernetes"}])
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
