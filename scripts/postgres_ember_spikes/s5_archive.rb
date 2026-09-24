#!/usr/bin/env ruby
# frozen_string_literal: true

#
# S2, archive leg: pause, upload the detached volume to object storage, delete
# the local copy, and resume elsewhere from the archive (storage design
# approach 1 / design doc 6.1 `detached_archived`).
#
# The interesting correctness question: a NEW volume is seeded from the PGDATA
# raw image with copy_on_read, so most stripes were never fetched or written.
# If the archive only carries written stripes, a restore elsewhere would have
# holes exactly where the initdb'd cluster lives. This checks the whole PGDATA
# tree byte for byte across the round trip.
#
#   ruby s5_archive.rb [template] [mb_of_data]

require_relative "lib/ember"
require_relative "lib/s3"

template = ARGV[0] || "t512"
data_mb = Integer(ARGV[1] || 100)
template_dir = File.join(Spike::TEMPLATES, template)
pgdata_image = "#{Spike::IMAGES}/cell-pgdata-18.raw"
HOST_C_ROOT = "/var/storage/detachable-hostc"
PASSWORD = "ember-#{SecureRandom.hex(8)}"
BUCKET = "ember-archives"
ENDPOINT = "http://127.0.0.1:9000"
ACCESS = "sbspike"
SECRET = "sbspikesecret"

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
FileUtils.mkdir_p(HOST_C_ROOT)
s3 = MiniS3.new(endpoint: ENDPOINT, access_key: ACCESS, secret_key: SECRET)
s3.create_bucket(BUCKET)

slot_a = Spike::Slot.new(200).create
slot_c = Spike::Slot.new(202).create

def psql(slot, sql, timeout: 60)
  Spike.sh("ip", "netns", "exec", slot.netns, "env", "PGPASSWORD=#{PASSWORD}",
    "PGCONNECT_TIMEOUT=#{timeout}", "psql", "-h", Spike::GUEST_IP6, "-U", "postgres",
    "-d", "postgres", "-tAqX", "-c", sql).strip
end

# Bring the VM up and attach the volume, but leave PostgreSQL stopped so the
# on-disk tree can be digested while nothing is writing to it.
def attach_only(slot, vol, template_dir)
  ph = {}
  t = Spike.now
  vol.start
  ph[:volume] = Spike.ms(t)
  vm = Spike::Vm.new(slot)
  vm.restore(vm.prepare_restore_dir(template_dir), memory_restore_mode: "ondemand")
  vm.wait_api_socket(timeout: 30)
  vm.wait_state("Running", timeout: 30)
  vm.agent.wait_ready(timeout: 30)
  vm.agent.call("post_restore", nonce_hex: SecureRandom.hex(32),
    unix_time_ms: (Time.now.to_f * 1000).round)
  vm.add_disk(vhost_sock: vol.vhost_sock)
  att = vm.agent.call("attach", device: "cldata", mount: "/data", timeout_s: 30)
  ph[:fsck_ran] = att["fsck_ran"]
  ph[:attached] = Spike.ms(t)
  [vm, ph]
end

def tree_digest(vm)
  vm.agent.call("exec", timeout_s: 300, argv: ["sh", "-c",
    "find /data/pgdata -type f ! -name postmaster.pid ! -path '*/pg_wal/*' " \
    "! -path '*/pg_stat*' ! -path '*/log/*' | LC_ALL=C sort | xargs -r md5sum | md5sum"])["stdout"].strip
end

