# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli ss" do
  it "creates a secret store, with and without a description" do
    expect(SecretStore.count).to eq 0
    body = cli(%w[ss my-store create])
    store = SecretStore.first
    expect(store.name).to eq "my-store"
    expect(store.description).to be_nil
    expect(body).to eq "Secret store created with id: #{store.ubid}\n"

    cli(%w[ss other create -d] << "prod secrets")
    expect(SecretStore[name: "other"].description).to eq "prod secrets"
  end

  it "lists secret stores, with and without headers" do
    SecretStore.create(project_id: @project.id, name: "store-a")
    SecretStore.create(project_id: @project.id, name: "store-b")

    body = cli(%w[ss list])
    expect(body).to include("name", "store-a", "store-b")

    body = cli(%w[ss list -N])
    expect(body).to include("store-a", "store-b")
  end

  it "shows details including keys" do
    store = SecretStore.create(project_id: @project.id, name: "my-store", description: "prod")
    store.add_secret(key: "k1", value: "v1")
    store.add_secret(key: "k2", value: "v2")

    body = cli(%w[ss my-store show])
    expect(body).to eq <<~OUT
      id: #{store.ubid}
      name: my-store
      description: prod
      keys:
        k1
        k2
    OUT
  end

  it "renames a secret store" do
    store = SecretStore.create(project_id: @project.id, name: "my-store")
    body = cli(%w[ss my-store rename renamed])
    expect(store.reload.name).to eq "renamed"
    expect(body).to eq "Secret store with id #{store.ubid} renamed to renamed\n"
  end

  it "sets, gets and unsets secrets" do
    store = SecretStore.create(project_id: @project.id, name: "my-store")

    body = cli(%w[ss my-store set db-pass] << "p@ss")
    expect(body).to eq "Secret db-pass set in secret store with id #{store.ubid}\n"
    expect(store.secrets_dataset.first(key: "db-pass").value).to eq "p@ss"

    expect(cli(%w[ss my-store get db-pass])).to eq "p@ss\n"

    # setting again updates in place
    cli(%w[ss my-store set db-pass] << "rotated")
    expect(cli(%w[ss my-store get db-pass])).to eq "rotated\n"
    expect(store.secrets_dataset.where(key: "db-pass").count).to eq 1

    body = cli(%w[ss my-store unset db-pass])
    expect(body).to eq "Secret db-pass deleted from secret store with id #{store.ubid}\n"
    expect(store.secrets_dataset.first(key: "db-pass")).to be_nil
  end

  describe "destroy" do
    before do
      @store = SecretStore.create(project_id: @project.id, name: "my-store")
    end

    it "destroys directly with -f" do
      expect(cli(%w[ss my-store destroy -f])).to eq "Secret store, and all secrets it contains, have been destroyed\n"
      expect(@store).not_to be_exist
    end

    it "asks for confirmation without -f" do
      expect(cli(%w[ss my-store destroy], confirm_prompt: "Confirmation")).to eq <<~END
        Destroying this secret store is not recoverable.
        Enter the following to confirm destruction of the secret store: my-store
      END
      expect(@store).to be_exist
    end

    it "destroys on correct confirmation" do
      expect(cli(%w[--confirm my-store ss my-store destroy])).to eq "Secret store, and all secrets it contains, have been destroyed\n"
      expect(@store).not_to be_exist
    end

    it "fails on incorrect confirmation" do
      expect(cli(%w[--confirm wrong ss my-store destroy], status: 400)).to eq "! Confirmation of secret store name not successful.\n"
      expect(@store).to be_exist
    end
  end

  it "rejects references containing a slash" do
    expect(cli(%w[ss a/b show], status: 400)).to include('Invalid secret store reference ("a/b"), should not include /')
  end
end
