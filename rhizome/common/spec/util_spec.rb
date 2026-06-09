# frozen_string_literal: true

require_relative "../lib/util"
require "tmpdir"
require "fileutils"
require "openssl"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "util" do
  # rubocop:enable RSpec/DescribeClass
  describe "fsync_or_fail" do
    it "calls fsync on the given file" do
      f = instance_double(File)
      expect(f).to receive(:fsync)
      fsync_or_fail(f)
    end

    it "raises FsyncFail when fsync raises SystemCallError" do
      f = instance_double(File)
      expect(f).to receive(:fsync).and_raise(Errno::EIO, "fsync error")
      expect { fsync_or_fail(f) }.to raise_error(FsyncFail, /fsync error/)
    end
  end

  describe "sync_parent_dir" do
    it "fsyncs the parent directory of the given path" do
      dir_file = instance_double(File)
      expect(File).to receive(:open).with("/some/dir").and_yield(dir_file)
      expect(dir_file).to receive(:fsync)
      sync_parent_dir("/some/dir/file.txt")
    end
  end

  describe "safe_write_to_file" do
    it "raises ArgumentError when neither content nor block is provided" do
      Dir.mktmpdir do |dir|
        expect { safe_write_to_file("#{dir}/test") }.to raise_error(ArgumentError, /must provide either content or block/)
      end
    end

    it "raises ArgumentError when both content and block are provided" do
      Dir.mktmpdir do |dir|
        expect { safe_write_to_file("#{dir}/test", "content") { |f| } }.to raise_error(ArgumentError, /must provide either content or block/)
      end
    end

    it "supports the block form for writing" do
      Dir.mktmpdir do |dir|
        path = "#{dir}/test.txt"
        safe_write_to_file(path) do |f|
          f.write("block content")
        end
        expect(File.read(path)).to eq("block content")
      end
    end
  end

  describe "validate_keys" do
    it "accepts a hash with all required and no extra keys" do
      expect { validate_keys("ctx", [:a, :b], [:c], {a: 1, b: 2}) }.not_to raise_error
    end

    it "accepts a hash with required keys and allowed optional keys" do
      expect { validate_keys("ctx", [:a], [:b], {a: 1, b: 2}) }.not_to raise_error
    end

    it "raises ArgumentError for missing required keys" do
      expect { validate_keys("ctx", [:a, :b], [], {a: 1}) }.to raise_error(ArgumentError, /Missing required keys in ctx: b/)
    end

    it "raises ArgumentError for unexpected extra keys" do
      expect { validate_keys("ctx", [:a], [], {a: 1, z: 99}) }.to raise_error(ArgumentError, /Unexpected keys in ctx: z/)
    end
  end

  describe "curl_file" do
    it "calls r with curl command and returns the sha256 hash" do
      url = "https://example.com/file.gz"
      path = "/tmp/file.gz"
      expect(self).to receive(:r).with("bash -c 'curl -f -L3 #{url.shellescape} | tee >(openssl dgst -sha256) > #{path.shellescape}'").and_return("SHA2-256(stdin)= #{"a" * 64}")
      expect(curl_file(url, path)).to eq("a" * 64)
    end
  end

  describe "r" do
    it "raises CommandFail when command exits with non-zero status" do
      expect { r("false") }.to raise_error(CommandFail, /command failed: false/)
    end
  end

  describe "rm_if_exists" do
    it "removes an existing path" do
      Dir.mktmpdir do |dir|
        path = "#{dir}/test_file"
        FileUtils.touch(path)
        expect(File).to exist(path)
        rm_if_exists(path)
        expect(File).not_to exist(path)
      end
    end

    it "does nothing if the path does not exist" do
      expect { rm_if_exists("/nonexistent/path/that/does/not/exist") }.not_to raise_error
    end
  end
end
