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
