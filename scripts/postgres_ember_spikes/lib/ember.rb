# frozen_string_literal: true

# Harness for the Postgres Ember spikes (design doc section 12). Runs on a
# ember host as root. Deliberately standalone: it drives cloud-hypervisor and
# ubiblk directly so the measurements are not confounded by strand scheduling.

require "base64"
require "fileutils"
require "json"
require "openssl"
require "securerandom"
require "socket"
require "timeout"

module Spike
  CH_DIR = "/opt/cloud-hypervisor/v53.0"
  CH_BIN = "#{CH_DIR}/cloud-hypervisor"
  CH_REMOTE = "#{CH_DIR}/ch-remote"
  FIRMWARE = "/opt/fw/CLOUDHV-202311.fd"
  # UBIBLK_DIR=/opt/vhost-block-backend/<version> selects a specific build,
  # which is how the patched and stock builds are compared.
  UBIBLK_DIR = ENV["UBIBLK_DIR"] || Dir["/opt/vhost-block-backend/v*"].max
  SB = "/var/storage/ember"
  IMAGES = "#{SB}/images"
  TEMPLATES = "#{SB}/templates"
  VOLUMES = "/var/storage/detachable"
  VMROOT = "/vm"
  GUEST_MAC = "02:5b:0c:00:00:02"
  GUEST_IP6 = "fd00:b1c:5b0c::2"
  GATEWAY_IP6 = "fd00:b1c:5b0c::1"
  AGENT_PORT = 5000

  module_function

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def ms(t0)
    ((now - t0) * 1000).round(1)
  end

  def sh(*cmd, check: true)
    out = IO.popen([*cmd.map(&:to_s), {err: [:child, :out]}], &:read)
    st = $?
    raise "command failed (#{st.exitstatus}): #{cmd.join(" ")}\n#{out}" if check && !st.success?
    out
  end

  def host_prefix
    @host_prefix ||= begin
      dev = sh("sh", "-c", "ip -6 route show default | awk '{print $5}'").strip
      addr = sh("sh", "-c", "ip -6 -o addr show dev #{dev} scope global | awk '{print $4}' | head -1").strip
      addr.split("/").first.sub(/::?\d*$/, "").split(":")[0, 4].join(":")
    end
  end

  def percentile(sorted, p)
    return nil if sorted.empty?
    idx = ((sorted.length - 1) * p / 100.0).round
    sorted[idx]
  end

  def summarize(label, samples)
    s = samples.compact.sort
    return "#{label}: no samples" if s.empty?
    format("%-22s n=%-3d min=%-7.1f p50=%-7.1f p95=%-7.1f max=%-7.1f",
      label, s.length, s.first, percentile(s, 50), percentile(s, 95), s.last)
  end

  # A pre-built network namespace holding one ember VM (design doc 5.2).
  class Slot
    attr_reader :n, :name, :netns, :dir

    def initialize(n)
      @n = n
      @name = format("emslot%04d", n)
      @netns = @name
      @dir = File.join(VMROOT, @name)
    end

    def public_ip6
      "#{Spike.host_prefix}:5b0c::#{@n.to_s(16)}"
    end

    def vetho = "vetho#{@n}"

    def vethi = "vethi#{@n}"

    def link_host = "fd00:b1c:ffff:#{@n.to_s(16)}::1"

    def link_ns = "fd00:b1c:ffff:#{@n.to_s(16)}::2"

    def ns(*cmd, check: true)
      Spike.sh("ip", "netns", "exec", @netns, *cmd, check:)
    end

    def exists?
      File.exist?("/var/run/netns/#{@netns}")
    end

    def create(gateway_sources: ["::/0"])
      destroy
      FileUtils.mkdir_p(@dir)
      Spike.sh("ip", "netns", "add", @netns)
      Spike.sh("ip", "link", "add", vetho, "type", "veth", "peer", "name", vethi)
      Spike.sh("ip", "link", "set", vethi, "netns", @netns)
      Spike.sh("ip", "addr", "add", "#{link_host}/64", "dev", vetho, "nodad")
      Spike.sh("ip", "link", "set", vetho, "up")
      ns("ip", "link", "set", "lo", "up")
      ns("sysctl", "-q", "-w", "net.ipv6.conf.all.forwarding=1")
      ns("sysctl", "-q", "-w", "net.ipv6.conf.all.accept_ra=0")
      ns("ip", "addr", "add", "#{link_ns}/64", "dev", vethi, "nodad")
      ns("ip", "link", "set", vethi, "up")
      ns("ip", "tuntap", "add", "dev", "cltap", "mode", "tap")
      ns("ip", "addr", "add", "#{GATEWAY_IP6}/64", "dev", "cltap", "nodad")
      ns("ip", "addr", "add", "10.255.255.1/30", "dev", "cltap")
      ns("ip", "link", "set", "cltap", "up")
      ns("ip", "-6", "route", "add", "default", "via", link_host, "dev", vethi)
      Spike.sh("ip", "-6", "route", "replace", "#{public_ip6}/128", "via", link_ns, "dev", vetho)
      apply_nft(gateway_sources)
      self
    end

    # Appendix E of the design doc.
    def apply_nft(gateway_sources)
      ruleset = <<~NFT
        table inet ember
        delete table inet ember
        table inet ember {
          set gateway_v6 {
            type ipv6_addr
            flags interval
            elements = { #{gateway_sources.join(", ")} }
          }
          chain prerouting { type nat hook prerouting priority dstnat; policy accept;
            ip6 daddr #{public_ip6} tcp dport 5432 dnat ip6 to [#{GUEST_IP6}]:5432
          }
          chain forward { type filter hook forward priority filter; policy drop;
            ct state established,related accept
            iifname "#{vethi}" oifname "cltap" ip6 saddr @gateway_v6 ip6 daddr #{GUEST_IP6} tcp dport 5432 ct state new accept
            iifname "cltap" drop
          }
          chain raw_pre { type filter hook prerouting priority raw; policy accept;
            iifname "cltap" ether saddr != #{GUEST_MAC} drop
            iifname "cltap" ip6 saddr != #{GUEST_IP6} ip6 saddr != fe80::/64 drop
          }
          chain input { type filter hook input priority filter; policy drop;
            ct state established,related accept
            icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert, echo-request, echo-reply } accept
            iifname "lo" accept
            iifname "#{vethi}" accept
          }
        }
      NFT
      IO.popen(["ip", "netns", "exec", @netns, "nft", "-f", "-"], "w") { _1.write(ruleset) }
      raise "nft failed for #{@netns}" unless $?.success?
    end

    def destroy
      Spike.sh("ip", "netns", "del", @netns, check: false) if exists?
      Spike.sh("ip", "link", "del", vetho, check: false)
      Spike.sh("ip", "-6", "route", "del", "#{public_ip6}/128", check: false)
    end
  end

  # Host end of the vsock link to the guest agent (design doc appendix B).
  class Agent
    def initialize(sock_path)
      @path = sock_path
    end

    def open
      @s = UNIXSocket.new(@path)
      @s.write("CONNECT #{AGENT_PORT}\n")
      line = read_line(2)
      raise "vsock CONNECT refused: #{line.inspect}" unless line.to_s.start_with?("OK")
      self
    end

    # Poll until the guest agent accepts a connection; this is the "restore
    # finished and userspace is alive" signal the restore benchmark measures to.
    def wait_ready(timeout: 60)
      deadline = Spike.now + timeout
      last = nil
      loop do
        begin
          return open
        rescue => e
          last = e
          close
        end
        raise "agent not ready after #{timeout}s: #{last}" if Spike.now > deadline
        sleep 0.001
      end
    end

    def call(command, timeout: 60, **args)
      id = SecureRandom.hex(4)
      @s.write(JSON.generate({id:, command:}.merge(args)) + "\n")
      resp = JSON.parse(read_line(timeout))
      unless resp["ok"]
        raise "agent #{command} failed: #{resp["error"]}: #{resp["detail"]}"
      end
      resp
    end

    def read_line(timeout)
      buf = +""
      deadline = Spike.now + timeout
      loop do
        remaining = deadline - Spike.now
        raise Timeout::Error, "vsock read timed out" if remaining <= 0
        raise EOFError, "vsock closed" unless IO.select([@s], nil, nil, remaining)
        chunk = @s.read_nonblock(65536, exception: false)
        raise EOFError, "vsock closed" if chunk.nil?
        next if chunk == :wait_readable
        buf << chunk
        return buf if buf.end_with?("\n")
      end
    end

    def close
      @s&.close
    rescue IOError
      nil
    ensure
      @s = nil
    end
  end

  # One cloud-hypervisor process occupying a slot.
  class Vm
    attr_reader :slot, :pid

    def initialize(slot)
      @slot = slot
    end

    def api_sock = "#{@slot.dir}/ch-api.sock"

    def vsock_sock = "#{@slot.dir}/vsock.sock"

    def serial_log = "#{@slot.dir}/serial.log"

    def ch_log = "#{@slot.dir}/ch.log"

    def clean_paths
      # cloud-hypervisor also leaves a lock file beside the API socket; a stale
      # one owned by another user makes the next start fail with EACCES.
      [api_sock, "#{api_sock}.lock", vsock_sock].each { FileUtils.rm_f(_1) }
      FileUtils.mkdir_p(@slot.dir)
    end

    def spawn_ch(args)
      log = File.open(ch_log, "a")
      @pid = Process.spawn("ip", "netns", "exec", @slot.netns, CH_BIN, *args,
        out: log, err: log, close_others: true)
      log.close
      @pid
    end

    # Cold boot used only to build a template (design doc 4.3).
    def boot(root_image:, memory_mib: 512, vcpus: 1)
      clean_paths
      FileUtils.rm_f(serial_log)
      spawn_ch([
        "-v",
        "--api-socket", "path=#{api_sock}",
        "--kernel", FIRMWARE,
        "--disk", "path=#{root_image},readonly=on,id=root",
        "--console", "off", "--serial", "file=#{serial_log}",
        "--cpus", "boot=#{vcpus}",
        "--memory", "size=#{memory_mib}M,shared=on",
        "--net", "mac=#{GUEST_MAC},tap=cltap,ip=,mask=,num_queues=#{vcpus * 2 + 1}",
        "--vsock", "cid=3,socket=#{vsock_sock}",
        "--balloon", "size=0,free_page_reporting=on",
        "--rng", "src=/dev/urandom",
      ])
    end

    # Copy the template's small files, hard-link the big one, and point the
    # per-VM paths at this slot (design doc 5.3 step 1).
    def prepare_restore_dir(template_dir, link_memory: true)
      dir = "#{@slot.dir}/restore"
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
      cfg = JSON.parse(File.read(File.join(template_dir, "config.json")))
      cfg["vsock"]["socket"] = vsock_sock if cfg["vsock"]
      if cfg["serial"] && cfg["serial"]["file"]
        cfg["serial"]["file"] = serial_log
      end
      File.write(File.join(dir, "config.json"), JSON.generate(cfg))
      Dir.children(template_dir).each do |f|
        next if f == "config.json"
        src = File.join(template_dir, f)
        dst = File.join(dir, f)
        if link_memory
          begin
            File.link(src, dst)
            next
          rescue SystemCallError
            nil
          end
        end
        FileUtils.cp(src, dst)
      end
      dir
    end

    def restore(restore_dir, memory_restore_mode: "copy", prefault: false, resume: true)
      clean_paths
      params = ["source_url=file://#{restore_dir}",
        "memory_restore_mode=#{memory_restore_mode}",
        "prefault=#{prefault ? "on" : "off"}",
        "resume=#{resume}"]
      spawn_ch(["-v", "--api-socket", "path=#{api_sock}", "--restore", params.join(",")])
    end

    def ch_remote(*args, check: true)
      Spike.sh(CH_REMOTE, "--api-socket", api_sock, *args, check:)
    end

    # Minimal HTTP client for the CH API socket: polling with ch-remote costs a
    # process spawn per sample, which is the same order as what we measure.
    def api_get(path)
      s = UNIXSocket.new(api_sock)
      s.write("GET #{path} HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\n\r\n")
      raw = +""
      while (chunk = s.read_nonblock(65536, exception: false))
        break if chunk.nil?
        if chunk == :wait_readable
          break unless IO.select([s], nil, nil, 5)
          next
        end
        raw << chunk
        break if raw.include?("\r\n\r\n") && complete_body?(raw)
      end
      s.close
      head, _, body = raw.partition("\r\n\r\n")
      [head.lines.first.to_s.split[1].to_i, body]
    rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::EPIPE
      [nil, nil]
    end

    def complete_body?(raw)
      head, _, body = raw.partition("\r\n\r\n")
      len = head[/Content-Length: (\d+)/i, 1]
      len.nil? || body.bytesize >= len.to_i
    end

    def api_put(path, body)
      payload = JSON.generate(body)
      s = UNIXSocket.new(api_sock)
      s.write("PUT #{path} HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\n" \
              "Content-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\n\r\n#{payload}")
      raw = +""
      loop do
        break unless IO.select([s], nil, nil, 30)
        chunk = s.read_nonblock(65536, exception: false)
        break if chunk.nil?
        next if chunk == :wait_readable
        raw << chunk
        break if raw.include?("\r\n\r\n") && complete_body?(raw)
      end
      s.close
      head, _, rbody = raw.partition("\r\n\r\n")
      code = head.lines.first.to_s.split[1].to_i
      raise "CH API #{path} returned #{code}: #{rbody}" unless (200..299).cover?(code)
      rbody
    end

    # Hot-plug a ubiblk volume as a vhost-user-blk device (design doc 5.3 step 4).
    def add_disk(vhost_sock:, id: "data", num_queues: 1, queue_size: 64)
      api_put("/api/v1/vm.add-disk", {
        "vhost_user" => true,
        "vhost_socket" => vhost_sock,
        "num_queues" => num_queues,
        "queue_size" => queue_size,
        "id" => id,
      })
    end

    def remove_device(id)
      api_put("/api/v1/vm.remove-device", {"id" => id})
    end

    def api_state
      code, body = api_get("/api/v1/vm.info")
      return nil unless code == 200
      JSON.parse(body)["state"]
    rescue JSON::ParserError
      nil
    end

    # Poll until the VMM answers on its API socket at all.
    def wait_api_socket(timeout: 30)
      deadline = Spike.now + timeout
      loop do
        code, = api_get("/api/v1/vmm.ping")
        return true if code == 200
        raise "api socket not ready after #{timeout}s (see #{ch_log})" if Spike.now > deadline
        sleep 0.0005
      end
    end

    def wait_state(want, timeout: 30)
      deadline = Spike.now + timeout
      loop do
        return true if api_state == want
        raise "vm never reached #{want} (see #{ch_log})" if Spike.now > deadline
        sleep 0.0005
      end
    end

    def wait_api(timeout: 30)
      deadline = Spike.now + timeout
      loop do
        return true if File.exist?(api_sock) && ch_remote("ping", check: false).include?("build_version")
        raise "api socket not ready after #{timeout}s (see #{ch_log})" if Spike.now > deadline
        sleep 0.001
      end
    end

    def state
      JSON.parse(ch_remote("info", check: false))["state"]
    rescue JSON::ParserError
      nil
    end

    def agent
      @agent ||= Agent.new(vsock_sock)
    end

    def alive?
      @pid && Process.waitpid(@pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      false
    end

    # vm.shutdown stops the guest but leaves the VMM running so it can host
    # another VM; vmm.shutdown is what makes the process exit and the slot free.
    def shutdown(timeout: 10)
      @agent&.close
      @agent = nil
      begin
        api_put("/api/v1/vmm.shutdown", {})
      rescue => e
        warn "vmm.shutdown failed: #{e.message}"
      end
      deadline = Spike.now + timeout
      while alive? && Spike.now < deadline
        sleep 0.01
      end
      kill
    end

    def kill
      return unless @pid
      begin
        Process.kill("KILL", @pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.waitpid(@pid)
      rescue Errno::ECHILD
        nil
      end
      @pid = nil
    end
  end

  # A detachable ubiblk volume that outlives the VM (design doc section 6).
  class Volume
    attr_reader :id, :dir

    def initialize(id, root: VOLUMES)
      @id = id
      @dir = File.join(root, id)
    end

    def disk_file = "#{@dir}/disk.raw"

    def metadata = "#{@dir}/metadata"

    def vhost_sock = "#{@dir}/vhost.sock"

    def rpc_sock = "#{@dir}/rpc.sock"

    def kek_pipe = "#{@dir}/kek.pipe"

    def main_conf = "#{@dir}/vhost-backend.conf"

    def source_conf = "#{@dir}/vhost-backend-stripe-source.conf"

    def secrets_conf = "#{@dir}/vhost-backend-secrets.conf"

    def keys_file = "#{@dir}/spike-keys.json"

    def exist? = File.exist?(main_conf)

    def kek
      keys["kek"]
    end

    def xts
      Base64.decode64(keys["xts"])
    end

    def keys
      @keys ||= JSON.parse(File.read(keys_file))
    end

    # source: {"type" => "raw"|"remote"|"archive", ...}
    # keys_from: reuse another volume's KEK and XTS key, which is what moving a
    # detachable volume between hosts amounts to (the control plane carries the
    # keys with the volume row, not with the VM).
    def create(size_gib: 2, source: nil, track_written: true, device_id: "cldata",
      num_queues: 1, queue_size: 64, stripe_shift: 11, keys_from: nil)
      FileUtils.mkdir_p(@dir)
      @keys = if keys_from
        keys_from.keys
      else
        {"kek" => Base64.strict_encode64(SecureRandom.random_bytes(32)),
         "xts" => Base64.strict_encode64(SecureRandom.random_bytes(64))}
      end
      kek_bytes = Base64.decode64(@keys["kek"])
      wrapped_xts = Base64.strict_encode64(aes256gcm_encrypt(kek_bytes, "xts-key", xts))
      File.write(keys_file, JSON.generate(@keys))

      File.open(disk_file, File::CREAT | File::WRONLY) { _1.truncate(size_gib * 1024 * 1024 * 1024) }
      write_conf(source, track_written, device_id, num_queues, queue_size, wrapped_xts)
      if source || track_written
        File.open(metadata, File::CREAT | File::WRONLY) { _1.truncate(8 * 1024 * 1024) }
        with_kek_pipe do
          run_async([File.join(UBIBLK_DIR, "init-metadata"), "-s", stripe_shift.to_s, "--config", main_conf])
        end
      end
      self
    end

    def write_conf(source, track_written, device_id, num_queues, queue_size, wrapped_xts)
      includes = []
      includes << File.basename(source_conf) if source
      includes << File.basename(secrets_conf)

      device = "[device]\ndata_path = \"#{disk_file}\"\nvhost_socket = \"#{vhost_sock}\"\n" \
        "rpc_socket = \"#{rpc_sock}\"\ndevice_id = \"#{device_id}\"\ntrack_written = #{track_written}\n"
      device << "metadata_path = \"#{metadata}\"\n" if source || track_written

      File.write(main_conf, <<~TOML)
        include = [#{includes.map { "\"#{_1}\"" }.join(", ")}]

        #{device}
        [tuning]
        num_queues = #{num_queues}
        queue_size = #{queue_size}
        seg_size_max = 65536
        seg_count_max = 4
        poll_timeout_us = 1000
        write_through = false

        [encryption.xts_key]
        ref = "xts-key"
      TOML

      secrets = <<~TOML
        [secrets.xts-key]
        encoding = "base64"
        [secrets.xts-key.source]
        inline = "#{wrapped_xts}"
        [secrets.xts-key.encrypted_by]
        ref = "kek"

        [secrets.kek]
        encoding = "base64"
        [secrets.kek.source]
        file = "#{kek_pipe}"
      TOML

      if source && source["type"] == "archive"
        %w[access_key_id secret_access_key].each do |f|
          secrets << wrapped_secret_toml("archive-#{f.tr("_", "-")}", wrap_with_kek("archive-#{f.tr("_", "-")}", source[f]))
        end
        secrets << wrapped_secret_toml("archive-kek",
          wrap_with_kek("archive-kek", Base64.decode64(source["archive_kek"])))
      end

      if source && source["type"] == "remote"
        wrapped_psk = wrap_with_kek("remote-psk", source.delete("psk_secret"))
        secrets << <<~TOML

          [secrets.remote-psk]
          encoding = "base64"
          [secrets.remote-psk.source]
          inline = "#{wrapped_psk}"
          [secrets.remote-psk.encrypted_by]
          ref = "kek"
        TOML
      end
      File.write(secrets_conf, secrets)
      File.write(source_conf, stripe_source_toml(source)) if source
    end

    def wrapped_secret_toml(name, wrapped_b64)
      <<~TOML

        [secrets.#{name}]
        encoding = "base64"
        [secrets.#{name}.source]
        inline = "#{wrapped_b64}"
        [secrets.#{name}.encrypted_by]
        ref = "kek"
      TOML
    end

    def stripe_source_toml(source)
      case source["type"]
      when "raw"
        <<~TOML
          [stripe_source]
          type = "raw"
          image_path = "#{source["image_path"]}"
          copy_on_read = #{source.fetch("copy_on_read", true)}
        TOML
      when "archive"
        <<~TOML
          [stripe_source]
          type = "archive"
          storage = "s3"
          bucket = "#{source["bucket"]}"
          prefix = "#{source["prefix"]}"
          region = "#{source["region"]}"
          endpoint = "#{source["endpoint"]}"
          autofetch = #{source.fetch("autofetch", true)}

          [stripe_source.access_key_id]
          ref = "archive-access-key-id"

          [stripe_source.secret_access_key]
          ref = "archive-secret-access-key"

          [stripe_source.archive_kek]
          ref = "archive-kek"
        TOML
      when "remote"
        <<~TOML
          [stripe_source]
          type = "remote"
          address = "#{source["address"]}"
          autofetch = #{source.fetch("autofetch", true)}
          connections = #{source.fetch("connections", 16)}

          [stripe_source.psk]
          identity = "#{source["psk_identity"]}"

          [stripe_source.psk.secret]
          ref = "remote-psk"
        TOML
      else
        raise "unsupported stripe source #{source["type"]}"
      end
    end

    def wrap_with_kek(name, plaintext)
      Base64.strict_encode64(aes256gcm_encrypt(Base64.decode64(kek), name, plaintext))
    end

    # Same wire format as StorageKeyEncryption.aes256gcm_encrypt.
    def aes256gcm_encrypt(key, auth_data, plaintext)
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      cipher.key = key
      nonce = SecureRandom.random_bytes(12)
      cipher.iv = nonce
      cipher.auth_data = auth_data
      nonce + cipher.update(plaintext) + cipher.final + cipher.auth_tag
    end

    def with_kek_pipe
      FileUtils.rm_f(kek_pipe)
      File.mkfifo(kek_pipe, 0o600)
      yield
    ensure
      FileUtils.rm_f(kek_pipe)
    end

    def run_async(cmd)
      log = File.open("#{@dir}/ubiblk.log", "a")
      pid = Process.spawn(*cmd, out: log, err: log)
      log.close
      Timeout.timeout(10) { File.write(kek_pipe, kek, mode: File::WRONLY) }
      _, st = Process.wait2(pid)
      raise "#{cmd.first} failed: see #{@dir}/ubiblk.log" unless st.success?
    end

    # Start the backend and return once the vhost socket is accepting.
    def start(timeout: 15)
      stop
      FileUtils.rm_f(vhost_sock)
      FileUtils.rm_f(rpc_sock)
      with_kek_pipe do
        log = File.open("#{@dir}/ubiblk.log", "a")
        @backend_pid = Process.spawn({"RUST_LOG" => "info"},
          File.join(UBIBLK_DIR, "vhost-backend"), "--config", main_conf, out: log, err: log)
        log.close
        Timeout.timeout(timeout) { File.write(kek_pipe, kek, mode: File::WRONLY) }
      end
      deadline = Spike.now + timeout
      until File.socket?(vhost_sock)
        raise "vhost socket never appeared (see #{@dir}/ubiblk.log)" if Spike.now > deadline
        raise "backend exited (see #{@dir}/ubiblk.log)" unless backend_alive?
        sleep 0.001
      end
      self
    end

    def backend_alive?
      return false unless @backend_pid
      Process.waitpid(@backend_pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      false
    end

    # Kill the backend without letting it flush, the way a host crash would.
    def stop_hard
      return unless @backend_pid
      begin
        Process.kill("KILL", @backend_pid)
        Process.waitpid(@backend_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      @backend_pid = nil
    end

    def stop
      return unless @backend_pid
      begin
        Process.kill("TERM", @backend_pid)
        Timeout.timeout(5) { Process.waitpid(@backend_pid) }
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      rescue Timeout::Error
        begin
          Process.kill("KILL", @backend_pid)
        rescue
          nil
        end
        begin
          Process.waitpid(@backend_pid)
        rescue
          nil
        end
      end
      @backend_pid = nil
    end

    # ubiblk's control socket takes {"command": ...}, same as VmStats does.
    def rpc(command, extra = {})
      s = UNIXSocket.new(rpc_sock)
      s.write(JSON.generate({"command" => command}.merge(extra)) + "\n")
      line = s.gets
      s.close
      JSON.parse(line.to_s)
    end

    # Fraction of the source already fetched locally (design doc 6.1).
    def caught_up?
      st = rpc("status").dig("status", "stripes")
      st.nil? || st["fetched"] == st["source"]
    end

    # Upload the volume to object storage, the way
    # rhizome/host/lib/storage_archive.rb does.
    def archive(target, stats_file: nil)
      stop
      stats_file ||= "#{@dir}/archive-stats.json"
      config = <<~TOML
        [target]
        storage = "s3"
        bucket = "#{target["bucket"]}"
        prefix = "#{target["prefix"]}"
        region = "#{target["region"]}"
        endpoint = "#{target["endpoint"]}"

        [target.access_key_id]
        ref = "s3-key-id"

        [target.secret_access_key]
        ref = "s3-secret-key"

        [target.archive_kek]
        ref = "archive-kek"

        [secrets.s3-key-id.source]
        inline = "#{target["access_key_id"]}"

        [secrets.s3-secret-key.source]
        inline = "#{target["secret_access_key"]}"

        [secrets.archive-kek]
        encoding = "base64"
        [secrets.archive-kek.source]
        inline = "#{target["archive_kek"]}"

        [danger_zone]
        enabled = true
        allow_inline_plaintext_secrets = true
      TOML
      cmd = [File.join(UBIBLK_DIR, "archive"), "--config", main_conf,
        "--target-config", "/dev/stdin", "--compression", "zstd", "--zstd-level", "3",
        "--encrypt", "--stats", stats_file]
      with_kek_pipe do
        stdin_r, stdin_w = IO.pipe
        log = File.open("#{@dir}/archive.log", "a")
        pid = Process.spawn({"RUST_LOG" => "info"}, *cmd, in: stdin_r, out: log, err: log)
        stdin_r.close
        log.close
        stdin_w.write(config)
        stdin_w.close
        Timeout.timeout(15) { File.write(kek_pipe, kek, mode: File::WRONLY) }
        _, st = Process.wait2(pid)
        raise "archive failed: see #{@dir}/archive.log" unless st.success?
      end
      begin
        JSON.parse(File.read(stats_file))
      rescue
        {}
      end
    end

    def destroy
      stop
      FileUtils.rm_rf(@dir)
    end
  end

  # Serve a detached volume over the ubiblk remote stripe protocol so another
  # host can source from it (storage design approach 2). Mirrors
  # rhizome/host/lib/remote_storage_server.rb.
  class RemoteStripeServer
    attr_reader :port, :psk_identity, :psk

    # netns runs the server inside a network namespace, reached at
    # check_address, for runs that put a shaped link between the hosts.
    def initialize(volume, port:, psk_identity: "spike", psk: nil, netns: nil, check_address: "127.0.0.1")
      @volume = volume
      @port = port
      @netns = netns
      @check_address = check_address
      @psk_identity = psk_identity
      @psk = psk || Base64.strict_encode64(SecureRandom.random_bytes(32))
    end

    def listen_config
      <<~TOML
        [server]
        address = "0.0.0.0:#{@port}"

        [server.psk]
        identity = "#{@psk_identity}"

        [server.psk.secret]
        ref = "psk"

        [secrets.psk]
        encoding = "base64"

        [secrets.psk.source]
        inline = "#{@psk}"

        [danger_zone]
        enabled = true
        allow_inline_plaintext_secrets = true
      TOML
    end

    # The volume's own vhost backend must be stopped: it owns the disk and the
    # kek pipe.
    def start(timeout: 20)
      @volume.stop
      FileUtils.rm_f(@volume.kek_pipe)
      File.mkfifo(@volume.kek_pipe, 0o600)
      stdin_r, stdin_w = IO.pipe
      log = File.open("#{@volume.dir}/remote-server.log", "a")
      prefix = @netns ? ["ip", "netns", "exec", @netns] : []
      @pid = Process.spawn(*prefix, File.join(UBIBLK_DIR, "remote-stripe-server"),
        "-f", @volume.main_conf, "--listen-config", "/dev/stdin",
        in: stdin_r, out: log, err: log)
      stdin_r.close
      log.close
      stdin_w.write(listen_config)
      stdin_w.close
      Timeout.timeout(timeout) { File.write(@volume.kek_pipe, @volume.kek, mode: File::WRONLY) }
      deadline = Spike.now + timeout
      until listening?
        raise "remote stripe server never listened (see #{@volume.dir}/remote-server.log)" if Spike.now > deadline
        sleep 0.01
      end
      self
    ensure
      FileUtils.rm_f(@volume.kek_pipe)
    end

    def listening?
      TCPSocket.new(@check_address, @port).close
      true
    rescue SystemCallError
      false
    end

    def stop
      return unless @pid
      begin
        Process.kill("TERM", @pid)
        Timeout.timeout(5) { Process.waitpid(@pid) }
      rescue Errno::ESRCH, Errno::ECHILD, Timeout::Error
        nil
      end
      @pid = nil
    end
  end
end
