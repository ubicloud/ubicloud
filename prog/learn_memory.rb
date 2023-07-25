# frozen_string_literal: true

class Prog::LearnMemory < Prog::Base
  subject_is :sshable

  def parse_sum(s)
    s.each_line.filter_map do |line|
      next unless line =~ /\A\s*Size: (\d+) (\w+)/
      # Fail noisily if unit is not in gigabytes
      fail "BUG: unexpected dmidecode unit" unless $2 == "GB"
      Integer($1)
    end.sum
  end

  label def start
    # Use dmidecode to get an integral amount of system memory.
    # Generally, there is a gigabyte or so less available to
    # applications than installed as reported by /proc/meminfo.
    #
    # Thus, in practice we can't run VMs at 100% system size anyway,
    # we'll have to leave padding, but to keep the ratios neat for the
    # customer, we compute CPU memory allocation ratio against
    # physical memory.
    mem_gib = parse_sum(sshable.cmd("sudo /usr/sbin/dmidecode -t memory | fgrep Size:"))
    pop mem_gib: mem_gib
  end
end
