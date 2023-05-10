# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupMinioNode do
  let(:cluster) { MinioCluster.create(name: "test", capacity: 100) }
  let(:pool) { MinioPool.create(cluster_id: cluster.id, capacity: 100, node_count: 1) }
  let(:minio_node) { MinioNode.create(pool_id: pool.id) }
  let(:st) { Strand.create(prog: "Prog::SetupMinioNode", label: "start", stack: [{subject_id: minio_node.id}]) { _1.id = minio_node.id } }
  let(:prog) { described_class.new(st) }

  it "generates the two child progs" do
    expect(st).to receive(:load).and_return(prog)
    st.run
    expect(st.children.count).to eq 2
    expect(st.children.map(&:prog).sort).to eq ["ConfigureMinio", "PrepMinio"]
  end

  it "if there is no children then finished" do
    expect(st).to receive(:load).and_return(prog)
    st.update(label: "wait_prep")
    st.run
    expect(st.label).to eq "setup_users"
  end

  it "waits if there is at least one prog to finish" do
    expect(st).to receive(:load).and_return(prog).twice
    st.run
    expect(st.children.count).to eq 2
    # we need to mock the children strands so that it's not actually running
    # and we make sure to stick to the same state
    expect(st).to receive(:children).and_return([instance_double(Strand, run: nil)]).twice
    expect(st.label).to eq "wait_prep"

    st.run
    expect(st.label).to eq "wait_prep"
  end

  it "sets up users" do
    expect(st).to receive(:load).and_return(prog)
    st.update(label: "setup_users")
    expect { st.run }.to change(st, :label).from("setup_users").to("wait_setup_users")
    expect(st.retval).to be_nil
    expect(st.exitval).to be_nil
    expect(st.children.count).to eq 1
    expect(st.children.first.prog).to eq "SetupMinioUsers"
  end

  it "starts the minio service" do
    expect(st).to receive(:load).and_return(prog)
    st.update(label: "start_node")
    expect(minio_node.sshable).to receive(:cmd).with("sudo systemctl start minio").and_return("")
    st.run
    expect(st.exitval).to eq "started minio node"
  end
end
