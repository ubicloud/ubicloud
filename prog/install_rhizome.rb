# frozen_string_literal: true

class Prog::InstallRhizome < Prog::Base
  def sshable
    @sshable ||= Sshable[frame["sshable_id"]]
  end

  def start
    require "rubygems/package"
    require "stringio"

    sshable.connect.open_channel do |channel|
      channel.exec("tar xf -") do |ch, success|
        raise "could not execute command" unless success

        # Print stdout.
        channel.on_data do |ch, data|
          $stdout.write(data)
        end

        # Print stderr.
        channel.on_extended_data do |ch, data|
          $stderr.write(data)
        end

        tar = StringIO.new
        Gem::Package::TarWriter.new(tar) do |writer|
          base = Config.root + "/rhizome"
          Dir.glob("**/*", base: base).map do |file|
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
            else
              fail "BUG"
            end
          end
        end

        ch.send_data tar.string
        ch.eof!
        ch.wait
      end

      channel.wait
    end.wait

    hop :install_gems
  end

  def install_gems
    sshable.cmd("bundle config set --local path vendor/bundle")
    sshable.cmd("bundle install")
    pop "installed rhizome"
  end
end
