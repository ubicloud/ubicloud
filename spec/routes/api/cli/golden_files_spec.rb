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
    expect(Config).to receive(:kubernetes_service_project_id).and_return(postgres_project.id).at_least(:once)
    expect(Vm).to receive(:generate_ubid).and_return(UBID.parse("vmdzyppz6j166jh5e9t2dwrfas"), UBID.parse("vmc9b4yf8r424nna257b3ck3j3"))
    expect(PrivateSubnet).to receive(:generate_ubid).and_return(UBID.parse("psfzm9e26xky5m9ggetw4dpqe2"))
    expect(Nic).to receive(:generate_ubid).and_return(UBID.parse("nc69z0cda8jt0g5b120hamn4vf"), UBID.parse("nchfcq5bmsae7mc7bm6nx82d2n"))
    expect(Firewall).to receive(:generate_uuid).and_return("24242d92-217b-85fc-b891-7046af3c1150")
    expect(FirewallRule).to receive(:generate_uuid).and_return("51e5bc7d-245b-8df8-bf91-7c5d150cb160", "3b367895-7f18-89f8-a295-ff247e9d5192", "305d838d-a3cd-85f8-aa08-9a66e71a5877", "5aa5b086-37bd-81f8-8d03-dd4b0e09a436", "20c360fa-bc06-8df8-b067-33f4a1ebdbbd", "2b628450-25bd-8df8-8b42-fb5cc5d01ad1", "da42e2ef-b5f1-8df8-966d-1387afb1b2f4", "bc9b093a-0e00-89f8-991a-5e0cd15a7942", "b5e13849-a04f-89f8-b564-ab8ad37298aa", "e46b8b76-88e2-89f8-972b-692232699d16", "e0804078-98cf-85f8-bf74-702ec92c91e8", "d62c8465-7f9b-85f8-a548-5a8772352988", "ff48a299-529c-8df8-993a-ddb0450be4a4", "ce327a30-12cb-8df8-86c3-d2db53a4b837")
    expect(PostgresResource).to receive(:generate_uuid).and_return("dd0375a6-1c66-82d0-a5e8-af1e8527a8a2")
    expect(PostgresFirewallRule).to receive(:generate_uuid).and_return("5a601238-b56e-8ecf-bbca-9e3e680812b8", "02d5082e-e75c-82cf-af6f-5f8f5aa89a52")
    expect(PostgresMetricDestination).to receive(:generate_uuid).and_return("45754ea1-c139-8a8d-af18-7b24e0dbc7de")
    SshPublicKey.create_with_id("32092997-2a00-8f33-8129-4c0f18e5153c", project_id: @project.id, name: "spk", public_key: "a a")
    cli(%w[vm eu-central-h1/test-vm create] << "ssh-rsa a")
    @vm = Vm.first
    add_ipv4_to_vm(@vm, "128.0.0.1")
    @vm.nics.first.update(private_ipv4: "10.67.141.133/32", private_ipv6: "fda0:d79a:93e7:d4fd:1c2::0/80")
    @ps = PrivateSubnet.first
    @ps.update(net4: "172.27.99.128/26", net6: "fdd9:1ea7:125d:5fa4::/64")
    Prog::Vm::Nexus.assemble("some_ssh key", postgres_project.id, private_subnet_id: @ps.id, allow_private_subnet_in_other_project: true)

    expect(Config).to receive(:postgres_service_hostname).and_return("pg.example.com").at_least(:once)
    expect(Vm).to receive(:generate_ubid).and_return(UBID.parse("vma9rnygexga6jns6x3yj9a6b2"))
    DnsZone.create(project_id: postgres_project.id, name: "pg.example.com")
    expect(PrivateSubnet).to receive(:generate_ubid).and_return(UBID.parse("psnqtahcasrj1hn16kh1ygekmn"))
    expect(Firewall).to receive(:generate_uuid).and_return("30a3eec9-afb5-81fc-bbb5-8691d252ef03")
    expect(Nic).to receive(:generate_ubid).and_return(UBID.parse("nc2kyevjaqey6h0et8qj89zvm1"))

    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64 -t foo=bar -v 16])
    pg = PostgresResource.first(name: "test-pg")
    pg.update(user_config: {allow_in_place_tablespaces: "on", max_connections: "1000"}, pgbouncer_user_config: {server_round_robin: "1", disable_pqexec: "1"})
    pg.representative_server.vm.add_vm_storage_volume(boot: false, size_gib: 64, disk_index: 0)
    cli(%w[pg eu-central-h1/test-pg reset-superuser-password bar456FOO123])
    cli(%w[pg eu-central-h1/test-pg add-metric-destination foo bar https://baz.example.com])

    expect(Firewall).to receive(:generate_uuid).and_return("e9843761-3af7-85fc-ba6a-1709852cf736")
    expect(PrivateSubnet).to receive(:generate_ubid).and_return(UBID.parse("pshfgpzvs0t20gpezmz2kkk8e4"))
    cli(%w[ps eu-central-h1/test-ps create])
    PrivateSubnet["pshfgpzvs0t20gpezmz2kkk8e4"].update(net4: "10.147.204.0/26", net6: "fdab:de77:9a94:fa69::/64")

    expect(LoadBalancer).to receive(:generate_uuid).and_return("dd91e986-6ac4-882b-ac39-1d430f899d96")
    lb = Prog::Vnet::LoadBalancerNexus.assemble(@ps.id, name: "test-lb", src_port: 12345, dst_port: 54321).subject
    lb.add_vm(@vm)

    expect(KubernetesCluster).to receive(:generate_ubid).and_return(UBID.parse("kcnzrctjjg4j4g6eqvdsvzthwp"))
    expect(KubernetesNodepool).to receive(:generate_uuid).and_return("2432784b-3c9e-8a75-900d-df23880643ec")
    expect(Firewall).to receive(:generate_uuid).and_return("850f5687-1a76-8dfc-8949-a115826d20e7")
    expect(FirewallRule).to receive(:generate_uuid).and_return("d5889073-4aed-89f8-8894-1c376ebea8f6", "0803b040-d565-81f8-b2ed-f4d28df19f7c")
    expect(PrivateSubnet).to receive(:generate_ubid).and_return(UBID.parse("ps788q81w5w26h900k13ad8bkx"))
    cli(%W[kc eu-central-h1/test-kc create -c 1 -z standard-2 -w 1 -v #{Option.kubernetes_versions.first}])

    expect(Vm).to receive(:generate_ubid).and_return(UBID.parse("vmgbbazmznfa0mp49nzh5v0z25"), UBID.parse("vmnwfmjk5k462kkzsfa4n1h4xm"))
    expect(Nic).to receive(:generate_ubid).and_return(UBID.parse("ncnqx1bbxgra7k8r9k9qwvspwd"), UBID.parse("nc1c3bggqpxt5kqqrdtkym1g03"))
    kubernetes_cluster = KubernetesCluster.first
    vms = ["kc-cp-vm", "kc-np-vm"].map do |vm_name|
      Prog::Vm::Nexus.assemble_with_sshable(
        Config.kubernetes_service_project_id,
        sshable_unix_user: "ubi",
        name: vm_name,
        location_id: kubernetes_cluster.location.id,
        size: kubernetes_cluster.target_node_size,
        storage_volumes: [{encrypted: true, size_gib: kubernetes_cluster.target_node_storage_size_gib}],
        boot_image: "kubernetes-#{kubernetes_cluster.version.tr(".", "_")}",
        private_subnet_id: kubernetes_cluster.private_subnet_id,
        enable_ip4: true
      ).subject
    end
    vms[0].update(ephemeral_net6: "ccab:de77:9a94:fa69::/64")
    vms[1].update(ephemeral_net6: "bbab:de77:9a94:fa69::/64")
    add_ipv4_to_vm(vms[0], "129.0.0.2")
    add_ipv4_to_vm(vms[1], "130.0.0.3")
    KubernetesNode.create(vm_id: vms[0].id, kubernetes_cluster_id: kubernetes_cluster.id)
    KubernetesNode.create(vm_id: vms[1].id, kubernetes_cluster_id: kubernetes_cluster.id, kubernetes_nodepool_id: KubernetesNodepool.first.id)
    expect(KubernetesCluster).to receive(:kubeconfig).and_return("example-kubeconfig").at_least(:once)

    expect(Vm).to receive(:generate_ubid).and_return(UBID.parse("vmz7b0dxt40t4g7rnmag9hct7c")).at_least(:once)
    expect(PrivateSubnet).to receive(:generate_ubid).and_return(UBID.parse("ps9a8v5tm1020qn73f0c7db0x7")).at_least(:once)
    fw_uuids = %w[2b4ae5cf-1aac-8dfc-bc80-c87e3e381e10 f5e6cb31-e580-81fc-88d6-a379f13494bf].cycle
    expect(Firewall).to receive(:generate_uuid).and_invoke(-> { fw_uuids.next }).at_least(:once)
    fwr_uuids = %w[c81cb3d1-81bc-89f8-96c8-6b4e8d4375bd e3fdf2f2-2603-85f8-b0f9-3fc2c28636cd 99785615-0cc7-8df8-a937-4f1d26b620c8 168054f0-e069-89f8-b12a-e4b010cf47b5 6d590d38-5f88-89f8-b6d8-0a079e1c61b6 9ccb12b4-813c-81f8-9ffc-4a2da3236e51 c5146202-2682-85f8-985f-91adfa07c3da ab7066fa-399b-8df8-a650-826d095211af 3d0c8e62-ad6f-85f8-b9f0-17f02a007d34 7a494601-25ec-85f8-8cb9-b84e05894d2e a4161d96-595a-85f8-a95b-5893bd5b34b1 2d1e405e-6e6f-81f8-8d10-0d9ed6496fcb 2f0b82a9-fac2-85f8-8991-d29b3893633b].cycle
    expect(FirewallRule).to receive(:generate_uuid).and_invoke(-> { fwr_uuids.next }).at_least(:once)
    expect(PostgresResource).to receive(:generate_uuid).and_return("97eb0a77-7869-86d0-9dcb-a46416ddc5c9").at_least(:once)
    pg_fwr_uuids = %w[6d674a31-e1c1-8ecf-b5ac-363abb5b9185 e92edec8-453e-8ecf-9c82-f8bdbe0c5811].cycle
    expect(PostgresFirewallRule).to receive(:generate_uuid).and_invoke(-> { pg_fwr_uuids.next }).at_least(:once)
    expect(PostgresMetricDestination).to receive(:generate_uuid).and_return("46d93419-abcc-8a8d-823a-55efe660727f").at_least(:once)
    expect(Nic).to receive(:generate_ubid).and_return(UBID.parse("nc186qw3d23j1kzsgjqg2t811r")).at_least(:once)
    expect(LoadBalancer).to receive(:generate_uuid).and_return("eb8e0b21-94f2-8c2b-82c8-da57fcfe88c7").at_least(:once)
    ApiKey.create_with_id("13012223-089c-8953-ac55-889bca83c6e5", owner_table: "project", owner_id: @project.id, used_for: "inference_endpoint", project_id: @project.id, key: "89k2Q8FSzNU3lbQ1ZIpS6HCAQzxplOq1")
    expect(ApiKey).to receive(:random_key).and_return("B5T6fbB5wXBX9kZEEdQXmAWbNY9rWuoL").at_least(:once)
    expect(ApiKey).to receive(:generate_uuid).and_return("6677de33-3888-8953-bde1-ed8a8137d507").at_least(:once)
    expect(SshPublicKey).to receive(:generate_uuid).and_return("7c2410cd-511a-8b33-8771-8a169d368d2d").at_least(:once)

    cli_commands = []
    cli_commands.concat File.readlines("spec/routes/api/cli/golden-file-commands/success.txt").map { [it, {}] }
    cli_commands.concat File.readlines("spec/routes/api/cli/golden-file-commands/error.txt").map { [it, {status: 400}] }
    cli_commands.concat File.readlines("spec/routes/api/cli/golden-file-commands/missing.txt").map { [it, {status: 404}] }
    cli_commands.concat File.readlines("spec/routes/api/cli/golden-file-commands/confirm.txt").map { [it, {confirm_prompt: "Confirmation"}] }
    Dir["spec/routes/api/cli/golden-file-commands/execute/*.txt"].each do |f|
      cmd = File.basename(f).delete_suffix(".txt")
      cli_commands.concat File.readlines(f).map { [it, {command_execute: cmd}] }
    end

    cli_commands_hash = {}
    cli_commands.each do |cmd, kws|
      cmd.chomp!
      lowercase_cmd = cmd.downcase
      if (other_cmd = cli_commands_hash[lowercase_cmd])
        raise "Golden file commands differ only in case and would break on case insensitive file systems:\n#{cmd}\n#{other_cmd}"
      end

      cli_commands_hash[lowercase_cmd] = cmd
      body = DB.transaction(savepoint: true, rollback: :always) do
        cli(cmd.shellsplit, **kws)
      end
      File.write(File.join(output_dir, "#{cmd.tr("/", "_")}.txt"), body)
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
    File.delete(File.join(output_dir, ".txt"))
    Dir.rmdir(output_dir)
  end
end
