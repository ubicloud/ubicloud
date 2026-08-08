# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LocationNexus do
  subject(:nx) { described_class.new(Strand.create_with_id(location, prog: "LocationNexus", label: "wait")) }

  let(:project) { Project.create(name: "test-project") }
  let(:location) {
    loc = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "aws-us-west-2", ui_name: "aws-us-west-2", visible: true)
    LocationCredentialAws.create_with_id(loc.id, access_key: "k", secret_key: "s")
    LocationAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
    loc
  }
  let(:pg) { create_postgres_resource(project:, location_id: location.id) }
  let(:server) { create_postgres_server(resource: pg) }

  def stub_events(events)
    expect(nx.location).to receive(:scheduled_maintenance_events).and_return(events)
  end

  describe "#wait" do
    it "recycles the server and bypasses the maintenance window when the event is within 24h" do
      stub_events({server.vm_id => Time.now + 10 * 3600})
      expect { nx.wait }.to nap(3600)
      expect(server.reload.recycle_set?).to be true
      expect(pg.reload.bypass_maintenance_window_set?).to be true
    end

    it "recycles but keeps the window when the event is 24h to 48h out" do
      stub_events({server.vm_id => Time.now + 36 * 3600})
      expect { nx.wait }.to nap(3600)
      expect(server.reload.recycle_set?).to be true
      expect(pg.reload.bypass_maintenance_window_set?).to be false
    end

    it "ignores events beyond the 48h lead" do
      stub_events({server.vm_id => Time.now + 72 * 3600})
      expect { nx.wait }.to nap(3600)
      expect(server.reload.recycle_set?).to be false
      expect(pg.reload.bypass_maintenance_window_set?).to be false
    end

    it "does not re-increment recycle when already set" do
      server.incr_recycle
      stub_events({server.vm_id => Time.now + 10 * 3600})
      expect { nx.wait }.to nap(3600)
      expect(Semaphore.where(strand_id: server.id, name: "recycle").count).to eq(1)
    end

    it "does not re-increment the window bypass when already set" do
      server
      pg.incr_bypass_maintenance_window
      stub_events({server.vm_id => Time.now + 10 * 3600})
      expect { nx.wait }.to nap(3600)
      expect(Semaphore.where(strand_id: pg.id, name: "bypass_maintenance_window").count).to eq(1)
    end

    it "ignores vms without a postgres server" do
      vm = create_vm(location_id: location.id)
      stub_events({vm.id => Time.now + 3600})
      expect { nx.wait }.to nap(3600)
      expect(Semaphore.where(name: "recycle").count).to eq(0)
    end

    it "naps for 24h if AWS returns UnauthorizedOperation" do
      expect(nx.location).to receive(:scheduled_maintenance_events).and_raise(Aws::EC2::Errors::UnauthorizedOperation.new(nil, "test"))
      expect(Prog::PageNexus).to receive(:assemble).with("aws_unauthorized_operation", ["AwsUnauthorizedOperation", location.ubid], location.ubid, severity: "warning", extra_data: {project: location.project.ubid})
      expect { nx.wait }.to nap(3600 * 24 * 31)
    end

    it "skips provider ip range refresh when metering is disabled" do
      stub_events({})
      expect(nx).not_to receive(:refresh_provider_ip_ranges)
      expect { nx.wait }.to nap(3600)
    end

    it "refreshes provider ip ranges when metering is enabled and rows are stale" do
      allow(Config).to receive(:pg_network_metering_enabled).and_return(true)
      stub_events({})
      expect(nx).to receive(:refresh_provider_ip_ranges)
      expect { nx.wait }.to nap(3600)
    end

    it "skips refresh when metering enabled but rows are fresh" do
      allow(Config).to receive(:pg_network_metering_enabled).and_return(true)
      ProviderIpRange.create(location_id: location.id, bucket_id: "intra_region", ip_version: 4, cidrs: Sequel.pg_array([], :cidr))
      stub_events({})
      expect(nx).not_to receive(:refresh_provider_ip_ranges)
      expect { nx.wait }.to nap(3600)
    end
  end

  describe "#refresh_provider_ip_ranges" do
    let(:aws_partition) do
      {
        "v4" => {"intra_region" => ["3.248.0.0/13"], "inter_region_t1" => ["13.124.0.0/16"], "excluded_svc" => ["52.218.0.0/17"]},
        "v6" => {"intra_region" => [], "inter_region_t1" => [], "excluded_svc" => []},
      }
    end
    let(:feeder) { instance_double(NetworkMetering::Provider::Aws, fetch_ranges: {}) }

    before { allow(NetworkMetering::Provider::Aws).to receive(:new).and_return(feeder) }

    it "upserts provider_ip_range rows from the AWS feeder" do
      expect(feeder).to receive(:classify_ranges).with({}, location.metering_region, {}).and_return(aws_partition)
      nx.refresh_provider_ip_ranges
      rows = ProviderIpRange.where(location_id: location.id).all.map { |r| [r.bucket_id, r.ip_version, r.cidrs.map(&:to_s)] }
      expect(rows).to contain_exactly(
        ["intra_region", 4, ["3.248.0.0/13"]],
        ["inter_region_t1", 4, ["13.124.0.0/16"]],
        ["excluded_svc", 4, ["52.218.0.0/17"]],
        ["intra_region", 6, []],
        ["inter_region_t1", 6, []],
        ["excluded_svc", 6, []],
      )
    end

    it "updates in place on subsequent refresh" do
      expect(feeder).to receive(:classify_ranges).and_return(aws_partition, aws_partition.merge("v4" => aws_partition["v4"].merge("intra_region" => ["3.248.0.0/13", "34.240.0.0/13"])))
      nx.refresh_provider_ip_ranges
      nx.refresh_provider_ip_ranges
      row = ProviderIpRange.first(location_id: location.id, bucket_id: "intra_region", ip_version: 4)
      expect(row.cidrs.map(&:to_s)).to contain_exactly("3.248.0.0/13", "34.240.0.0/13")
    end

    it "clears the refresh semaphore when it was set" do
      expect(feeder).to receive(:classify_ranges).and_return(aws_partition)
      nx.incr_refresh_provider_ip_ranges
      nx.refresh_provider_ip_ranges
      expect(location.reload.refresh_provider_ip_ranges_set?).to be false
    end

    it "logs and returns without updating rows when the feed fetch fails" do
      err = Excon::Error::Socket.new(RuntimeError.new("boom"))
      expect(feeder).to receive(:fetch_ranges).and_raise(err)
      expect(feeder).not_to receive(:classify_ranges)
      expect(Clog).to receive(:emit).with("failed to fetch provider ip ranges", anything)
      nx.incr_refresh_provider_ip_ranges
      nx.refresh_provider_ip_ranges
      expect(ProviderIpRange.where(location_id: location.id).count).to eq(0)
      expect(location.reload.refresh_provider_ip_ranges_set?).to be true
    end

    it "logs on malformed JSON from the feed and keeps semaphore set" do
      expect(feeder).to receive(:fetch_ranges).and_raise(JSON::ParserError.new("bad"))
      expect(Clog).to receive(:emit).with("failed to fetch provider ip ranges", anything)
      nx.incr_refresh_provider_ip_ranges
      nx.refresh_provider_ip_ranges
      expect(location.reload.refresh_provider_ip_ranges_set?).to be true
    end
  end

  describe "#before_run" do
    it "hops to destroy when the destroy semaphore is set" do
      nx
      location.incr_destroy
      expect { described_class.new(nx.strand).before_run }.to hop("destroy")
    end
  end

  describe "#destroy" do
    it "destroys the location with its credential, then exits" do
      expect { nx.destroy }.to exit({"msg" => "location destroyed"})
      expect(Location[location.id]).to be_nil
      expect(LocationCredentialAws[location.id]).to be_nil
    end
  end
end
