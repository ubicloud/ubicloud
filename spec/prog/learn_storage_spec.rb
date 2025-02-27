# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnStorage do
  describe "#start" do
    it "exits, saving StorageDevice model instances" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      ls = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      expect(ls.sshable).to receive(:cmd).with("df -B1 --output=source,target,size,avail ").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/sda       /                            205520896     99571712
/dev/sdb       /var/storage/devices/stor1   205520896     99571712
/dev/sdc       /var/storage/devices/stor2  3331416064   3331276800
EOS
      expect(ls.sshable).to receive(:cmd).with("df -B1 --output=source,target,size,avail /var/storage").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/sda       /var/storage/devices/stor1   205520896     99571712
/dev/sdb       /var/storage/devices/stor2  3331416064   3331276800
EOS
      expect(ls.sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'sda$' | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-some-random-id1")
      expect(ls.sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'sdb$' | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-some-random-id2")
      expect(ls.sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'sdc$' | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-some-random-id3")

      expect { ls.start }.to exit({"msg" => "created StorageDevice records"}).and change {
        StorageDevice.all.map { |d| [d.name, d.unix_device_list.sort] }.sort
      }.from([]).to([
        ["DEFAULT", ["wwn-some-random-id1"]],
        ["stor1", ["wwn-some-random-id2"]],
        ["stor2", ["wwn-some-random-id3"]]
      ])
    end

    it "exits, updating existing StorageDevice model instances" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      ls = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      expect(ls.sshable).to receive(:cmd).with("df -B1 --output=source,target,size,avail ").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/nvme0n1   /                           6205520896     99571712
/dev/nvme0n2   /var/storage/devices/stor1  6205520896   3099571712
/dev/nvme0n3   /var/storage/devices/stor2  3331416064   1531276800
EOS
      expect(ls.sshable).to receive(:cmd).with("df -B1 --output=source,target,size,avail /var/storage").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/nvme0n2   /var/storage/devices/stor1  6205520896   3099571712
/dev/nvme0n3   /var/storage/devices/stor2  3331416064   1531276800
EOS

      allow(ls.sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'nvme0n2$' | grep 'nvme-eui' | sed -E 's/.*(nvme-eui[^ ]*).*/\\1/'").and_return("nvme-eui.some-random-id1")
      expect(ls.sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'nvme0n3$' | grep 'nvme-eui' | sed -E 's/.*(nvme-eui[^ ]*).*/\\1/'").and_return("nvme-eui.some-random-id2")

      StorageDevice.create_with_id(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100, unix_device_list: ["nvme0n1"])
      expect { ls.start }.to exit({"msg" => "created StorageDevice records"}).and change {
        StorageDevice.map { |sd|
          sd.values.slice(
            :name, :available_storage_gib, :total_storage_gib
          )
        }.sort_by { _1[:name] }
      }.from(
        [{name: "stor1", total_storage_gib: 100, available_storage_gib: 100}]
      ).to(
        [
          {name: "DEFAULT", total_storage_gib: 5, available_storage_gib: 0},
          {name: "stor1", total_storage_gib: 5, available_storage_gib: 2},
          {name: "stor2", total_storage_gib: 3, available_storage_gib: 1}
        ]
      )

      expect(vmh.reload.available_storage_gib).to eq(3)
      expect(vmh.reload.total_storage_gib).to eq(13)
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
      expect(sshable).to receive(:cmd).with("df -B1 --output=source,target,size,avail ").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
tmpfs          /run                        3331420160   3328692224
/dev/sda       /                         452564664320 381456842752
tmpfs          /dev/shm                   16657084416  16605118464
tmpfs          /run/lock                      5242880      5234688
tmpfs          /sys/firmware/efi/efivars       448412        74256
/dev/aaa       /boot                       2024529920   1641877504
/dev/sdb       /var/storage/devices/stor1   205520896     99571712
/dev/sdc       /var/storage/devices/stor2  3331416064   3331276800
EOS

      expect(sshable).to receive(:cmd).with("df -B1 --output=source,target,size,avail /var/storage").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/sdb       /var/storage/devices/stor1   205520896     99571712
/dev/sdc       /var/storage/devices/stor2  3331416064   3331276800
EOS
      allow(ls.sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'sdb$' | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-some-random-id1")
      expect(ls.sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'sdc$' | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-some-random-id2")

      expect(ls.make_model_instances.map(&:name)).to eq(%w[DEFAULT stor1 stor2])
    end

    it "can use any file system that is present at '/var/storage'" do
      # First, the sshable is scanned for any file systems in
      # /var/storage/devices. Iff there are none, a second command is
      # sent to fill in the "DEFAULT" storage device.
      expect(sshable).to receive(:cmd).with("df -B1 --output=source,target,size,avail ").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
tmpfs          /run                        3331420160   3328692224
/dev/sda       /                         452564664320 381456842752
tmpfs          /dev/shm                   16657084416  16605118464
tmpfs          /run/lock                      5242880      5234688
tmpfs          /sys/firmware/efi/efivars       448412        74256
/dev/aaa       /boot                       2024529920   1641877504
EOS

      expect(sshable).to receive(:cmd).with("df -B1 --output=source,target,size,avail /var/storage").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/sda       /                         452564664320 381456842752
EOS
      allow(ls.sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'sda$' | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-some-random-id1")

      expect(ls.make_model_instances.map(&:name)).to eq(%w[DEFAULT])
    end

    it "can find underlying unix devices for raided disks" do
      expect(sshable).to receive(:cmd).with("df -B1 --output=source,target,size,avail ").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
tmpfs          /run                        3331420160   3328692224
/dev/sda       /                         452564664320 381456842752
tmpfs          /dev/shm                   16657084416  16605118464
tmpfs          /run/lock                      5242880      5234688
tmpfs          /sys/firmware/efi/efivars       448412        74256
/dev/aaa       /boot                       2024529920   1641877504
EOS

      expect(sshable).to receive(:cmd).with("cat /proc/mdstat").and_return(<<EOS)
Personalities : [raid1] [linear] [multipath] [raid0] [raid6] [raid5] [raid4] [raid10]
md2 : active raid1 nvme1n1p3[1] nvme0n1p3[0]
      465370432 blocks super 1.2 [2/2] [UU]
      bitmap: 3/4 pages [12KB], 65536KB chunk

md0 : active raid1 nvme1n1p1[1] nvme0n1p1[0]
      33520640 blocks super 1.2 [2/2] [UU]

md1 : active raid1 nvme1n1p2[1] nvme0n1p2[0]
      1046528 blocks super 1.2 [2/2] [UU]

unused devices: <none>
EOS

      expect(sshable).to receive(:cmd).with("df -B1 --output=source,target,size,avail /var/storage").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/md2       /                         452564664320 381456842752
EOS

      expect(sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'nvme1n1$' | grep 'nvme-eui' | sed -E 's/.*(nvme-eui[^ ]*).*/\\1/'").and_return("nvme-eui.random-id1")
      expect(sshable).to receive(:cmd).with("ls -l /dev/disk/by-id/ | grep 'nvme0n1$' | grep 'nvme-eui' | sed -E 's/.*(nvme-eui[^ ]*).*/\\1/'").and_return("nvme-eui.random-id2")
      expect(ls.make_model_instances.map(&:unix_device_list)).to eq([["nvme-eui.random-id1", "nvme-eui.random-id2"]])
    end
  end
end
