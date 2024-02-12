# frozen_string_literal: true

require_relative "../model"

class Vm < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm_host
  one_to_many :nics, key: :vm_id, class: :Nic
  many_to_many :private_subnets, join_table: Nic.table_name, left_key: :vm_id, right_key: :private_subnet_id
  one_to_one :sshable, key: :id
  one_to_one :assigned_vm_address, key: :dst_vm_id, class: :AssignedVmAddress
  one_to_many :vm_storage_volumes, key: :vm_id
  one_to_one :active_billing_record, class: :BillingRecord, key: :resource_id do |ds| ds.active end
  one_to_many :firewalls, key: :vm_id

  plugin :association_dependencies, sshable: :destroy, assigned_vm_address: :destroy, vm_storage_volumes: :destroy, firewalls: :destroy

  dataset_module Authorization::Dataset

  include ResourceMethods
  include SemaphoreMethods
  semaphore :destroy, :start_after_host_reboot, :prevent_destroy, :update_firewall_rules

  include Authorization::HyperTagMethods

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/vm/#{name}"
  end

  include Authorization::TaggableMethods

  def path
    "/location/#{location}/vm/#{name}"
  end

  def ephemeral_net4
    assigned_vm_address&.ip&.network
  end

  def ip4
    assigned_vm_address&.ip
  end

  def display_state
    return "deleting" if destroy_set?
    super
  end

  def mem_gib_ratio
    return 3.2 if arch == "arm64"
    8
  end

  def mem_gib
    (cores * mem_gib_ratio).to_i
  end

  # cloud-hypervisor takes topology information in this format:
  #
  # topology=<threads_per_core>:<cores_per_die>:<dies_per_package>:<packages>
  #
  # And the result of multiplication must equal the thread/vcpu count
  # we wish to allocate:
  #
  #     let total = t.threads_per_core * t.cores_per_die * t.dies_per_package * t.packages;
  #     if total != self.cpus.max_vcpus {
  #         return Err(ValidationError::CpuTopologyCount);
  #     }
  CloudHypervisorCpuTopo = Struct.new(:threads_per_core, :cores_per_die, :dies_per_package, :packages) do
    def to_s
      to_a.map(&:to_s).join(":")
    end

    def max_vcpus
      @max_vcpus ||= to_a.reduce(&:*)
    end
  end

  def cloud_hypervisor_cpu_topology
    threads_per_core, r = vm_host.total_cpus.divmod vm_host.total_cores
    fail "BUG" unless r.zero?

    total_dies_per_package, r = vm_host.total_dies.divmod vm_host.total_sockets
    fail "BUG" unless r.zero?

    total_packages = vm_host.total_sockets

    # Computed all-system statistics, now scale it down to meet VM needs.
    proportion = Rational(cores) / vm_host.total_cores
    packages = (total_packages * proportion).ceil
    dies_per_package = (total_dies_per_package * proportion).ceil
    cores_per_die = Rational(cores) / (packages * dies_per_package)
    fail "BUG: need uniform number of cores allocated per die" unless cores_per_die.denominator == 1

    topo = [threads_per_core, cores_per_die, dies_per_package, packages].map { |num|
      # :nocov:
      fail "BUG: non-integer in topology array" unless num.denominator == 1
      # :nocov:
      Integer(num)
    }

    # :nocov:
    unless topo.reduce(&:*) == threads_per_core * cores
      fail "BUG: arithmetic does not result in the correct number of vcpus"
    end
    # :nocov:

    CloudHypervisorCpuTopo.new(*topo)
  end

  def display_size
    # With additional product families, it is likely that we hit a
    # case where this conversion wouldn't work. We can use map or
    # when/case block at that time.

    # Define suffix integer as 2 * numcores. This coincides with
    # SMT-enabled x86 processors, to give people the right idea if
    # they compare the product code integer to the preponderance of
    # spec sheets on the web.
    #
    # With non-SMT processors, maybe we'll keep it that way too,
    # even though it doesn't describe any attribute about the
    # processor.  But, it does allow "standard-2" is compared to
    # another "standard-2" variant regardless of SMT,
    # e.g. "standard-2-arm", instead of making people interpreting
    # the code adjust the scale factor to do the comparison
    # themselves.
    #
    # Another weakness of this approach, besides it being indirect
    # in description of non-SMT processors, is having "standard-2"
    # be the smallest unit of product is also noisier than
    # "standard-1".
    "#{family}-#{cores * 2}"
  end

  # Various names in linux, like interface names, are obliged to be
  # short, so truncate the ubid. This does introduce the spectre of
  # collisions.  When the time comes, we'll have to ensure it doesn't
  # happen on a single host, pushing into the allocation process.
  def self.ubid_to_name(id)
    id.to_s[0..7]
  end

  def inhost_name
    self.class.ubid_to_name(UBID.from_uuidish(id))
  end

  def storage_size_gib
    vm_storage_volumes.map { _1.size_gib }.sum
  end

  def storage_encrypted?
    vm_storage_volumes.all? { !_1.key_encryption_key_1_id.nil? }
  end

  def self.redacted_columns
    super + [:public_key]
  end
end
