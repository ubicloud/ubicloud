# frozen_string_literal: true

require_relative "spec_helper"

# rubocop:disable RSpec/DescribeClass
# refresh_frame is a spec helper defined in an anonymous module.
RSpec.describe "spec_helper#refresh_frame" do
  # rubocop:enable RSpec/DescribeClass
  let(:strand) { Strand.create(prog: "Test", label: "start") }
  let(:prog) { Prog::Test.new(strand) }

  it "raises when parent_values is passed on a 1-frame stack" do
    expect(strand.stack.length).to eq(1)
    expect {
      refresh_frame(prog, parent_values: {"x" => 1})
    }.to raise_error(RuntimeError, /parent_values requires a 2\+ frame stack \(has 1\)/)
  end

  it "does not issue a DB write on a bare call" do
    expect(prog.strand).not_to receive(:save_changes)
    expect(prog.strand).not_to receive(:modified!)
    refresh_frame(prog)
  end

  it "clears prog @frame on a bare call" do
    prog.instance_variable_set(:@frame, {"cached" => true})
    refresh_frame(prog)
    expect(prog.instance_variable_get(:@frame)).to be_nil
  end

  it "still issues exactly one save_changes when new_values is given" do
    expect(prog.strand).to receive(:save_changes).once.and_call_original
    refresh_frame(prog, new_values: {"a" => 1})
    expect(strand.reload.stack.first["a"]).to eq(1)
  end

  it "raises when both new_frame and new_values are passed" do
    expect {
      refresh_frame(prog, new_frame: {"x" => 1}, new_values: {"y" => 2})
    }.to raise_error(RuntimeError, "cannot pass both new_frame and new_values")
  end

  it "writes both frames and issues exactly one save_changes on a 2-frame stack" do
    strand.stack = [{}, {}]
    strand.save_changes
    expect(prog.strand.stack.length).to eq(2)
    expect(prog.strand).to receive(:save_changes).once.and_call_original
    refresh_frame(prog, new_values: {"child" => "c"}, parent_values: {"parent" => "p"})
    strand.reload
    expect(strand.stack.first["child"]).to eq("c")
    expect(strand.stack.last["parent"]).to eq("p")
  end

  it "replaces the first frame when new_frame is given" do
    strand.stack = [{"old" => true}]
    strand.save_changes
    refresh_frame(prog, new_frame: {"fresh" => true})
    expect(strand.reload.stack.first).to eq({"fresh" => true})
  end
end
