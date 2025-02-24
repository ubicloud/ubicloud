# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Github::DockerRegistryMirrorServerNexus do
  subject(:mirror_server_nexus) { described_class.new(Strand.new(id: "3f6e67c7-6b42-81b4-be47-d9c4be9bb781")) }

  let(:project_id) { Project.create(name: "test-project").id }

  let(:vm_host) {
    sa = Sshable.create_with_id(host: "1.1.1.1", raw_private_key_1: SshKey.generate.keypair)
    VmHost.create(location: "hetzner-fsn1", arch: "x64") { _1.id = sa.id }
  }

  let(:sshable) { instance_double(Sshable) }

  let(:vm) { Vm.create(vm_host:, unix_user: "ubi", public_key: "key", name: "vm1", location: "github-runners", boot_image: "github-ubuntu-2204", family: "standard", arch: "arm64", cores: 2, vcpus: 2, memory_gib: 8, project_id:) }

  let(:docker_registry_mirror_server) { instance_double(DockerRegistryMirrorServer) }

  before do
    allow(mirror_server_nexus).to receive_messages(
      vm: vm,
      docker_registry_mirror_server: docker_registry_mirror_server
    )
    allow(vm).to receive(:sshable).and_return(sshable)
  end

  describe ".assemble" do
    it "can not find host" do
      expect {
        described_class.assemble("154cc58f-999a-8771-a3ba-342f5dd0917d")
      }.to raise_error RuntimeError, "Host not found"
    end

    it "creates the mirror server strand" do
      allow(Config).to receive(:docker_registry_mirror_project_id).and_return(project_id)
      described_class.assemble(vm_host.id)

      expect(Strand.where(prog: "Github::DockerRegistryMirrorServerNexus").count).to eq(1)
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(mirror_server_nexus).to receive(:when_destroy_set?).and_yield
      expect { mirror_server_nexus.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(mirror_server_nexus).to receive(:when_destroy_set?).and_yield
      expect(mirror_server_nexus.strand).to receive(:label).and_return("destroy")
      expect { mirror_server_nexus.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "naps if vm not ready" do
      expect(mirror_server_nexus.vm).to receive(:strand).and_return(instance_double(Strand, label: "prep"))
      expect { mirror_server_nexus.start }.to nap(5)
    end

    it "hops to create_load_balancer" do
      expect(mirror_server_nexus.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect { mirror_server_nexus.start }.to hop("create_load_balancer")
    end
  end

  describe "#create_load_balancer" do
    it "creates the load balancer" do
      expect(vm).to receive(:private_subnets).and_return([instance_double(PrivateSubnet, id: "123")])
      lb = instance_double(LoadBalancer)
      expect(Prog::Vnet::LoadBalancerNexus).to receive(:assemble).with("123", name: vm.ubid, src_port: 5000, dst_port: 5000, health_check_endpoint: "/up", health_check_protocol: "tcp", stack: "ipv4").and_return(instance_double(Strand, id: "123", subject: lb))
      expect(lb).to receive(:add_vm).with(vm)
      expect { mirror_server_nexus.create_load_balancer }.to hop("install_docker")
    end
  end

  describe "#install_docker" do
    it "installs docker" do
      expect(sshable).to receive(:cmd).with(<<~COMMAND)
        set -ueo pipefail
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo systemctl enable docker
        sudo systemctl start docker
      COMMAND

      expect { mirror_server_nexus.install_docker }.to hop("fetch_certificate")
    end
  end

  describe "#fetch_certificate" do
    it "fetches the certificate" do
      expect(sshable).to receive(:cmd).with(<<~COMMAND)
        set -ueo pipefail
        sudo install -m 0755 -d /etc/docker/registry/certs
        sudo curl -f -L3 [FD00:0B1C:100D:5afe:CE::]/load-balancer/cert.pem | sudo tee /etc/docker/registry/certs/domain.crt > /dev/null
        sudo curl -f -L3 [FD00:0B1C:100D:5afe:CE::]/load-balancer/key.pem | sudo tee /etc/docker/registry/certs/domain.key > /dev/null
        
        if [ ! -s /etc/docker/registry/certs/domain.crt ] || [ ! -s /etc/docker/registry/certs/domain.key ]; then
          echo "Failed to fetch certificate files" >&2
          exit 1
        fi
      COMMAND

      expect { mirror_server_nexus.fetch_certificate }.to hop("update_docker_registry_config")
    end
  end

  describe "#update_docker_registry_config" do
    it "updates the docker registry config" do
      config = <<-CONFIG
      version: 0.1
      log:
        fields:
          service: registry

      storage:
        cache:
          blobdescriptor: inmemory
        filesystem:
          rootdirectory: /var/lib/registry

      http:
        addr: :5000
        tls:
          certificate: /certs/domain.crt
          key: /certs/domain.key

      proxy:
        remoteurl: https://registry-1.docker.io
      CONFIG

      expect(sshable).to receive(:cmd).with("sudo tee /etc/docker/registry/config.yml > /dev/null", stdin: config)
      expect { mirror_server_nexus.update_docker_registry_config }.to hop("start_docker_registry")
    end
  end

  describe "#start_docker_registry" do
    it "starts the docker registry" do
      expect(sshable).to receive(:cmd).with(<<~COMMAND)
        sudo docker run -d \
          --name registry-mirror \
          --restart=always \
          -p 5000:5000 \
          -v /etc/docker/registry/config.yml:/etc/docker/registry/config.yml:ro \
          -v /etc/docker/registry/certs:/certs:ro \
          -v /var/lib/registry:/var/lib/registry \
          registry:2
      COMMAND
      expect { mirror_server_nexus.start_docker_registry }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps" do
      expect { mirror_server_nexus.wait }.to nap(60)
    end
  end

  describe "#destroy" do
    it "destroys the mirror server" do
      expect(sshable).to receive(:destroy)
      expect(vm).to receive(:incr_destroy)
      expect(docker_registry_mirror_server).to receive(:destroy)
      expect { mirror_server_nexus.destroy }.to exit({"msg" => "docker registry mirror destroyed"})
    end
  end
end
