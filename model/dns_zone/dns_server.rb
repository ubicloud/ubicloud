# frozen_string_literal: true

require_relative "../../model"

class DnsServer < Sequel::Model
  many_to_many :dns_zones
  many_to_many :vms

  include ResourceMethods

  def run_commands_on_all_vms(commands)
    vms.each do |vm|
      outputs = vm.sshable.cmd("sudo -u knot knotc", stdin: commands.join("\n")).split("\n")

      # Passing multiple commands to knotc via stdin is faster compared to running each
      # command one by one. However, this approach has one drawback; in stdin mode knotc
      # always with 0 exit code (i.e. no errors would be raised). At least, errors are
      # being written to stdout, so we can search them manually to see if we need to
      # raise any errors.
      outputs.each_with_index do |output, index|
        next if output == "OK"
        next if index == 0 && output.include?("no active transaction")
        next if commands[index].include?("zone-set") && output.include?("such record already exists in zone")
        next if commands[index].include?("zone-unset") && output.include?("no such record in zone found")

        raise "Rectify failed on #{self}. Command: #{commands[index]}. Output: #{output}"
      end
    end
  end
end
