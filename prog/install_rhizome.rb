# frozen_string_literal: true

require "rubygems/package"
require "stringio"
require "digest/md5"

class Prog::InstallRhizome < Prog::Base
  subject_is :sshable

  label def start
    tar = StringIO.new
    hash_map = {} # pun intended
    Gem::Package::TarWriter.new(tar) do |writer|
      base = Config.root + "/rhizome"
      Dir.glob(["Gemfile", "Gemfile.lock", "common/**/*", "#{frame["target_folder"]}/**/*"], base: base) do |file|
        next if !frame["install_specs"] && file.end_with?("_spec.rb")
        full_path = base + "/" + file
        stat = File.stat(full_path)
        if stat.directory?
          writer.mkdir(file, stat.mode)
        elsif stat.file?
          writer.add_file(file, stat.mode) do |tf|
            File.open(full_path, "rb") do
              IO.copy_stream(_1, tf)
            end
          end
          hash_map[file] = Digest::MD5.file(full_path).hexdigest
        else
          # :nocov:
          fail "BUG"
          # :nocov:
        end
      end

      writer.add_file("hashes.json", "100755".to_i(8)) do |tf|
        tf.write hash_map.to_json
      end
    end

    payload = tar.string.freeze
    sshable.cmd("tar xf -", stdin: payload)

    hop_install_gems
  end

  label def install_gems
    sshable.cmd("bundle config set --local path vendor/bundle && bundle install")

    hop_validate
  end

  label def validate
    sshable.cmd("common/bin/validate")

    pop "installed rhizome"
  end
end
