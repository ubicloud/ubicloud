# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Github::DockerRegistryMirrorServerNexus < Prog::Base
  subject_is :docker_registry_mirror_server

  extend Forwardable
  def_delegators :docker_registry_mirror_server, :vm

  def self.assemble(host_id, vm_size: "standard-2", storage_size_gib: 40, boot_image: "ubuntu-jammy")
    DB.transaction do
      vm_host = VmHost[host_id] || fail("Host not found")

      ubid = DockerRegistryMirrorServer.generate_ubid
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        "docker-mirror",
        Config.docker_registry_mirror_project_id,
        location: vm_host.location,
        name: ubid.to_s,
        size: vm_size,
        storage_volumes: [{encrypted: true, size_gib: storage_size_gib}],
        boot_image: boot_image,
        enable_ip4: true,
        arch: vm_host.arch,
        force_host_id: host_id
      )

      docker_registry_mirror_server = DockerRegistryMirrorServer.create(vm_id: vm_st.id) { _1.id = ubid.to_uuid }
      Strand.create(prog: "Github::DockerRegistryMirrorServerNexus", label: "start") { _1.id = docker_registry_mirror_server.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"
    hop_create_load_balancer
  end

  label def create_load_balancer
    lb = Prog::Vnet::LoadBalancerNexus.assemble(vm.private_subnets.first.id, name: vm.ubid, src_port: 5000, dst_port: 5000, health_check_endpoint: "/up", health_check_protocol: "tcp", stack: "ipv4").subject
    lb.add_vm(vm)
    hop_install_docker
  end

  label def install_docker
    command = <<~COMMAND
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

    vm.sshable.cmd(command)
    hop_fetch_certificate
  end

  label def fetch_certificate
    command = <<~COMMAND
      set -ueo pipefail
      sudo install -m 0755 -d /etc/docker/registry/certs
      sudo curl -f -L3 [FD00:0B1C:100D:5afe:CE::]/load-balancer/cert.pem | sudo tee /etc/docker/registry/certs/domain.crt > /dev/null
      sudo curl -f -L3 [FD00:0B1C:100D:5afe:CE::]/load-balancer/key.pem | sudo tee /etc/docker/registry/certs/domain.key > /dev/null
      
      if [ ! -s /etc/docker/registry/certs/domain.crt ] || [ ! -s /etc/docker/registry/certs/domain.key ]; then
        echo "Failed to fetch certificate files" >&2
        exit 1
      fi
    COMMAND

    vm.sshable.cmd(command)
    hop_update_docker_registry_config
  end

  label def update_docker_registry_config
    # TODO: Add delete scheduler
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

    vm.sshable.cmd("sudo tee /etc/docker/registry/config.yml > /dev/null", stdin: config)
    hop_start_docker_registry
  end

  label def start_docker_registry
    command = <<~COMMAND
      sudo docker run -d \
        --name registry-mirror \
        --restart=always \
        -p 5000:5000 \
        -v /etc/docker/registry/config.yml:/etc/docker/registry/config.yml:ro \
        -v /etc/docker/registry/certs:/certs:ro \
        -v /var/lib/registry:/var/lib/registry \
        registry:2
    COMMAND

    vm.sshable.cmd(command)
    hop_wait
  end

  label def wait
    # TODO: Add certificate rotation
    nap 60
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy

    vm.sshable.destroy
    vm.incr_destroy
    docker_registry_mirror_server.destroy

    pop "docker registry mirror destroyed"
  end
end
