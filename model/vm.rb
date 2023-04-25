# frozen_string_literal: true

require_relative "../model"

class Vm < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm_host
  one_to_many :vm_private_subnet, key: :vm_id
  one_to_many :ipsec_tunnels, key: :src_vm_id
  one_to_one :minio_node

  include SemaphoreMethods
  semaphore :destroy, :refresh_mesh

  def private_subnets
    vm_private_subnet.map { _1.private_subnet }
  end

  Product = Struct.new(:line, :cores)

  def product
    return @product if @product
    fail "BUG: cannot parse vm size" unless size =~ /\A(.*)-(\d+)\z/
    line = $1
    cores = Integer($2)
    @product = Product.new(line, cores)
  end

  def mem_gib_ratio
    @mem_gib_ratio ||= case product.line
    when "standard"
      4
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
    fail "BUG" unless r == 0

    total_dies_per_package, r = vm_host.total_nodes.divmod vm_host.total_sockets
    fail "BUG" unless r == 0

    total_packages = vm_host.total_sockets

    # Computed all-system statistics, now scale it down to meet VM needs.
    proportion = Rational(cores) / vm_host.total_cores
    packages = (total_packages * proportion).ceil
    dies_per_package = (total_dies_per_package * proportion).ceil
    cores_per_die = Rational(cores) / (packages * dies_per_package)
    fail "BUG: need uniform number of cores allocated per die" unless cores_per_die.denominator == 1

    topo = [threads_per_core, cores_per_die, dies_per_package, packages].map { |num|
      fail "BUG: non-integer in topology array" if num.denominator != 1
      Integer(num)
    }

    unless topo.reduce(&:*) == threads_per_core * cores
      fail "BUG: arithmetic does not result in the correct number of vcpus"
    end

    CloudHypervisorCpuTopo.new(*topo)
  end

  def cores
    product.cores
  end
end
