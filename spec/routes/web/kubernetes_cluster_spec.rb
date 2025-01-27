# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "Kubernetes" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:kc) do
    Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "myk8s",
      version: "v1.32",
      project_id: project.id,
      private_subnet_id: PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "mysubnet", location: "hetzner-fsn1", project_id: project.id).id,
      location: "hetzner-fsn1"
    ).subject
  end

  let(:kc_no_perm) do
    Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "not-my-k8s",
      version: "v1.32",
      project_id: project_wo_permissions.id,
      private_subnet_id: PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "othersubnet", location: "x", project_id: project_wo_permissions.id).id,
      location: "hetzner-fsn1"
    ).subject
  end

  before do
    project.set_ff_kubernetes true
    project_wo_permissions.set_ff_kubernetes true
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

    describe "feature disabled" do
      before do
        project.set_ff_kubernetes false
      end

      it "is not shown in the sidebar" do
        visit project.path
        expect(page).to have_no_content("Kubernetes")

        project.set_ff_kubernetes true

        visit project.path
        expect(page).to have_content("Kubernetes")
      end

      it "kubernetes page is not accessible" do
        visit "#{project.path}/kubernetes-cluster"
        expect(page.status_code).to eq(404)
      end
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

      it "can create new kubernetes cluster" do
        fill_in "Name", with: "k8stest"
        choose option: "v1.32"
        choose option: "eu-central-h1"
        select "mysubnet", from: "private_subnet_id"
        choose option: 3
        select 2, from: "worker_nodes"

        click_button "Create"
        expect(page.title).to eq("Ubicloud - k8stest")
        expect(page).to have_flash_notice("'k8stest' will be ready in a few minutes")
        expect(KubernetesCluster.count).to eq(2)

        new_kc = KubernetesCluster[name: "k8stest"]

        expect(new_kc.project_id).to eq(project.id)
        expect(new_kc.cp_node_count).to eq(3)
        expect(new_kc.nodepools.first.node_count).to eq(2)
      end

      it "can not create kubernetes cluster with invalid name" do
        fill_in "Name", with: "invalid name"
        choose option: "v1.32"
        choose option: "eu-central-h1"
        select "mysubnet", from: "private_subnet_id"
        choose option: 3
        select 2, from: "worker_nodes"

        click_button "Create"
        expect(page.title).to eq("Ubicloud - Create Kubernetes Cluster")
        expect(page).to have_content "Kubernetes cluster name must only contain lowercase"
        expect((find "input[name=name]")["value"]).to eq("invalid name")
      end

      it "can not create a cluster with invalid subnet" do
        kc
        csrf_token = find("form[action='#{project.path}/kubernetes-cluster'] input[name='_csrf']", visible: false).value

        expect(KubernetesCluster.count).to eq(1)

        params = {
          name: "dummy",
          location: "eu-central-h1",
          version: "v1.32",
          private_subnet_id: UBID.generate_random("ps"),
          cp_nodes: 3,
          worker_nodes: 2,
          _csrf: csrf_token
        }
        page.driver.post "#{project.path}/kubernetes-cluster", params
        expect(KubernetesCluster.count).to eq(1)

        visit "#{project.path}/kubernetes-cluster/create"
        csrf_token = find("form[action='#{project.path}/kubernetes-cluster'] input[name='_csrf']", visible: false).value
        params[:private_subnet_id] = kc.private_subnet.ubid
        params[:_csrf] = csrf_token

        page.driver.post "#{project.path}/kubernetes-cluster", params
        expect(KubernetesCluster.count).to eq(2)
      end

      it "can not create a cluster with a subnet in a different location" do
        kc
        csrf_token = find("form[action='#{project.path}/kubernetes-cluster'] input[name='_csrf']", visible: false).value

        expect(KubernetesCluster.count).to eq(1)

        params = {
          name: "dummy",
          location: "us-east-a2",
          version: "v1.32",
          private_subnet_id: kc.private_subnet.ubid,
          cp_nodes: 3,
          worker_nodes: 2,
          _csrf: csrf_token
        }
        page.driver.post "#{project.path}/kubernetes-cluster", params
        expect(KubernetesCluster.count).to eq(1)

        visit "#{project.path}/kubernetes-cluster/create"
        csrf_token = find("form[action='#{project.path}/kubernetes-cluster'] input[name='_csrf']", visible: false).value
        params[:_csrf] = csrf_token
        kc.private_subnet.update(location: "leaseweb-wdc02")

        page.driver.post "#{project.path}/kubernetes-cluster", params
        expect(KubernetesCluster.count).to eq(2)
      end

      it "can not create kubernetes cluster with same name in same project & location" do
        fill_in "Name", with: "myk8s"
        choose option: "v1.32"
        choose option: "eu-central-h1"
        select "mysubnet", from: "private_subnet_id"
        choose option: 3
        select 2, from: "worker_nodes"

        click_button "Create"
        expect(page.title).to eq("Ubicloud - Create Kubernetes Cluster")
        expect(page).to have_flash_error("project_id and location and name is already taken")
      end

      it "can not select invisible location" do
        expect { choose option: "github-runners" }.to raise_error Capybara::ElementNotFound
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

        kc.add_cp_vm(create_vm(name: "cp1"))
        kc.add_cp_vm(create_vm(name: "cp2"))

        kn = KubernetesNodepool.create(
          name: "kn",
          node_count: 2,
          kubernetes_cluster_id: kc.id
        )

        kn.add_vm(create_vm(name: "node1"))

        kc.reload
        page.refresh

        expect(page).to have_content "cp1"
        expect(page).to have_content "cp2"
        expect(page).to have_content "node1"
      end

      it "works with ubid" do
        visit "#{project.path}/location/#{kc.display_location}/kubernetes-cluster/_#{kc.ubid}"

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

    describe "delete" do
      it "can delete kubernetes cluster" do
        visit "#{project.path}#{kc.path}"

        # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
        # UI tests run without a JavaScript enginer.
        btn = find "#kc-delete-#{kc.ubid} .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

        expect(SemSnap.new(kc.id).set?("destroy")).to be true
      end

      it "can not delete kubernetes cluster when does not have permissions" do
        # Give permission to view, so we can see the detail page
        AccessControlEntry.create_with_id(project_id: project_wo_permissions.id, subject_id: user.id, action_id: ActionType::NAME_MAP["KubernetesCluster:view"])

        visit "#{project_wo_permissions.path}#{kc_no_perm.path}"
        expect(page.title).to eq "Ubicloud - not-my-k8s"

        expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
      end
    end
  end
end
