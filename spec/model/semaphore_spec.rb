# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Semaphore do
  let(:st) { Strand.create(prog: "Test", label: "start") }

  it ".incr returns nil and does not add Semaphore if there is no related strand" do
    expect(described_class.all).to be_empty
    expect(described_class.incr(Vm.generate_uuid, "foo")).to be_nil
    expect(described_class.all).to be_empty
  end

  it ".incr raises if invalid name is given" do
    expect { described_class.incr(st.id, nil) }.to raise_error(Sequel::ValidationFailed)
  end

  it ".incr raises nil it strand is deleted between the update and semaphore create" do
    expect(described_class).to receive(:create).and_wrap_original do |original_method, arg|
      st.destroy
      original_method.call(arg)
    end
    expect(described_class.incr(st.id, "foo")).to be_nil
  end
end
