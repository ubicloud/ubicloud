# frozen_string_literal: true

require "base64"
RSpec.describe Minio::Crypto do
  describe "encrypt" do
    it "can encrypt a payload" do
      expect(SecureRandom).to receive(:random_bytes).with(8).and_return("noncenon")
      expect(SecureRandom).to receive(:random_bytes).with(32).and_return("saltsaltsaltsaltsaltsaltsaltsalt")
      payload = "test"
      password = "password"
      expect(Base64.encode64(described_class.new.encrypt(payload, password))).to eq("c2FsdHNhbHRzYWx0c2FsdHNhbHRzYWx0c2FsdHNhbHQAbm9uY2Vub24Q8NnE\ng9RvKzKmwFclyEJrPFFKJA==\n")
    end
  end

  describe "decrypt" do
    it "can decrypt a payload" do
      payload = "c2FsdHNhbHRzYWx0c2FsdHNhbHRzYWx0c2FsdHNhbHQAbm9uY2Vub24Q8NnE\ng9RvKzKmwFclyEJrPFFKJA==\n"
      password = "password"
      expect(described_class.new.decrypt(Base64.decode64(payload), password)).to eq("test")
    end

    it "fails if cipher is not known" do
      payload = "111111111111111111111111111111111111111111111111111111111111\ng9RvKzKmwFclyEJrPFFKJA==\n"
      password = "password"
      expect {
        described_class.new.decrypt(Base64.decode64(payload), password)
      }.to raise_error RuntimeError, "Unsupported cipher ID: 117"
    end
  end
end
