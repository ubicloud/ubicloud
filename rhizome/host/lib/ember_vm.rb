# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "ember_config"
require "fileutils"
require "json"
require "socket"

class EmberVm
  attr_reader :slot

  def initialize(slot, ch_version:)
    @slot = slot
    @ch_version = ch_version
  end

  def api_sock = File.join(@slot.dir, "ch-api.sock")

  def serial_log = File.join(@slot.dir, "serial.log")

  def restore_dir = File.join(@slot.dir, "restore")

  def unit = "#{@slot.name}.service"

  def ch_bin = "/opt/cloud-hypervisor/v#{@ch_version}/cloud-hypervisor"

  def prepare_restore(template_dir)
    FileUtils.rm_rf(restore_dir)
    FileUtils.mkdir_p(restore_dir)

    config = JSON.parse(File.read(File.join(template_dir, "config.json")))
    config["serial"]["file"] = serial_log if config.dig("serial", "file")
    own_config = File.join(restore_dir, "config.json")
    File.write(own_config, JSON.generate(config))

    Dir.children(template_dir).each do |entry|
      next if entry == "config.json"
      source = File.join(template_dir, entry)
      target = File.join(restore_dir, entry)
      begin
        File.link(source, target)
      rescue SystemCallError
        FileUtils.cp(source, target)
      end
    end

    FileUtils.chown(@slot.name, @slot.name, [@slot.dir, restore_dir, own_config])
    restore_dir
  end

  def start(cpu_percent_limit:)
    clean_paths
    write_unit("Ember #{@slot.name}",
      "--api-socket path=#{api_sock} --restore source_url=file://#{restore_dir},memory_restore_mode=ondemand,resume=true",
      cpu_quota: "CPUQuota=#{cpu_percent_limit}%")
    r("systemctl", "daemon-reload")
    r("systemctl", "start", unit)
    wait_api
    wait_state("Running")
  end

  def boot(root_image:, memory_mib:, vcpus:)
    clean_paths
    FileUtils.rm_f(serial_log)
    write_unit("Ember template build #{@slot.name}", [
      "--api-socket path=#{api_sock}",
      "--kernel /opt/fw/CLOUDHV-202311.fd",
      "--disk path=#{root_image},readonly=on,id=root",
      "--console off --serial file=#{serial_log}",
      "--cpus boot=#{vcpus}",
      "--memory size=#{memory_mib}M,shared=on",
      "--net mac=#{EmberConfig::GUEST_MAC},tap=cltap,ip=,mask=,num_queues=#{(vcpus * 2) + 1}",
      "--balloon size=0,free_page_reporting=on",
      "--rng src=/dev/urandom",
    ].join(" "))
    r("systemctl", "daemon-reload")
    r("systemctl", "start", unit)
    wait_api(timeout: 120)
  end

  def write_unit(description, args, cpu_quota: nil)
    safe_write_to_file("/etc/systemd/system/#{unit}", <<~UNIT)
      [Unit]
      Description=#{description}
      After=network.target

      [Service]
      Slice=ember.slice
      #{cpu_quota}
      NetworkNamespacePath=/var/run/netns/#{@slot.netns}
      User=#{@slot.name}
      Group=#{@slot.name}
      AmbientCapabilities=CAP_NET_ADMIN
      CapabilityBoundingSet=CAP_NET_ADMIN
      ExecStartPre=/usr/bin/rm -f #{api_sock}
      ExecStart=#{ch_bin} -v #{args}
      Restart=no
      KillMode=process

      [Install]
      WantedBy=multi-user.target
    UNIT
  end

  def clean_paths
    [api_sock, "#{api_sock}.lock"].each { |path| FileUtils.rm_f(path) }
    FileUtils.mkdir_p(@slot.dir)
  end

  def pause_vm
    api_put("/api/v1/vm.pause")
  end

  def power_button
    api_put("/api/v1/vm.power-button")
  end

  def wait_exit(timeout:)
    deadline = monotonic + timeout
    loop do
      code, = api_get("/api/v1/vmm.ping")
      return true if code.nil?
      return false if monotonic > deadline
      sleep 0.005
    end
  end

  def wait_serial(marker, timeout:)
    deadline = monotonic + timeout
    loop do
      return true if File.exist?(serial_log) && File.read(serial_log, mode: "rb").include?(marker)
      raise "#{@slot.name} never printed #{marker}" if monotonic > deadline
      sleep 0.1
    end
  end

  def snapshot(destination_dir)
    FileUtils.mkdir_p(destination_dir)
    FileUtils.chown(@slot.name, @slot.name, destination_dir)
    result = api_put("/api/v1/vm.snapshot", {"destination_url" => "file://#{destination_dir}"})

    FileUtils.chown_R("root", "root", destination_dir)
    File.chmod(0o755, destination_dir)
    Dir.children(destination_dir).each { |f| File.chmod(0o644, File.join(destination_dir, f)) }
    result
  end

  def add_disk(vhost_socket)
    api_put("/api/v1/vm.add-disk", {
      "vhost_user" => true, "vhost_socket" => vhost_socket, "num_queues" => 1, "queue_size" => 64, "id" => "data",
    })
  end

  def shutdown
    begin
      api_put("/api/v1/vmm.shutdown")
    rescue
      nil
    end
    deadline = monotonic + 10
    sleep 0.01 while running? && monotonic < deadline
    r("systemctl", "stop", unit)
  rescue CommandFail
    nil
  ensure
    FileUtils.rm_f("/etc/systemd/system/#{unit}")
  end

  def running?
    r("systemctl", "is-active", "--quiet", unit)
    true
  rescue CommandFail
    false
  end

  def state
    code, body = api_get("/api/v1/vm.info")
    return nil unless code == 200
    JSON.parse(body)["state"]
  rescue JSON::ParserError
    nil
  end

  def wait_api(timeout: 30)
    deadline = monotonic + timeout
    loop do
      code, = api_get("/api/v1/vmm.ping")
      return true if code == 200
      raise "cloud-hypervisor never answered for #{@slot.name}" if monotonic > deadline
      sleep 0.0005
    end
  end

  def wait_state(want)
    deadline = monotonic + 30
    loop do
      return true if state == want
      raise "#{@slot.name} never reached #{want}" if monotonic > deadline
      sleep 0.0005
    end
  end

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def api_get(path)
    socket = UNIXSocket.new(api_sock)
    socket.write("GET #{path} HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\n\r\n")
    read_http(socket)
  rescue SystemCallError
    [nil, nil]
  end

  def api_put(path, body = nil)
    headers = "PUT #{path} HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\n"
    payload = +""
    if body
      payload << JSON.generate(body)
      headers << "Content-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\n"
    end
    socket = UNIXSocket.new(api_sock)
    socket.write("#{headers}\r\n#{payload}")
    code, response = read_http(socket)
    raise "cloud-hypervisor #{path} returned #{code}: #{response}" unless (200..299).cover?(code.to_i)
    response
  end

  def read_http(socket)
    raw = +""
    loop do
      break unless IO.select([socket], nil, nil, 30)
      chunk = socket.read_nonblock(65_536, exception: false)
      break if chunk.nil?
      next if chunk == :wait_readable
      raw << chunk
      break if raw.include?("\r\n\r\n") && complete_body?(raw)
    end
    socket.close
    head, _, body = raw.partition("\r\n\r\n")
    [head.lines.first.to_s.split[1].to_i, body]
  end

  def complete_body?(raw)
    head, _, body = raw.partition("\r\n\r\n")
    length = head[/Content-Length: (\d+)/i, 1]
    length.nil? || body.bytesize >= length.to_i
  end
end
