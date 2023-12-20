# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnStorage do
  describe "#start" do
    it "exits, saving StorageDevice model instances" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      ls = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      expect(ls.sshable).to receive(:cmd).with("df -B1 --output=target,size,avail ").and_return(<<EOS)
Mounted on                   1B-blocks        Avail
/var/storage/devices/stor1   205520896     99571712
/var/storage/devices/stor2  3331416064   3331276800
EOS

      expect { ls.start }.to exit({"total_storage_gib" => 3, "available_storage_gib" => 3, "msg" => "created StorageDevice records"}).and change {
        StorageDevice.map(&:name).sort
      }.from([]).to(%w[stor1 stor2])
    end
  end

  describe Prog::LearnStorage, "#make_model_instances" do
    subject(:ls) { described_class.new(Strand.new) }

    let(:sshable) { instance_double(Sshable) }
    let(:vmh) { instance_double(VmHost, id: "746976d6-315b-8f71-95e6-367c4ac068d7") }

    before do
      expect(ls).to receive(:sshable).and_return(sshable).at_least(:once)
      expect(ls).to receive(:vm_host).and_return(vmh).at_least(:once)
    end

    it "can parse multiple file systems in /var/storage/NAME" do
      expect(sshable).to receive(:cmd).with("df -B1 --output=target,size,avail ").and_return(<<EOS)
Mounted on                   1B-blocks        Avail
/run                        3331420160   3328692224
/                         452564664320 381456842752
/dev/shm                   16657084416  16605118464
/run/lock                      5242880      5234688
/sys/firmware/efi/efivars       448412        74256
/boot                       2024529920   1641877504
/var/storage/devices/stor1   205520896     99571712
/var/storage/devices/stor2  3331416064   3331276800
EOS

      expect(ls.make_model_instances.map(&:name)).to eq(%w[stor1 stor2])
    end

    it "can use any file system that is present at '/var/storage'" do
      expect(sshable).to receive(:cmd).with("df -B1 --output=target,size,avail ").and_return(<<EOS)
Mounted on                   1B-blocks        Avail
/run                        3331420160   3328692224
/                         452564664320 381456842752
/dev/shm                   16657084416  16605118464
/run/lock                      5242880      5234688
/sys/firmware/efi/efivars       448412        74256
/boot                       2024529920   1641877504
EOS

      expect(sshable).to receive(:cmd).with("df -B1 --output=target,size,avail /var/storage").and_return(<<EOS)
Mounted on                   1B-blocks        Avail
/                         452564664320 381456842752
EOS

      expect(ls.make_model_instances.map(&:name)).to eq(%w[DEFAULT])
    end
  end

  describe Prog::LearnStorage::DfRecord do
    it "raises an error" do
      expect {
        described_class.parse_all("")
      }.to raise_error RuntimeError, "BUG: df header parse failed"
    end

    #     it "can scan many entries" do
    #       p described_class.parse_all <<EOS
    # Mounted on                   1B-blocks        Avail
    # /run                        3331420160   3328692224
    # /                         452564664320 381456842752
    # /dev/shm                   16657084416  16605118464
    # /run/lock                      5242880      5234688
    # /sys/firmware/efi/efivars       448412        74256
    # /boot                       2024529920   1641877504
    # /var/storage                 205520896     99571712
    # /var/storage/test_name       3331416064   3331276800
    # EOS
    #     end
  end
end
