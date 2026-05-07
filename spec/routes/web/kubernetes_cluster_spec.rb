# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "Kubernetes" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:kc) do
    cluster = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "myk8s",
      version: Option.kubernetes_versions.first,
      project_id: project.id,
      private_subnet_id: PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "mysubnet", location_id: Location::HETZNER_FSN1_ID, project_id: project.id).id,
      location_id: Location::HETZNER_FSN1_ID,
    ).subject

    Prog::Kubernetes::KubernetesNodepoolNexus.assemble(
      name: "kn",
      node_count: 2,
      kubernetes_cluster_id: cluster.id,
    ).subject

    services_lb = Prog::Vnet::LoadBalancerNexus.assemble(
      cluster.private_subnet_id,
      name: cluster.services_load_balancer_name,
      algorithm: "hash_based",
      # TODO: change the api to support LBs without ports
      # The next two fields will be later modified by the sync_kubernetes_services label
      # These are just set for passing the creation validations
      src_port: 443,
      dst_port: 6443,
      health_check_endpoint: "/",
      health_check_protocol: "tcp",
      stack: LoadBalancer::Stack::IPV4,
    ).subject

    cluster.update(services_lb_id: services_lb.id)
    cluster
  end

  let(:kc_no_perm) do
    Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "not-my-k8s",
      version: Option.kubernetes_versions.first,
      project_id: project_wo_permissions.id,
      private_subnet_id: PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "othersubnet", location_id: Location::HETZNER_FSN1_ID, project_id: project_wo_permissions.id).id,
      location_id: Location::HETZNER_FSN1_ID,
    ).subject
  end

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
  end

  describe "unauthenticated" do
    it "can not list without login" do
      visit "#{project.path}/kubernetes-cluster"
      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "#{project.path}/kubernetes-cluster/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "list" do
      it "works with 0 kubernetes clusters" do
        visit "#{project.path}/kubernetes-cluster"
        expect(page.title).to eq("Ubicloud - Kubernetes Clusters")
        expect(page).to have_content "No Kubernetes Clusters"
        expect(page).to have_content "Create Kubernetes Cluster"

        click_link "Create Kubernetes Cluster"
        expect(page.title).to eq("Ubicloud - Create Kubernetes Cluster")
      end

      it "lists existing permissible clusters" do
        kc
        kc_no_perm

        visit "#{project.path}/kubernetes-cluster"

        expect(page).to have_content "myk8s"
        expect(page).to have_no_content "not-my-k8s"
        expect(page).to have_content "Create Kubernetes Cluster"
      end

      it "doesn't show the create button without permission" do
        project
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])

        expect(KubernetesCluster.count).to eq(0)

        visit "#{project.path}/kubernetes-cluster"

        expect(page).to have_content("No Kubernetes Clusters")
        expect(page).to have_no_content "Create Kubernetes Cluster"

        kc
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])

        expect(KubernetesCluster.count).to eq(1)
        visit "#{project.path}/kubernetes-cluster"

        expect(page).to have_content(kc.name)
        expect(page).to have_no_content "No Kubernetes Clusters"
        expect(page).to have_no_content "Create Kubernetes Cluster"
      end
    end

    describe "create" do
      before do
        kc
        visit "#{project.path}/kubernetes-cluster/create"
        expect(page.title).to eq("Ubicloud - Create Kubernetes Cluster")
      end

      it "cannot create kubernetes cluster when location does not exist" do
        fill_in "Cluster Name", with: "cannotcreate"
        choose option: 3
        find('select#worker_nodes option[value="4"]:not([disabled])').select_option
        choose option: Location::LEASEWEB_WDC02_UBID
        Location[Location::LEASEWEB_WDC02_ID].destroy

        click_button "Create"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content("ResourceNotFound")
      end

      it "can not create cluster if project has no valid payment method" do
        expect(described_class).to receive(:authorized_project).with(user, project.id).and_return(project).at_least(:once)
        expect(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)

        page.refresh

        expect(page).to have_content "Project doesn't have valid billing information"

        fill_in "Cluster Name", with: "dummyk8s"
        choose option: Location::HETZNER_FSN1_UBID
        choose option: 3
        find('select#worker_nodes option[value="4"]:not([disabled])').select_option

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Kubernetes Cluster")
        expect(page).to have_content "Project doesn't have valid billing information"
      end

      it "can create new kubernetes cluster" do
        fill_in "Cluster Name", with: "k8stest"
        choose option: Location::HETZNER_FSN1_UBID
        choose option: 3
        find('select#worker_nodes option[value="4"]:not([disabled])').select_option

        [1, 2, 4, 8].each do
          expect(page).to have_content "#{it * 2} vCPUs / #{it * 8} GB RAM / #{it * 40} GB NVMe Storage"
        end

        click_button "Create"
        expect(page.title).to eq("Ubicloud - k8stest")
        expect(page).to have_flash_notice("'k8stest' will be ready in a few minutes")
        expect(KubernetesCluster.count).to eq(2)

        new_kc = KubernetesCluster[name: "k8stest"]

        expect(new_kc.project_id).to eq(project.id)
        expect(new_kc.cp_node_count).to eq(3)
        expect(new_kc.nodepools.first.node_count).to eq(4)
        expect(new_kc.private_subnet.name).to eq("#{new_kc.ubid}-subnet")
      end

      it "can not create kubernetes cluster with invalid name" do
        fill_in "Cluster Name", with: "invalid name"
        choose option: Location::HETZNER_FSN1_UBID
        choose option: 3
        find('select#worker_nodes option[value="4"]:not([disabled])').select_option

        click_button "Create"
        expect(page.title).to eq("Ubicloud - Create Kubernetes Cluster")
        expect(page).to have_content "Kubernetes cluster name must only contain lowercase"
        expect((find "input[name=name]")["value"]).to eq("invalid name")
      end

      it "can not create kubernetes cluster with same name in same project & location" do
        fill_in "Cluster Name", with: "myk8s"
        choose option: Location::HETZNER_FSN1_UBID
        choose option: 3
        find('select#worker_nodes option[value="4"]:not([disabled])').select_option

        click_button "Create"
        expect(page.title).to eq("Ubicloud - Create Kubernetes Cluster")
        expect(page).to have_flash_error("project_id and location_id and name is already taken")
      end

      it "can not select invisible location" do
        expect { choose option: Location::GITHUB_RUNNERS_UBID }.to raise_error Capybara::ElementNotFound
      end

      it "can not create kubernetes cluster in a project when does not have permissions" do
        visit "#{project_wo_permissions.path}/kubernetes-cluster/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end
    end

    describe "show" do
      it "can show kubernetes cluster details" do
        kc
        visit "#{project.path}/kubernetes-cluster"
        expect(page.title).to eq("Ubicloud - Kubernetes Clusters")

        expect(page).to have_content kc.name

        click_link kc.name, href: "#{project.path}#{kc.path}"

        expect(page.title).to eq("Ubicloud - #{kc.name}")
        expect(page).to have_content kc.name
        expect(page).to have_content kc.ubid
        expect(page).to have_content kc.display_location
        expect(page).to have_content kc.version

        KubernetesNode.create(vm_id: create_vm(name: "cp1").id, kubernetes_cluster_id: kc.id)
        KubernetesNode.create(vm_id: create_vm(name: "cp2").id, kubernetes_cluster_id: kc.id)

        kn = kc.nodepools.first

        KubernetesNode.create(vm_id: create_vm(name: "node1").id, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)

        kc.reload
        expect(kc.display_state).to eq("creating")
        expect(page.body).to include "auto-refresh hidden"
        expect(page.body).to include "creating"
        expect(page).to have_content "Waiting for cluster to be ready..."
        expect(page).to have_no_content "Download"

        kc.strand.update(label: "wait")
        kn.strand.update(label: "wait")
        page.refresh
        expect(page.body).not_to include "auto-refresh hidden"
        expect(page.body).to include "running"
        expect(page).to have_no_content "Waiting for cluster to be ready..."
        expect(page).to have_content "Download"

        within("#kubernetes-cluster-submenu") { click_link "Nodes" }

        expect(page).to have_content "cp1"
        expect(page).to have_content "cp2"
        expect(page).to have_content "node1"

        kc.incr_destroy
        kc.reload

        expect(kc.display_state).to eq("deleting")
        within("#kubernetes-cluster-submenu") { click_link "Overview" }
        expect(page.body).to include "deleting"
        expect(page.body).to include "auto-refresh hidden"
      end

      it "shows up on customer private subnet vms page" do
        visit "#{project.path}/location/#{kc.display_location}/private-subnet/#{kc.private_subnet.ubid}/vms"
        expect(page.title).to eq "Ubicloud - mysubnet"
        expect(page.all("#private-subnet-nics h3").map(&:text)).to eq ["Attached VMs", "Other Attached Resources"]
        expect(page.all("#private-subnet-nics td").map(&:text)).to eq ["No VM attached", "Kubernetes Cluster", kc.name, kc.ubid]
        click_link kc.name
        expect(page.title).to eq "Ubicloud - #{kc.name}"
      end

      it "works with ubid" do
        visit "#{project.path}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}"

        expect(page.title).to eq("Ubicloud - #{kc.name}")
        expect(page).to have_content kc.name
      end

      it "does not show delete option without permissions" do
        kc
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])
        visit "#{project.path}#{kc.path}"

        expect(page.title).to eq("Ubicloud - #{kc.name}")
        expect(page).to have_content kc.name
        expect(page).to have_content kc.ubid
        expect(page).to have_content kc.display_location

        expect(page).to have_no_content "Danger Zone"
      end

      it "raises forbidden when does not have permissions" do
        visit "#{project_wo_permissions.path}#{kc_no_perm.path}"
        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "raises not found when kubernetes cluster does not exist" do
        visit "#{project.path}/location/eu-central-h1/kubernetes-cluster/blabla"

        expect(page.title).to eq("Ubicloud - ResourceNotFound")
        expect(page.status_code).to eq(404)
        expect(page).to have_content "ResourceNotFound"
      end
    end

    describe "kubeconfig" do
      before do
        kc
      end

      it "returns kubeconfig content for authorized users" do
        expect(KubernetesCluster).to receive(:kubeconfig).and_return "kubeconfig content"

        visit "#{project.path}#{kc.path}/kubeconfig"

        expect(page.response_headers["Content-Type"]).to eq("text/yaml")
        expect(page.response_headers["Content-Disposition"]).to include("attachment; filename=\"#{kc.name}-kubeconfig.yaml\"")
        expect(page.body).to eq("kubeconfig content")
      end

      it "shows error page if there is an error getting kubeconfig file from control plane node" do
        expect(KubernetesCluster).to receive(:kubeconfig).and_raise(IOError)

        visit "#{project.path}#{kc.path}/kubeconfig"

        expect(page.response_headers["Content-Type"]).to include("text/html")
        expect(page.response_headers["Content-Disposition"]).to be_nil
        expect(page.title).to eq "Ubicloud - myk8s"
        expect(page).to have_flash_error("Temporary error downloading kubeconfig.yaml. Please try again.")
      end

      it "raises forbidden error when user does not have permission" do
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])

        visit "#{project.path}#{kc.path}/kubeconfig"
        expect(page.status_code).to eq(403)
        expect(page).to have_content("Forbidden")
      end

      it "raises not found when Kubernetes cluster does not exist" do
        visit "#{project.path}/kubernetes-cluster/_nonexistent/kubeconfig"

        expect(page.status_code).to eq(404)
        expect(page).to have_content("ResourceNotFound")
      end

      it "returns proper content headers and content" do
        expect(KubernetesCluster).to receive(:kubeconfig).and_return "mocked kubeconfig content"

        visit "#{project.path}#{kc.path}/kubeconfig"
        expect(page.response_headers["Content-Type"]).to eq("text/yaml")
        expect(page.response_headers["Content-Disposition"]).to include("attachment; filename=\"#{kc.name}-kubeconfig.yaml\"")
        expect(page.body).to eq("mocked kubeconfig content")
      end

      it "does not allow unauthorized access" do
        AccessControlEntry.dataset.destroy
        visit "#{project.path}#{kc.path}/kubeconfig"

        expect(page.status_code).to eq(403)
        expect(page).to have_content("Forbidden")
      end
    end

    describe "rename" do
      it "can rename kubernetes cluster" do
        old_name = kc.name
        visit "#{project.path}#{kc.path}/settings"
        fill_in "name", with: "new-name%"
        click_button "Rename"
        expect(page).to have_flash_error("Validation failed for following fields: name")
        expect(page).to have_content("Kubernetes cluster name must only contain lowercase letters, numbers, and hyphens and have max length 40.")
        expect(kc.reload.name).to eq old_name

        fill_in "name", with: "new-name"
        click_button "Rename"
        expect(page).to have_flash_notice("Name updated")
        expect(kc.reload.name).to eq "new-name"
        expect(page).to have_content("new-name")
      end

      it "does not show rename option without permissions" do
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])
        visit "#{project_wo_permissions.path}#{kc_no_perm.path}/settings"
        expect(page).to have_no_content("Rename")
      end
    end

    describe "resize" do
      it "can resize kubernetes cluster" do
        visit "#{project.path}#{kc.path}/settings"
        expect(kc.nodepools.first.reload.node_count).not_to eq(4)
        find('select#node_count option[value="4"]:not([disabled])').select_option
        click_button "Resize"

        expect(page).to have_flash_notice("myk8s node pool kn will be resized")
        expect(kc.nodepools.first.reload.node_count).to eq(4)
      end

      it "does not show resize option without permissions" do
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])
        visit "#{project_wo_permissions.path}#{kc_no_perm.path}/settings"
        expect(page).to have_no_content("Resize")
      end
    end

    describe "networking" do
      let(:kc_ps) { kc.private_subnet }

      let(:pg_subnet) {
        Prog::Vnet::SubnetNexus.assemble(project.id, name: "pg-subnet", location_id: Location::HETZNER_FSN1_ID).subject
      }

      let(:pg) {
        resource = create_postgres_resource(project: project, location_id: Location::HETZNER_FSN1_ID)
        resource.update(private_subnet_id: pg_subnet.id)
        resource.reload
      }

      it "can navigate to networking page via tab" do
        kc
        visit "#{project.path}#{kc.path}"
        within("#kubernetes-cluster-submenu") { click_link "Networking" }
        expect(page.title).to eq("Ubicloud - #{kc.name}")
        expect(page).to have_content kc_ps.name
      end

      it "shows private subnet with networking link when user has PrivateSubnet:edit" do
        kc
        visit "#{project.path}#{kc.path}/networking"
        expect(page).to have_link(kc_ps.name, href: "#{project.path}#{kc_ps.path}/networking")
      end

      it "shows private subnet without link when user lacks PrivateSubnet:edit" do
        kc
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])

        visit "#{project.path}#{kc.path}/networking"
        expect(page).to have_content kc_ps.name
        expect(page).to have_no_link(kc_ps.name)
      end

      it "shows attached firewall with networking link when user has Firewall:edit" do
        kc
        fw = Firewall.create(name: "kc-fw", description: "kc firewall", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)
        fw.associate_with_private_subnet(kc_ps)

        visit "#{project.path}#{kc.path}/networking"
        expect(page).to have_link(fw.name, href: "#{project.path}#{fw.path}/networking")
      end

      it "shows attached firewall without link when user lacks Firewall:edit" do
        kc
        fw = Firewall.create(name: "kc-fw", description: "kc firewall", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)
        fw.associate_with_private_subnet(kc_ps)

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Firewall:view"])

        visit "#{project.path}#{kc.path}/networking"
        expect(page).to have_content fw.name
        expect(page).to have_no_link(fw.name)
      end

      it "shows no firewall section content when no firewalls attached" do
        kc
        visit "#{project.path}#{kc.path}/networking"
        expect(page).to have_content "No firewall attached"
      end

      it "does not show postgres section when no postgres databases exist" do
        kc
        visit "#{project.path}#{kc.path}/networking"
        expect(page).to have_no_content "PostgreSQL Databases"
      end

      it "shows postgres databases when user has Postgres:view" do
        pg
        kc
        visit "#{project.path}#{kc.path}/networking"
        expect(page).to have_content "PostgreSQL Databases"
        expect(page).to have_content pg.name
        expect(page).to have_content "Not connected"
      end

      it "does not show postgres databases when user lacks Postgres:view" do
        pg
        kc
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])

        visit "#{project.path}#{kc.path}/networking"
        expect(page).to have_no_content "PostgreSQL Databases"
        expect(page).to have_no_content pg.name
      end

      it "shows connect button when subnets are not connected and user has all required permissions" do
        pg
        kc
        visit "#{project.path}#{kc.path}/networking"
        expect(page).to have_button("Connect")
      end

      it "does not show connect button when user lacks PrivateSubnet:connect" do
        pg
        kc
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Firewall:edit"])

        visit "#{project.path}#{kc.path}/networking"
        expect(page).to have_content pg.name
        expect(page).to have_no_button("Connect")
      end

      it "does not show connect button when user lacks Firewall:edit on postgres subnet firewalls" do
        pg
        kc
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:connect"])

        visit "#{project.path}#{kc.path}/networking"
        expect(page).to have_content pg.name
        expect(page).to have_no_button("Connect")
      end

      context "when subnets are already connected" do
        before do
          kc_subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "kc-connected-subnet", location_id: Location::HETZNER_FSN1_ID).subject
          @kc_connected = Prog::Kubernetes::KubernetesClusterNexus.assemble(
            name: "kc-connected",
            version: Option.kubernetes_versions.first,
            project_id: project.id,
            private_subnet_id: kc_subnet.id,
            location_id: Location::HETZNER_FSN1_ID,
          ).subject
          pg
          @kc_connected.private_subnet.connect_subnet(pg_subnet)
        end

        it "shows Connected status with links to postgres subnet and firewalls when user has all permissions" do
          visit "#{project.path}#{@kc_connected.path}/networking"
          expect(page).to have_content pg.name
          expect(page).to have_link("Connected", href: "#{project.path}#{pg_subnet.path}/networking")

          pg_fw = pg_subnet.firewalls.first
          expect(page).to have_link(pg_fw.name, href: "#{project.path}#{pg_fw.path}/networking")
        end

        it "shows Connected status without links when user lacks PrivateSubnet:edit on postgres subnet" do
          AccessControlEntry.dataset.destroy
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Firewall:edit"])

          visit "#{project.path}#{@kc_connected.path}/networking"
          expect(page).to have_content pg.name
          expect(page).to have_content "Connected"
          expect(page).to have_no_link("Connected")
        end

        it "shows Connected status without firewall links when user lacks Firewall:edit on postgres subnet firewalls" do
          AccessControlEntry.dataset.destroy
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:edit"])

          visit "#{project.path}#{@kc_connected.path}/networking"
          expect(page).to have_content pg.name
          expect(page).to have_link("Connected", href: "#{project.path}#{pg_subnet.path}/networking")
          pg_fw = pg_subnet.firewalls.first
          expect(page).to have_no_link(pg_fw.name)
        end
      end

      context "when connecting postgres subnet" do
        before do
          kc_subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "kc-connect-subnet", location_id: Location::HETZNER_FSN1_ID).subject
          @kc_connectable = Prog::Kubernetes::KubernetesClusterNexus.assemble(
            name: "kc-connectable",
            version: Option.kubernetes_versions.first,
            project_id: project.id,
            private_subnet_id: kc_subnet.id,
            location_id: Location::HETZNER_FSN1_ID,
          ).subject
          pg
        end

        it "connects the private subnets and adds firewall rules when button is clicked" do
          visit "#{project.path}#{@kc_connectable.path}/networking"
          expect(page).to have_content pg.name
          expect(page).to have_button("Connect")

          click_button "Connect"

          expect(page).to have_flash_notice("Connecting to #{pg.name}. Firewall rules will be updated in a few seconds.")
          expect(page.current_path).to eq("#{project.path}#{@kc_connectable.path}/networking")

          @kc_connectable.private_subnet.reload
          expect(@kc_connectable.private_subnet.connected_subnets.map(&:id)).to include pg_subnet.id

          pg_fw = pg_subnet.firewalls.first
          pg_fw.reload
          kc_cidr = @kc_connectable.private_subnet.net4.to_s
          rule_summaries = pg_fw.firewall_rules.map { |r| [r.cidr.to_s, r.display_port_range] }
          expect(rule_summaries).to include([kc_cidr, "5432"])
          expect(rule_summaries).to include([kc_cidr, "6432"])
        end

        it "returns forbidden when user lacks KubernetesCluster:view" do
          visit "#{project.path}#{@kc_connectable.path}/networking"
          _csrf = find("#form-connect-pg-#{pg.ubid} input[name='_csrf']", visible: false).value
          AccessControlEntry.dataset.destroy
          page.driver.post "#{project.path}#{@kc_connectable.path}/connect-postgres/#{pg.ubid}", {_csrf:}
          expect(page.status_code).to eq(403)
        end

        it "returns forbidden when user lacks Postgres:view" do
          visit "#{project.path}#{@kc_connectable.path}/networking"
          _csrf = find("#form-connect-pg-#{pg.ubid} input[name='_csrf']", visible: false).value
          AccessControlEntry.dataset.destroy
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:connect"])
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Firewall:edit"])
          page.driver.post "#{project.path}#{@kc_connectable.path}/connect-postgres/#{pg.ubid}", {_csrf:}
          expect(page.status_code).to eq(403)
        end

        it "returns forbidden when user lacks PrivateSubnet:connect" do
          visit "#{project.path}#{@kc_connectable.path}/networking"
          _csrf = find("#form-connect-pg-#{pg.ubid} input[name='_csrf']", visible: false).value
          AccessControlEntry.dataset.destroy
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Firewall:edit"])
          page.driver.post "#{project.path}#{@kc_connectable.path}/connect-postgres/#{pg.ubid}", {_csrf:}
          expect(page.status_code).to eq(403)
        end

        it "returns forbidden when user lacks Firewall:edit on postgres subnet firewalls" do
          visit "#{project.path}#{@kc_connectable.path}/networking"
          _csrf = find("#form-connect-pg-#{pg.ubid} input[name='_csrf']", visible: false).value
          AccessControlEntry.dataset.destroy
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])
          AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:connect"])
          page.driver.post "#{project.path}#{@kc_connectable.path}/connect-postgres/#{pg.ubid}", {_csrf:}
          expect(page.status_code).to eq(403)
        end
      end
    end

    describe "delete" do
      it "can delete kubernetes cluster" do
        visit "#{project.path}#{kc.path}"
        within("#kubernetes-cluster-submenu") { click_link "Settings" }

        within("#kc-delete-#{kc.ubid}") do
          click_button "Delete"
        end
        expect(page).to have_flash_notice("Kubernetes cluster scheduled for deletion.")

        expect(SemSnap.new(kc.id).set?("destroy")).to be true
      end

      it "can not delete kubernetes cluster when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])

        visit "#{project_wo_permissions.path}#{kc_no_perm.path}/settings"
        expect(page.title).to eq "Ubicloud - not-my-k8s"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end
  end
end
