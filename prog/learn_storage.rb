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

  def make_model_instances
    devices = DfRecord.parse_all(sshable.cmd(df_command))
    rec = DfRecord.parse_all(sshable.cmd(df_command("/var/storage"))).first
    sds = [StorageDevice.new_with_id(
      vm_host_id: vm_host.id, name: "DEFAULT",
      # reserve 5G the host.
      available_storage_gib: [rec.avail_gib - 5, 0].max,
      total_storage_gib: rec.size_gib
    )]

    devices.each do |rec|
      next unless (name = rec.optional_name)
      sds << StorageDevice.new_with_id(
        vm_host_id: vm_host.id, name: name,
        available_storage_gib: rec.avail_gib,
        total_storage_gib: rec.size_gib
      )
    end

    sds
  end

  label def start
    make_model_instances.each do |sd|
      sd.skip_auto_validations(:unique) do
        sd.insert_conflict(target: [:vm_host_id, :name],
          update: {
            total_storage_gib: Sequel[:excluded][:total_storage_gib],
            available_storage_gib: Sequel[:excluded][:available_storage_gib]
          }).save_changes
      end
    end

    pop("created StorageDevice records")
  end
end
