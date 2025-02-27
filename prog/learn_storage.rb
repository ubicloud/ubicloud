# frozen_string_literal: true

require_relative "../lib/system_parser"

class Prog::LearnStorage < Prog::Base
  subject_is :sshable, :vm_host

  def make_model_instances
    devices = SystemParser.extract_disk_info_from_df(sshable.cmd(SystemParser.df_command))
    rec = SystemParser.extract_disk_info_from_df(sshable.cmd(SystemParser.df_command("/var/storage"))).first
    sds = [StorageDevice.new_with_id(
      vm_host_id: vm_host.id, name: "DEFAULT",
      # reserve 5G the host.
      available_storage_gib: [rec.avail_gib - 5, 0].max,
      total_storage_gib: rec.size_gib,
      unix_device_list: find_underlying_unix_device_ids(rec.unix_device)
    )]

    devices.each do |rec|
      next unless (name = rec.optional_name)
      sds << StorageDevice.new_with_id(
        vm_host_id: vm_host.id, name: name,
        available_storage_gib: rec.avail_gib,
        total_storage_gib: rec.size_gib,
        unix_device_list: find_underlying_unix_device_ids(rec.unix_device)
      )
    end

    sds
  end

  def find_underlying_unix_device_ids(unix_device)
    device_names = find_underlying_unix_device_names(unix_device)
    device_names.map { |device_name| StorageDevice.convert_device_name_to_device_id(sshable, device_name) }
  end

  def find_underlying_unix_device_names(unix_device)
    return [unix_device.delete_prefix("/dev/")] unless unix_device.start_with?("/dev/md")
    SystemParser.extract_underlying_raid_devices_from_mdstat(sshable.cmd("cat /proc/mdstat"), unix_device)
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
