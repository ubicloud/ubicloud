# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "terraform: request gate interleavings" do
  it "sequences a create/create race so terraform deterministically loses" do
    runner = tf_runner("firewall_basic.tf.erb", name: "tf-race")
    gate = tf_gate(method: "POST", path: %r{/firewall/tf-race\z})

    # terraform blocks on the held HTTP request, so it runs on a
    # background thread; the spec thread stays in control. The
    # non-raising runner makes the expected failure data, not an
    # exception smuggled through Thread#value.
    apply = tf_async { runner.run("apply", "-auto-approve", "-no-color") }

    gate.wait_for_arrival

    # Barrier is *before* the handler: the request is in flight but the
    # DB is untouched. The DB is the only clock, and it hasn't ticked.
    expect(Firewall.where(project_id: tf_project.id).count).to eq 0

    # Mutate mid-flight: an interloper takes the name first. Names are
    # unique per (project, location), so terraform now loses the race —
    # deterministically, because the gate sequenced it.
    interloper = Firewall.create(
      name: "tf-race",
      location_id: Location::HETZNER_FSN1_ID,
      project_id: tf_project.id,
    )

    gate.release
    result = apply.value

    expect(result.status.success?).to be false
    expect(result.output).to include "already taken"

    # Only the interloper exists, and the failed create left no phantom
    # resource in terraform state.
    expect(Firewall.where(project_id: tf_project.id).select_map(:id)).to eq [interloper.id]
    expect(runner.state_resources).to be_nil
  end

  it "reconciles an ambiguous create: a bodyless 200 adopts the row by name" do
    runner = tf_runner("firewall_basic.tf.erb", name: "tf-ambig")
    gate = tf_gate(method: "POST", path: %r{/firewall/tf-ambig\z})

    apply = tf_async { runner.run("apply", "-auto-approve", "-no-color") }
    gate.wait_for_arrival

    # The claim is in flight; nothing committed yet.
    expect(Firewall.where(project_id: tf_project.id).count).to eq 0

    # Deliver the create but strip the body: the server committed, the
    # client cannot know. The name is the claim, so the provider must
    # reconcile by it rather than fail and orphan the row.
    gate.release(corrupt: :empty_body)
    result = apply.value

    expect(result.status.success?).to be true
    fw = Firewall.first(project_id: tf_project.id, name: "tf-ambig")
    expect(fw).not_to be_nil
    expect(runner.state_resources.length).to eq 1
  end
end
