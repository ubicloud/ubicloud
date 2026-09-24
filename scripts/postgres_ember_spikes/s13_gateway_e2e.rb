#!/usr/bin/env ruby
# frozen_string_literal: true

#
# The gateway against a real ember.
#
# Brings up an ember whose PostgreSQL terminates TLS with a per-ember
# certificate, stands in for the control plane's internal API, runs the real
# gateway binary in front of it, and connects with psql. Then pauses the
# ember and connects again, which is the path the gateway exists for:
# resume on connect.
#
#   ruby s13_gateway_e2e.rb [template]

require_relative "lib/ember"
require "openssl"
# deliberately not WEBrick; see emberd_stub.rb

TEMPLATE = ARGV[0] || "t512"
# "plain": the ember runs PostgreSQL with ssl off and the hop is encrypted
# below PostgreSQL (the chosen design). "tls": the opt-in second TLS session.
MODE = ARGV[1] || "plain"
EMBER_ID = "ember1"
SNI_HOST = "#{EMBER_ID}.ember.test"
GATEWAY_PORT = 6432
CONTROL_PORT = 8460
PASSWORD = "ember-#{SecureRandom.hex(8)}"
WORK = "/var/storage/ember/gwtest"
GATEWAY_BIN = "/root/gateway/ember-gateway"

template_dir = File.join(Spike::TEMPLATES, TEMPLATE)
pgdata_image = "#{Spike::IMAGES}/cell-pgdata-18.raw"

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
FileUtils.mkdir_p(WORK)

# --- certificates -----------------------------------------------------------
# One CA stands in for both the ember root CA and the public issuer of the
# location's wildcard certificate; in production those are separate.
def issue(ca_key, ca_cert, subject, sans, serial)
  key = OpenSSL::PKey::EC.generate("prime256v1")
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = serial
  cert.subject = OpenSSL::X509::Name.parse("/CN=#{subject}")
  cert.issuer = ca_cert.subject
  cert.public_key = key
  cert.not_before = Time.now - 3600
  cert.not_after = Time.now + 86_400
  ef = OpenSSL::X509::ExtensionFactory.new
  ef.subject_certificate = cert
  ef.issuer_certificate = ca_cert
  cert.add_extension(ef.create_extension("extendedKeyUsage", "serverAuth"))
  cert.add_extension(ef.create_extension("subjectAltName", sans)) unless sans.empty?
  cert.sign(ca_key, OpenSSL::Digest.new("SHA256"))
  [key, cert]
end

ca_key = OpenSSL::PKey::EC.generate("prime256v1")
ca_cert = OpenSSL::X509::Certificate.new
ca_cert.version = 2
ca_cert.serial = 1
ca_cert.subject = ca_cert.issuer = OpenSSL::X509::Name.parse("/CN=ember spike CA")
ca_cert.public_key = ca_key
ca_cert.not_before = Time.now - 3600
ca_cert.not_after = Time.now + 86_400
ef = OpenSSL::X509::ExtensionFactory.new
ef.subject_certificate = ef.issuer_certificate = ca_cert
ca_cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
ca_cert.add_extension(ef.create_extension("keyUsage", "keyCertSign, cRLSign", true))
ca_cert.sign(ca_key, OpenSSL::Digest.new("SHA256"))
File.write("#{WORK}/ca.crt", ca_cert.to_pem)

slot = Spike::Slot.new(210)
slot.create
ember_key, ember_cert = issue(ca_key, ca_cert, EMBER_ID,
  "IP:#{slot.public_ip6},IP:#{Spike::GUEST_IP6}", 2)
gw_key, gw_cert = issue(ca_key, ca_cert, "*.ember.test", "DNS:*.ember.test", 3)
File.write("#{WORK}/gw.crt", gw_cert.to_pem)
File.write("#{WORK}/gw.key", gw_key.to_pem)

vol = Spike::Volume.new("dvgw")
FileUtils.rm_rf(vol.dir)
report = {"mode" => MODE}
vm = nil

