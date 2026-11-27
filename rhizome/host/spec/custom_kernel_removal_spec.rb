# frozen_string_literal: true

require_relative "../lib/custom_kernel_removal"

RSpec.describe CustomKernelRemoval do
  subject(:ckr) { described_class.new }

  let(:query) { ["dpkg-query", "-W", "-f", "${db:Status-Status} ${Package} ${Version}\n", "linux-image-unsigned-*", "linux-modules-*"] }
  let(:custom_status) {
    <<~OUTPUT
      installed linux-image-unsigned-6.8.0-151-generic 6.8.0-151.151+ubi1
      installed linux-modules-6.8.0-151-generic 6.8.0-151.151+ubi1
      installed linux-modules-6.8.0-149-generic 6.8.0-149.149
    OUTPUT
  }
  let(:commands) { [] }

  # Each command returns its next output, or "" if it has none.
  def stub_commands(outputs)
    allow(ckr).to receive(:_run_command) do |*command, **kw|
      commands << (kw.empty? ? command : [*command, kw])
      outputs.fetch(command, []).shift || ""
    end
  end

  def apt_get(*args)
    ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "-y", *args]
  end

  def apt_cache_show(package)
    ["apt-cache", "show", package, {expect: [0, 100]}]
  end

  describe "#remove" do
    it "unholds the custom packages and replaces them with the stock packages" do
      stub_commands(
        query => [custom_status, "installed linux-modules-6.8.0-149-generic 6.8.0-149.149\n"],
        ["apt-cache", "show", "linux-image-6.8.0-151-generic=6.8.0-151.151"] => ["Package: linux-image-6.8.0-151-generic\n"],
      )

      ckr.remove
      expect(commands).to eq([
        apt_get("update"),
        [*query, {expect: [0, 1]}],
        ["apt-mark", "unhold", "linux-image-unsigned-6.8.0-151-generic", "linux-modules-6.8.0-151-generic"],
        apt_cache_show("linux-image-6.8.0-151-generic=6.8.0-151.151"),
        apt_cache_show("linux-modules-6.8.0-151-generic=6.8.0-151.151"),
        apt_get("install", "--allow-downgrades", "linux-image-generic",
          "linux-image-6.8.0-151-generic=6.8.0-151.151", "linux-image-unsigned-6.8.0-151-generic-",
          "linux-modules-6.8.0-151-generic-"),
        apt_get("full-upgrade"),
        [*query, {expect: [0, 1]}],
      ])
    end

    it "installs only the metapackage when there is no custom package" do
      stub_commands({})

      ckr.remove
      expect(commands).to eq([
        apt_get("update"),
        [*query, {expect: [0, 1]}],
        apt_get("install", "--allow-downgrades", "linux-image-generic"),
        apt_get("full-upgrade"),
        [*query, {expect: [0, 1]}],
      ])
    end

    it "fails when custom packages are still installed" do
      stub_commands(query => ["", custom_status])

      expect { ckr.remove }.to raise_error(RuntimeError, "Custom kernel packages are still installed: linux-image-unsigned-6.8.0-151-generic, linux-modules-6.8.0-151-generic")
    end
  end

  describe "#custom_packages" do
    it "lists the installed packages with a custom version" do
      stub_commands(query => [<<~OUTPUT])
        not-installed linux-image-unsigned-6.8.0-149-generic
        installed linux-image-unsigned-6.8.0-151-generic 6.8.0-151.151+ubi1
        config-files linux-modules-6.8.0-146-generic 6.8.0-146.146+ubi1
        installed linux-modules-6.8.0-149-generic 6.8.0-149.149
        installed linux-modules-6.8.0-151-generic 6.8.0-151.151+ubi1
      OUTPUT

      expect(ckr.custom_packages).to eq(
        "linux-image-unsigned-6.8.0-151-generic" => "6.8.0-151.151+ubi1",
        "linux-modules-6.8.0-151-generic" => "6.8.0-151.151+ubi1",
      )
    end
  end

  describe "#stock_changes" do
    it "replaces the unsigned image with the signed stock image" do
      stub_commands(["apt-cache", "show", "linux-image-6.8.0-151-generic=6.8.0-151.151"] => ["Package: linux-image-6.8.0-151-generic\n"])
      expect(ckr.stock_changes("linux-image-unsigned-6.8.0-151-generic", "6.8.0-151.151+ubi1")).to eq(["linux-image-6.8.0-151-generic=6.8.0-151.151", "linux-image-unsigned-6.8.0-151-generic-"])
    end

    it "downgrades a module package to the stock version" do
      stub_commands(["apt-cache", "show", "linux-modules-6.8.0-151-generic=6.8.0-151.151"] => ["Package: linux-modules-6.8.0-151-generic\n"])
      expect(ckr.stock_changes("linux-modules-6.8.0-151-generic", "6.8.0-151.151+ubi1")).to eq(["linux-modules-6.8.0-151-generic=6.8.0-151.151"])
    end

    it "removes the package when the stock version is not available" do
      stub_commands({})
      expect(ckr.stock_changes("linux-modules-6.8.0-151-generic", "6.8.0-151.151+ubi1")).to eq(["linux-modules-6.8.0-151-generic-"])
      expect(commands).to eq([apt_cache_show("linux-modules-6.8.0-151-generic=6.8.0-151.151")])
    end
  end
end
