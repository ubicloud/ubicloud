# frozen_string_literal: true

class Prog::LearnStorage < Prog::Base
  subject_is :sshable

  ParseDf = Struct.new(:size_gib, :avail_gib) do
    def self.parse(s)
      m = /\A\s*1B-blocks\s+Avail\n(\d+)\s+(\d+)\s*\n\z/.match(s)
      fail "BUG: unexpected output from df" unless m
      new(*m.captures.map { Integer(_1) / 1073741824 })
    end
  end

  def df_command(path) = "df -B1 --output=size,avail #{path}"

  label def start
    q_var_root = "/var".shellescape.freeze
    q_storage_root = "/var/storage".shellescape.freeze

    # For GitHub runner hosts, we mount /var/storage from a separate btrfs disk
    # partition. As a result, /var does not include the size of /var/storage,
    # which has more storage. We can't check the size of /var/storage directly,
    # because it might not there for other hosts at this step. Until we unify
    # our hosts with ext4 disks, we check /var/storage only if exists.
    output = sshable.cmd("if [ -d #{q_storage_root} ]; then #{df_command(q_storage_root)}; else #{df_command(q_var_root)}; fi")
    parsed = ParseDf.parse(output)

    # reserve 5G for future host related stuff
    available_storage_gib = [0, parsed.avail_gib - 5].max
    pop total_storage_gib: parsed.size_gib, available_storage_gib: available_storage_gib
  end
end
