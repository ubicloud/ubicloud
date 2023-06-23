# frozen_string_literal: true

require_relative "../model"

class Vm < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm_host
  one_to_many :vm_private_subnet, key: :vm_id
  one_to_many :ipsec_tunnels, key: :src_vm_id
  one_to_one :sshable, key: :id
  one_to_one :assigned_vm_address, key: :dst_vm_id, class: :AssignedVmAddress
  one_to_many :vm_storage_volumes, key: :vm_id

  dataset_module Authorization::Dataset

  include ResourceMethods
  include SemaphoreMethods
  semaphore :destroy, :refresh_mesh

  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  def private_subnets
    vm_private_subnet.map { [_1.private_subnet, _1.net4] }
  end

  def path
    "/vm/#{ulid}"
  end

  def ephemeral_net4
    assigned_vm_address&.ip&.nth(1)
  end

  def ip4
    assigned_vm_address&.ip
  end

  Product = Struct.new(:line, :cores)

  def product
    return @product if @product
    fail "BUG: cannot parse vm size" unless size =~ /\A(.*)\.(\d+)x\z/
    line = $1

    # YYY: Hack to deal with the presentation currently being in
    # "vcpu" which has a pretty specific meaning being ambigious to
    # threads or actual cores.
    #
    # The presentation is currently helpful because our bare metal
    # sizes are quite small, supporting only 1, 2, 3 cores (reserving
    # one for ourselves) and 2, 4, 6 vcpu.  So the product line is
    # ambiguous as to whether it's ordinal or descriptive (it's
    # descriptive).  To convey the right thing in demonstration, use
    # vcpu counts.  It would have been nice to have gotten bigger
    # hardware in time to avoid that and standardize on cores.
    #
    # As an aside, although we probably want to reserve a core an I/O
    # process of some kind (e.g. SPDK, reserving the entire memory
    # quota for it may be overkill.
    cores = Integer($2) / 2
    @product = Product.new(line, cores)
  end

  def mem_gib_ratio
    @mem_gib_ratio ||= case product.line
    when "m5a"
      4
    when "c5a"
      2
    else
      fail "BUG: unrecognized product line"
    end
  end

  def mem_gib
    product.cores * mem_gib_ratio
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

    total_dies_per_package, r = vm_host.total_nodes.divmod vm_host.total_sockets
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

  def cores
    product.cores
  end

  def self.uuid_to_name(id)
    "vm" + ULID.from_uuidish(id).to_s[0..5].downcase
  end

  def inhost_name
    # YYY: various names in linux, like interface names, are obliged
    # to be short, so alas, probably can't reproduce entropy from
    # vm.id to be collision free and there will need to be a second
    # addressing scheme scoped to each VmHost.  But for now, assume
    # entropy.
    self.class.uuid_to_name(id)
  end

  def storage_size_gib
    vm_storage_volumes.map { _1.size_gib }.sum
  end
end
