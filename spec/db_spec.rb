# frozen_string_literal: true

RSpec.describe "Database" do
  it "has no unexpectedly collated columns" do
    collated_columns = DB[:pg_class]
      .join(:pg_namespace, oid: :relnamespace) { |j| Sequel.qualify(j, :nspname) !~ ["pg_catalog", "information_schema"] }
      .join(:pg_attribute, attrelid: Sequel[:pg_class][:oid])
      .join(:pg_collation, oid: :attcollation) { |j| Sequel.qualify(j, :collcollate) !~ "C" }
      .select_map(Sequel.join(%i[nspname relname attname].map { Sequel.function(:quote_ident, it) }, ".").as(:name))

    expect(collated_columns).to eq []
  end

  describe "audit_log table" do
    def insert_row(at)
      DB[:audit_log].returning(:ubid_type).insert(at:, ubid_type: "vm", action: "create", project_id: Project.generate_uuid, subject_id: Account.generate_uuid, object_ids: Sequel.pg_array([], :uuid))
    end

    it "inserts row for current date without error" do
      expect(insert_row(Date.today)).to eq [{ubid_type: "vm"}]
    end

    it "needs new partitions (action required)" do
      # if this test starts to fail, it's time to create new partitions for table audit_log. if this is ignored,
      # DB[:audit_log].insert will start to fail in 45 days or less.
      # Add a warning 60 days out, so the issue can be fixed before the warning turns into an test failure.

      begin
        DB.transaction(savepoint: true) do
          insert_row(Time.now + 60 * 60 * 24 * 60)
        end
      rescue Sequel::ConstraintViolation
        warn "\n\nNEED TO CREATE MORE audit_log PARTITIONS!\n\n\n"
      end

      expect(insert_row(Time.now + 60 * 60 * 24 * 45)).to eq [{ubid_type: "vm"}]
    end

    it "fails to create in the past" do
      expect { insert_row(Date.new(2025, 4)) }.to raise_error(Sequel::ConstraintViolation)
    end

    it "fails to create in the distant future" do
      expect { insert_row(Time.now + 60 * 60 * 24 * 365 * 10) }.to raise_error(Sequel::ConstraintViolation)
    end
  end

  describe "NetAddr extensions" do
    it "converts inet/cidr columns to NetAddr objects" do
      expect(DB.get(Sequel.cast("127.0.0.1", :inet))).to be_a NetAddr::IPv4
      expect(DB.get(Sequel.cast("127.0.0.0/8", :cidr))).to be_a NetAddr::IPv4Net
      expect(DB.get(Sequel.cast("::1", :inet))).to be_a NetAddr::IPv6
      expect(DB.get(Sequel.cast("fe80::/16", :cidr))).to be_a NetAddr::IPv6Net
    end

    it "converts inet/cidr array columns to arrays of NetAddr objects" do
      expect(DB.get(Sequel.pg_array([Sequel.cast("127.0.0.1", :inet)])).first).to be_a NetAddr::IPv4
      expect(DB.get(Sequel.pg_array([Sequel.cast("127.0.0.0/8", :cidr)])).first).to be_a NetAddr::IPv4Net
      expect(DB.get(Sequel.pg_array([Sequel.cast("::1", :inet)])).first).to be_a NetAddr::IPv6
      expect(DB.get(Sequel.pg_array([Sequel.cast("fe80::/16", :cidr)])).first).to be_a NetAddr::IPv6Net
    end

    it "supports NetAddr objects in dataset filters" do
      expect(DB.get(NetAddr::IPv4.parse("127.0.0.1"))).to be_a NetAddr::IPv4
      expect(DB.get(NetAddr::IPv4Net.parse("127.0.0.0/8"))).to be_a NetAddr::IPv4Net
      expect(DB.get(NetAddr::IPv6.parse("::1"))).to be_a NetAddr::IPv6
      expect(DB.get(NetAddr::IPv6Net.parse("fe80::/16"))).to be_a NetAddr::IPv6Net
    end

    it "typecasts cidr columns to NetAddr objects" do
      address = Address.new(routed_to_host_id: "46683a25-acb1-4371-afe9-d39f303e44b4")

      address.cidr = "127.0.0.0/8"
      expect(address.cidr).to be_a NetAddr::IPv4Net
      address.cidr = NetAddr::IPv4.parse("127.0.0.1")
      expect(address.cidr).to be_a NetAddr::IPv4Net
      address.cidr = NetAddr::IPv4Net.parse("127.0.0.0/30")
      expect(address.cidr).to be_a NetAddr::IPv4Net
      expect(address.valid?).to be true

      address.cidr = "fe80::/8"
      expect(address.cidr).to be_a NetAddr::IPv6Net
      address.cidr = NetAddr::IPv6.parse("::1")
      expect(address.cidr).to be_a NetAddr::IPv6Net
      expect(address.cidr.to_s).to eq "::1/128"
      address.cidr = NetAddr::IPv6Net.parse("fe80::/16")
      expect(address.cidr).to be_a NetAddr::IPv6Net
      expect(address.valid?).to be true

      address.cidr = "10"
      expect(address.cidr).to eq "10"
      expect(address.valid?).to be false

      address.cidr = 10
      expect(address.cidr).to eq 10
      expect(address.valid?).to be false
    end

    it "typecasts inet columns to NetAddr objects" do
      host = Prog::Vm::HostNexus.assemble("127.0.0.1").subject

      host.ip6 = "127.0.0.1"
      expect(host.ip6).to be_a NetAddr::IPv4
      host.ip6 = NetAddr::IPv4.parse("127.0.0.1")
      expect(host.ip6).to be_a NetAddr::IPv4
      expect(host.valid?).to be true

      host.ip6 = "::1"
      expect(host.ip6).to be_a NetAddr::IPv6
      host.ip6 = NetAddr::IPv6.parse("::1")
      expect(host.ip6).to be_a NetAddr::IPv6
      expect(host.valid?).to be true

      host.ip6 = "127.0.0.0/8"
      expect(host.ip6).to eq "127.0.0.0/8"
      expect(host.valid?).to be false

      host.ip6 = 10
      expect(host.ip6).to eq 10
      expect(host.valid?).to be false
    end
  end
end
