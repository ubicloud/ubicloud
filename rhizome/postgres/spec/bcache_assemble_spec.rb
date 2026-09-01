# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"

# Exercise device selection and bcache setup against fake sysfs and block tools.
RSpec.describe "bcache-assemble" do
  let(:script) { File.expand_path("../bin/bcache-assemble", __dir__) }
  let(:tmpdir) { File.realpath(Dir.mktmpdir) }
  let(:bin) { File.join(tmpdir, "bin") }
  let(:sysfs) { File.join(tmpdir, "sys") }
  let(:dev) { File.join(tmpdir, "dev") }
  let(:byid) { File.join(dev, "disk", "by-id") }
  let(:calls) { File.join(tmpdir, "calls") }
  let(:bcache0) { File.join(sysfs, "block", "bcache0", "bcache") }
  let(:cset) { "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" }
  let(:cset_dir) { File.join(sysfs, "fs", "bcache", cset) }

  # Sizes in bytes, keyed by the resolved device path.
  def sizes = @sizes ||= {}

  def stub(name, body)
    path = File.join(bin, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
  end

  def make_disk(name, bytes)
    path = File.join(dev, name)
    FileUtils.touch(path)
    sizes[path] = bytes
    path
  end

  def link(alias_name, target)
    File.symlink(target, File.join(byid, alias_name))
  end

  before do
    [bin, byid, bcache0, File.join(sysfs, "fs", "bcache"), cset_dir].each { |d| FileUtils.mkdir_p(d) }
    FileUtils.touch(calls)
    FileUtils.touch(File.join(sysfs, "fs", "bcache", "register_quiet"))
    # The kernel creates these once the cache set is attached.
    %w[cache_mode sequential_cutoff attach].each { |f| FileUtils.touch(File.join(bcache0, f)) }
    %w[congested_read_threshold_us congested_write_threshold_us].each { |f| FileUtils.touch(File.join(cset_dir, f)) }

    %w[modprobe udevadm wipefs mdadm mkfs.ext4 parted mount].each { |c| stub(c, %(echo "#{c} $*" >> "#{calls}")) }
    stub("sleep", "exit 0")
    stub("mountpoint", "exit 1")
    stub("blkid", %(echo "blkid $*" >> "#{calls}"; exit 2))          # no existing WAL label
    # The kernel exposes bcache0/cache once a cache set is registered.
    stub("make-bcache", <<~SH)
      echo "make-bcache $*" >> "#{calls}"
      if [ "$1" = "-C" ]; then ln -sfn "#{cset_dir}" "#{bcache0}/cache"; fi
    SH
    # A fresh network volume has no superblock, so the backing probe fails and
    # make-bcache -B runs. Every other device reports the cache set uuid.
    stub("bcache-super-show", <<~SH)
      echo "bcache-super-show $*" >> "#{calls}"
      [ "$1" = "$BACKING_DEV" ] && exit 1
      printf 'cset.uuid\t#{cset}\n'
    SH
  end

  after { FileUtils.rm_rf(tmpdir) }

  def stub_sizes
    body = sizes.map { |path, bytes| %(  #{path}) + ") echo #{bytes} ;;" }.join("\n")
    stub("blockdev", "case \"$2\" in\n#{body}\n  *) echo 0 ;;\nesac")
  end

  # PKNAME is only consulted for a partitioned WAL device.
  def stub_lsblk(pkname_for = {})
    body = pkname_for.map { |part, parent| %(  #{part}) + ") echo #{File.basename(parent)} ;;" }.join("\n")
    stub("lsblk", "case \"$3\" in\n#{body}\n  *) echo ;;\nesac")
  end

  def run(data_dev:, cache_glob:)
    env = {
      "PATH" => "#{bin}:#{ENV["PATH"]}",
      "BCACHE_ENV" => File.join(tmpdir, "bcache.env"),
      "SYSFS" => sysfs, "WAL_MNT" => File.join(tmpdir, "wal"), "DAT_MNT" => File.join(tmpdir, "dat"),
      "BCACHE_DEV" => File.join(dev, "bcache0"), "MD_DEV" => File.join(dev, "md0"),
      "IS_DEV" => "-e", "DEV_DIR" => dev, "BACKING_DEV" => data_dev,
    }
    File.write(env["BCACHE_ENV"], "DATA_DEVICE=#{data_dev}\nCACHE_GLOB=#{cache_glob}\n")
    FileUtils.touch(File.join(dev, "bcache0"))   # appears once the backing device registers
    Open3.capture3(env, "bash", script)
  end

  def call_log = File.read(calls)
  def sysfs_value(*parts) = File.read(File.join(*parts)).strip

  describe "with one local NVMe beside the network volume" do
    let!(:data) { make_disk("nvme0n1", 64 * 1024**3) }
    let!(:local) { make_disk("nvme1n1", 110 * 1024**3) }
    let!(:wal_part) { make_disk("nvme1n1p1", 27 * 1024**3) }
    let!(:cache_part) { make_disk("nvme1n1p2", 82 * 1024**3) }

    before do
      link("nvme-Amazon_EC2_NVMe_Instance_Storage_AWS111", local)
      link("nvme-Amazon_EC2_NVMe_Instance_Storage_AWS111_1", local)   # provider alias for the same disk
      link("nvme-Amazon_EC2_NVMe_Instance_Storage_AWS111-part1", wal_part)
      stub_sizes
      stub_lsblk(wal_part => local)
    end

    it "leaves the cache in a mode that actually caches" do
      _out, err, status = run(data_dev: data, cache_glob: "#{byid}/nvme-Amazon_EC2_NVMe_Instance_Storage*")
      expect([status.exitstatus, err]).to eq([0, ""])

      expect(sysfs_value(bcache0, "cache_mode")).to eq("writethrough")
      expect(sysfs_value(bcache0, "sequential_cutoff")).to eq("0")
      # Network volumes cross the default local-disk latency thresholds.
      expect(sysfs_value(cset_dir, "congested_read_threshold_us")).to eq("0")
      expect(sysfs_value(cset_dir, "congested_write_threshold_us")).to eq("0")
    end

    it "backs the cache with the network volume, not a local disk" do
      run(data_dev: data, cache_glob: "#{byid}/nvme-Amazon_EC2_NVMe_Instance_Storage*")
      expect(call_log).to include("make-bcache -B #{data}")
      expect(call_log).not_to include("make-bcache -B #{local}")
    end

    it "keeps WAL off the cache and caches only what is left of the local disk" do
      run(data_dev: data, cache_glob: "#{byid}/nvme-Amazon_EC2_NVMe_Instance_Storage*")
      expect(call_log).to include("make-bcache -C #{cache_part}")
      expect(call_log).not_to include("make-bcache -C #{wal_part}")
      expect(call_log).not_to include("make-bcache -C #{data}")
    end

    it "sizes the WAL partition at a quarter of local storage" do
      run(data_dev: data, cache_glob: "#{byid}/nvme-Amazon_EC2_NVMe_Instance_Storage*")
      # 110 GiB / 4 = 27.5 GiB, above the 16 GiB floor.
      expect(call_log).to match(/parted .*mkpart .*?(2816[0-9]|281[0-9]{2})MiB/)
    end

    it "deduplicates provider aliases and skips partition links" do
      run(data_dev: data, cache_glob: "#{byid}/nvme-Amazon_EC2_NVMe_Instance_Storage*")
      # One disk behind three links: partitioned once, not once per alias.
      expect(call_log.scan(/^parted /).length).to eq(1)
    end
  end
end
