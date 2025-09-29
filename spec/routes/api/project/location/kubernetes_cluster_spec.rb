# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "kubernetes-cluster" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }
  let(:k8s_project) { Project.create(name: "UbicloudKubernetesService") }
  let(:subnet) { PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "x", location_id: Location::HETZNER_FSN1_ID, project_id: k8s_project.id) }
  let(:kc) {
    Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "cluster",
      version: Option.kubernetes_versions.first,
      cp_node_count: 3,
      project_id: project.id,
      private_subnet_id: subnet.id,
      location_id: Location::HETZNER_FSN1_ID,
      target_node_size: "standard-2"
    ).subject
  }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(k8s_project.id)
  end

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      [
        [:get, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster"],
        [:post, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/foo_name"],
        [:post, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/foo_name/nodepool/bar_name/resize"],
        [:delete, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}"],
        [:delete, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}"],
        [:get, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}"],
        [:get, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}"]
      ].each do |method, path|
        send method, path

        expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
      end
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    describe "list" do
      it "success list" do
        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster"

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["items"].length).to eq(1)
        expect(parsed_body["count"]).to eq(1)
        expect(parsed_body["items"][0]["name"]).to eq("cluster")
        expect(parsed_body["items"][0]["version"]).to eq(Option.kubernetes_versions.first)
      end
    end

    describe "create" do
      it "success" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/kubernetes-cluster/test-cluster", {
          version: "v1.33",
          worker_size: "standard-2",
          worker_nodes: 2,
          cp_nodes: 1
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-cluster")
        expect(JSON.parse(last_response.body)["version"]).to eq("v1.33")
        expect(KubernetesCluster[name: "test-cluster"]).not_to be_nil
      end
    end

    describe "show" do
      it "success" do
        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(kc.name)
      end

      it "success ubid" do
        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(kc.name)
      end

      it "not found" do
        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/not-exists-cluster"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end
    end

    describe "delete" do
      it "success" do
        delete "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(kc.id).set?("destroy")).to be true
      end

      it "success ubid" do
        delete "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(kc.id).set?("destroy")).to be true
      end
    end

    describe "nodepool" do
      let(:kn) do
        Prog::Kubernetes::KubernetesNodepoolNexus.assemble(
          name: "np",
          node_count: 2,
          kubernetes_cluster_id: kc.id
        ).subject
      end

      describe "resize" do
        it "success" do
          [kn.name, kn.ubid].each do |identifier|
            new_count = rand(1..10)
            kn.strand.load.decr_scale_worker_count
            post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{identifier}/resize", {node_count: new_count}.to_json

            expect(last_response.status).to eq(200)
            body = JSON.parse(last_response.body)
            expect(body["node_count"]).to eq(new_count)
            expect(kn.reload.node_count).to eq(new_count)
            expect(kn.scale_worker_count_set?).to be true
          end
        end

        it "returns validation error for bad input" do
          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/resize", {node_count: 0}.to_json

          expect(last_response.status).to eq(400)
        end

        it "checks vCPU quota when scaling up" do
          kn.update(target_node_size: "standard-4", node_count: 5)
          expect(project.reload.current_resource_usage("KubernetesVCpu")).to eq 26 # cp: 3*2 + workers: 5*4

          project.add_quota(quota_id: ProjectQuota.default_quotas["KubernetesVCpu"]["id"], value: 15)
          expect(project.reload.effective_quota_value("KubernetesVCpu")).to eq 15

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/resize", {node_count: 10}.to_json
          expect(last_response.status).to eq(400)
          expect(last_response.body).to include("Insufficient quota for requested size")

          # Allows downsizing, even though the new quota is still not enough
          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/resize", {node_count: 4}.to_json
          expect(last_response.status).to eq(200)
          expect(kn.reload.node_count).to eq(4)
        end
      end
    end
  end
end
