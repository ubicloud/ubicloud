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
      expect(server.recycle_set?(cached: false)).to be true
      expect(pg.bypass_maintenance_window_set?(cached: false)).to be true
    end

    it "recycles but keeps the window when the event is 24h to 48h out" do
      stub_events({server.vm_id => Time.now + 36 * 3600})
      expect { nx.wait }.to nap(3600)
      expect(server.recycle_set?(cached: false)).to be true
      expect(pg.bypass_maintenance_window_set?(cached: false)).to be false
    end

    it "ignores events beyond the 48h lead" do
      stub_events({server.vm_id => Time.now + 72 * 3600})
      expect { nx.wait }.to nap(3600)
      expect(server.recycle_set?(cached: false)).to be false
      expect(pg.bypass_maintenance_window_set?(cached: false)).to be false
    end

    it "does not recycle a server of an ephemeral database, which cannot fail over" do
      pg.update(ephemeral: true)
      stub_events({server.vm_id => Time.now + 10 * 3600})
      expect { nx.wait }.to nap(3600)
      expect(server.recycle_set?(cached: false)).to be false
      expect(pg.bypass_maintenance_window_set?(cached: false)).to be false
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

    context "when metering is enabled" do
      before { allow(Config).to receive(:pg_network_metering_enabled).and_return(true) }

      it "refreshes provider ip ranges when rows are stale" do
        stub_events({})
        expect(nx).to receive(:refresh_provider_ip_ranges)
        expect { nx.wait }.to nap(3600)
      end

      it "skips refresh when rows are fresh" do
        ProviderIpRange.create(location_id: location.id, bucket_id: "intra_region", ip_version: 4, cidrs: Sequel.pg_array([], :cidr))
        stub_events({})
        expect(nx).not_to receive(:refresh_provider_ip_ranges)
        expect { nx.wait }.to nap(3600)
      end

      it "skips refresh on metal locations" do
        metal_loc = Location.create(name: "hetzner-fsn2", provider: "hetzner", project_id: project.id, display_name: "hetzner", ui_name: "hetzner", visible: true)
        metal_nx = described_class.new(Strand.create_with_id(metal_loc, prog: "LocationNexus", label: "wait"))
        expect(metal_nx.location).to receive(:scheduled_maintenance_events).and_return({})
        expect(metal_nx).not_to receive(:refresh_provider_ip_ranges)
        expect { metal_nx.wait }.to nap(3600)
      end

      it "refreshes provider ip ranges on GCP locations" do
        gcp_loc = Location.create(name: "gcp-us-east4", provider: "gcp", project_id: project.id, display_name: "gcp", ui_name: "gcp", visible: true)
        gcp_nx = described_class.new(Strand.create_with_id(gcp_loc, prog: "LocationNexus", label: "wait"))
        expect(gcp_nx.location).to receive(:scheduled_maintenance_events).and_return({})
        expect(gcp_nx).to receive(:refresh_provider_ip_ranges)
        expect { gcp_nx.wait }.to nap(3600)
      end

      it "refreshes provider ip ranges when the semaphore is set even if rows are fresh" do
        ProviderIpRange.create(location_id: location.id, bucket_id: "intra_region", ip_version: 4, cidrs: Sequel.pg_array([], :cidr))
        nx.incr_refresh_provider_ip_ranges
        stub_events({})
        expect(nx).to receive(:refresh_provider_ip_ranges)
        expect { nx.wait }.to nap(3600)
      end
    end
  end

  describe "#refresh_provider_ip_ranges" do
    let(:aws_ranges_v1) do
      {
        "prefixes" => [
          {"ip_prefix" => "3.248.0.0/13", "region" => "us-west-2", "service" => "EC2"},
          {"ip_prefix" => "52.218.0.0/17", "region" => "us-west-2", "service" => "S3"},
          {"ip_prefix" => "13.124.0.0/16", "region" => "ap-northeast-2", "service" => "EC2"},
        ],
        "ipv6_prefixes" => [],
      }
    end
    let(:aws_ranges_v2) do
      {
        "prefixes" => aws_ranges_v1["prefixes"] + [{"ip_prefix" => "34.240.0.0/13", "region" => "us-west-2", "service" => "EC2"}],
        "ipv6_prefixes" => [],
      }
    end

    before do
      stub_request(:get, NetworkMetering::Provider::Aws::IP_RANGES_URL).to_return(status: 200, body: aws_ranges_v1.to_json)
    end

    it "creates provider_ip_range rows and spawns a rollout when data is new" do
      pg = create_postgres_resource(project:, location_id: location.id)
      server = create_postgres_server(resource: pg)
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
      rollouts = Strand.where(prog: "RolloutSemaphore").all
      expect(rollouts.size).to eq(1)
      frame = rollouts.first.stack.first
      expect(frame["semaphore"]).to eq("configure_metrics")
      expect(frame["remaining"]).to include(server.id)
      expect(frame["auto_exit"]).to be true
    end

    it "updates rows and spawns a new rollout on subsequent refresh with drift" do
      pg = create_postgres_resource(project:, location_id: location.id)
      create_postgres_server(resource: pg)
      nx.refresh_provider_ip_ranges
      first_rollout_id = Strand.where(prog: "RolloutSemaphore").get(:id)
      stub_request(:get, NetworkMetering::Provider::Aws::IP_RANGES_URL).to_return(status: 200, body: aws_ranges_v2.to_json)
      nx.refresh_provider_ip_ranges
      row = ProviderIpRange.first(location_id: location.id, bucket_id: "intra_region", ip_version: 4)
      expect(row.cidrs.map(&:to_s)).to contain_exactly("3.248.0.0/13", "34.240.0.0/13")
      rollout_ids = Strand.where(prog: "RolloutSemaphore").select_map(:id)
      expect(rollout_ids.size).to eq(2)
      expect(rollout_ids).to include(first_rollout_id)
    end

    it "only bumps refreshed_at and skips rollout when cidrs are unchanged" do
      pg = create_postgres_resource(project:, location_id: location.id)
      create_postgres_server(resource: pg)
      nx.refresh_provider_ip_ranges
      first_rollout_count = Strand.where(prog: "RolloutSemaphore").count
      before = ProviderIpRange.first(location_id: location.id, bucket_id: "intra_region", ip_version: 4).refreshed_at
      sleep 0.01
      nx.refresh_provider_ip_ranges
      row = ProviderIpRange.first(location_id: location.id, bucket_id: "intra_region", ip_version: 4)
      expect(row.refreshed_at).to be > before
      expect(Strand.where(prog: "RolloutSemaphore").count).to eq(first_rollout_count)
    end

    it "clears the refresh semaphore when it was set" do
      nx.incr_refresh_provider_ip_ranges
      nx.refresh_provider_ip_ranges
      expect(location.reload.refresh_provider_ip_ranges_set?).to be false
    end

    it "logs and returns without updating rows when the feed fetch fails" do
      stub_request(:get, NetworkMetering::Provider::Aws::IP_RANGES_URL).to_raise(Excon::Error::Socket.new(RuntimeError.new("boom")))
      expect(Clog).to receive(:emit).with("failed to fetch provider ip ranges", anything)
      nx.incr_refresh_provider_ip_ranges
      nx.refresh_provider_ip_ranges
      expect(ProviderIpRange.where(location_id: location.id).count).to eq(0)
      expect(location.reload.refresh_provider_ip_ranges_set?).to be true
    end

    it "logs on malformed JSON from the feed and keeps semaphore set" do
      stub_request(:get, NetworkMetering::Provider::Aws::IP_RANGES_URL).to_return(status: 200, body: "not-json")
      expect(Clog).to receive(:emit).with("failed to fetch provider ip ranges", anything)
      nx.incr_refresh_provider_ip_ranges
      nx.refresh_provider_ip_ranges
      expect(location.reload.refresh_provider_ip_ranges_set?).to be true
    end

    it "dispatches to the GCP feeder when the location is GCP" do
      gcp_loc = Location.create(name: "gcp-us-east4", provider: "gcp", project_id: project.id, display_name: "gcp", ui_name: "gcp", visible: true)
      gcp_nx = described_class.new(Strand.create_with_id(gcp_loc, prog: "LocationNexus", label: "wait"))
      stub_request(:get, NetworkMetering::Provider::Gcp::CLOUD_RANGES_URL).to_return(status: 200, body: {"prefixes" => [{"ipv4Prefix" => "34.1.0.0/16", "scope" => "us-east4"}]}.to_json)
      stub_request(:get, NetworkMetering::Provider::Gcp::GOOG_RANGES_URL).to_return(status: 200, body: {"prefixes" => []}.to_json)
      gcp_nx.refresh_provider_ip_ranges
      row = ProviderIpRange.first(location_id: gcp_loc.id, bucket_id: "intra_region", ip_version: 4)
      expect(row.cidrs.map(&:to_s)).to eq(["34.1.0.0/16"])
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
