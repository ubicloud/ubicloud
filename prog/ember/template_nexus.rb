# frozen_string_literal: true

# Builds a template memory snapshot on every host that can use it (design doc
# 4.3).
#
# A template is immutable and keyed by everything that has to match for a
# restore to work, so a new image or hypervisor version produces a new template
# rather than mutating one. The old template is retired once no ember needs
# it, which is why retirement is a separate label rather than part of the
# build.
class Prog::Ember::TemplateNexus < Prog::Base
  subject_is :ember_template

  BUILD_POLL_SECONDS = 15
  WAIT_SECONDS = 120

  def self.assemble(location_id:, cpu_signature:, root_image:, data_image:,
    workload:, version:, arch: "x64", memory_mib: nil, vcpus: 1)
    DB.transaction do
      template = EmberTemplate.create(
        location_id:, cpu_signature:, root_image:, data_image:,
        workload:, version:, arch:, vcpus:,
        ch_version: Config.ember_ch_version,
        memory_mib: memory_mib || Config.ember_default_memory_mib,
        state: "building",
      )
      Strand.create_with_id(template, prog: "Ember::TemplateNexus", label: "start")
      template
    end
  end

  label def start
    register_deadline("wait", 60 * 60)
    hop_build
  end

  # Every host that could place embers from this template builds its own copy.
  # Hosts that already have a row are building, done, or failed at it.
  label def build
    peers.each do |host|
      next if EmberTemplateHost[ember_template_id: ember_template.id, vm_host_id: host.id]

      begin
        host.ember.cmd_json("sudo host/bin/ember build-template :template", template: ember_template.ubid, stdin: build_payload)
        EmberTemplateHost.create(ember_template_id: ember_template.id, vm_host_id: host.id)
      rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
        Clog.emit("template build failed to start",
          {template: ember_template.ubid, host: host.ubid, error: e.message})
      end
    end

    # Nothing in this location has started one yet; a host will appear, or
    # come back.
    nap 60 if ember_template.ember_template_hosts_dataset.empty?
    hop_wait_builds
  end

  label def wait_builds
    building = EmberTemplateHost.where(ember_template_id: ember_template.id, state: "building").all
    building.each do |row|
      status = begin
        row.vm_host.ember.cmd_json("sudo host/bin/ember template-status :template", template: ember_template.ubid)
      rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
        Clog.emit("template build poll failed", {template: ember_template.ubid, host: row.vm_host.ubid, error: e.message})
        next
      end

      case status["state"]
      when "ready"
        row.update(state: "ready")
      when "failed"
        Clog.emit("template build failed", {template: ember_template.ubid, host: row.vm_host.ubid, detail: status["detail"]})
        row.update(state: "failed")
      end
    end

    # One host is enough to start placing embers on; the rest join as they
    # finish.
    rows = ember_template.ember_template_hosts_dataset
    if ember_template.state == "building"
      if !rows.where(state: "ready").empty?
        ember_template.update(state: "ready")
      elsif rows.exclude(state: "failed").empty?
        ember_template.update(state: "failed")
      end
    end

    hop_wait if rows.where(state: "building").empty?
    nap BUILD_POLL_SECONDS
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    when_retire_set? do
      decr_retire
      ember_template.update(state: "retired")
      hop_wait
    end

    # A host added after the build still needs its own.
    hop_build if ember_template.ready? && peers.any? { |host|
      EmberTemplateHost[ember_template_id: ember_template.id, vm_host_id: host.id].nil?
    }

    nap WAIT_SECONDS
  end

  label def destroy
    decr_destroy
    unless ember_template.embers_dataset.empty?
      Clog.emit("template still in use", {template: ember_template.ubid})
      nap 60
    end

    EmberTemplateHost.where(ember_template_id: ember_template.id).all.each do |row|
      row.vm_host.ember.cmd_json("sudo host/bin/ember delete-template :template", template: ember_template.ubid)
    rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS => e
      Clog.emit("template delete failed", {template: ember_template.ubid, error: e.message})
    end

    DB.transaction do
      EmberTemplateHost.where(ember_template_id: ember_template.id).destroy
      ember_template.destroy
    end
    pop "ember template destroyed"
  end

  # Hosts that could build this template: same location, same CPU class.
  def peers
    VmHost
      .ember_enabled(location_id: ember_template.location_id)
      .where(cpu_signature: ember_template.cpu_signature)
      .all
  end

  def build_payload
    {
      "root_image" => ember_template.root_image,
      "data_image" => ember_template.data_image,
      "memory_mib" => ember_template.memory_mib,
      "vcpus" => ember_template.vcpus,
      "ch_version" => ember_template.ch_version,
    }
  end
end
