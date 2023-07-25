# frozen_string_literal: true

require_relative "../model"

class Vm < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm_host
  one_to_many :private_subnets, key: :vm_id, class: :VmPrivateSubnet
  one_to_many :ipsec_tunnels, key: :src_vm_id
  one_to_one :sshable, key: :id
  one_to_one :assigned_vm_address, key: :dst_vm_id, class: :AssignedVmAddress
  one_to_many :vm_storage_volumes, key: :vm_id

  dataset_module Authorization::Dataset

  include ResourceMethods
  include SemaphoreMethods
  semaphore :destroy, :refresh_mesh

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

  class Product < Struct.new(:manufacturer, :year, :cores, :ram, keyword_init: true)
    def initialize(**args)
      %i[year cores ram].each {
        args[_1] = args[_1].to_s
      }
      super(**args)

      # Used for the side effect of eagerly raising errors if the
      # input cannot be rendered.
      to_s
    end

    def to_s
      "#{manufacturer}#{year}-#{self.class.sort_padded(cores)}c-#{self.class.sort_padded(ram)}r"
    end

    MATCHER = /(?<manufacturer>[a-z]+)(?<year>\d+)-[t-w]?(?<cores>\d+(?:\.\d+)?)c-[t-w]?(?<ram>\d+(?:\.\d+)?)r/

    def self.parse(s)
      fail "BUG: cannot parse vm size" unless (match = MATCHER.match(s))
      new(**match.named_captures.transform_keys(&:intern))
    end

    def self.sort_padded(number)
      rendered = number.to_s
      return rendered if rendered.include?(".")

      case rendered.length
      when 1
        ""
      when 2
        "t"
      when 3
        "u"
      when 4
        "v"
      when 5
        "w"
      else
        fail "BUG: unsupported number of digits"
      end + rendered
    end
  end

  def product
    @product ||= Product.parse(size)
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
    Integer(product.cores)
  end

  def mem_gib
    Integer(product.ram)
  end

  def mem_gib_ratio
    mem_gib.to_f / cores
  end

  def self.ubid_to_name(id)
    id.to_s[0..7]
  end

  def inhost_name
    # YYY: various names in linux, like interface names, are obliged
    # to be short, so alas, probably can't reproduce entropy from
    # vm.id to be collision free and there will need to be a second
    # addressing scheme scoped to each VmHost.  But for now, assume
    # entropy.
    self.class.ubid_to_name(UBID.from_uuidish(id))
  end

  def storage_size_gib
    vm_storage_volumes.map { _1.size_gib }.sum
  end

  def storage_encrypted?
    vm_storage_volumes.all? { !_1.key_encryption_key_1_id.nil? }
  end
end