report = {}
vm = nil
vol_a = Spike::Volume.new("dv#{SecureRandom.hex(4)}")
vol_c = nil
begin
  puts "== host A: create, fill, pause =="
  vol_a.create(size_gib: 2, source: {"type" => "raw", "image_path" => pgdata_image, "copy_on_read" => true})
  vm, = attach_only(slot_a, vol_a, template_dir)
  vm.agent.call("pg_start", superuser_password: PASSWORD, database: "postgres", timeout: 120)
  psql(slot_a, "CREATE TABLE t (id serial primary key, v text)")
  rows = (data_mb * 1024 * 1024) / 128
  psql(slot_a, "INSERT INTO t (v) SELECT repeat(md5(g::text), 3) FROM generate_series(1, #{rows}) g")
  psql(slot_a, "CHECKPOINT")
  count = psql(slot_a, "SELECT count(*) FROM t")
  sum = psql(slot_a, "SELECT sum(hashtextextended(v, 0)) FROM t")
  size = psql(slot_a, "SELECT pg_size_pretty(pg_database_size('postgres'))")
  vm.agent.call("pg_stop", timeout: 60)
  digest_a = tree_digest(vm)
  puts "  #{count} rows, database #{size}, PGDATA tree digest #{digest_a}"
  vm.agent.call("detach")
  vm.agent.close
  vm.remove_device("data")
  vm.shutdown(timeout: 10)
  vm = nil
  vol_a.stop
  before = begin
    vol_a.rpc("status")
  rescue
    nil
  end
  local_bytes = Spike.sh("du", "-sb", vol_a.dir).split.first.to_i
  puts "  local volume #{(local_bytes / 1048576.0).round(1)} MiB"

  puts "== archive to object storage =="
  archive_kek = Base64.strict_encode64(SecureRandom.random_bytes(32))
  prefix = "#{vol_a.id}/"
  t = Spike.now
  stats = vol_a.archive({"bucket" => BUCKET, "prefix" => prefix, "region" => "us-east-1",
    "endpoint" => ENDPOINT, "access_key_id" => ACCESS, "secret_access_key" => SECRET,
    "archive_kek" => archive_kek})
  archive_ms = Spike.ms(t)
  objects = s3.list(BUCKET, prefix)
  uploaded = objects.sum { _2 }
  puts "  archived in #{(archive_ms / 1000).round(1)} s: #{objects.length} objects, " \
       "#{(uploaded / 1048576.0).round(1)} MiB in the bucket"
  puts "  archive stats: #{stats.inspect}" unless stats.empty?
  report["archive_ms"] = archive_ms
  report["archive_objects"] = objects.length
  report["archive_bytes"] = uploaded
  report["local_bytes"] = local_bytes

  puts "== delete the local copy, resume on host C from the archive =="
  FileUtils.rm_rf(vol_a.dir)
  vol_c = Spike::Volume.new(vol_a.id, root: HOST_C_ROOT)
  t = Spike.now
  vol_c.create(size_gib: 2, keys_from: vol_a,
    source: {"type" => "archive", "bucket" => BUCKET, "prefix" => prefix,
             "region" => "us-east-1", "endpoint" => ENDPOINT, "autofetch" => true,
             "access_key_id" => ACCESS, "secret_access_key" => SECRET,
             "archive_kek" => archive_kek})
  create_ms = Spike.ms(t)

  t = Spike.now
  vm, ph = attach_only(slot_c, vol_c, template_dir)
  digest_c = tree_digest(vm)
  st = vm.agent.call("pg_start", superuser_password: PASSWORD, database: "postgres", timeout: 180)
  ph[:pg_ready] = Spike.ms(t)
  psql(slot_c, "SELECT 1")
  ph[:first_query] = Spike.ms(t)
  puts "  volume create #{create_ms.round(1)} ms, attached #{ph[:attached]} ms, " \
       "first query #{ph[:first_query]} ms (fsck=#{ph[:fsck_ran]} recovery=#{st["recovery_ran"]})"
  report["resume_archive"] = ph.merge("volume_create_ms" => create_ms)

  got_count = psql(slot_c, "SELECT count(*) FROM t")
  got_sum = psql(slot_c, "SELECT sum(hashtextextended(v, 0)) FROM t")
  puts "  SQL verify rows=#{got_count} checksum_match=#{got_sum == sum}"
  puts "  PGDATA tree digest: host A #{digest_a}"
  puts "                      host C #{digest_c}  => #{(digest_a == digest_c) ? "IDENTICAL" : "DIFFERENT"}"
  report["sql_verify"] = (got_count == count && got_sum == sum)
  report["tree_digest_match"] = (digest_a == digest_c)

  st2 = begin
    vol_c.rpc("status")
  rescue
    nil
  end
  puts "  host C stripes: #{st2.inspect} (host A had #{before.inspect} at pause)"
  report["host_c_stripes"] = st2
ensure
  begin
    vm&.shutdown(timeout: 5)
  rescue
    nil
  end
  vol_a.stop
  vol_c&.stop
  File.write("/root/ember_spikes/out/s5_archive.json", JSON.pretty_generate(report))
  puts JSON.pretty_generate(report)
end
