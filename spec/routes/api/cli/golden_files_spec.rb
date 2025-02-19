# frozen_string_literal: true

require_relative "spec_helper"
require "open3"

RSpec.describe Clover, "cli" do
  it "produces expected output for commands" do
    golden_file_dir = "spec/routes/api/cli/golden-files"
    output_dir = "spec/routes/api/cli/spec-output-files"
    diff_file = "cli-golden-files.diff"
    Dir.mkdir(output_dir) unless File.directory?(output_dir)

    postgres_project = Project.create(name: "postgres")
    expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id).at_least(:once)
    expect(Vm).to receive(:generate_ubid).and_return(UBID.parse("vmdzyppz6j166jh5e9t2dwrfas"))
    expect(PrivateSubnet).to receive(:generate_ubid).and_return(UBID.parse("psfzm9e26xky5m9ggetw4dpqe2"))
    expect(Nic).to receive(:generate_ubid).and_return(UBID.parse("nc69z0cda8jt0g5b120hamn4vf"))
    expect(Firewall).to receive(:generate_uuid).and_return("24242d92-217b-85fc-b891-7046af3c1150")
    expect(FirewallRule).to receive(:generate_uuid).and_return("51e5bc7d-245b-8df8-bf91-7c5d150cb160", "3b367895-7f18-89f8-a295-ff247e9d5192", "305d838d-a3cd-85f8-aa08-9a66e71a5877", "5aa5b086-37bd-81f8-8d03-dd4b0e09a436", "20c360fa-bc06-8df8-b067-33f4a1ebdbbd", "2b628450-25bd-8df8-8b42-fb5cc5d01ad1", "da42e2ef-b5f1-8df8-966d-1387afb1b2f4", "bc9b093a-0e00-89f8-991a-5e0cd15a7942", "b5e13849-a04f-89f8-b564-ab8ad37298aa", "e46b8b76-88e2-89f8-972b-692232699d16", "e0804078-98cf-85f8-bf74-702ec92c91e8", "d62c8465-7f9b-85f8-a548-5a8772352988")
    expect(PostgresResource).to receive(:generate_uuid).and_return("dd0375a6-1c66-82d0-a5e8-af1e8527a8a2")
    expect(PostgresFirewallRule).to receive(:generate_uuid).and_return("5a601238-b56e-8ecf-bbca-9e3e680812b8")
    expect(PostgresMetricDestination).to receive(:generate_uuid).and_return("1682bcf3-37f8-81da-a1e4-7ac9f25d9200")
    cli(%w[vm eu-central-h1/test-vm create a])
    @vm = Vm.first
    add_ipv4_to_vm(@vm, "128.0.0.1")
    @vm.nics.first.update(private_ipv4: "10.67.141.133/32", private_ipv6: "fda0:d79a:93e7:d4fd:1c2::0/80")
    @ps = PrivateSubnet.first
    @ps.update(net4: "172.27.99.128/26", net6: "fdd9:1ea7:125d:5fa4::/64")

    expect(Config).to receive(:postgres_service_hostname).and_return("pg.example.com").at_least(:once)
    @dns_zone = DnsZone.new
    expect(Vm).to receive(:generate_ubid).and_return(UBID.parse("vma9rnygexga6jns6x3yj9a6b2"))
    expect(Prog::Postgres::PostgresResourceNexus).to receive(:dns_zone).and_return(@dns_zone).at_least(:once)
    expect(PrivateSubnet).to receive(:generate_ubid).and_return(UBID.parse("psnqtahcasrj1hn16kh1ygekmn"))
    expect(Firewall).to receive(:generate_uuid).and_return("30a3eec9-afb5-81fc-bbb5-8691d252ef03")
    expect(Nic).to receive(:generate_ubid).and_return(UBID.parse("nc2kyevjaqey6h0et8qj89zvm1"))

    cli(%w[pg eu-central-h1/test-pg create])
    cli(%w[pg eu-central-h1/test-pg reset-superuser-password bar456FOO123])
    cli(%w[pg eu-central-h1/test-pg add-metric-destination foo bar https://baz.example.com])

    expect(Firewall).to receive(:generate_uuid).and_return("e9843761-3af7-85fc-ba6a-1709852cf736")
    expect(PrivateSubnet).to receive(:generate_ubid).and_return(UBID.parse("pshfgpzvs0t20gpezmz2kkk8e4"))
    cli(%w[ps eu-central-h1/test-ps create])
    PrivateSubnet["pshfgpzvs0t20gpezmz2kkk8e4"].update(net4: "10.147.204.0/26", net6: "fdab:de77:9a94:fa69::/64")

    expect(Vm).to receive(:generate_ubid).and_return(UBID.parse("vmz7b0dxt40t4g7rnmag9hct7c")).at_least(:once)
    expect(PrivateSubnet).to receive(:generate_ubid).and_return(UBID.parse("ps9a8v5tm1020qn73f0c7db0x7")).at_least(:once)
    fw_uuids = %w[2b4ae5cf-1aac-8dfc-bc80-c87e3e381e10 f5e6cb31-e580-81fc-88d6-a379f13494bf].cycle
    expect(Firewall).to receive(:generate_uuid).and_invoke(-> { fw_uuids.next }).at_least(:once)
    fwr_uuids = %w[c81cb3d1-81bc-89f8-96c8-6b4e8d4375bd e3fdf2f2-2603-85f8-b0f9-3fc2c28636cd 99785615-0cc7-8df8-a937-4f1d26b620c8 168054f0-e069-89f8-b12a-e4b010cf47b5 6d590d38-5f88-89f8-b6d8-0a079e1c61b6 9ccb12b4-813c-81f8-9ffc-4a2da3236e51 c5146202-2682-85f8-985f-91adfa07c3da ab7066fa-399b-8df8-a650-826d095211af 3d0c8e62-ad6f-85f8-b9f0-17f02a007d34 7a494601-25ec-85f8-8cb9-b84e05894d2e a4161d96-595a-85f8-a95b-5893bd5b34b1].cycle
    expect(FirewallRule).to receive(:generate_uuid).and_invoke(-> { fwr_uuids.next }).at_least(:once)
    expect(PostgresResource).to receive(:generate_uuid).and_return("97eb0a77-7869-86d0-9dcb-a46416ddc5c9").at_least(:once)
    expect(PostgresFirewallRule).to receive(:generate_uuid).and_return("6d674a31-e1c1-8ecf-b5ac-363abb5b9185").at_least(:once)
    expect(PostgresMetricDestination).to receive(:generate_uuid).and_return("bc563e43-9b83-89da-b3ac-d38acc87fd63").at_least(:once)
    expect(Nic).to receive(:generate_ubid).and_return(UBID.parse("nc186qw3d23j1kzsgjqg2t811r")).at_least(:once)

    Dir["#{golden_file_dir}/*.txt"].each do |f|
      f = File.basename(f)
      cmd = f.delete_suffix(".txt")
      status, cmd = cmd.split("-", 2)
      cmd.tr!("_", "/")
      cmd.gsub!("pg/dump", "pg_dump")
      kws = {}
      if (kw = status[/\[(\w+:\w+)\]/, 1])
        status.sub!(/\[(\w+:\w+)\]/, "")
        kw, kw_value = kw.split(":", 2)
        kw = kw.to_sym
        kws[kw] = kw_value
      end
      kws[:status] = Integer(status)
      body = DB.transaction(savepoint: true, rollback: :always) do
        cli(cmd.split, **kws)
      end
      File.write(File.join(output_dir, f), body)
    end

    diff, = Open3.capture2e("diff", "-u", golden_file_dir, output_dir)
    output_matches_golden_files = diff.empty?

    if diff.empty?
      File.delete(diff_file) if File.file?(diff_file)
    else
      File.write(diff_file, diff)
    end

    expect(output_matches_golden_files).to be_truthy, "differences are in #{diff_file}"

    # Only clear output directory on success
    Dir["#{output_dir}/*.txt"].each do |f|
      File.delete(f)
    end
    Dir.rmdir(output_dir)
  end
end
