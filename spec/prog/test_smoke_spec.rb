# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Prog::Test do
  let(:strand) { Strand.create(prog: "Test", label: "smoke_test_1") }

  let(:prog) { described_class.new(strand) }

  it "smoke_test_1 naps, then hops to smoke_test_0" do
    expect(prog).to receive(:rand).and_return(2).thrice
    expect(prog).to receive(:print).with(1)
    expect { prog.smoke_test_1 }.to nap(2)
    expect { prog.smoke_test_1 }.to hop("smoke_test_0")
    expect { prog.smoke_test_0 }.to nap(1000)
  end
end
