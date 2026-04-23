# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Config do
  it "can have float config" do
    described_class.class_eval do
      override :test_float, 0.5, float
    end

    expect(described_class.test_float).to eq(0.5)
  end

  it "can have nil array config" do
    described_class.class_eval do
      override :test_array, nil, array
    end

    expect(described_class.test_array).to be_nil
  end

  it "uuid accepts valid uuid" do
    id = SecureRandom.uuid
    described_class.class_eval do
      override :test_valid_uuid, id, uuid
    end
    expect(described_class.test_valid_uuid).to eq(id)
  end

  it "uuid accepts nil" do
    described_class.class_eval do
      optional :test_nil_uuid, uuid
    end
    expect(described_class.test_nil_uuid).to be_nil
  end

  it "uuid rejects invalid uuid" do
    expect {
      described_class.class_eval do
        override :test_valid_uuid, "invalid", uuid
      end
    }.to raise_error("invalid uuid invalid")
  end

  it "has correct defaults for Leaseweb config entries" do
    expect(described_class.leaseweb_connection_string).to eq("https://api.leaseweb.com")
    expect(described_class.leaseweb_api_key).to be_nil
    expect(described_class.leaseweb_user).to be_nil
    expect(described_class.leaseweb_password).to be_nil
  end

  it "ignores LoadError when .env.rb is not present" do
    main = TOPLEVEL_BINDING.eval("self")
    expect(main).to receive(:require_relative).with("lib/casting_config_helpers")
    expect(main).to receive(:require_relative).with(".env").and_raise(LoadError)
    expect(ENV).to receive(:[]) do |k|
      throw :skip, k
    end
    value = catch(:skip) do
      expect { load(File.expand_path("../config.rb", __dir__)) }.not_to raise_error
    end
    expect(value).to eq "SYNC"
  end
end
