# frozen_string_literal: true

class Prog::LearnStorage < Prog::Base
  subject_is :sshable, :vm_host

  DfRecord = Struct.new(:optional_name, :size_gib, :avail_gib) do
    def self.parse_all(str)
      s = StringScanner.new(str)
      fail "BUG: df header parse failed" unless s.scan(/\AMounted on\s+1B-blocks\s+Avail\n/)
      out = []

      until s.eos?
        fail "BUG: df data parse failed" unless s.scan(/(.*?)\s+(\d+)\s+(\d+)\s*\n/)
        optional_name = if s.captures.first =~ %r{/var/storage/devices/(.*)?}
          $1
        end
        size_gib, avail_gib = s.captures[1..].map { Integer(_1) / 1073741824 }
        out << DfRecord.new(optional_name, size_gib, avail_gib)
      end

      out.freeze
    end
  end

  def df_command(path = "") = "df -B1 --output=target,size,avail #{path}"

  def storage_device(name)
    vm_host.storage_devices.find { _1.name == name } || StorageDevice.new_with_id(vm_host_id: vm_host.id, name: name)
  end

  def make_model_instances
    devices = DfRecord.parse_all(sshable.cmd(df_command))
    if devices.none? { _1.optional_name }
      rec = DfRecord.parse_all(sshable.cmd(df_command("/var/storage"))).first
      [
        storage_device("DEFAULT").set(
          # reserve 5G the host.
          available_storage_gib: [rec.avail_gib - 5, 0].max,
          total_storage_gib: rec.size_gib
        )
      ]
    else
      devices.filter_map do |rec|
        next unless (name = rec.optional_name)
        storage_device(name).set(
          available_storage_gib: rec.avail_gib,
          total_storage_gib: rec.size_gib
        )
      end
    end
  end

  label def start
    total, avail = make_model_instances.each_with_object([0, 0]) { |sd, accum|
      sd.save_changes
      accum[0] += sd.total_storage_gib
      accum[1] += sd.available_storage_gib
    }
    pop({"total_storage_gib" => total, "available_storage_gib" => avail,
         "msg" => "created StorageDevice records"})
  end
end
