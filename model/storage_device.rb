# frozen_string_literal: true

require_relative "../model"
require_relative "../lib/system_parser"

class StorageDevice < Sequel::Model
  include ResourceMethods

  many_to_one :vm_host

  def self.ubid_type
    UBID::TYPE_ETC
  end

  def set_underlying_unix_devices
    df_command_path = (name == "DEFAULT") ? "/var/storage" : "/var/storage/devices/#{name}"
    df_command_output = vm_host.sshable.cmd(SystemParser.df_command(df_command_path))

    unix_device_name = SystemParser.extract_disk_info_from_df(df_command_output).first.unix_device
    if unix_device_name.start_with?("/dev/md") # we are dealing with raided disk
      mdstat_file_content = vm_host.sshable.cmd("cat /proc/mdstat")
      self.unix_device_list = SystemParser.extract_underlying_raid_devices_from_mdstat(mdstat_file_content, unix_device_name)
    else
      self.unix_device_list = [unix_device_name.delete_prefix("/dev/")]
    end

    save_changes
  end
end

# Table: storage_device
# Columns:
#  id                    | uuid    | PRIMARY KEY
#  name                  | text    | NOT NULL
#  total_storage_gib     | integer | NOT NULL
#  available_storage_gib | integer | NOT NULL
#  enabled               | boolean | NOT NULL DEFAULT true
#  vm_host_id            | uuid    |
#  unix_device_list      | text[]  |
# Indexes:
#  storage_device_pkey                | PRIMARY KEY btree (id)
#  storage_device_vm_host_id_name_key | UNIQUE btree (vm_host_id, name)
# Check constraints:
#  available_storage_gib_less_than_or_equal_to_total | (available_storage_gib <= total_storage_gib)
#  available_storage_gib_non_negative                | (available_storage_gib >= 0)
# Foreign key constraints:
#  storage_device_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  vm_storage_volume | vm_storage_volume_storage_device_id_fkey | (storage_device_id) REFERENCES storage_device(id)
