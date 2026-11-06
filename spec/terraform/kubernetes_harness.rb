# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "ubicloud_kubernetes_cluster" do
  def cluster(name: "k8s", version: "v1.36") = <<~HCL
    resource "ubicloud_kubernetes_cluster" "k8s" {
      location = "eu-central-h1"
      name     = "#{name}"
      version  = "#{version}"
    }
  HCL

  def pool(name, node_count: 2, label: name, **attrs) = <<~HCL
    resource "ubicloud_kubernetes_cluster_nodepool" "#{label}" {
      location              = "eu-central-h1"
      kubernetes_cluster_id = ubicloud_kubernetes_cluster.k8s.id
      name                  = "#{name}"
      node_count            = #{node_count}
      node_size             = "standard-2"
      #{attrs.map { |k, v| "#{k} = #{v}" }.join("\n")}
    }
  HCL

  def kc = KubernetesCluster.first(project_id: project.id)

  def pools = kc.nodepools.map { [it.name, it.node_count, it.version] }

  it "creates a cluster without a nodepool" do
    expect(tf.apply(cluster).mutations).to eq ["POST kubernetes-cluster/k8s"]
    expect([kc.version, kc.cp_node_count, kc.nodepools]).to eq ["v1.36", 1, []]
    expect(tf.state("ubicloud_kubernetes_cluster.k8s")).to include("state" => "running", "nodepool_ids" => [])
    expect(tf.plan).to be_empty
  end

  # The API upgrades a nodepool only to its cluster's version, and only
  # while the cluster is idle, so the cluster must be upgraded first.
  # Terraform does that, since the nodepools depend on the cluster.
  it "upgrades the cluster, then a nodepool that follows the cluster's version" do
    tf.apply cluster + pool("a", version: "ubicloud_kubernetes_cluster.k8s.version") + pool("b")

    expect(tf.apply(cluster(version: "v1.37") + pool("a", version: "ubicloud_kubernetes_cluster.k8s.version") + pool("b")).mutations).to eq [
      "POST kubernetes-cluster/@k8s/upgrade", "POST kubernetes-cluster/@k8s/nodepool/@a/upgrade",
    ]
    expect([kc.version, kc.display_state, pools]).to eq ["v1.37", "running", [["a", 2, "v1.37"], ["b", 2, "v1.36"]]]
    expect(tf.plan).to be_empty
  end

  # The harness settles the resize before terraform gets the answer, so
  # set scale_worker_count again, and settle the nodepool only after the
  # provider has read it as resizing.
  it "resizes a nodepool, and waits for the resize to settle" do
    tf.apply cluster + pool("a")
    np = kc.nodepools.first

    at(:response, "POST kubernetes-cluster/@k8s/nodepool/@a/resize") do
      np.incr_scale_worker_count
      at(:response, "GET kubernetes-cluster/@k8s/nodepool/@a") do
        expect(it.response["state"]).to eq "resizing"
        settle(np)
      end
    end
    expect(tf.apply(cluster + pool("a", node_count: 3)).mutations).to eq ["POST kubernetes-cluster/@k8s/nodepool/@a/resize"]
    expect(pools).to eq [["a", 3, "v1.36"]]
    expect(tf.state("ubicloud_kubernetes_cluster_nodepool.a")).to include("state" => "running", "node_count" => 3)
    expect(tf.plan).to be_empty
  end

  # Terraform creates both nodepools in parallel, and the API refuses to
  # add a nodepool, with Retry-After, while another is being set up. The
  # harness settles each create before serving the next request, so the
  # example answers the first create with that refusal.
  it "creates two nodepools in one apply, retrying the one refused while the cluster was busy" do
    busy = {error: {code: 422, type: "UnprocessableContent", message: "Cluster is not ready to add a nodepool"}}
    at(:request, "POST kubernetes-cluster/@k8s/nodepool") { it.answer(422, busy, "retry-after" => "1") }

    tf.apply cluster + pool("a") + pool("b")
    creates = ledger.entries.select { it.to_s == "POST kubernetes-cluster/@k8s/nodepool" }
    expect(creates.map(&:status)).to eq [422, 200, 200]
    expect(pools).to eq [["a", 2, "v1.36"], ["b", 2, "v1.36"]]
    expect(tf.plan).to be_empty
  end

  it "adopts a nodepool by name when a proxy answers 502 after the API created it" do
    tf.apply cluster
    at(:response, "POST kubernetes-cluster/@k8s/nodepool") { it.answer(502) }

    expect(tf.apply(cluster + pool("a")).requests).to eq [
      "GET kubernetes-cluster/@k8s", "POST kubernetes-cluster/@k8s/nodepool",
      "GET kubernetes-cluster/@k8s/nodepool/a", "GET kubernetes-cluster/@k8s/nodepool/@a",
    ]
    expect(pools).to eq [["a", 2, "v1.36"]]
    expect(tf.state("ubicloud_kubernetes_cluster_nodepool.a")["id"]).to eq kc.nodepools.first.ubid
    expect(tf.plan).to be_empty
  end
end
