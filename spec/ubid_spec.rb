# frozen_string_literal: true

RSpec.describe UBID do
  let(:all_types) { described_class.constants.select { _1.start_with?("TYPE_") }.map { described_class.const_get(_1) } }

  it "can set_bits" do
    expect(described_class.set_bits(0, 0, 7, 0xab)).to eq(0xab)
    expect(described_class.set_bits(0xab, 8, 12, 0xc)).to eq(0xcab)
    expect(described_class.set_bits(0xcab, 40, 48, 0x12)).to eq(0x120000000cab)
  end

  it "can get bits" do
    expect(described_class.get_bits(0x120000000cab, 8, 11)).to eq(0xc)
  end

  it "can convert to base32" do
    tests = [
      ["0", 0], ["o", 0], ["A", 10], ["e", 14], ["m", 20], ["S", 25], ["z", 31]
    ]
    tests.each {
      expect(described_class.to_base32(_1[0])).to eq(_1[1])
    }
  end

  it "can extract bits as hex" do
    expect(described_class.extract_bits_as_hex(0x12345, 1, 3)).to eq("234")
    expect(described_class.extract_bits_as_hex(0xabcdef00012, 4, 5)).to eq("cdef0")
    expect(described_class.extract_bits_as_hex(0xabcdef00012, 1, 4)).to eq("0001")
    expect(described_class.extract_bits_as_hex(0xabcdef00012, 9, 5)).to eq("000ab")
  end

  it "can encode multiple numbers" do
    expect(described_class.from_base32_n(10 + 20 * 32 + 1 * 32 * 32, 3)).to eq("1ma")
  end

  it "fails to convert U to base32" do
    expect { described_class.to_base32("u") }.to raise_error RuntimeError, "Invalid base32 encoding: U"
  end

  it "can convert from base32" do
    tests = [
      [0, "0"], [12, "c"], [16, "g"], [20, "m"], [26, "t"], [28, "w"], [31, "z"]
    ]
    tests.each {
      expect(described_class.from_base32(_1[0])).to eq(_1[1])
    }
  end

  it "can convert multiple from base32" do
    expect(described_class.to_base32_n("1MA")).to eq(10 + 20 * 32 + 1 * 32 * 32)
  end

  it "fails to convert from out of range numbers" do
    expect {
      described_class.from_base32(-1)
    }.to raise_error RuntimeError, "Invalid base32 number: -1"

    expect {
      described_class.from_base32(32)
    }.to raise_error RuntimeError, "Invalid base32 number: 32"
  end

  it "can calculate parity" do
    expect(described_class.parity(0b10101)).to eq(1)
    expect(described_class.parity(0b101011)).to eq(0)
  end

  it "can create from parts & encode it & parse it" do
    id = described_class.from_parts(1000, "ab", 3, 12292929)
    expect(described_class.parse(id.to_s).to_i).to eq(id.to_i)
  end

  it "can generate random ids" do
    ubid1 = described_class.generate(UBID::TYPE_VM)
    ubid2 = described_class.parse(ubid1.to_s)
    expect(ubid2.to_i).to eq(ubid1.to_i)
  end

  it "can convert to and from uuid" do
    ubid1 = described_class.generate(UBID::TYPE_ACCESS_TAG)
    ubid2 = described_class.from_uuidish(ubid1.to_uuid)
    expect(ubid2.to_s).to eq(ubid1.to_s)
  end

  it "can convert from and to uuid" do
    uuid1 = "550e8400-e29b-41d4-a716-446655440000"
    uuid2 = described_class.from_uuidish(uuid1).to_uuid
    expect(uuid2).to eq(uuid1)
  end

  it "fails to parse if length is not 26" do
    expect {
      described_class.parse("123456")
    }.to raise_error RuntimeError, "Invalid encoding length: 6"
  end

  it "fails to parse if top bits parity is incorrect" do
    invalid_ubid = "vm164pbm96ba3grq6vbsvjb3ax"
    expect {
      described_class.parse(invalid_ubid)
    }.to raise_error RuntimeError, "Invalid top bits parity"
  end

  it "fails to parse if bottom bits parity is incorrect" do
    invalid_ubid = "vm064pbm96ba3grq6vbsvjb3az"
    expect {
      described_class.parse(invalid_ubid)
    }.to raise_error RuntimeError, "Invalid bottom bits parity"
  end

  it "generates random timestamp for most types" do
    (all_types - described_class::CURRENT_TIMESTAMP_TYPES).each { |type|
      # generate 10 ids with this type, and verify that their timestamp
      # part is not close
      ubids = (1..10).map { described_class.generate(type).to_i }
      max_ubid = ubids.max
      min_ubid = ubids.min

      # Timestamp is the left 48 bits of the 128-bit ubid.
      time_difference = (max_ubid >> 80) - (min_ubid >> 80)

      # Timestamp parts are random, so with a very high probability
      # the difference between them will be > 8ms.
      expect(time_difference).to be > 8
    }
  end

  it "generates clock timestamp for strand and semaphore" do
    described_class::CURRENT_TIMESTAMP_TYPES.each { |type|
      # generate 10 ids with this type, and verify that their timestamp
      # part is close
      ubids = (1..10).map { described_class.generate(type).to_i }
      max_ubid = ubids.max
      min_ubid = ubids.min

      # Timestamp is the left 48 bits of the 128-bit ubid.
      time_difference = (max_ubid >> 80) - (min_ubid >> 80)

      # Timestamp parts are sequential, so with a very high probability
      # the difference between them will be < 128ms.
      expect(time_difference).to be < 128
    }
  end

  it "uses canonical type characters" do
    # In crockford's base32 multiple characters can map to a single number,
    # for example ["1","I","L"] all map to 1. However, the reverse (number
    # -> character) only uses one canonical one (e.g. 1 maps to "1").
    # This test ensures we only use canonical characters in our type
    # constants, so ids are actually prefixed by those constants.
    #
    # See https://www.crockford.com/base32.html

    all_types.each { |type|
      ubid = described_class.generate(type).to_s
      expect(ubid).to start_with type
    }
  end

  it "has unique type identifiers" do
    expect(all_types.uniq.length).to eq(all_types.length)
  end

  it "generates ids with proper prefix" do
    sshable = Sshable.create_with_id
    expect(sshable.ubid).to start_with UBID::TYPE_SSHABLE

    host = VmHost.create(location: "x") { _1.id = sshable.id }
    si = SpdkInstallation.create(version: "v1", allocation_weight: 100, vm_host_id: host.id) { _1.id = host.id }

    vm = create_vm
    expect(vm.ubid).to start_with UBID::TYPE_VM

    dev = StorageDevice.create(name: "x", available_storage_gib: 1, total_storage_gib: 1, vm_host_id: host.id) { _1.id = host.id }

    sv = VmStorageVolume.create_with_id(vm_id: vm.id, size_gib: 5, disk_index: 0, boot: false, spdk_installation_id: si.id, storage_device_id: dev.id)
    expect(sv.ubid).to start_with UBID::TYPE_VM_STORAGE_VOLUME

    kek = StorageKeyEncryptionKey.create_with_id(algorithm: "x", key: "x", init_vector: "x", auth_data: "x")
    expect(kek.ubid).to start_with UBID::TYPE_STORAGE_KEY_ENCRYPTION_KEY

    account = Account.create_with_id(email: "x@y.net")
    expect(account.ubid).to start_with UBID::TYPE_ACCOUNT

    prj = account.create_project_with_default_policy("x")
    expect(prj.ubid).to start_with UBID::TYPE_PROJECT

    policy = prj.access_policies.first
    expect(policy.ubid).to start_with UBID::TYPE_ACCESS_POLICY

    atag = AccessTag.create_with_id(project_id: prj.id, hyper_tag_table: "x", name: "x")
    expect(atag.ubid).to start_with UBID::TYPE_ACCESS_TAG

    subnet = PrivateSubnet.create_with_id(net6: "0::0", net4: "127.0.0.1", name: "x", location: "x")
    expect(subnet.ubid).to start_with UBID::TYPE_PRIVATE_SUBNET

    nic = Nic.create_with_id(
      private_ipv6: "fd10:9b0b:6b4b:8fbb::/128",
      private_ipv4: "10.0.0.12/32",
      mac: "00:11:22:33:44:55",
      encryption_key: "0x30613961313636632d653765372d343434372d616232392d376561343432623562623065",
      private_subnet_id: subnet.id,
      name: "def-nic"
    )
    expect(nic.ubid).to start_with UBID::TYPE_NIC
    tun = IpsecTunnel.create_with_id(src_nic_id: nic.id, dst_nic_id: nic.id)
    expect(tun.ubid).to start_with UBID::TYPE_IPSEC_TUNNEL

    adr = Address.create_with_id(cidr: "192.168.1.0/24", routed_to_host_id: host.id)
    expect(adr.ubid).to start_with UBID::TYPE_ADDRESS

    vm_adr = AssignedVmAddress.create_with_id(ip: "192.168.1.1", address_id: adr.id, dst_vm_id: vm.id)
    expect(vm_adr.ubid).to start_with UBID::TYPE_ASSIGNED_VM_ADDRESS

    host_adr = AssignedHostAddress.create_with_id(ip: "192.168.1.1", address_id: adr.id, host_id: host.id)
    expect(host_adr.ubid).to start_with UBID::TYPE_ASSIGNED_HOST_ADDRESS

    strand = Strand.create_with_id(prog: "x", label: "y")
    expect(strand.ubid).to start_with UBID::TYPE_STRAND

    semaphore = Semaphore.create_with_id(strand_id: strand.id, name: "z")
    expect(semaphore.ubid).to start_with UBID::TYPE_SEMAPHORE

    page = Page.create_with_id(summary: "x", tag: "y")
    expect(page.ubid).to start_with UBID::TYPE_PAGE
  end

  # useful for comparing objects having network values
  def string_kv(obj)
    obj.to_hash.map { |k, v| [k.to_s, v.to_s] }.to_h
  end

  it "can decode ids" do
    sshable = Sshable.create_with_id
    host = VmHost.create(location: "x") { _1.id = sshable.id }
    si = SpdkInstallation.create(version: "v1", allocation_weight: 100, vm_host_id: host.id) { _1.id = host.id }
    vm = create_vm
    dev = StorageDevice.create(name: "x", available_storage_gib: 1, total_storage_gib: 1, vm_host_id: host.id) { _1.id = host.id }
    sv = VmStorageVolume.create_with_id(vm_id: vm.id, size_gib: 5, disk_index: 0, boot: false, spdk_installation_id: si.id, storage_device_id: dev.id)
    kek = StorageKeyEncryptionKey.create_with_id(algorithm: "x", key: "x", init_vector: "x", auth_data: "x")
    account = Account.create_with_id(email: "x@y.net")
    project = account.create_project_with_default_policy("x")
    policy = project.access_policies.first
    atag = AccessTag.create_with_id(project_id: project.id, hyper_tag_table: "x", name: "x")
    subnet = PrivateSubnet.create_with_id(net6: "0::0", net4: "127.0.0.1", name: "x", location: "x")
    nic = Nic.create_with_id(private_ipv6: "fd10:9b0b:6b4b:8fbb::/128", private_ipv4: "10.0.0.12/32", mac: "00:11:22:33:44:55", encryption_key: "0x30613961313636632d653765372d343434372d616232392d376561343432623562623065", private_subnet_id: subnet.id, name: "def-nic")
    tun = IpsecTunnel.create_with_id(src_nic_id: nic.id, dst_nic_id: nic.id)
    adr = Address.create_with_id(cidr: "192.168.1.0/24", routed_to_host_id: host.id)
    vm_adr = AssignedVmAddress.create_with_id(ip: "192.168.1.1", address_id: adr.id, dst_vm_id: vm.id)
    host_adr = AssignedHostAddress.create_with_id(ip: "192.168.1.1", address_id: adr.id, host_id: host.id)
    strand = Strand.create_with_id(prog: "x", label: "y")
    semaphore = Semaphore.create_with_id(strand_id: strand.id, name: "z")
    page = Page.create_with_id(summary: "x", tag: "y")

    expect(described_class.decode(vm.ubid)).to eq(vm)
    expect(described_class.decode(sv.ubid)).to eq(sv)
    expect(described_class.decode(kek.ubid)).to eq(kek)
    expect(described_class.decode(account.ubid)).to eq(account)
    expect(described_class.decode(project.ubid)).to eq(project)
    expect(described_class.decode(policy.ubid)).to eq(policy)
    expect(described_class.decode(atag.ubid)).to eq(atag)
    expect(described_class.decode(tun.ubid)).to eq(tun)
    expect(string_kv(described_class.decode(subnet.ubid))).to eq(string_kv(subnet))
    expect(described_class.decode(sshable.ubid)).to eq(sshable)
    expect(string_kv(described_class.decode(adr.ubid))).to eq(string_kv(adr))
    expect(string_kv(described_class.decode(vm_adr.ubid))).to eq(string_kv(vm_adr))
    expect(string_kv(described_class.decode(host_adr.ubid))).to eq(string_kv(host_adr))
    expect(described_class.decode(strand.ubid)).to eq(strand)
    expect(described_class.decode(semaphore.ubid)).to eq(semaphore)
    expect(described_class.decode(page.ubid)).to eq(page)
    expect(string_kv(described_class.decode(nic.ubid))).to eq(string_kv(nic))
  end

  it "fails to decode unknown type" do
    expect {
      described_class.decode("han2sefsk4f61k91z77vn0y978")
    }.to raise_error RuntimeError, "Couldn't decode ubid: han2sefsk4f61k91z77vn0y978"
  end

  it "can be inspected" do
    expect(described_class.parse("vmqsknkzw5164hkfnt6z6zgjps").inspect).to eq("#<UBID:Vm @ubid=\"vmqsknkzw5164hkfnt6z6zgjps\" @uuid=\"be6759ff-8509-8b74-8cdf-5d1be6fc256c\">")
  end
end
