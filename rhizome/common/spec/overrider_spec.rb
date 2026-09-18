# frozen_string_literal: true

require_relative "../lib/overrider_enabled"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "open3"

RSpec.describe Overrider do
  describe ".load" do
    # A tree shaped like the guest, so ROOT resolves as it does on a host.
    def with_tree(overrides)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(["#{dir}/common/lib", "#{dir}/postgres/lib"])
        FileUtils.cp("#{__dir__}/../lib/overrider_enabled.rb", "#{dir}/common/lib/overrider_enabled.rb")
        File.write("#{dir}/common/lib/overrider.rb", "require_relative \"overrider_enabled\"\n")
        overrides.each do |name, body|
          path = "#{dir}/postgres/override/#{name}"
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, body)
        end
        yield dir
      end
    end

    # Run in a subprocess: ROOT is a load-time constant of the copied file.
    def run(dir, script)
      File.write("#{dir}/postgres/lib/subject.rb", script)
      Open3.capture2e({"RUBYOPT" => nil}, RbConfig.ruby, "-e", <<~PROBE).first
        require "#{dir}/common/lib/overrider.rb"
        require "#{dir}/postgres/lib/subject.rb"
      PROBE
    end

    it "loads the override mirroring the patched file's path" do
      with_tree("lib/subject.rb" => <<~OVERRIDE) do |dir|
        class Subject
          module PrependMethods
            def patterns
              super + [:deployment]
            end
          end
          prepend PrependMethods
        end
      OVERRIDE
        out = run(dir, <<~SUBJECT)
          class Subject
            UPSTREAM = [:upstream]
            def patterns
              UPSTREAM
            end
          end
          Overrider.load(__FILE__)
          print Subject.new.patterns.inspect
        SUBJECT

        expect(out).to eq "[:upstream, :deployment]"
      end
    end

    it "lets an override read what the class body defined" do
      with_tree("lib/subject.rb" => "class Subject; READ = UPSTREAM.first; end") do |dir|
        out = run(dir, <<~SUBJECT)
          class Subject
            UPSTREAM = [:upstream]
          end
          Overrider.load(__FILE__)
          print Subject::READ.inspect
        SUBJECT

        expect(out).to eq ":upstream"
      end
    end

    it "lets an override reopen a subclass without naming its superclass" do
      with_tree("lib/subject.rb" => "class Subject; def kind = :overridden; end") do |dir|
        out = run(dir, <<~SUBJECT)
          class Subject < StandardError
          end
          Overrider.load(__FILE__)
          print Subject.new.kind.inspect, Subject.superclass
        SUBJECT

        expect(out).to eq ":overriddenStandardError"
      end
    end

    it "does nothing when the file has no override" do
      with_tree({}) do |dir|
        out = run(dir, "class Subject; end\nOverrider.load(__FILE__)\nprint :ok")

        expect(out).to eq "ok"
      end
    end

    # In process, so the loader's own lines are measured.
    it "requires the mirrored override and ignores a file without one" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(["#{root}/postgres/lib", "#{root}/postgres/override/lib"])
        patched = "#{root}/postgres/lib/in_process.rb"
        File.write(patched, "")
        marker = "#{root}/marker"
        File.write("#{root}/postgres/override/lib/in_process.rb", "File.write(#{marker.inspect}, \"loaded\")")
        described_class.load(patched, root: root)
        expect(File.read(marker)).to eq "loaded"

        unpatched = "#{root}/postgres/lib/no_override.rb"
        File.write(unpatched, "")
        expect { described_class.load(unpatched, root: root) }.not_to raise_error
      end
    end
  end
end
