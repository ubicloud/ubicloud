# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::GatewayReplicaNexus do
  subject(:nx) { described_class.new(strand) }

  let(:project) { Project.create(name: "ember-service") }

  let(:gateway) {
    PostgresGateway.create(location_id: Location::HETZNER_FSN1_ID, hostname_suffix: "ember.test")
  }

  let(:vm) {
    v = create_vm
    Sshable.create_with_id(v.id, unix_user: "ubi", host: "gateway.test")
    Strand.create_with_id(v, prog: "Vm::Nexus", label: "wait")
    v.reload
  }

  let(:replica) {
    PostgresGatewayReplica.create(postgres_gateway_id: gateway.id, vm_id: vm.id, state: "creating")
  }

  let(:strand) {
    Strand.create_with_id(replica, prog: "Postgres::GatewayReplicaNexus", label: "wait")
  }

  let(:sshable) { nx.sshable }

  before do
    strand
    allow(Config).to receive(:ember_service_project_id).and_return(project.id)
  end

  describe ".assemble" do
    it "creates a VM in the fleet's own subnet" do
      subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "ember-subnet").subject
      gateway.update(private_subnet_id: subnet.id)
      other = create_vm(name: "other-gateway-vm")
      expect(Prog::Vm::Nexus).to receive(:assemble_with_sshable) { |_project, **args|
        expect(args[:private_subnet_id]).to eq(subnet.id)
        expect(args[:enable_ip4]).to be true
        Strand.create_with_id(other, prog: "Vm::Nexus", label: "wait")
      }
      r = described_class.assemble(gateway.id)
      expect(r.state).to eq("creating")
      expect(Strand[r.id].label).to eq("start")
    end

    it "refuses a replica for a gateway that does not exist" do
      expect { described_class.assemble(PostgresGateway.generate_uuid) }
        .to raise_error(RuntimeError, /no such gateway/)
    end
  end

  describe "#start" do
    it "waits for the VM before bootstrapping it" do
      vm.reload.strand.update(label: "start")
      expect { nx.start }.to nap(5)
    end

    # The tunnel ends in the VM's namespace on its host, so nothing has to be
    # installed inside the VM for it.
    it "goes straight to the tunnel once the VM is up" do
      vm.reload.strand.update(label: "wait")
      expect { nx.start }.to hop("setup_tunnel")
    end
  end

  describe "#setup_tunnel" do
    it "joins the mesh and asks the gateway to have its hosts peer back" do
      Strand.create_with_id(gateway, prog: "Postgres::GatewayNexus", label: "wait")
      expect(EmberTunnel).to receive(:push).with(replica)
      expect { nx.setup_tunnel }.to hop("setup")
      expect(JSON.parse(replica.reload.tunnel_keys)["keys"].size).to eq(1)
      expect(gateway.reload.semaphores.map(&:name)).to include("reconfigure")
    end
  end

  describe "#setup" do
    let(:cert) {
      Cert.create(hostname: "*.ember.test", cert: "CERTPEM", csr_key: OpenSSL::PKey::EC.generate("prime256v1").to_pem)
    }

    before do
      subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "ember-subnet").subject
      lb = LoadBalancer.create(private_subnet_id: subnet.id, project_id: project.id, name: "ember-lb",
        algorithm: "round_robin", health_check_endpoint: "/", stack: LoadBalancer::Stack::DUAL)
      gateway.update(load_balancer_id: lb.id, private_subnet_id: subnet.id)
      allow(lb).to receive(:active_cert).and_return(cert)
      allow(nx).to receive(:postgres_gateway).and_return(gateway)
      allow(gateway).to receive(:load_balancer).and_return(lb)
    end

    it "waits rather than failing while the wildcard certificate is being issued" do
      allow(gateway.load_balancer).to receive(:active_cert).and_return(nil)
      allow(sshable).to receive(:_cmd)
      expect { nx.setup }.to nap(30)
    end

    it "waits the same way before the fleet has a load balancer at all" do
      allow(gateway).to receive(:load_balancer).and_return(nil)
      allow(sshable).to receive(:_cmd)
      expect { nx.setup }.to nap(30)
    end

    it "fetches from the configured tarball when there is one" do
      allow(Config).to receive(:postgres_gateway_binary_url).and_return("http://example/sg.tar.gz")
      commands = []
      allow(sshable).to receive(:_cmd) { |command, **| commands << command }
      allow(sshable).to receive(:write_file)
      expect { nx.setup }.to hop("wait_healthy")
      expect(commands.join(" ")).to include("http://example/sg.tar.gz")
      expect(commands.join(" ")).not_to include("github.com")
    end

    it "fetches the release asset otherwise, named for the version" do
      allow(Config).to receive_messages(postgres_gateway_binary_url: nil,
        postgres_gateway_release_tag: "postgres-gateway/v0.1.0")
      commands = []
      allow(sshable).to receive(:_cmd) { |command, **| commands << command }
      allow(sshable).to receive(:write_file)
      expect { nx.setup }.to hop("wait_healthy")
      # A release asset's name cannot contain a slash, so it carries the
      # version alone.
      expect(commands.join(" ")).to include("https://github.com/ubicloud/postgres-gateway/releases/download/" \
        "postgres-gateway/v0.1.0/postgres-gateway-v0.1.0-x86_64-unknown-linux-gnu.tar.gz")
    end

    it "writes the certificate, the key and a unit that names the control plane" do
      allow(Config).to receive_messages(postgres_gateway_binary_url: "http://example/sg.tar.gz",
        postgres_ember_internal_api_url: "http://control-plane:9292")
      written = {}
      allow(sshable).to receive(:_cmd)
      allow(sshable).to receive(:write_file) { |path, content| written[path] = content }
      expect { nx.setup }.to hop("wait_healthy")
      expect(written["/postgres-gateway/wildcard.crt"]).to eq("CERTPEM")
      expect(written["/etc/systemd/system/postgres-gateway.service"]).to include("http://control-plane:9292")
      expect(written["/etc/systemd/system/postgres-gateway.service"]).to include("ember.test")
    end
  end

  describe "#wait_healthy" do
    before do
      subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "ember-subnet").subject
      @lb = LoadBalancer.create(private_subnet_id: subnet.id, project_id: project.id, name: "ember-lb",
        algorithm: "round_robin", health_check_endpoint: "/", stack: LoadBalancer::Stack::DUAL)
      Strand.create_with_id(@lb, prog: "Vnet::LoadBalancerNexus", label: "wait")
      Strand.create_with_id(gateway, prog: "Postgres::GatewayNexus", label: "wait")
      gateway.update(load_balancer_id: @lb.id)
    end

    it "waits until the gateway answers its health endpoint" do
      expect(sshable).to receive(:_cmd).and_return("")
      expect { nx.wait_healthy }.to nap(5)
      expect(replica.reload.state).to eq("creating")
    end

    it "joins the load balancer only once it is serving" do
      expect(sshable).to receive(:_cmd).and_return('{"ok":true}')
      expect { nx.wait_healthy }.to hop("wait")
      expect(replica.reload.state).to eq("running")
      expect(@lb.reload.vms.map(&:id)).to include(vm.id)
      expect(gateway.reload.semaphores.map(&:name)).to include("reconfigure")
    end

    it "does not join twice" do
      @lb.add_vm(vm)
      expect(sshable).to receive(:_cmd).and_return('{"ok":true}')
      expect { nx.wait_healthy }.to hop("wait")
      expect(@lb.reload.vms.count).to eq(1)
    end
  end

  describe "#wait" do
    it "tears the replica down on request" do
      replica.incr_destroy
      expect { nx.wait }.to hop("destroy")
    end

    it "re-reads its configuration on reconfigure, so a renewed certificate reaches it" do
      replica.incr_reconfigure
      expect(EmberTunnel).to receive(:push).with(replica)
      expect { nx.wait }.to hop("setup")
      expect(replica.reload.semaphores).to be_empty
    end

    it "rotates its tunnel key when that is due" do
      EmberTunnel.ensure_keys(replica)
      replica.update(tunnel_rekeyed_at: Time.now - EmberTunnel::REKEY_INTERVAL - 1)
      expect { nx.wait }.to hop("rekey_tunnel")
    end

    it "pushes its tunnels again every so often, in case the host lost them" do
      EmberTunnel.ensure_keys(replica)
      expect(EmberTunnel).to receive(:push).with(replica)
      expect { nx.wait }.to nap(described_class::WAIT_SECONDS)
    end

    it "leaves the load balancer before it stops serving" do
      subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "ember-subnet").subject
      lb = LoadBalancer.create(private_subnet_id: subnet.id, project_id: project.id, name: "ember-lb",
        algorithm: "round_robin", health_check_endpoint: "/", stack: LoadBalancer::Stack::DUAL)
      Strand.create_with_id(lb, prog: "Vnet::LoadBalancerNexus", label: "wait")
      gateway.update(load_balancer_id: lb.id)
      lb.add_vm(vm)
      replica.incr_drain
      expect(sshable).to receive(:_cmd).with(/systemctl stop/)
      expect { nx.wait }.to hop("wait")
      expect(replica.reload.state).to eq("draining")
      expect(lb.reload.vm_ports.map(&:state)).to all(eq("evacuating"))
    end

    it "still stops serving when the fleet has no load balancer yet" do
      replica.incr_drain
      expect(sshable).to receive(:_cmd).with(/systemctl stop/)
      expect { nx.wait }.to hop("wait")
      expect(replica.reload.state).to eq("draining")
    end

    it "settles when there is nothing to do" do
      expect { nx.wait }.to nap(described_class::WAIT_SECONDS)
    end
  end

  describe "#rekey_tunnel" do
    it "goes back to waiting once the key is rotated" do
      expect(EmberTunnel).to receive(:rekey).with(replica)
      expect { nx.rekey_tunnel }.to hop("wait")
    end

    it "tries again shortly when a host cannot be reached" do
      expect(EmberTunnel).to receive(:rekey).and_raise(EmberTunnel::PushFailed, "could not reach vh1")
      expect { nx.rekey_tunnel }.to nap(30)
    end
  end

  describe "#destroy" do
    it "takes the VM with it when there is no load balancer to leave" do
      expect { nx.destroy }.to exit({"msg" => "gateway replica destroyed"})
      expect(vm.reload.semaphores.map(&:name)).to include("destroy")
    end

    it "asks the gateway to have every host drop its tunnels" do
      Strand.create_with_id(gateway, prog: "Postgres::GatewayNexus", label: "wait")
      expect { nx.destroy }.to exit({"msg" => "gateway replica destroyed"})
      expect(gateway.reload.semaphores.map(&:name)).to include("reconfigure")
    end

    it "detaches from the load balancer and takes the VM with it" do
      subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "ember-subnet").subject
      lb = LoadBalancer.create(private_subnet_id: subnet.id, project_id: project.id, name: "ember-lb",
        algorithm: "round_robin", health_check_endpoint: "/", stack: LoadBalancer::Stack::DUAL)
      Strand.create_with_id(lb, prog: "Vnet::LoadBalancerNexus", label: "wait")
      gateway.update(load_balancer_id: lb.id)
      lb.add_vm(vm)
      expect { nx.destroy }.to exit({"msg" => "gateway replica destroyed"})
      expect(vm.reload.semaphores.map(&:name)).to include("destroy")
      expect(PostgresGatewayReplica[replica.id]).to be_nil
    end
  end
end
