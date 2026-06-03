# frozen_string_literal: true

require "rubygems/package"
require "stringio"
require "openssl"

class Prog::InstallRhizome < Prog::Base
  subject_is :sshable
  semaphore :destroy
  frame_reader :target_folder, :install_specs
  frame_accessor :rhizome_digest

  SKIP_VALIDATION = ["Gemfile.lock"]

  label def start
    tar = StringIO.new
    tar.binmode
    file_hash_map = {} # pun intended
    Gem::Package::TarWriter.new(tar) do |writer|
      base = Config.root + "/rhizome"
      Dir.glob(["Gemfile", "Gemfile.lock", "common/**/*", "#{target_folder}/**/*"], base:) do |file|
        next if !install_specs && file.end_with?("_spec.rb")

        full_path = base + "/" + file
        stat = File.stat(full_path)
        if stat.directory?
          writer.mkdir(file, stat.mode)
        elsif stat.file?
          writer.add_file(file, stat.mode) do |tf|
            File.open(full_path, "rb") do
              IO.copy_stream(it, tf)
            end
          end

          file_hash_map[file] = OpenSSL::Digest::SHA384.file(full_path).hexdigest unless SKIP_VALIDATION.include?(file)
        else
          # :nocov:
          fail "BUG"
          # :nocov:
        end
      end

      hashes_json = JSON.generate(file_hash_map.sort.to_h)
      self.rhizome_digest = OpenSSL::Digest::SHA256.hexdigest(hashes_json)[0, 24]
      writer.add_file("hashes.json", 0o100755) do |tf|
        tf.write hashes_json
      end
    end

    payload = tar.string.freeze
    sshable.cmd("tar xf -", stdin: payload)

    hop_install_gems
  end

  label def install_gems
    if target_folder == "host"
      sshable.cmd("bundle config set --local path vendor/bundle && bundle install")
    end

    hop_validate
  end

  label def validate
    sshable.cmd("common/bin/validate")
    folder = target_folder
    commit = Config.git_commit_hash
    digest = rhizome_digest
    RhizomeInstallation.dataset.insert_conflict(
      target: :id,
      update: {folder:, commit:, digest:, installed_at: Sequel::CURRENT_TIMESTAMP},
    ).insert(id: sshable.id, folder:, commit:, digest:)

    pop "installed rhizome"
  end
end