def bring_up(slot, vol, template_dir, cert, key, password)
  vol.start
  vm = Spike::Vm.new(slot)
  vm.restore(vm.prepare_restore_dir(template_dir), memory_restore_mode: "ondemand")
  vm.wait_api_socket(timeout: 60)
  vm.wait_state("Running", timeout: 60)
  vm.agent.wait_ready(timeout: 60)
  vm.agent.call("post_restore", nonce_hex: SecureRandom.hex(32),
    unix_time_ms: (Time.now.to_f * 1000).round, ember_id: EMBER_ID)
  vm.add_disk(vhost_sock: vol.vhost_sock)
  vm.agent.call("attach", device: "cldata", mount: "/data", clean_shutdown: true, timeout_s: 60)
  args = {superuser_password: password, database: "postgres", timeout: 180}
  args[:tls] = {"cert_pem" => cert.to_pem, "key_pem" => key.to_pem} if MODE == "tls"
  vm.agent.call("pg_start", **args)
  vm
end

# In "plain" mode the ember advertises no channel binding, so libpq's default
# works. In "tls" mode it advertises SCRAM-SHA-256-PLUS, which a TLS-terminating
# gateway cannot satisfy, so the rest of that run has to opt out to exercise the
# transport at all. That difference is the whole reason for choosing "plain".
CHANNEL_BINDING = (MODE == "tls") ? "disable" : "prefer"

def psql_via_gateway(sql, check: true, channel_binding: CHANNEL_BINDING)
  Spike.sh("timeout", "-s", "KILL", "30",
    "env", "PGPASSWORD=#{PASSWORD}", "PGSSLMODE=verify-full", "PGSSLROOTCERT=#{WORK}/ca.crt",
    "PGCHANNELBINDING=#{channel_binding}",
    "psql", "-h", SNI_HOST, "-p", GATEWAY_PORT.to_s, "-U", "postgres", "-d", "postgres",
    "-tAqX", "-c", sql, check:).strip
end

# --- stand-in control plane -------------------------------------------------
# Serves the three internal endpoints the gateway uses. The resume handler
# really does bring the ember back, so resume-on-connect is exercised end to
# end rather than faked.
class ControlPlaneStub
  attr_reader :resumes, :activity

  def initialize(port, state:, on_resume:)
    @port = port
    @state = state
    @on_resume = on_resume
    @resumes = 0
    @activity = []
    @mutex = Mutex.new
  end

  def state = @mutex.synchronize { @state[:value] }

  def set_state(value) = @mutex.synchronize { @state[:value] = value }

  def start
    server = TCPServer.new("127.0.0.1", @port)
    @thread = Thread.new do
      loop do
        conn = server.accept
        Thread.new(conn) { |c| handle(c) }
      rescue IOError, Errno::EBADF
        break
      end
    end
    self
  end

  def handle(conn)
    request_line = conn.gets
    return unless request_line
    method, path, = request_line.split
    length = 0
    while (line = conn.gets)
      line = line.strip
      break if line.empty?
      key, _, value = line.partition(":")
      length = value.strip.to_i if key.downcase == "content-length"
    end
    body = (length > 0) ? conn.read(length) : ""

    status, payload = route_request(method, path, body)
    encoded = JSON.generate(payload)
    conn.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
               "Content-Length: #{encoded.bytesize}\r\nConnection: close\r\n\r\n#{encoded}")
  rescue => e
    warn "control plane stub: #{e.class}: #{e.message}"
  ensure
    begin
      conn.close
    rescue
      nil
    end
  end

  def route_request(method, path, body)
    case [method, path.split("?").first]
    in ["GET", "/internal/ember/route"]
      [200, route_payload]
    in ["POST", %r{/internal/ember/.*/resume$} => _]
      @mutex.synchronize { @resumes += 1 }
      @on_resume.call
      set_state("running")
      [200, route_payload]
    in ["POST", "/internal/gateway/activity"]
      @mutex.synchronize { @activity.concat(JSON.parse(body)) }
      [204, {}]
    else
      [404, {"error" => "not found"}]
    end
  end

  def route_payload
    payload = {"ember_id" => EMBER_ID, "state" => state,
               "target_ip6" => @state[:ip6], "port" => 5432}
    if MODE == "tls"
      payload["upstream_tls"] = true
      payload["cert_cn"] = EMBER_ID
    end
    payload
  end

  def stop = @thread&.kill
end

