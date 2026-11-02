# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "kubernetes-cluster" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }
  let(:k8s_project) { Project.create(name: "UbicloudKubernetesService") }
  let(:kc) {
    kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "cluster",
      version: Option.selectable_kubernetes_versions.first,
      cp_node_count: 3,
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      target_node_size: "standard-2",
    ).subject
    Prog::Kubernetes::KubernetesNodepoolNexus.assemble(
      name: "np",
      node_count: 2,
      kubernetes_cluster_id: kc.id,
    ).subject
    kc
  }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(k8s_project.id)
  end

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      [
        [:get, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster"],
        [:post, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/foo_name"],
        [:post, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/foo_name/nodepool"],
        [:get, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/foo_name/nodepool/bar_name"],
        [:delete, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/foo_name/nodepool/bar_name"],
        [:post, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/foo_name/nodepool/bar_name/rename"],
        [:post, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/foo_name/nodepool/bar_name/resize"],
        [:post, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/foo_name/nodepool/bar_name/upgrade"],
        [:post, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/foo_name/node/baz_name/retire"],
        [:delete, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}"],
        [:delete, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}"],
        [:get, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}"],
        [:get, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}"],
        [:post, "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}/upgrade"],
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

    describe "metrics" do
      let(:tsdb_client) { instance_double(VictoriaMetrics::Client) }

      it "queries every kubernetes metric against the cluster ubid" do
        allow(VictoriaMetricsResource).to receive(:client_for_project).with(k8s_project.id).and_return(tsdb_client)
        queries = []
        expect(tsdb_client).to receive(:query_range).exactly(Metrics::KUBERNETES_METRICS.values.sum { it.series.count }).times do |query:, **|
          queries << query
          [{"values" => [[1619712000, "1.5"]], "labels" => {"instance" => "kn1"}}]
        end

        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/metrics"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["metrics"].size).to eq(Metrics::KUBERNETES_METRICS.size)
        expect(queries).to all(include(kc.ubid))
      end

      it "returns 404 when no victoria metrics resource is configured" do
        allow(VictoriaMetricsResource).to receive(:client_for_project).with(k8s_project.id).and_return(nil)

        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/metrics"

        expect(last_response).to have_api_error(404, "Metrics are not configured for this instance")
      end

      it "fails when the metric name is invalid" do
        allow(VictoriaMetricsResource).to receive(:client_for_project).with(k8s_project.id).and_return(tsdb_client)

        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/metrics?key=nope"

        expect(last_response).to have_api_error(400, "Invalid metric name")
      end
    end

    describe "list" do
      it "success list" do
        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster"

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["items"].length).to eq(1)
        expect(parsed_body["count"]).to eq(1)
        expect(parsed_body["items"][0]["name"]).to eq("cluster")
        expect(parsed_body["items"][0]["version"]).to eq(Option.selectable_kubernetes_versions.first)
        expect(parsed_body["items"][0]["state"]).to eq("creating")
        expect(parsed_body["items"][0].keys).not_to include("cp_vms", "nodepools")
      end

      it "lists several clusters, each with its services load balancer" do
        kc2 = Prog::Kubernetes::KubernetesClusterNexus.assemble(name: "cluster2", version: kc.version, project_id: project.id, location_id: kc.location_id).subject
        kc3 = Prog::Kubernetes::KubernetesClusterNexus.assemble(name: "cluster3", version: kc.version, project_id: project.id, location_id: kc.location_id).subject
        # Use version 1 hostnames, which include part of the subnet's ubid,
        # so that serializing them reads each load balancer's subnet.
        hostnames = [kc2, kc3].map do |c|
          lb = Prog::Vnet::LoadBalancerNexus.assemble(c.private_subnet_id, name: c.services_load_balancer_name, src_port: 80, dst_port: 8080, hostname_version: 1).subject
          c.update(services_lb_id: lb.id, kubeconfig: "stored")
          lb.hostname
        end

        if Config.unfrozen_test?
          # The duplicate query check can't catch these lookups, since Sequel
          # writes the key being looked up into the SQL.
          expect(LoadBalancer).not_to receive(:primary_key_lookup)
          expect(PrivateSubnet).not_to receive(:primary_key_lookup)
        end

        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].map { it.slice("name", "state", "services_load_balancer_url") }).to contain_exactly(
          {"name" => "cluster", "state" => "creating", "services_load_balancer_url" => nil},
          {"name" => "cluster2", "state" => "running", "services_load_balancer_url" => hostnames[0]},
          {"name" => "cluster3", "state" => "running", "services_load_balancer_url" => hostnames[1]},
        )
      end
    end

    describe "create" do
      it "success" do
        version = Option.selectable_kubernetes_versions.last
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/kubernetes-cluster/test-cluster", {
          version:,
          worker_size: "standard-2",
          worker_nodes: 2,
          cp_node_count: 1,
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-cluster")
        expect(JSON.parse(last_response.body)["version"]).to eq(version)
        expect(last_response["warning"]).to eq('299 - "worker_size is deprecated: use createKubernetesNodepool instead", ' \
          '299 - "worker_nodes is deprecated: use createKubernetesNodepool instead"')
        expect(KubernetesCluster[name: "test-cluster"].nodepools.map { [it.name, it.node_count, it.target_node_size] }).to eq([["test-cluster-np", 2, "standard-2"]])
      end

      def create_cluster(name: "test-cluster", **body)
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/kubernetes-cluster/#{name}", {version: Option.selectable_kubernetes_versions.last, **body}.to_json
      end

      it "creates a cluster without a nodepool when no worker input is given" do
        create_cluster

        expect(last_response.status).to eq(200)
        expect(last_response["deprecation"]).to be_nil
        expect(JSON.parse(last_response.body)["nodepools"]).to eq([])
        expect(KubernetesCluster[name: "test-cluster"].nodepools).to be_empty
      end

      it "still makes a default nodepool from worker_size alone in API version 2" do
        header "Accept", "application/vnd.ubicloud+json; version=2"
        create_cluster(worker_size: "standard-4")

        expect(last_response.status).to eq(200)
        expect(last_response["warning"]).to eq('299 - "worker_size is deprecated: use createKubernetesNodepool instead"')
        expect(KubernetesCluster[name: "test-cluster"].nodepools.map { [it.node_count, it.target_node_size] }).to eq([[1, "standard-4"]])
      end

      it "refuses worker_nodes without worker_size" do
        create_cluster(worker_nodes: 2)

        expect(last_response).to have_api_error(400, "missing parameter for worker_size")
        expect(KubernetesCluster[name: "test-cluster"]).to be_nil
      end

      it "checks vCPU quota against the control plane alone when no worker input is given" do
        project.add_quota(quota_id: ProjectQuota.default_quotas["KubernetesVCpu"]["id"], value: 4)
        create_cluster(cp_node_count: 3)

        expect(last_response).to have_api_error(400, "Validation failed for following fields: cp_node_count")
        expect(KubernetesCluster[name: "test-cluster"]).to be_nil
      end

      it "creates the cluster with cp_node_count, in both API versions" do
        ["application/json", "application/vnd.ubicloud+json; version=2"].each_with_index do |accept, i|
          header "Accept", accept
          create_cluster(name: "test-cluster-#{i}", cp_node_count: 3)

          expect(last_response.status).to eq(200)
          expect(last_response["deprecation"]).to be_nil
          expect(JSON.parse(last_response.body)["cp_node_count"]).to eq(3)
        end
      end

      it "takes the deprecated cp_nodes as cp_node_count in API version 1, with a warning" do
        create_cluster(cp_nodes: 3)

        expect(last_response.status).to eq(200)
        expect(last_response["warning"]).to eq('299 - "cp_nodes is deprecated: use cp_node_count instead"')
        expect(JSON.parse(last_response.body)["cp_node_count"]).to eq(3)
      end

      it "refuses cp_nodes together with cp_node_count" do
        create_cluster(cp_nodes: 3, cp_node_count: 1)

        expect(last_response).to have_api_error(400, "cp_nodes and cp_node_count name one value; send only cp_node_count", {"cp_nodes" => "send only cp_node_count"})
        expect(KubernetesCluster[name: "test-cluster"]).to be_nil
      end

      it "refuses cp_nodes in API version 2" do
        header "Accept", "application/vnd.ubicloud+json; version=2"
        create_cluster(cp_nodes: 3)

        expect(last_response).to have_api_error(400, "cp_nodes was removed in API version 2: use cp_node_count instead")
      end

      it "accepts a name of 37 characters, and refuses a longer one" do
        create_cluster(name: "a" * 37, worker_size: "standard-2")
        expect(last_response.status).to eq(200)
        expect(KubernetesCluster[name: "a" * 37].nodepools.map(&:name)).to eq(["#{"a" * 37}-np"])

        expect { create_cluster(name: "a" * 38) }.to raise_error(Committee::InvalidRequest, /pattern .* does not match value: "a{38}"/)
      end

      it "returns 400 for invalid kubernetes version" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/kubernetes-cluster/test-cluster", {
          version: "v1.30",
          worker_size: "standard-2",
          worker_nodes: 2,
          cp_node_count: 1,
        }.to_json

        expect(last_response.status).to eq(400)
        expect(last_response).to have_api_error(400, "Validation failed for following fields: version")
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["error"]["details"]["version"]).to include("Kubernetes version \"v1.30\" is not supported")
        expect(parsed_body["error"]["details"]["version"]).to include("Available versions:")
      end

      it "returns 400 for a supported kubernetes version that is not selectable" do
        version = (Option.kubernetes_versions - Option.selectable_kubernetes_versions).first
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/kubernetes-cluster/test-cluster", {
          version:,
          worker_size: "standard-2",
          worker_nodes: 2,
          cp_node_count: 1,
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: version")
        expect(KubernetesCluster[name: "test-cluster"]).to be_nil
      end
    end

    describe "show" do
      it "success" do
        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}"

        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        expect(body["name"]).to eq(kc.name)
        expect(body.slice("state", "display_state", "services_load_balancer_url")).to eq("state" => "creating", "display_state" => "creating", "services_load_balancer_url" => nil)
        expect(body["nodepools"].map { it.slice("name", "state", "vms") }).to eq([{"name" => "np", "state" => "creating", "vms" => []}])
      end

      it "shows a cluster with a kubeconfig as running while the nexus does routine work" do
        kc.update(kubeconfig: "stored")
        kc.strand.update(label: "sync_kubernetes_services")

        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body).slice("state", "display_state")).to eq("state" => "running", "display_state" => "running")
      end

      it "shows the hostname of the services load balancer" do
        lb = Prog::Vnet::LoadBalancerNexus.assemble(kc.private_subnet_id, name: kc.services_load_balancer_name, src_port: 80, dst_port: 8080).subject
        kc.update(services_lb_id: lb.id)

        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["services_load_balancer_url"]).to eq(lb.hostname)
      end

      it "shows the state of each nodepool" do
        Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np2", node_count: 1, kubernetes_cluster_id: kc.id)
        kc.nodepools_dataset.first(name: "np").strand.update(label: "wait")

        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["nodepools"].map { it.slice("name", "state") }).to eq([{"name" => "np", "state" => "running"}, {"name" => "np2", "state" => "creating"}])
      end

      it "checks the detailed part of the response against the schema" do
        expect(Serializers::KubernetesCluster).to receive(:serialize_internal).and_wrap_original { |m, *args| m.call(*args).merge(undocumented: true) }

        expect {
          get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}"
        }.to raise_error(Committee::InvalidResponse, /does not define properties: undocumented/)
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

    describe "rename" do
      it "answers with the detailed cluster" do
        post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/rename", {name: "new-name"}.to_json

        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        expect(body["name"]).to eq("new-name")
        expect(body["cp_vms"]).to eq([])
        expect(body["nodepools"].map { it["name"] }).to eq(["np"])
        expect(kc.reload.name).to eq("new-name")
      end
    end

    describe "kubeconfig" do
      it "success" do
        kc.update(kubeconfig: "kubeconfig content")

        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/kubeconfig"

        expect(last_response.status).to eq(200)
        expect(last_response.body).to eq("kubeconfig content")
      end

      it "fails when the cluster has not generated a kubeconfig yet" do
        kc.update(kubeconfig: nil)

        get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/kubeconfig"

        expect(last_response).to have_api_error(422, "Cluster is not ready, kubeconfig is not available yet")
      end
    end

    describe "delete" do
      it "success" do
        delete "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}"

        expect(last_response.status).to eq(204)
        expect(kc.destroy_set?).to be true
      end

      it "success ubid" do
        delete "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}"

        expect(last_response.status).to eq(204)
        expect(kc.destroy_set?).to be true
      end
    end

    describe "nodepool" do
      let(:kn) { kc.nodepools.first }

      describe "create" do
        it "creates a nodepool and requests bootstrapping" do
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool", {name: "np2", node_size: "standard-2", node_count: 2}.to_json

          expect(last_response.status).to eq(200)
          body = JSON.parse(last_response.body)
          expect(body["name"]).to eq("np2")
          expect(body["node_count"]).to eq(2)
          expect(body["node_size"]).to eq("standard-2")
          expect(body["version"]).to eq(kc.version)
          expect(body.slice("state", "vms")).to eq("state" => "creating", "vms" => [])
          expect(kc.nodepools_dataset.first(name: "np2").start_bootstrapping_set?).to be true
        end

        it "accepts the cluster's version, and refuses another" do
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool", {name: "np2", node_size: "standard-2", node_count: 1, version: Option.kubernetes_versions[1]}.to_json

          expect(last_response).to have_api_error(400, "Validation failed for following fields: version", {"version" => "Nodepool can only be created at the cluster's version, #{kc.version}"})
          expect(kc.nodepools_dataset.count).to eq(1)

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool", {name: "np2", node_size: "standard-2", node_count: 1, version: kc.version}.to_json

          expect(last_response.status).to eq(200)
          expect(JSON.parse(last_response.body)["version"]).to eq(kc.version)
          expect(kc.nodepools_dataset.count).to eq(2)
        end

        it "returns an error while the cluster is not in wait" do
          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool", {name: "np2", node_size: "standard-2", node_count: 1}.to_json

          expect(last_response).to have_api_error(422, "Cluster is not ready to add a nodepool")
          expect(last_response.headers["retry-after"]).to eq("10")
          expect(kc.nodepools_dataset.count).to eq(1)
        end

        it "returns a retryable error while another nodepool is still being set up" do
          kc.strand.update(label: "wait")
          kn.strand.update(label: "bootstrap_worker_nodes")

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool", {name: "np2", node_size: "standard-2", node_count: 1}.to_json

          expect(last_response).to have_api_error(422, "Cluster is not ready to add a nodepool")
          expect(last_response.headers["retry-after"]).to eq("10")
          expect(kc.nodepools_dataset.count).to eq(1)
        end

        it "returns a final error while the cluster is being deleted" do
          kc.strand.update(label: "wait")
          kc.incr_destroy

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool", {name: "np2", node_size: "standard-2", node_count: 1}.to_json

          expect(last_response).to have_api_error(422, "Cluster is not ready to add a nodepool")
          expect(last_response.headers).not_to have_key("retry-after")
          expect(kc.nodepools_dataset.count).to eq(1)
        end

        it "returns an error while the cluster has an upgrade pending" do
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")
          kc.incr_upgrade

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool", {name: "np2", node_size: "standard-2", node_count: 1}.to_json

          expect(last_response).to have_api_error(422, "Cluster is not ready to add a nodepool")
          expect(kc.nodepools_dataset.count).to eq(1)
        end

        it "returns an error when the nodepool name is taken" do
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool", {name: kn.name, node_size: "standard-2", node_count: 1}.to_json

          expect(last_response).to have_api_error(400, "Validation failed for following fields: name")
          expect(kc.nodepools_dataset.count).to eq(1)
        end

        it "checks vCPU quota" do
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")
          project.add_quota(quota_id: ProjectQuota.default_quotas["KubernetesVCpu"]["id"], value: 10)

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool", {name: "np2", node_size: "standard-4", node_count: 3}.to_json

          expect(last_response).to have_api_error(400, "Validation failed for following fields: node_count")
          expect(JSON.parse(last_response.body)["error"]["details"]["node_count"]).to eq("Insufficient quota for requested size. Requested vCPU count: 12, currently used vCPU count: 10, maximum allowed vCPU count: 10, remaining vCPU count: 0")
          expect(kc.nodepools_dataset.count).to eq(1)
        end
      end

      describe "show" do
        it "shows a nodepool by name or ubid" do
          kn.strand.update(label: "wait")

          [kn.name, kn.ubid].each do |identifier|
            get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{identifier}"

            expect(last_response.status).to eq(200)
            expect(JSON.parse(last_response.body).slice("id", "kubernetes_cluster_id", "name", "state", "vms")).to eq("id" => kn.ubid, "kubernetes_cluster_id" => kc.ubid, "name" => "np", "state" => "running", "vms" => [])
          end
        end

        it "answers 404 for a nodepool the cluster does not have" do
          other = Prog::Kubernetes::KubernetesClusterNexus.assemble(name: "other", version: kc.version, project_id: project.id, location_id: Location::HETZNER_FSN1_ID).subject
          other_kn = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "other-np", node_count: 1, kubernetes_cluster_id: other.id).subject

          ["not-exists-nodepool", other_kn.name, other_kn.ubid].each do |identifier|
            get "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{identifier}"

            expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
          end
        end
      end

      describe "delete" do
        it "deletes a nodepool by name or ubid" do
          kn2 = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np2", node_count: 1, kubernetes_cluster_id: kc.id).subject

          [kn2.name, kn2.ubid].each do |identifier|
            delete "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{identifier}"

            expect(last_response.status).to eq(204)
            expect(kn2.destroy_set?).to be true
          end
        end

        it "deletes the last nodepool of a cluster" do
          delete "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}"

          expect(last_response.status).to eq(204)
          expect(kn.destroy_set?).to be true
        end
      end

      describe "rename" do
        it "renames the nodepool" do
          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/rename", {name: "np-renamed"}.to_json

          expect(last_response.status).to eq(200)
          body = JSON.parse(last_response.body)
          expect(body["name"]).to eq("np-renamed")
          expect(body["vms"]).to eq([])
          expect(kn.reload.name).to eq("np-renamed")
        end

        it "returns an error when the new name is taken" do
          Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np2", node_count: 1, kubernetes_cluster_id: kc.id)

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/rename", {name: "np2"}.to_json

          message = "kubernetes_cluster_id and name is already taken"
          expect(last_response).to have_api_error(400, message, {"name" => message})
          expect(kn.reload.name).to eq("np")
        end

        it "returns an error for an invalid name" do
          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/rename", {name: "INVALID_NAME"}.to_json

          expect(last_response).to have_api_error(400, "Validation failed for following fields: name")
          expect(kn.reload.name).to eq("np")
        end
      end

      describe "resize" do
        it "success" do
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")
          [kn.name, kn.ubid].each do |identifier|
            new_count = rand(1..10)
            kn.strand.prog_class.new(kn.strand).decr_scale_worker_count
            post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{identifier}/resize", {node_count: new_count}.to_json

            expect(last_response.status).to eq(200)
            body = JSON.parse(last_response.body)
            expect(body["node_count"]).to eq(new_count)
            expect(body["state"]).to eq("resizing")
            expect(kn.reload.node_count).to eq(new_count)
            expect(kn.scale_worker_count_set?).to be true
          end
        end

        it "returns validation error for bad input" do
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")
          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/resize", {node_count: 0}.to_json

          expect(last_response.status).to eq(400)
        end

        it "returns an error while the cluster is not in wait" do
          kn.strand.update(label: "wait")

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/resize", {node_count: 4}.to_json

          expect(last_response).to have_api_error(422, "Cluster is not ready to resize a nodepool")
          expect(last_response.headers["retry-after"]).to eq("10")
          expect(kn.reload.node_count).to eq(2)
        end

        it "returns an error while the cluster has an upgrade pending" do
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")
          kc.incr_upgrade

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/resize", {node_count: 4}.to_json

          expect(last_response).to have_api_error(422, "Cluster is not ready to resize a nodepool")
          expect(last_response.headers["retry-after"]).to eq("10")
          expect(kn.reload.node_count).to eq(2)
        end

        it "returns an error while the nodepool is not in wait" do
          kc.strand.update(label: "wait")

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/resize", {node_count: 4}.to_json

          expect(last_response).to have_api_error(422, "Nodepool is not ready to be resized")
          expect(last_response.headers["retry-after"]).to eq("10")
          expect(kn.reload.node_count).to eq(2)
        end

        it "returns an error while the nodepool has an upgrade pending" do
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")
          kn.incr_upgrade

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/resize", {node_count: 4}.to_json

          expect(last_response).to have_api_error(422, "Nodepool is not ready to be resized")
          expect(last_response.headers["retry-after"]).to eq("10")
          expect(kn.reload.node_count).to eq(2)
        end

        it "returns a final error while the nodepool is being deleted" do
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")
          kn.incr_destroy

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/resize", {node_count: 4}.to_json

          expect(last_response).to have_api_error(422, "Nodepool is not ready to be resized")
          expect(last_response.headers).not_to have_key("retry-after")
          expect(kn.reload.node_count).to eq(2)
        end

        it "checks vCPU quota when scaling up" do
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")
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

      describe "upgrade" do
        it "upgrades the nodepool to the cluster version" do
          kn.update(version: Option.kubernetes_versions[2])
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/upgrade"

          expect(last_response.status).to eq(200)
          expect(JSON.parse(last_response.body).slice("version", "state")).to eq("version" => kc.version, "state" => "upgrading")
          expect(kn.reload.version).to eq(kc.version)
          expect(kn.upgrade_requested_set?).to be true
          expect(kn.upgrade_set?).to be false
          expect(kc.upgrade_nodepools_set?).to be true
        end

        it "upgrades to version when it is the cluster's version, and does nothing when resent" do
          kn.update(version: Option.kubernetes_versions[1])
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")

          2.times do
            post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/upgrade", {version: kc.version}.to_json

            expect(last_response.status).to eq(200)
            expect(JSON.parse(last_response.body).slice("version", "state")).to eq("version" => kc.version, "state" => "upgrading")
          end
          expect(kn.reload.version).to eq(kc.version)
          expect(DB[:audit_log].where(action: "upgrade").count).to eq(1)
        end

        it "refuses a version that is not the cluster's" do
          kn.update(version: Option.kubernetes_versions[2])
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/upgrade", {version: Option.kubernetes_versions[1]}.to_json

          expect(last_response).to have_api_error(400, "Validation failed for following fields: version", {"version" => "Nodepool can only be upgraded to the cluster's version, #{kc.version}"})
          expect(kn.reload.version).to eq(Option.kubernetes_versions[2])
          expect(kn.upgrade_requested_set?).to be false
        end

        it "returns an error when the nodepool is at the cluster version" do
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/upgrade"

          expect(last_response).to have_api_error(422, "Nodepool is already at the cluster's version, #{kc.version}")
          expect(last_response.headers).not_to have_key("retry-after")
          expect(kn.reload.version).to eq(kc.version)
          expect(kn.upgrade_requested_set?).to be false
        end

        it "returns an error when the cluster is not idle" do
          kn.update(version: Option.kubernetes_versions[1])
          kc.strand.update(label: "upgrade")
          kn.strand.update(label: "wait")

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/upgrade"

          expect(last_response).to have_api_error(422, "Cluster is not ready to upgrade a nodepool")
          expect(last_response.headers["retry-after"]).to eq("10")
          expect(kn.reload.version).to eq(Option.kubernetes_versions[1])
          expect(kn.upgrade_requested_set?).to be false
        end

        it "returns a final error when the cluster is being deleted" do
          kn.update(version: Option.kubernetes_versions[1])
          kc.strand.update(label: "wait")
          kn.strand.update(label: "wait")
          kc.incr_destroy

          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/nodepool/#{kn.name}/upgrade"

          expect(last_response).to have_api_error(422, "Cluster is not ready to upgrade a nodepool")
          expect(last_response.headers).not_to have_key("retry-after")
          expect(kn.upgrade_requested_set?).to be false
        end
      end
    end

    describe "retire node" do
      let(:kn) { kc.nodepools.first }

      def assemble_worker_node(name)
        Prog::Kubernetes::KubernetesNodeNexus.assemble(k8s_project.id, sshable_unix_user: "ubi", name:, location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-#{kc.version.tr(".", "_")}", enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id).subject
      end

      it "retires a worker node by name and decrements node_count" do
        node = assemble_worker_node("worker-by-name")

        post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/node/#{node.name}/retire"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["node_count"]).to eq(1)
        expect(node.retire_set?).to be true
        expect(kn.reload.node_count).to eq(1)
      end

      it "returns 404 when the node does not exist in the cluster" do
        post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/node/missing-node/retire"

        expect(last_response.status).to eq(404)
        expect(kn.reload.node_count).to eq(2)
      end

      it "does not allow retiring the last node of a nodepool" do
        kn.update(node_count: 1)
        node = assemble_worker_node("last-node")

        post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/node/#{node.name}/retire"

        expect(last_response).to have_api_error(422, "You cannot retire the last node of a nodepool")
        expect(node.retire_set?).to be false
        expect(kn.reload.node_count).to eq(1)
      end

      it "does not allow retiring a node that is already being retired" do
        node = assemble_worker_node("retiring-node")
        node.incr_retire

        post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.name}/node/#{node.name}/retire"

        expect(last_response).to have_api_error(422, "Node retiring-node is already being retired")
        expect(kn.reload.node_count).to eq(2)
      end
    end

    describe "upgrade" do
      it "upgrades only the control plane when upgrade is available" do
        kc.update(version: Option.selectable_kubernetes_versions[1])
        kn = kc.nodepools.first
        kn.update(version: Option.selectable_kubernetes_versions[1])
        kc.strand.update(label: "wait")
        kn.strand.update(label: "wait")

        post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}/upgrade"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["state"]).to eq("upgrading")
        expect(kc.reload.version).to eq(Option.selectable_kubernetes_versions.first)
        expect(kc.upgrade_set?).to be true
        expect(kc.upgrade_nodepools_set?).to be false
        expect(kn.reload.version).to eq(Option.selectable_kubernetes_versions[1])
        expect(kn.upgrade_requested_set?).to be false
        expect(kn.upgrade_set?).to be false
      end

      it "upgrades to version when it is the next version, and does nothing when resent" do
        kc.update(version: Option.kubernetes_versions[1])
        kc.strand.update(label: "wait")
        kc.nodepools.first.strand.update(label: "wait")

        2.times do
          post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}/upgrade", {version: Option.kubernetes_versions[0]}.to_json

          expect(last_response.status).to eq(200)
          expect(JSON.parse(last_response.body).slice("version", "state")).to eq("version" => Option.kubernetes_versions[0], "state" => "upgrading")
        end
        expect(kc.reload.version).to eq(Option.kubernetes_versions[0])
        expect(DB[:audit_log].where(action: "upgrade").count).to eq(1)
      end

      it "refuses a version that is not the next one" do
        kc.update(version: Option.kubernetes_versions[2])
        kc.strand.update(label: "wait")
        kc.nodepools.first.strand.update(label: "wait")

        post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}/upgrade", {version: Option.kubernetes_versions[0]}.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: version", {"version" => "Cluster can only be upgraded to the next version, #{Option.kubernetes_versions[1]}"})
        expect(kc.reload.version).to eq(Option.kubernetes_versions[2])
        expect(kc.upgrade_set?).to be false
      end

      it "refuses a version when the cluster is at the latest version" do
        post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}/upgrade", {version: "v1.99"}.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: version", {"version" => "Cluster is at the latest version, #{kc.version}"})
        expect(kc.reload.upgrade_set?).to be false
      end

      it "returns an error when no upgrade is available" do
        original_version = kc.version
        kc.strand.update(label: "wait")
        kc.nodepools.first.strand.update(label: "wait")

        post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}/upgrade"

        expect(last_response).to have_api_error(422, "Cluster is at the latest version, #{original_version}")
        expect(last_response.headers).not_to have_key("retry-after")
        expect(kc.reload.version).to eq(original_version)
      end

      it "returns an error when a nodepool is more than two minor versions behind" do
        kc.update(version: Option.selectable_kubernetes_versions[1])
        kn = kc.nodepools.first
        kn.update(version: "v1.#{Option.kubernetes_minor_version(kc.version) - 3}")
        kc.strand.update(label: "wait")
        kn.strand.update(label: "wait")

        post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}/upgrade"

        expect(last_response).to have_api_error(422, "All nodepools must be upgraded to within two minor versions of the cluster first")
        expect(last_response.headers).not_to have_key("retry-after")
        expect(kc.reload.version).to eq(Option.selectable_kubernetes_versions[1])
        expect(kc.upgrade_set?).to be false
      end

      it "returns an error when the cluster is not idle" do
        original_version = Option.selectable_kubernetes_versions[1]
        kc.update(version: original_version)
        kc.strand.update(label: "wait")
        kc.nodepools.first.strand.update(label: "bootstrap_worker_nodes")

        post "/project/#{project.ubid}/location/#{kc.display_location}/kubernetes-cluster/#{kc.ubid}/upgrade"

        expect(last_response).to have_api_error(422, "Cluster is not ready to be upgraded")
        expect(last_response.headers["retry-after"]).to eq("10")
        expect(kc.reload.version).to eq(original_version)
        expect(kc.upgrade_set?).to be false
      end
    end
  end
end
