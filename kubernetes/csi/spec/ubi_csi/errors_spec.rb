# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/ubi_csi/errors'

RSpec.describe "Error Classes" do
  describe ObjectNotFoundError do
    it "is a StandardError" do
      expect(ObjectNotFoundError.new).to be_a(StandardError)
    end

    it "can be raised with a message" do
      expect { raise ObjectNotFoundError, "test message" }.to raise_error(ObjectNotFoundError, "test message")
    end

    it "can be raised without a message" do
      expect { raise ObjectNotFoundError }.to raise_error(ObjectNotFoundError)
    end
  end

  describe CopyNotFinishedError do
    it "is a StandardError" do
      expect(CopyNotFinishedError.new).to be_a(StandardError)
    end

    it "can be raised with a message" do
      expect { raise CopyNotFinishedError, "copy not finished" }.to raise_error(CopyNotFinishedError, "copy not finished")
    end

    it "can be raised without a message" do
      expect { raise CopyNotFinishedError }.to raise_error(CopyNotFinishedError)
    end
  end
end

