# frozen_string_literal: true

class Prog::LearnStorage < Prog::Base
  subject_is :sshable

  def parse_size_gib(storage_root, s)
    sizes = s.each_line.filter_map do |line|
      next unless line =~ /^\s*([\d.]+)(\w+)$/
      if $2 == "G"
        Float($1).floor
      elsif $2 == "T"
        (Float($1) * 1024).floor
      else
        # Fail noisily if unit is not in gigabytes or terabytes
        fail "BUG: unexpected storage size unit: #{$2}"
      end
    end

    fail "BUG: expected one size for #{storage_root}, but received: [#{sizes.join(", ")}]" unless sizes.length == 1

    sizes.first
  end

  label def start
    storage_root = "/var"
    total_storage_gib = parse_size_gib(storage_root, sshable.cmd("df -h --output=size #{storage_root}"))
    reported_available_storage_gib = parse_size_gib(storage_root, sshable.cmd("df -h --output=avail #{storage_root}"))

    # reserve 5G for future host related stuff
    available_storage_gib = [0, reported_available_storage_gib - 5].max
    pop total_storage_gib: total_storage_gib, available_storage_gib: available_storage_gib
  end
end
