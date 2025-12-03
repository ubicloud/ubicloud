# frozen_string_literal: true

# Run with: bundle exec rspec -O /dev/null spec/rubocop/cop/custom/safe_shell_command_spec.rb

require_relative "../../../coverage_helper"
require "rubocop"
require "rubocop/rspec/support"
require_relative "../../../../rubocop/cop/custom/safe_shell_command"

RSpec.configure do |config|
  config.include RuboCop::RSpec::ExpectOffense
end

RSpec.describe RuboCop::Cop::Custom::SafeShellCommand do
  subject(:cop) { described_class.new(config) }

  let(:config) { RuboCop::Config.new }

  # ============================================================================
  # Category 1: False Positives & Ignored Patterns
  # ============================================================================
  context "when ignoring valid or irrelevant calls" do
    it "ignores literal strings (assumed intentional)" do
      expect_no_offenses(<<~RUBY)
        cmd("echo hello world")
        cmd("ls > output.txt")
        cmd("git status")
      RUBY
    end

    it "ignores non-string arguments" do
      expect_no_offenses(<<~RUBY)
        cmd(:symbol)
        cmd(1234)
        cmd(["array", "args"])
      RUBY
    end

    it "ignores empty strings" do
      expect_no_offenses('cmd("")')
    end

    it "ignores implicit calls to `cmd` with no arguments" do
      expect_no_offenses("result = cmd")
    end

    it "ignores calls to `cmd` on explicit constants" do
      expect_no_offenses('Open3.cmd("foo #{bar}")')
      expect_no_offenses('Shellwords.cmd("foo #{bar}")')
    end

    it "ignores `cmd` used as a local variable or splat" do
      expect_no_offenses(<<~RUBY)
        args = ["echo", "test"]
        runner.run(*args)
      RUBY
    end
  end

  # ============================================================================
  # Category 2: Unsafe Shell Operators (Detection Only)
  # ============================================================================
  context "when flagging unsafe shell operators (no autocorrect)" do
    it "flags pipes `|`" do
      expect_offense(<<~RUBY)
        cmd("find \#{dir} | grep pattern")
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Unsafe interpolation. Converting to `%W[]` will safely escape arguments, but this disables shell features in: ["|"].
      RUBY
      expect_no_corrections
    end

    it "flags redirects `>` and `2>&1`" do
      expect_offense(<<~RUBY)
        cmd("cat \#{file} > /dev/null 2>&1")
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Unsafe interpolation. Converting to `%W[]` will safely escape arguments, but this disables shell features in: [">", "2>&1"].
      RUBY
      expect_no_corrections
    end

    it "flags brackets `[]` because they act as shell globs" do
      expect_offense(<<~RUBY)
        cmd("echo [bracket] \#{foo}")
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Unsafe interpolation. Converting to `%W[]` will safely escape arguments, but this disables shell features in: ["[bracket]"].
      RUBY
      expect_no_corrections
    end
  end

  # ============================================================================
  # Category 3: Manual Intervention Required (Punting)
  # ============================================================================
  context "when handling structures too complex to safely autocorrect" do
    it "errors on Heredocs but does not attempt to rewrite them" do
      expect_offense(<<~RUBY)
        cmd(<<~SHELL)
        ^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. This structure (heredoc or mid-word concatenation) cannot be safely autocorrected to `%W[]`. Please refactor manually.
          echo one \#{foo}
          echo two
        SHELL
      RUBY
      expect_no_corrections
    end

    it "errors on mid-word string concatenation (risk of splitting one arg into two)" do
      expect_offense(<<~RUBY)
        cmd("curl https://very-long-url-" \\
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. This structure (heredoc or mid-word concatenation) cannot be safely autocorrected to `%W[]`. Please refactor manually.
            "part2")
      RUBY
      expect_no_corrections
    end
  end

  # ============================================================================
  # Category 4: Autocorrection Logic
  # ============================================================================
  context "when autocorrecting safe interpolations" do
    # --- Sub-group: Basic Functionality ---
    it "converts basic interpolation to %W[]" do
      expect_offense(<<~RUBY)
        cmd("git commit -m \#{message}")
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
      RUBY

      expect_correction(<<~RUBY)
        cmd(%W[git commit -m \#{message}])
      RUBY
    end

    # --- Sub-group: Unwrapping Logic ---
    describe "redundant escape removal" do
      it "removes `.shellescape` from interpolated variables" do
        expect_offense(<<~RUBY)
          cmd("sudo rm -rf \#{path.shellescape}")
          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
        RUBY
        expect_correction(<<~RUBY)
          cmd(%W[sudo rm -rf \#{path}])
        RUBY
      end

      it "removes `Shellwords.escape(...)` wrapper" do
        expect_offense(<<~RUBY)
          cmd("echo \#{Shellwords.escape(foo)}")
          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
        RUBY
        expect_correction(<<~RUBY)
          cmd(%W[echo \#{foo}])
        RUBY
      end
    end

    # --- Sub-group: Safe Concatenation ---
    describe "safe multiline concatenation" do
      it "autocorrects splits that happen at whitespace boundaries" do
        expect_offense(<<~'RUBY')
          cmd("echo arg1 " \
          ^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
              "arg2")
        RUBY

        expect_correction(<<~RUBY)
          cmd(%W[echo arg1 
          arg2])
        RUBY
      end

      it "autocorrects safe splits involving interpolation" do
        expect_offense(<<~'RUBY')
          cmd("ip -n #{@ns} addr add " \
          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
              "#{addr} dev #{dev}")
        RUBY

        expect_correction(<<~'RUBY')
          cmd(%W[ip -n #{@ns} addr add 
          #{addr} dev #{dev}])
        RUBY
      end
    end

    # --- Sub-group: Data Integrity (The Backslash Trap) ---
    describe "literal backslash handling" do
      it "safely escapes literal backslashes in generated code (Unit Test via Stub)" do
        expect(Shellwords).to receive(:escape).and_wrap_original do |original, word|
          (word == "\\t") ? word : original.call(word)
        end.at_least(:once)

        expect_offense(<<~RUBY)
          cmd("grep \\\\t \#{file}")
          ^^^^^^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
        RUBY

        expect_correction(<<~RUBY)
          cmd(%W[grep \\\\t \#{file}])
        RUBY
      end
    end

    # --- Sub-group: Robustness ---
    describe "robustness (handling diverse node types)" do
      it "handles instance variables" do
        expect_offense(<<~RUBY)
          cmd("echo \#{@foo}")
          ^^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
        RUBY
        expect_correction(<<~RUBY)
          cmd(%W[echo \#{@foo}])
        RUBY
      end

      it "handles constants" do
        expect_offense(<<~RUBY)
          cmd("echo \#{FOO}")
          ^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
        RUBY
        expect_correction(<<~RUBY)
          cmd(%W[echo \#{FOO}])
        RUBY
      end

      it "handles empty interpolation" do
        expect_offense(<<~RUBY)
          cmd("echo \#{}")
          ^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
        RUBY
        expect_correction(<<~RUBY)
          cmd(%W[echo \#{}])
        RUBY
      end

      it "handles method calls that are NOT escapes" do
        expect_offense(<<~RUBY)
          cmd("echo \#{foo.upcase}")
          ^^^^^^^^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
        RUBY
        expect_correction(<<~RUBY)
          cmd(%W[echo \#{foo.upcase}])
        RUBY
      end

      it "handles `escape` methods from other classes" do
        expect_offense(<<~RUBY)
          cmd("echo \#{Other.escape(foo)}")
          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
        RUBY
        expect_correction(<<~RUBY)
          cmd(%W[echo \#{Other.escape(foo)}])
        RUBY
      end

      it "handles `shellescape` called without a receiver" do
        expect_offense(<<~RUBY)
          cmd("echo \#{shellescape}")
          ^^^^^^^^^^^^^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
        RUBY
        expect_correction(<<~RUBY)
          cmd(%W[echo \#{shellescape}])
        RUBY
      end
    end

    # --- Sub-group: Coverage Gaps (Hitting Missed Branches) ---
    describe "edge cases for coverage" do
      it "handles single-component dstr (no split possible)" do
        expect_offense(<<~RUBY)
          cmd("\#{foo}")
          ^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
        RUBY
        expect_correction(<<~RUBY)
          cmd(%W[\#{foo}])
        RUBY
      end

      it "handles split where first part ends in interpolation (unsafe)" do
        expect_offense(<<~RUBY)
          cmd("\#{foo}" \\
          ^^^^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. This structure (heredoc or mid-word concatenation) cannot be safely autocorrected to `%W[]`. Please refactor manually.
              "bar")
        RUBY
        expect_no_corrections
      end

      it "handles split where second part starts with interpolation (unsafe)" do
        expect_offense(<<~RUBY)
          cmd("foo" \\
          ^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. This structure (heredoc or mid-word concatenation) cannot be safely autocorrected to `%W[]`. Please refactor manually.
              "\#{bar}")
        RUBY
        expect_no_corrections
      end

      it "handles split where second part is a dstr starting with space (safe)" do
        expect_offense(<<~RUBY)
          cmd("foo" \\
          ^^^^^^^^^^^ Custom/SafeShellCommand: Avoid interpolation in shell commands. Use `cmd(%W[...])` instead.
              " bar \#{baz}")
        RUBY

        expect_correction(<<~RUBY)
          cmd(%W[foo
           bar \#{baz}])
        RUBY
      end
    end
  end
end
