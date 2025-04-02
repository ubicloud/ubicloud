# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Github::DockerRegistryMirrorNexus < Prog::Base
  subject_is :docker_registry_mirror

  extend Forwardable
  def_delegators :docker_registry_mirror, :vm

  def self.assemble(vm_host_id, vm_size: "standard-2", storage_size_gib: 40, boot_image: "ubuntu-jammy")
    DB.transaction do
      vm_host = VmHost[vm_host_id] || fail("Host not found")

      ubid = DockerRegistryMirror.generate_ubid
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        Config.docker_registry_mirror_project_id,
        sshable_unix_user: "ubi",
        location_id: vm_host.location_id,
        name: ubid.to_s,
        size: vm_size,
        storage_volumes: [{encrypted: true, size_gib: storage_size_gib}],
        boot_image: boot_image,
        enable_ip4: true,
        arch: vm_host.arch,
        force_host_id: vm_host_id
      )

      DockerRegistryMirror.create(vm_id: vm_st.id) { _1.id = ubid.to_uuid }
      Strand.create(prog: "Github::DockerRegistryMirrorNexus", label: "start") { _1.id = ubid.to_uuid }
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
      sudo systemctl enable --now docker
    COMMAND

    vm.sshable.cmd(command)
    hop_update_docker_registry_config
  end

  label def update_docker_registry_config
    # TODO: Add delete scheduler with or without online garbage collection
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
    docker_registry_mirror.last_certificate_reset_at = Time.now

    # While initiating the server it is started, while resetting the certificate it is restarted
    hop_start_or_restart_docker_registry
  end

  label def start_or_restart_docker_registry
    container_status_command = "sudo docker ps -a --filter name=registry-mirror --format '{{.Status}}'"
    container_status = vm.sshable.cmd(container_status_command).strip

    command = if container_status.empty?
      <<~COMMAND
        sudo docker run -d \
          --name registry-mirror \
          --restart=always \
          -p 5000:5000 \
          -v /etc/docker/registry/config.yml:/etc/docker/registry/config.yml:ro \
          -v /etc/docker/registry/certs:/certs:ro \
          -v /var/lib/registry:/var/lib/registry \
          registry:2
      COMMAND
    else
      "sudo docker restart registry-mirror"
    end

    vm.sshable.cmd(command)
    hop_wait
  end

  label def wait
    if need_certificate_reset?
      register_deadline("wait", 5 * 60)
      hop_fetch_certificate
    end

    nap 60 * 60 * 24
  end

  label def destroy
    decr_destroy

    vm.incr_destroy
    docker_registry_mirror.destroy

    pop "docker registry mirror destroyed"
  end

  def need_certificate_reset?
    docker_registry_mirror.last_certificate_reset_at < Time.now - 60 * 60 * 24 * 30 # ~1 month
  end
end