gateway_pid = nil
stub = nil
begin
  puts "== bring up an ember (mode: #{MODE}) =="
  vol.create(size_gib: 2, source: {"type" => "raw", "image_path" => pgdata_image, "copy_on_read" => true})
  vm = bring_up(slot, vol, template_dir, ember_cert, ember_key, PASSWORD)
  puts "  ember up at #{slot.public_ip6}" \
       "#{(MODE == "tls") ? ", PostgreSQL TLS cert CN=#{EMBER_ID}" : ", PostgreSQL ssl off"}"

  state = {value: "running", ip6: slot.public_ip6}
  resumed = proc do
    puts "  [control plane] resuming the ember"
    vm = bring_up(slot, vol, template_dir, ember_cert, ember_key, PASSWORD)
  end
  stub = ControlPlaneStub.new(CONTROL_PORT, state:, on_resume: resumed).start

  puts "== start the gateway =="
  env = {"POSTGRES_GATEWAY_TOKEN_SECRET" => "spike-secret"}
  gateway_pid = Process.spawn(env, GATEWAY_BIN,
    "-listen", "127.0.0.1:#{GATEWAY_PORT}",
    "-admin-listen", "127.0.0.1:8461",
    "-cert", "#{WORK}/gw.crt", "-key", "#{WORK}/gw.key",
    "-ember-ca", "#{WORK}/ca.crt",
    "-control-plane", "http://127.0.0.1:#{CONTROL_PORT}",
    "-hostname-suffix", "ember.test",
    "-activity-interval", "2s",
    "-log-level", "debug",
    out: "#{WORK}/gateway.log", err: "#{WORK}/gateway.log")
  sleep 1

  puts "== what libpq does by default (channel_binding=prefer) =="
  default_out = Spike.sh("sh", "-c",
    "PGPASSWORD=#{PASSWORD} PGSSLMODE=verify-full PGSSLROOTCERT=#{WORK}/ca.crt " \
    "timeout -s KILL 30 psql -h #{SNI_HOST} -p #{GATEWAY_PORT} -U postgres -d postgres " \
    "-tAqX -c 'SELECT 1' 2>&1", check: false).strip
  report["default_libpq_works"] = (default_out == "1")
  puts "  #{default_out.lines.first&.strip}"

  puts "== connect through the gateway (running ember) =="
  t = Spike.now
  version = psql_via_gateway("SELECT version()")
  puts "  #{version[0, 55]}"
  puts "  first query through the gateway: #{Spike.ms(t).round(1)} ms"
  report["running_query_ms"] = Spike.ms(t)
  psql_via_gateway("CREATE TABLE IF NOT EXISTS t (v text)")
  psql_via_gateway("INSERT INTO t VALUES ('through the gateway')")
  puts "  round trip: #{psql_via_gateway("SELECT v FROM t")}"
  report["running_ok"] = true

  puts "== pause the ember, then connect again =="
  vm.agent.call("pg_stop", timeout: 60)
  vm.agent.call("detach")
  vm.agent.close
  vm.remove_device("data")
  vm.shutdown(timeout: 10)
  vol.stop
  stub.set_state("paused")
  Spike.sh("curl", "-sf", "-X", "POST", "-H", "Content-Type: application/json",
    "-d", JSON.generate({"all" => true}), "http://127.0.0.1:8461/invalidate", check: false)
  puts "  ember paused"

  t = Spike.now
  got = psql_via_gateway("SELECT v FROM t")
  resume_ms = Spike.ms(t)
  puts "  connected after a resume in #{(resume_ms / 1000).round(2)} s, read back: #{got}"
  report["resume_on_connect_ms"] = resume_ms
  report["resume_ok"] = (got == "through the gateway")
  report["resumes"] = stub.resumes

  puts "== activity reporting =="
  sleep 3
  report["activity_reports"] = stub.activity.length
  puts "  control plane received #{stub.activity.length} activity records: " \
       "#{stub.activity.last.inspect}"
ensure
  Process.kill("TERM", gateway_pid) if gateway_pid
  stub&.stop
  begin
    vm&.shutdown(timeout: 5)
  rescue
    nil
  end
  vol.stop
  File.write("/root/ember_spikes/out/s13_gateway_e2e_#{MODE}.json", JSON.pretty_generate(report))
  puts JSON.pretty_generate(report)
  puts "(gateway log at #{WORK}/gateway.log)"
end
