# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Pagination do
  let(:project) { Project.create_with_id(name: "default") }

  let!(:first_vm) do
    Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "dummy-vm-1").subject
  end

  let!(:second_vm) do
    Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "dummy-vm-2").subject
  end

  describe "#validate_paginated_result" do
    describe "success" do
      it "order column" do
        result = project.vms_dataset.paginated_result(order_column: "name")
        expect(result[:records][0].ubid).to eq(first_vm.ubid)
        expect(result[:records][1].ubid).to eq(second_vm.ubid)
      end

      it "page size 1" do
        result = project.vms_dataset.paginated_result(page_size: 1)
        expect(result[:records].length).to eq(1)
        expect(result[:count]).to eq(2)
      end

      it "page size 2" do
        result = project.vms_dataset.paginated_result(page_size: 2)
        expect(result[:records].length).to eq(2)
        expect(result[:count]).to eq(2)
      end

      it "last resource" do
        result = project.vms_dataset.paginated_result(page_size: 3, order_column: "name")
        expect(result[:records][-1].name).to eq(second_vm.name)
      end

      it "partial name" do
        result = project.vms_dataset.paginated_result(page_size: 1, order_column: "name", start_after: "dummy-vm")
        expect(result[:records][0].name).to eq(first_vm.name)
      end

      it "negative page size" do
        result = project.vms_dataset.paginated_result(page_size: -1)
        expect(result[:records].length).to eq(1)
      end

      it "more objects than requested page size" do
        3.times do |index|
          ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "additional-ps-#{index}", location_id: Location::HETZNER_FSN1_ID).subject
          Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "additional-vm-#{index}", private_subnet_id: ps.id).subject
        end

        result = project.vms_dataset.paginated_result(page_size: 2)
        expect(result[:records].length).to eq(2)
      end

      it "empty page" do
        result = project.vms_dataset.paginated_result(start_after: second_vm.name, order_column: "name")
        expect(result[:records].length).to eq(0)
        expect(result[:count]).to eq(2)
      end
    end

    describe "unsuccesful" do
      it "invalid start after" do
        expect { project.vms_dataset.paginated_result(start_after: "invalidubid") }.to raise_error(Validation::ValidationFailed)
      end

      it "invalid order column" do
        expect { project.vms_dataset.paginated_result(order_column: "non-existing-column") }.to raise_error(Validation::ValidationFailed)
      end

      it "non numeric page size" do
        expect { project.vms_dataset.paginated_result(page_size: "foo") }.to raise_error(Validation::ValidationFailed)
      end
    end
  end
end
