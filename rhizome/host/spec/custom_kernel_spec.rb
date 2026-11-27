# frozen_string_literal: true

require_relative "../lib/custom_kernel"

RSpec.describe CustomKernel do
  subject(:ck) { described_class.new(version, "https://example.com/k.tar.gz", "abc") }

  let(:version) { "6.8.0-151.151+ubi1" }
  let(:packages) { ["linux-image-unsigned-6.8.0-151-generic", "linux-modules-6.8.0-151-generic", "linux-modules-extra-6.8.0-151-generic"] }
  let(:status_query) { ["dpkg-query", "-W", "-f", "${db:Status-Status} ${Version}\n", *packages] }
  let(:commands) { [] }

  def stub_commands(outputs)
    allow(ck).to receive(:_run_command) do |*command, **kw|
      commands << (kw.empty? ? command : [*command, kw])
      outputs.fetch(command, "")
    end
  end

  def apt_get(*args)
    ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "-y", *args]
  end

  describe "#initialize" do
    it "fails for a version without the +ubi suffix" do
      expect { described_class.new("6.8.0-151.151", "u", "s") }.to raise_error(RuntimeError, 'Invalid custom kernel version "6.8.0-151.151"')
    end
  end

  describe "#packages" do
    it "lists the image and module packages of the ABI" do
      expect(ck.packages).to eq(packages)
    end
  end

  describe "#apply_patches" do
    let(:dir) { "/tmp/custom-kernel-1" }
    let(:kernels) { {["linux-version", "list"] => "list", ["linux-version", "sort"] => "6.8.0-149-generic\n6.8.0-151-generic\n"} }
    let(:check_commands) { [["linux-version", "list"], ["linux-version", "sort", {stdin: "list"}]] }

    it "installs and holds the kernel before full-upgrade" do
      stub_commands(kernels)
      expect(Dir).to receive(:mktmpdir).with("custom-kernel").and_yield(dir)
      expect(ck).to receive(:curl_file).with("https://example.com/k.tar.gz", "#{dir}/kernel.tar.gz").and_return("abc")
      arch = Arch.render(x64: "amd64", arm64: "arm64")

      ck.apply_patches
      expect(commands).to eq([
        apt_get("update"),
        [*status_query, {expect: [0, 1]}],
        ["tar", "-xzf", "#{dir}/kernel.tar.gz", "-C", dir, "--no-same-owner", "--strip-components=1"],
        apt_get("install", "--allow-change-held-packages", *packages.map { |package| "#{dir}/#{package}_#{version}_#{arch}.deb" }),
        ["apt-mark", "hold", *packages],
        apt_get("full-upgrade"),
        *check_commands,
      ])
    end

    it "skips the install when the kernel is installed" do
      stub_commands(kernels.merge(status_query => "installed #{version}\n" * 3))
      expect(Dir).not_to receive(:mktmpdir)

      ck.apply_patches
      expect(commands).to eq([
        apt_get("update"),
        [*status_query, {expect: [0, 1]}],
        ["apt-mark", "hold", *packages],
        apt_get("full-upgrade"),
        *check_commands,
      ])
    end

    it "fails when the digest does not match" do
      stub_commands({})
      expect(Dir).to receive(:mktmpdir).with("custom-kernel").and_yield(dir)
      expect(ck).to receive(:curl_file).and_return("def")

      expect { ck.apply_patches }.to raise_error(RuntimeError, "Invalid SHA-256 digest")
      expect(commands).to eq([apt_get("update"), [*status_query, {expect: [0, 1]}]])
    end
  end

  describe "#installed?" do
    def expect_status(output)
      expect(ck).to receive(:_run_command).with(*status_query, expect: [0, 1]).and_return(output)
    end

    it "is true when all packages are installed at the version" do
      expect_status("installed #{version}\n" * 3)
      expect(ck.installed?).to be true
    end

    it "is false when a package has another version" do
      expect_status("installed 6.8.0-151.151\ninstalled #{version}\ninstalled #{version}\n")
      expect(ck.installed?).to be false
    end

    it "is false when dpkg does not know a package" do
      expect_status("installed #{version}\n")
      expect(ck.installed?).to be false
    end
  end

  describe "#check_default_kernel" do
    before do
      expect(ck).to receive(:_run_command).with("linux-version", "list").and_return("list")
    end

    it "passes when the custom kernel is the newest" do
      expect(ck).to receive(:_run_command).with("linux-version", "sort", stdin: "list").and_return("6.8.0-149-generic\n6.8.0-151-generic\n")

      expect(ck.check_default_kernel).to be_nil
    end

    it "fails when a newer kernel is installed" do
      expect(ck).to receive(:_run_command).with("linux-version", "sort", stdin: "list").and_return("6.8.0-151-generic\n6.8.0-152-generic\n")

      expect { ck.check_default_kernel }.to raise_error(RuntimeError, "Kernel 6.8.0-152-generic is newer than the custom kernel 6.8.0-151-generic, build the fix for 6.8.0-152-generic")
    end
  end
end
