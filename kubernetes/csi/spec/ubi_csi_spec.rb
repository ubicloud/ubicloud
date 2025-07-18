# frozen_string_literal: true

require 'spec_helper'

RSpec.describe UbiCSI do
  describe "VERSION" do
    it "has a version number" do
      expect(UbiCSI::VERSION).not_to be nil
      expect(UbiCSI::VERSION).to eq("0.1.0")
    end
  end

  describe "module loading" do
    it "loads without errors" do
      expect { require_relative '../lib/ubi_csi' }.not_to raise_error
    end

    it "defines the UbiCSI module" do
      expect(defined?(UbiCSI)).to eq("constant")
      expect(UbiCSI).to be_a(Module)
    end
  end
end

