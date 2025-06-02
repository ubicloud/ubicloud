# frozen_string_literal: true

require_relative "../../common/lib/util"

class HugepagesSetup
  def initialize(instance)
    @version, @cluster = instance.split("-", 2)
  end

  def hugepage_size_kib
    r('awk \'/Hugepagesize/ {printf "%.2f\n", $2}\' /proc/meminfo').to_f
  end

  def get_postgres_param(param)
    r "sudo -u postgres /usr/lib/postgresql/#{@version}/bin/postgres -D /dat/#{@version}/data -c config_file=/etc/postgresql/#{@version}/#{@cluster}/postgresql.conf -C #{param.shellescape}"
  end

  def shared_buffers_kib
    shared_buffers_blocks = get_postgres_param("shared_buffers").to_f
    block_size_bytes = get_postgres_param("block_size").to_f

    shared_buffers_blocks * block_size_bytes / 1024
  end

  def stop_postgres_cluster
    r "sudo pg_ctlcluster stop #{@version} #{@cluster}", expect: [0, 2] # 2 is "not running"
  end

  def hugepages_count
    @hugepages_count ||= begin
      shared_memory_size_kib = 1024 * get_postgres_param("shared_memory_size").to_f
      (shared_memory_size_kib / hugepage_size_kib).ceil
    end
  end

  def setup_postgres_hugepages
    shared_memory_size_kib = 1024 * get_postgres_param("shared_memory_size").to_f
    hugepages_kib = hugepages_count * hugepage_size_kib
    update_postgres_hugepages_conf(hugepages_kib.ceil)

    # Get the updated shared_memory_size from the postgres config, and remove
    # the overhead from shared_buffers.
    new_shared_memory_size_kib = 1024 * get_postgres_param("shared_memory_size").to_f
    additional_shared_memory_kib = new_shared_memory_size_kib - shared_memory_size_kib

    reduced_shared_buffers_kib = shared_buffers_kib - additional_shared_memory_kib
    update_postgres_hugepages_conf(reduced_shared_buffers_kib.floor)
  end

  def setup_system_hugepages
    r "echo 'vm.nr_hugepages = #{hugepages_count}' | sudo tee /etc/sysctl.d/10-hugepages.conf"
    r "sudo sysctl --system"
  end

  def update_postgres_hugepages_conf(shared_buffers_kib)
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
      setup_postgres_hugepages
      setup_system_hugepages
    end
  end
end
