# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::AppService::AppServerNexus < Prog::Base
  subject_is :app_server

  extend Forwardable

  def_delegators :app_server, :vm, :app_resource

  def self.assemble(app_process)
    app_resource = app_process.app_resource
    DB.transaction do
      ubid = AppServer.generate_ubid
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        Config.app_service_project_id,
        sshable_unix_user: "ubi",
        location_id: app_resource.location_id,
        name: ubid.to_s,
        size: app_process.vm_size,
        storage_volumes: [{encrypted: true, size_gib: 30}],
        boot_image: "ubuntu-noble",
        private_subnet_id: app_resource.private_subnet_id,
        enable_ip4: true,
      )

      id = ubid.to_uuid
      AppServer.create_with_id(id, app_resource_id: app_resource.id, app_process_id: app_process.id, vm_id: vm_st.id)

      # Grant the VM's managed identity (created by Prog::Vm::Nexus) read access to
      # the app's secret store, so it can pull config/secrets at build and run time.
      AccessControlEntry.create(
        project_id: Config.app_service_project_id,
        subject_id: vm_st.id,
        action_id: ActionType::NAME_MAP["SecretStore:view"],
        object_id: app_resource.secret_store_id,
      )

      Strand.create_with_id(id, prog: "AppService::AppServerNexus", label: "start")
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"

    register_deadline("wait", 10 * 60)
    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    bud Prog::BootstrapRhizome, {"target_folder" => "app_service", "subject_id" => vm.id, "user" => "ubi"}

    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap(:install_dependencies)
  end

  label def install_dependencies
    case vm.sshable.d_check("install_app_service_deps")
    when "Succeeded"
      vm.sshable.d_clean("install_app_service_deps")
      # Only web servers sit behind the load balancer; workers run headless.
      if app_server.web?
        hop_register_with_load_balancer
      else
        hop_wait
      end
    when "Failed", "NotStarted"
      vm.sshable.d_run("install_app_service_deps", "/home/ubi/app_service/bin/install")
    end
    nap 5
  end

  label def register_with_load_balancer
    app_resource.load_balancer.add_vm(vm)
    hop_wait
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    when_deploy_set? do
      hop_deploy
    end

    nap 60 * 60 * 24 * 30
  end

  label def deploy
    target = app_resource.latest_deployment

    case vm.sshable.d_check("deploy_app")
    when "Succeeded"
      vm.sshable.d_clean("deploy_app")
      app_server.update(current_deployment_id: target.id)
      decr_deploy
      hop_wait
    when "Failed"
      vm.sshable.d_clean("deploy_app")
      target.update(status: "failed")
      decr_deploy
      hop_wait
    when "NotStarted"
      target.update(commit_sha: resolve_commit_sha) if target.commit_sha.nil?
      vm.sshable.d_run("deploy_app", "/home/ubi/app_service/bin/deploy", app_resource.repo_url, app_resource.branch, target.commit_sha, app_resource.secret_store.ubid, app_server.app_process.process_type)
    end
    nap 5
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy

    Semaphore.incr(strand.children_dataset.select(:id), "destroy")
    hop_wait_children_destroyed
  end

  label def wait_children_destroyed
    reap(nap: 5) do
      remove_from_load_balancer
      vm.incr_destroy
      app_server.destroy

      pop "app server destroyed"
    end
  end

  # Web servers sit behind the load balancer; remove this one (rewriting the
  # LB's DNS records) before its VM is destroyed. No-op for non-web servers or
  # servers that never finished registering.
  def remove_from_load_balancer
    return unless app_server.web?
    lb = app_resource.load_balancer
    lb.remove_vm(vm) if lb.load_balancer_vms_dataset.where(vm_id: vm.id).any?
  end

  def resolve_commit_sha
    vm.sshable.cmd("git ls-remote :repo_url :branch", repo_url: app_resource.repo_url, branch: app_resource.branch).split.first
  end
end
