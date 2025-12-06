# frozen_string_literal: true

require_relative "../model"

class VmHostSlice < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm_host
  one_to_many :vms
  one_to_many :cpus, class: :VmHostCpu, key: :vm_host_slice_id

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :start_after_host_reboot, :checkup
  include HealthMonitorMethods

  plugin :association_dependencies, cpus: :nullify

  # We use cgroup format here, which looks like:
  # 2-3,6-10
  # (comma-separated ranges of cpus)
  def allowed_cpus_cgroup
    @allowed_cpus_cgroup ||= cpus.map(&:cpu_number).sort.slice_when { |a, b| b != a + 1 }.map do |group|
      (group.size > 1) ? "#{group.first}-#{group.last}" : group.first
    end.join(",")
  end

  # It allocates the CPUs to the slice and updates the slice's cores and total_cpu_percent
  # Input (allowed_cpus) should be a list of cpu numbers.
  def set_allowed_cpus(allowed_cpus)
    vm_host_cpu = Sequel[:vm_host_cpu]
    allocated_cpus = vm_host.cpus_dataset.where(
      vm_host_cpu[:spdk] => false,
      vm_host_cpu[:vm_host_slice_id] => nil,
      vm_host_cpu[:cpu_number] => allowed_cpus
    ).update(vm_host_slice_id: id)

    # A concurrent xact might take some of the CPUs, so check if we got them all
    fail "Not enough CPUs available." if allocated_cpus != allowed_cpus.size

    # Get the proportion of cores to cpus from the host
    threads_per_core = vm_host.total_cpus / vm_host.total_cores

    update(cores: allocated_cpus / threads_per_core, total_cpu_percent: allocated_cpus * 100)
  end

  # Returns the name as used by systemctl and cgroup
  def inhost_name
    name + ".slice"
  end

  def init_health_monitor_session
    {
      ssh_session: vm_host.sshable.start_fresh_session
    }
  end

  def up?(session)
    # We let callers handle exceptions, as each calling method may have opt to handle them differently
    session.exec!("systemctl is-active :inhost_name", inhost_name:).split("\n").all?("active") &&
      (session.exec!("cat /sys/fs/cgroup/:inhost_name/cpuset.cpus.effective", inhost_name:).chomp == allowed_cpus_cgroup) &&
      ["root", "member"].include?(session.exec!("cat /sys/fs/cgroup/:inhost_name/cpuset.cpus.partition", inhost_name:).chomp)
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      up?(session[:ssh_session]) ? "up" : "down"
    rescue
      "down"
    end
    pulse = aggregate_readings(previous_pulse: previous_pulse, reading: reading)

    if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30 && !reload.checkup_set?
      incr_checkup
    end

    pulse
  end

  def validate
    super
    errors.add(:name, "is not present") if name && name.empty?
    errors.add(:family, "is not present") if family && family.empty?
    errors.add(:name, "cannot be 'user' or 'system'") if name == "user" || name == "system"
    errors.add(:name, "cannot contain a hyphen (-)") if name&.include?("-")
  end
end

# Table: vm_host_slice
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  name              | text                     | NOT NULL
#  enabled           | boolean                  | NOT NULL DEFAULT false
#  is_shared         | boolean                  | NOT NULL DEFAULT false
#  cores             | integer                  | NOT NULL
#  total_cpu_percent | integer                  | NOT NULL
#  used_cpu_percent  | integer                  | NOT NULL
#  total_memory_gib  | integer                  | NOT NULL
#  used_memory_gib   | integer                  | NOT NULL
#  family            | text                     | NOT NULL
#  created_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  vm_host_id        | uuid                     | NOT NULL
# Indexes:
#  vm_host_slice_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  cores_not_negative       | (cores >= 0)
#  cpu_allocation_limit     | (used_cpu_percent <= total_cpu_percent)
#  memory_allocation_limit  | (used_memory_gib <= total_memory_gib)
#  used_cpu_not_negative    | (used_cpu_percent >= 0)
#  used_memory_not_negative | (used_memory_gib >= 0)
# Foreign key constraints:
#  vm_host_slice_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  vm          | vm_vm_host_slice_id_fkey          | (vm_host_slice_id) REFERENCES vm_host_slice(id)
#  vm_host_cpu | vm_host_cpu_vm_host_slice_id_fkey | (vm_host_slice_id) REFERENCES vm_host_slice(id)
