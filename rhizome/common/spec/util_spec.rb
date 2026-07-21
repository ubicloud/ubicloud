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
      Dir.mktmpdir do |dir|
        File.open(dir) do |f|
          expect(fsync_or_fail(f)).to eq 0
        end
      end
    end

    it "raises FsyncFail when fsync raises SystemCallError" do
      f = instance_double(File)
      expect(f).to receive(:fsync).and_raise(Errno::EIO, "fsync error")
      expect { fsync_or_fail(f) }.to raise_error(FsyncFail, /fsync error/)
    end
  end

  describe "sync_parent_dir" do
    it "fsyncs the parent directory of the given path" do
      Dir.mktmpdir do |dir|
        expect(sync_parent_dir("#{dir}/nonexistant")).to eq 0
      end
    end
  end

  describe "safe_write_to_file" do
    it "raises ArgumentError when neither content nor block is provided" do
      expect { safe_write_to_file("test") }.to raise_error(ArgumentError, /must provide either content or block/)
    end

    it "raises ArgumentError when both content and block are provided" do
      expect { safe_write_to_file("test", "content") {} }.to raise_error(ArgumentError, /must provide either content or block/)
    end

    it "supports passing a string for file content" do
      Dir.mktmpdir do |dir|
        path = "#{dir}/test.txt"
        safe_write_to_file(path, "string content")
        expect(File.read(path)).to eq("string content")
      end
    end

    it "passes File to the block" do
      Dir.mktmpdir do |dir|
        path = "#{dir}/test.txt"
        safe_write_to_file(path) do |f|
          f.write("block content")
        end
        expect(File.read(path)).to eq("block content")
      end
    end

    it "drops a stale temp so the block path never publishes an old tail" do
      Dir.mktmpdir do |dir|
        path = "#{dir}/test.txt"
        File.write("#{path}.tmp", "stale-and-longer-than-the-new-content")
        safe_write_to_file(path) do |f|
          f.write("fresh")
        end
        expect(File.read(path)).to eq("fresh")
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

  describe "cmd" do
    it "interpolates variables into string" do
      expect(cmd("a :b :c d", b: 1, c: "e f")).to eq "a 1 e\\ f d"
    end

    it "handles shelljoin interpolation" do
      expect(cmd("a :b :shelljoin_c d", b: 1, shelljoin_c: ["e f", "g"])).to eq "a 1 e\\ f g d"
    end

    it "returns string when not given keyword" do
      s = "a d"
      expect(cmd(s)).to be s
    end

    it "raises for interpolated strings with keywords" do
      c = ":c"
      expect { cmd("a :b #{c} d", b: 1, c: "e f") }.to raise_error(PotentialInsecurity)
      expect { cmd("a #{c}", c: "e f") }.to raise_error(PotentialInsecurity)
    end

    it "raises for non-strings" do
      o = Object.new
      expect { cmd(o) }.to raise_error(TypeError)
      expect { cmd(o, b: 1) }.to raise_error(TypeError)
    end

    it "raises for placeholder inside quotes" do
      expect { cmd("a ':c'", c: "a") }.to raise_error(PotentialInsecurity)
      expect { cmd('a ":c"', c: "a") }.to raise_error(PotentialInsecurity)
    end

    it "raises for unterminated quotes" do
      expect { cmd(":c '", c: "a") }.to raise_error(PotentialInsecurity)
      expect { cmd(':c "', c: "a") }.to raise_error(PotentialInsecurity)
      expect { cmd(":c 'a", c: "a") }.to raise_error(PotentialInsecurity)
      expect { cmd(':c "a', c: "a") }.to raise_error(PotentialInsecurity)
    end

    it "works with comments with '" do
      expect(cmd("# isn't it fun\n:c", c: "e f")).to eq "# isn't it fun\ne\\ f"
    end

    it "works for placeholders after quotes" do
      c = "e f"
      expect(cmd("'' :c a", c: c)).to eq "'' e\\ f a"
      expect(cmd('"" :c', c: c)).to eq "\"\" e\\ f"
      expect(cmd("\\' :c", c: c)).to eq "\\' e\\ f"
      expect(cmd('\\" :c', c: c)).to eq "\\\" e\\ f"
      expect(cmd("'\"' :c", c: c)).to eq "'\"' e\\ f"
      expect(cmd('"\'" :c', c: c)).to eq "\"'\" e\\ f"
      expect(cmd('"\\"" :c', c: c)).to eq "\"\\\"\" e\\ f"
      expect(cmd("'\"'\"'\" :c", c: c)).to eq "'\"'\"'\" e\\ f"
      expect(cmd("'\\\"'\"'\" :c", c: c)).to eq "'\\\"'\"'\" e\\ f"
    end
  end

  describe "curl_file" do
    it "calls r with curl command and returns the sha256 hash" do
      url = "https://example.com/file.gz"
      path = "/tmp/file.gz"
      expect(self).to receive(:_run_command).with("bash -c curl\\ -f\\ -L3\\ https://example.com/file.gz\\ \\|\\ tee\\ \\>\\(openssl\\ dgst\\ -sha256\\)\\ \\>\\ /tmp/file.gz").and_return("SHA2-256(stdin)= #{"a" * 64}")
      expect(curl_file(url, path)).to eq("a" * 64)
    end
  end

  describe "r" do
    it "delegates to _run_command" do
      expect(self).to receive(:_run_command).with("echo -n a").and_return("a")
      expect(r("echo -n a")).to eq "a"
    end

    it "passes through stdin and expect keywords unchanged" do
      expect(self).to receive(:_run_command).with("echo -n a", stdin: "x", expect: [0, 2]).and_return("a")
      expect(r("echo -n a", stdin: "x", expect: [0, 2])).to eq "a"
    end

    it "raises for an interpolated (non-frozen) single-string command" do
      x = "a"
      expect { r("echo #{x}") }.to raise_error(PotentialInsecurity)
    end

    it "does not raise for a non-frozen string built via cmd" do
      expect(self).to receive(:_run_command).with("echo a").and_return("a")
      expect(r(cmd("echo :x", x: "a"))).to eq "a"
    end

    it "does not raise for multiple positional arguments" do
      x = "a"
      expect(self).to receive(:_run_command).with("echo", x).and_return("a")
      expect(r("echo", x)).to eq "a"
    end
  end

  describe "_run_command" do
    it "raises MissingMock when not mocked and not explicitly skipped" do
      expect { _run_command("echo -n a") }.to raise_error(MissingMock, /_run_command not mocked/)
    end

    it "raises CommandFail when command exits with non-zero status" do
      expect { _run_command("false", _skip_command_checking: true) }.to raise_error(CommandFail, /command failed: false/)
    end

    it "executes command as a string using a shell" do
      expect(_run_command("echo -n a", _skip_command_checking: true)).to eq "a"
      expect(_run_command("true && echo -n a", _skip_command_checking: true)).to eq "a"
    end

    it "executes program directly without a shell when given multiple arguments" do
      expect(_run_command("echo", "-n", "$$", _skip_command_checking: true)).to eq "$$"
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
      expect(rm_if_exists("/nonexistent/path/that/does/not/exist")).to be_nil
    end
  end
end
