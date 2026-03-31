# frozen_string_literal: true

require_relative "../model"

class PrivatelinkAwsResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :private_subnet
  one_to_many :ports, class: :PrivatelinkAwsPort, key: :privatelink_aws_resource_id
  one_to_many :privatelink_aws_vms, key: :privatelink_aws_resource_id
  many_to_many :vms, join_table: :privatelink_aws_vm, left_key: :privatelink_aws_resource_id, right_key: :vm_id
  many_to_many :vm_ports, join_table: :privatelink_aws_vm, right_key: :id, right_primary_key: :privatelink_aws_vm_id, class: :PrivatelinkAwsVmPort, read_only: true

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :add_port, :remove_port

  def display_state
    return "deleting" if destroy_set? || strand.nil? || strand.label == "destroy"
    return "available" if strand.label == "wait"

    "creating"
  end

  def display_location
    private_subnet.display_location
  end

  def location
    private_subnet.location
  end

  def path
    "/location/#{display_location}/privatelink/#{ubid}"
  end

  def add_vm(vm)
    unless vm.nics.any? { |nic| nic.private_subnet_id == private_subnet_id }
      fail "VM must be in the same subnet as PrivateLink"
    end

    DB.transaction do
      pl_vm = add_privatelink_aws_vm(vm_id: vm.id)
      Strand.create_with_id(pl_vm, prog: "Vnet::PrivatelinkAwsVmNexus", label: "start")
    end
  end

  def remove_vm(vm)
    pl_vm = privatelink_aws_vms_dataset[vm_id: vm.id]
    return unless pl_vm

    if pl_vm.strand
      pl_vm.incr_destroy
    else
      pl_vm.destroy
    end
  end

  def add_port(src_port, dst_port)
    DB.transaction do
      port = PrivatelinkAwsPort.create(
        privatelink_aws_resource_id: id,
        src_port:,
        dst_port:
      )

      privatelink_aws_vms.each do |pl_vm|
        pl_vm.add_vm_port(privatelink_aws_port_id: port.id, state: "registering")
      end

      incr_add_port

      port
    end
  end

  def remove_port(port)
    DB.transaction do
      PrivatelinkAwsVmPort.where(privatelink_aws_port_id: port.id)
        .update(state: "deregistering")

      incr_remove_port
    end
  end

  def get_vm_nic(vm)
    vm.nics.find { |nic| nic.private_subnet_id == private_subnet_id }
  end
end

# Table: privatelink_aws_resource
# Columns:
#  id                   | uuid                     | PRIMARY KEY
#  created_at           | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at           | timestamp with time zone | NOT NULL DEFAULT now()
#  private_subnet_id    | uuid                     | NOT NULL
#  nlb_arn              | text                     |
#  service_id           | text                     |
#  service_name         | text                     |
# Indexes:
#  privatelink_aws_resource_pkey                 | PRIMARY KEY btree (id)
#  privatelink_aws_resource_private_subnet_id_index | UNIQUE btree (private_subnet_id)
# Foreign key constraints:
#  privatelink_aws_resource_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
