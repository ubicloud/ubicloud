# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::BuildNodeImage do
  let(:project) { Project.create(name: "kubernetes-service") }
  let(:image_project) { Project.create(name: "machine-images-service") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:strand) { described_class.assemble(kubernetes_version: "v1.35", location_id:, image_version: "20260730.1.0") }
  let(:prog) { described_class.new(strand) }
  let(:vm) { prog.vm }
  let(:sshable) { vm.sshable }

  before do
    allow(Config).to receive_messages(kubernetes_service_project_id: project.id, machine_images_service_project_id: image_project.id)
    MachineImageStore.create(project_id: image_project.id, location_id:, provider: "r2", region: "auto", endpoint: "https://r2.cloudflare.com/", bucket: "test-bucket", access_key: "ak", secret_key: "sk")
  end

  describe ".assemble" do
    it "creates the machine image and a builder vm" do
      expect(strand.label).to eq "wait_vm"

      machine_image = MachineImage[strand.stack.first["machine_image_id"]]
      expect(machine_image.name).to eq "kubernetes-v1_35"
      expect(machine_image.arch).to eq "x64"
      expect(machine_image.location_id).to eq location_id
      expect(machine_image.project_id).to eq image_project.id

      expect(vm.boot_image).to eq "ubuntu-noble"
      expect(vm.unix_user).to eq "ubi"
      expect(vm.storage_size_gib).to eq 10
      expect(strand.stack.first["skip_verification"]).to be false
    end

    it "reuses the machine image when building another version" do
      first = strand
      second = described_class.assemble(kubernetes_version: "v1.35", location_id:, image_version: "20260731.1.0")

      expect(second.stack.first["machine_image_id"]).to eq first.stack.first["machine_image_id"]
      expect(MachineImage.where(project_id: image_project.id, name: "kubernetes-v1_35").count).to eq 1
    end

    it "rejects an unsupported kubernetes version" do
      expect { described_class.assemble(kubernetes_version: "v0.1", location_id:, image_version: "20260730.1.0") }
        .to raise_error RuntimeError, "invalid kubernetes version: v0.1"
    end

    it "rejects a location that does not run kubernetes" do
      expect { described_class.assemble(kubernetes_version: "v1.35", location_id: Location::HETZNER_HEL1_ID, image_version: "20260730.1.0") }
        .to raise_error RuntimeError, "invalid location for kubernetes: #{Location::HETZNER_HEL1_ID}"
    end

    it "rejects an invalid image version" do
      expect { described_class.assemble(kubernetes_version: "v1.35", location_id:, image_version: "not a version") }
        .to raise_error RuntimeError, "invalid image version: not a version"
    end

    it "rejects a missing kubernetes service project" do
      allow(Config).to receive(:kubernetes_service_project_id).and_return(nil)

      expect { described_class.assemble(kubernetes_version: "v1.35", location_id:, image_version: "20260730.1.0") }
        .to raise_error RuntimeError, "no kubernetes service project"
    end

    it "rejects a missing machine images service project" do
      allow(Config).to receive(:machine_images_service_project_id).and_return(nil)

      expect { described_class.assemble(kubernetes_version: "v1.35", location_id:, image_version: "20260730.1.0") }
        .to raise_error RuntimeError, "no machine images service project"
    end

    it "rejects a location without a machine image store" do
      expect { described_class.assemble(kubernetes_version: "v1.35", location_id: Location::LEASEWEB_WDC02_ID, image_version: "20260730.1.0") }
        .to raise_error RuntimeError, "no machine image store for #{Location::LEASEWEB_WDC02_ID}"
    end
  end

  describe "#wait_vm" do
    it "naps until the builder vm is running" do
      expect { prog.wait_vm }.to nap(10)
    end

    it "hops to bootstrap_rhizome once the vm is running" do
      vm.update(display_state: "running")

      expect { prog.wait_vm }.to hop("bootstrap_rhizome")
    end
  end

  describe "#bootstrap_rhizome" do
    it "installs the kubernetes rhizome on the builder vm" do
      strands = Strand.where(prog: "BootstrapRhizome")

      expect { prog.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
        .and change { strands.count }.from(0).to(1)
      expect(strands.get(:stack)[0].values_at("target_folder", "subject_id", "user")).to eq ["kubernetes", vm.id, "ubi"]
    end
  end

  describe "#wait_bootstrap_rhizome" do
    it "hops to build if there are no sub-programs running" do
      expect { prog.wait_bootstrap_rhizome }.to hop("build")
    end

    it "naps while the rhizome install is still leased by another thread" do
      Strand.create(parent_id: strand.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)

      expect { prog.wait_bootstrap_rhizome }.to nap(120)
    end
  end

  describe "#build" do
    it "registers a deadline and starts the build when it has not started" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check build_node_image").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 run build_node_image kubernetes/bin/build-node-image v1.35", {log: true, stdin: nil})

      expect { prog.build }.to nap(10)
      expect(prog.strand.stack.first["deadline_target"]).to eq "sanitize"
      expect(Time.new(prog.strand.stack.first["deadline_at"])).to be_within(60).of(Time.now + 15 * 60)
    end

    it "naps while the build is in progress" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check build_node_image").and_return("InProgress")

      expect { prog.build }.to nap(10)
    end

    it "cleans the unit and hops to restart when the build succeeds" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check build_node_image").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean build_node_image")

      expect { prog.build }.to hop("restart")
    end

    it "pages and hops to failed when the build fails" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check build_node_image").and_return("Failed")

      expect { prog.build }.to hop("failed")

      page = Page.first
      expect(page.summary).to eq "Kubernetes node image kubernetes-v1_35@20260730.1.0 build Failed"
      expect(page.severity).to eq "info"
      expect(page.details["reason"]).to eq "build Failed"
      expect(page.details["builder_vm_id"]).to eq vm.id
    end

    it "pages when the daemonizer reports an unexpected state" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check build_node_image").and_return("Unknown")

      expect { prog.build }.to hop("failed")

      expect(Page.first.summary).to eq "Kubernetes node image kubernetes-v1_35@20260730.1.0 build Unknown"
    end
  end

  describe "#failed" do
    it "naps" do
      expect { prog.failed }.to nap(60 * 60)
    end
  end

  describe "#destroy" do
    it "hops to destroy from any label when the destroy semaphore is set" do
      Semaphore.incr(strand.id, "destroy")

      expect { prog.before_run }.to hop("destroy")
    end

    it "destroys the builder vm and resolves the page" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check build_node_image").and_return("Failed")
      expect { prog.build }.to hop("failed")

      expect { prog.destroy }.to exit({"msg" => "Kubernetes node image build destroyed"})
      expect(vm.destroy_set?).to be true
      expect(Page.first.semaphores.map(&:name)).to eq ["resolve"]
    end

    it "destroys the captured version when there is one" do
      metal = create_machine_image_version_metal
      refresh_frame(prog, new_values: {"machine_image_version_id" => metal.id})

      expect { prog.destroy }.to exit({"msg" => "Kubernetes node image build destroyed"})
      expect(metal.destroy_set?).to be true
      expect(vm.destroy_set?).to be true
    end

    it "destroys the verification cluster when there is one" do
      cluster = assemble_verify_cluster

      expect { prog.destroy }.to exit({"msg" => "Kubernetes node image build destroyed"})
      expect(cluster.destroy_set?).to be true
    end

    it "succeeds when the builder vm is already destroyed" do
      refresh_frame(prog, new_values: {"vm_id" => Vm.generate_uuid})

      expect { prog.destroy }.to exit({"msg" => "Kubernetes node image build destroyed"})
    end

    it "waits for the rhizome install before tearing anything down" do
      Strand.create(parent_id: strand.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)

      expect { prog.destroy }.to nap(120)
      expect(vm.destroy_set?).to be false
    end
  end

  describe "#restart" do
    it "flushes the build's writes, records the current boot id and restarts the builder vm" do
      expect(sshable).to receive(:_cmd).with("sync")
      expect(sshable).to receive(:_cmd).with("cat /proc/sys/kernel/random/boot_id").and_return("old-boot-id\n")

      expect { prog.restart }.to hop("wait_restart")
      expect(prog.strand.stack.first["boot_id"]).to eq "old-boot-id"
      expect(vm.restart_set?).to be true
    end
  end

  describe "#wait_restart" do
    before { strand.update(stack: [strand.stack.first.merge("boot_id" => "old-boot-id")]) }

    it "naps while the builder vm is unreachable" do
      expect(sshable).to receive(:_cmd).with("true").and_raise(Errno::ECONNREFUSED)

      expect { prog.wait_restart }.to nap(5)
    end

    it "naps while the builder vm is still running the boot it was restarted from" do
      expect(sshable).to receive(:_cmd).with("true").and_return("")
      expect(sshable).to receive(:_cmd).with("cat /proc/sys/kernel/random/boot_id").and_return("old-boot-id\n")

      expect { prog.wait_restart }.to nap(5)
    end

    it "hops to sanitize once the builder vm comes back on a new boot" do
      expect(sshable).to receive(:_cmd).with("true").and_return("")
      expect(sshable).to receive(:_cmd).with("cat /proc/sys/kernel/random/boot_id").and_return("new-boot-id\n")

      expect { prog.wait_restart }.to hop("sanitize")
    end
  end

  describe "#sanitize" do
    it "sanitizes the builder vm and stops it" do
      expect(sshable).to receive(:_cmd).with("kubernetes/bin/sanitize-node-image")

      expect { prog.sanitize }.to hop("wait_stopped")
      expect(vm.stop_set?).to be true
    end
  end

  describe "#wait_stopped" do
    it "naps until the builder vm is stopped" do
      expect { prog.wait_stopped }.to nap(10)
    end

    it "hops to capture once the vm is stopped" do
      vm.strand.update(label: "stopped")

      expect { prog.wait_stopped }.to hop("capture")
    end
  end

  describe "#capture" do
    it "captures the builder vm as a machine image version" do
      source = create_archive_ready_vm(project_id: project.id, location_id:)
      refresh_frame(prog, new_values: {"vm_id" => source.id})

      expect { prog.capture }.to hop("wait_capture")

      miv_metal = MachineImageVersionMetal[strand.stack.first["machine_image_version_id"]]
      expect(miv_metal.status).to eq "creating"
      expect(miv_metal.machine_image_version.version).to eq "20260730.1.0"
      expect(miv_metal.pinned_source_vm_id).to eq source.id
      expect(Strand[miv_metal.id].stack.first["set_as_latest"]).to be false
    end
  end

  describe "#wait_capture" do
    it "naps while the version is still being archived" do
      metal = create_machine_image_version_metal
      metal.update(status: "creating")
      refresh_frame(prog, new_values: {"machine_image_version_id" => metal.id})

      expect { prog.wait_capture }.to nap(15)
    end

    it "hops to verify once the version is ready" do
      metal = create_machine_image_version_metal
      refresh_frame(prog, new_values: {"machine_image_version_id" => metal.id})

      expect { prog.wait_capture }.to hop("verify")
    end

    it "hops straight to promote when verification is skipped" do
      metal = create_machine_image_version_metal
      refresh_frame(prog, new_values: {"machine_image_version_id" => metal.id, "skip_verification" => true})

      expect { prog.wait_capture }.to hop("promote")
    end

    it "pages and hops to failed when the archive failed" do
      metal = create_machine_image_version_metal
      metal.update(status: "failed")
      refresh_frame(prog, new_values: {"machine_image_version_id" => metal.id})

      expect { prog.wait_capture }.to hop("failed")

      page = Page.first
      expect(page.summary).to eq "Kubernetes node image kubernetes-v1_35@20260730.1.0 capture failed"
      expect(page.severity).to eq "info"
    end
  end

  describe "#verify" do
    it "creates a cluster and a nodepool pinned to the captured version" do
      metal = create_machine_image_version_metal
      refresh_frame(prog, new_values: {"machine_image_version_id" => metal.id})

      expect { prog.verify }.to hop("wait_verify")
      expect(Time.new(prog.strand.stack.first["deadline_at"])).to be_within(60).of(Time.now + 30 * 60)

      name = "verify-#{metal.machine_image_version.ubid}"
      cluster = KubernetesCluster[prog.strand.stack.first["verify_cluster_id"]]
      expect(cluster.name).to eq name
      expect(cluster.version).to eq "v1.35"
      expect(cluster.cp_node_count).to eq 3
      expect(cluster.project_id).to eq project.id
      expect(cluster.strand.stack.first["machine_image_version_id"]).to eq metal.id
      expect(cluster.nodepools.map { [it.name, it.node_count, it.strand.stack.first["machine_image_version_id"]] })
        .to eq [["#{name}-np", 1, metal.id]]
    end
  end

  describe "#wait_verify" do
    it "naps until the cluster and its nodepools are ready" do
      cluster = assemble_verify_cluster
      cluster.strand.update(label: "wait")

      expect { prog.wait_verify }.to nap(30)
    end

    it "hops to promote once the cluster and its nodepools are ready" do
      cluster = assemble_verify_cluster
      cluster.strand.update(label: "wait")
      cluster.nodepools.each { it.strand.update(label: "wait") }

      expect { prog.wait_verify }.to hop("promote")
    end
  end

  describe "#promote" do
    it "tags the version as latest and destroys the verification cluster" do
      metal = create_machine_image_version_metal
      cluster = assemble_verify_cluster
      refresh_frame(prog, new_values: {"machine_image_version_id" => metal.id, "verify_cluster_id" => cluster.id})

      expect { prog.promote }.to exit({"msg" => "Kubernetes node image built"})
      expect(MachineImage[strand.stack.first["machine_image_id"]].latest_version_id).to eq metal.id
      expect(cluster.destroy_set?).to be true
    end

    it "tags the version as latest when verification was skipped" do
      metal = create_machine_image_version_metal
      refresh_frame(prog, new_values: {"machine_image_version_id" => metal.id})

      expect { prog.promote }.to exit({"msg" => "Kubernetes node image built"})
      expect(MachineImage[strand.stack.first["machine_image_id"]].latest_version_id).to eq metal.id
    end
  end

  def assemble_verify_cluster
    cluster = Prog::Kubernetes::KubernetesClusterNexus.assemble(name: "verify-cluster", project_id: project.id, location_id:, version: Option.selectable_kubernetes_versions.first, cp_node_count: 3).subject
    Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "verify-cluster-np", node_count: 1, kubernetes_cluster_id: cluster.id)
    refresh_frame(prog, new_values: {"verify_cluster_id" => cluster.id})
    cluster
  end
end
