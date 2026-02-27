# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Location do
  let(:location) {
    described_class.create(name: "gcp-us-central1", provider: "gcp",
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }
  let(:location_credential) {
    LocationCredential.create_with_id(location.id,
      project_id: "test-project",
      service_account_email: "test@test-project.iam.gserviceaccount.com",
      credentials_json: '{"type":"service_account","project_id":"test-project"}')
  }

  context "with GCP provider" do
    describe "#pg_gce_image" do
      it "returns a GCE image path using the image's hosting project" do
        PgGceImage.create_with_id(SecureRandom.uuid,
          gcp_project_id: "image-hosting-project",
          gce_image_name: "postgres-ubuntu-2404-x64-20260218",
          pg_version: "99",
          arch: "x64")

        expect(location.pg_gce_image("99", "x64")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2404-x64-20260218"
        )
      end

      it "raises when no matching PgGceImage is found" do
        expect { location.pg_gce_image("99", "x64") }.to raise_error(
          RuntimeError, /No GCE image found for PostgreSQL 99 \(x64\)/
        )
      end
    end

    describe "#pg_boot_image" do
      it "delegates to pg_gce_image" do
        PgGceImage.create_with_id(SecureRandom.uuid,
          gcp_project_id: "image-hosting-project",
          gce_image_name: "postgres-ubuntu-2404-arm64-20260218",
          pg_version: "99",
          arch: "arm64")

        expect(location.send(:gcp_pg_boot_image, "99", "arm64", "standard")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2404-arm64-20260218"
        )
      end
    end

    describe "#azs" do
      let(:zones_client) { instance_double(Google::Cloud::Compute::V1::Zones::Rest::Client) }

      it "returns cached AZs when they exist" do
        LocationGcpAz.create_with_id(SecureRandom.uuid, location_id: location.id, az: "a", zone_name: "us-central1-a")
        LocationGcpAz.create_with_id(SecureRandom.uuid, location_id: location.id, az: "b", zone_name: "us-central1-b")

        azs = location.send(:gcp_azs)
        expect(azs.map(&:az)).to contain_exactly("a", "b")
      end

      it "fetches zones from GCP API when cache is empty" do
        location_credential
        allow(location).to receive(:location_credential).and_return(location_credential)
        allow(location_credential).to receive(:zones_client).and_return(zones_client)

        zone_a = double(name: "us-central1-a", status: "UP")
        zone_b = double(name: "us-central1-b", status: "UP")
        zone_c = double(name: "us-central1-c", status: "UP")
        zone_f = double(name: "us-central1-f", status: "UP")
        zone_other = double(name: "us-east1-a", status: "UP")
        zone_down = double(name: "us-central1-d", status: "DOWN")

        allow(zones_client).to receive(:list)
          .with(project: "test-project")
          .and_return([zone_a, zone_b, zone_c, zone_f, zone_other, zone_down])

        azs = location.send(:gcp_azs)
        expect(azs.map(&:az)).to contain_exactly("a", "b", "c", "f")
        expect(azs.first).to be_a(LocationGcpAz)

        # Verify they are persisted
        expect(LocationGcpAz.where(location_id: location.id).count).to eq(4)
      end

      it "handles empty zone list from GCP API" do
        location_credential
        allow(location).to receive(:location_credential).and_return(location_credential)
        allow(location_credential).to receive(:zones_client).and_return(zones_client)
        allow(zones_client).to receive(:list)
          .with(project: "test-project")
          .and_return([])

        azs = location.send(:gcp_azs)
        expect(azs).to be_empty
      end
    end
  end
end
