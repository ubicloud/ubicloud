# frozen_string_literal: true

require_relative "../../common/lib/util"
require "logger"

class VirtualMemorySetup
  def initialize(instance, logger)
    @version, @cluster = instance.split("-", 2)
    @logger = logger
  end

  def get_postgres_param(param)
    Integer(r("sudo -u postgres /usr/lib/postgresql/#{@version.shellescape}/bin/postgres -D /dat/#{@version.shellescape}/data -c config_file=/etc/postgresql/#{@version.shellescape}/#{@cluster.shellescape}/postgresql.conf -C #{param.shellescape}"), 10)
  end

  def hugepage_info
    meminfo = File.read("/proc/meminfo")
    hugepages_count = Integer(meminfo[/^HugePages_Total:\s*(\d+)/, 1], 10)
    hugepage_size_kib = Integer(meminfo[/^Hugepagesize:\s*(\d+)\s*kB/, 1], 10)
    [hugepages_count, hugepage_size_kib]
  end

  def stop_postgres_cluster
    r "sudo pg_ctlcluster stop #{@version} #{@cluster}", expect: [0, 2] # 2 is "not running"
  end

  def setup_postgres_hugepages
    hugepages_count, hugepage_size_kib = hugepage_info

    if hugepages_count == 0
      @logger.warn("No hugepages configured, skipping setup.")
      return
    end

    hugepages_kib = hugepages_count * hugepage_size_kib
    update_postgres_hugepages_conf(hugepages_kib)

    shmem_and_overhead_kib = 1024 * get_postgres_param("shared_memory_size")
    overhead = shmem_and_overhead_kib - hugepages_kib

    target_kib = hugepages_kib - overhead

    # Floor division to nearest multiple of block_size: (a / b) * b
    block_size_bytes = get_postgres_param("block_size")
    block_size_kib = block_size_bytes / 1024
    final_shared_buffers_kib = (target_kib / block_size_kib) * block_size_kib

    update_postgres_hugepages_conf(final_shared_buffers_kib)
  end

  def update_postgres_hugepages_conf(shared_buffers_kib)
    safe_write_to_file("/etc/postgresql/#{@version}/#{@cluster}/conf.d/002-hugepages.conf", <<CONF
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

  def configure_memory_overcommit
    r "sudo sysctl -w vm.overcommit_memory=2"
    r "echo 'vm.overcommit_memory=2' | sudo tee -a /etc/sysctl.conf"

    meminfo = File.read("/proc/meminfo")
    mem_total_kb = Integer(meminfo[/^MemTotal:\s*(\d+)/, 1], 10)
    hugepages_total, hugepage_size_kb = hugepage_info
    hugepages_kb = hugepages_total * hugepage_size_kb

    # Calculate overcommit_kbytes as 256 MiB + 1.75 * (MemTotal - HugePages)
    overcommit_kbytes = (256 * 1024) + (1.75 * (mem_total_kb - hugepages_kb)).round

    r "sudo sysctl -w vm.overcommit_kbytes=#{overcommit_kbytes}"
    r "echo 'vm.overcommit_kbytes=#{overcommit_kbytes}' | sudo tee -a /etc/sysctl.conf"
  end

  def setup
    unless postgres_running?
      stop_postgres_cluster
      setup_postgres_hugepages
    end
    configure_memory_overcommit
  end
end
