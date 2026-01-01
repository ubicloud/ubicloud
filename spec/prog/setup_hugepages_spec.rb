# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupHugepages do
  describe "#start" do
    it "pops after installing hugepages" do
      vm_host = Prog::Vm::HostNexus.assemble("::1").subject
      vm_host.update(total_mem_gib: 64)
      sh = described_class.new(Strand.new(stack: [{"subject_id" => vm_host.id}], prog: "SetupHugepages"))
      expect(sh.sshable).to receive(:_cmd).with("sudo sed -i '/^GRUB_CMDLINE_LINUX=\"/ s/\"$/ hugetlb_free_vmemmap=on default_hugepagesz='1G' hugepagesz='1G' hugepages='59'&/' /etc/default/grub")
      expect(sh.sshable).to receive(:_cmd).with("sudo update-grub")
      expect { sh.start }.to exit({"msg" => "hugepages installed"})
    end
  end
end
