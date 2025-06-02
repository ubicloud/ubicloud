# frozen_string_literal: true

require_relative "../../common/lib/util"

class HugepagesSetup
  def initialize(instance)
    @version, @cluster = instance.split("-", 2)
  end

  def hugepage_size_kib
    (r 'awk \'/Hugepagesize/ {printf "%.2f\n", $2}\' /proc/meminfo').to_f
  end

  def get_postgres_param(param)
    r "sudo -u postgres /usr/lib/postgresql/#{@version}/bin/postgres -D /dat/#{@version}/data -c config_file=/etc/postgresql/#{@version}/#{@cluster}/postgresql.conf -C #{param}"
  end

  def shared_buffers_kib
    shared_buffers_blocks = get_postgres_param("shared_buffers").to_f
    block_size_bytes = get_postgres_param("block_size").to_f

    shared_buffers_blocks * block_size_bytes / 1024
  end

  def stop_postgres_cluster
    r "sudo pg_ctlcluster stop #{@version} #{@cluster}", expect: [0, 2] # 2 is "not running"
  end

  def hugepages_config
    shared_memory_size_kib = 1024 * get_postgres_param("shared_memory_size").to_f
    hugepages_count = shared_memory_size_kib / hugepage_size_kib

    # Round up to the nearest number of huge pages if the last huge page is >
    # 50% full.
    hugepages_fractional = hugepages_count % 1

    if hugepages_fractional > 0.5
      additional_hugepages = 1 - hugepages_fractional
      additional_shared_buffers_kib = (additional_hugepages * hugepage_size_kib).floor

      {
        hugepages_count: hugepages_count.ceil.to_i,
        shared_buffers_kib: (shared_buffers_kib + additional_shared_buffers_kib).to_i
      }
    else
      excess_shared_buffers_kib = (hugepages_fractional * hugepage_size_kib).ceil

      {
        hugepages_count: hugepages_count.floor.to_i,
        shared_buffers_kib: (shared_buffers_kib - excess_shared_buffers_kib).to_i
      }
    end
  end

  def setup_system_hugepages(hugepages_count)
    r "echo 'vm.nr_hugepages = #{hugepages_count}' | sudo tee /etc/sysctl.d/10-hugepages.conf"
    r "sudo sysctl --system"
  end

  def setup_postgres_hugepages(shared_buffers_kib)
    File.write("/etc/postgresql/#{@version}/#{@cluster}/conf.d/002-hugepages.conf", <<CONF
huge_pages = 'on'
huge_page_size = 0
shared_buffers = #{shared_buffers_kib}kB
CONF
    )
  end

  def postgres_running?
    r "sudo pg_ctlcluster status #{@version} #{@cluster}", expect: [3]
    false
  rescue CommandFail
    true
  end

  def setup
    # If postgres is already running, we don't change the hugepages
    # configuration.
    unless postgres_running?
      stop_postgres_cluster
      config = hugepages_config
      setup_system_hugepages(config[:hugepages_count])
      setup_postgres_hugepages(config[:shared_buffers_kib])
    end
  end
end
