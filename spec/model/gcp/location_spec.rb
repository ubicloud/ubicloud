# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Location do
  let(:location) {
    described_class.create(name: "gcp-us-central1", provider: "gcp",
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }
  let(:location_credential_gcp) {
    LocationCredentialGcp.create_with_id(location,
      project_id: "test-project",
      service_account_email: "test@test-project.iam.gserviceaccount.com",
      credentials_json: '{"type":"service_account","project_id":"test-project"}')
  }

  context "with GCP provider" do
    describe "#pg_gce_image" do
      before { PgGceImage.dataset.destroy }

      it "returns a GCE image path using the image's hosting project" do
        PgGceImage.create(
          gcp_project_id: "image-hosting-project",
          gce_image_name: "postgres-ubuntu-2404-x64-20260218",
          arch: "x64",
        )

        expect(location.pg_gce_image("x64")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2404-x64-20260218",
        )
      end

      it "raises when no matching PgGceImage is found" do
        expect { location.pg_gce_image("x64") }.to raise_error(
          RuntimeError, /No GCE image found for arch x64/,
        )
      end
    end

    describe "#pg_boot_image" do
      before { PgGceImage.dataset.destroy }

      it "delegates to pg_gce_image" do
        PgGceImage.create(
          gcp_project_id: "image-hosting-project",
          gce_image_name: "postgres-ubuntu-2404-arm64-20260218",
          arch: "arm64",
        )

        expect(location.send(:gcp_pg_boot_image, "99", "arm64", "standard")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2404-arm64-20260218",
        )
      end
    end

    describe "#azs" do
      let(:zones_client) { instance_double(Google::Cloud::Compute::V1::Zones::Rest::Client) }

      it "returns cached AZs when they exist" do
        LocationAz.create(location_id: location.id, az: "a")
        LocationAz.create(location_id: location.id, az: "b")

        azs = location.send(:gcp_azs)
        expect(azs.map(&:az)).to contain_exactly("a", "b")
      end

      it "fetches zones from GCP API when cache is empty" do
        location_credential_gcp
        allow(location).to receive(:location_credential_gcp).and_return(location_credential_gcp)
        allow(location_credential_gcp).to receive(:zones_client).and_return(zones_client)

        zone_a = Google::Cloud::Compute::V1::Zone.new(name: "us-central1-a")
        zone_b = Google::Cloud::Compute::V1::Zone.new(name: "us-central1-b")
        zone_c = Google::Cloud::Compute::V1::Zone.new(name: "us-central1-c")
        zone_f = Google::Cloud::Compute::V1::Zone.new(name: "us-central1-f")
        zone_other = Google::Cloud::Compute::V1::Zone.new(name: "us-east1-a")
        zone_down = Google::Cloud::Compute::V1::Zone.new(name: "us-central1-d")

        allow(zones_client).to receive(:list)
          .with(project: "test-project")
          .and_return([zone_a, zone_b, zone_c, zone_f, zone_other, zone_down])

        azs = location.send(:gcp_azs)
        expect(azs.map(&:az)).to contain_exactly("a", "b", "c", "d", "f")
        expect(azs.first).to be_a(LocationAz)

        # Verify they are persisted
        expect(LocationAz.where(location_id: location.id).count).to eq(5)
      end

      it "handles empty zone list from GCP API" do
        location_credential_gcp
        allow(location).to receive(:location_credential_gcp).and_return(location_credential_gcp)
        allow(location_credential_gcp).to receive(:zones_client).and_return(zones_client)
        allow(zones_client).to receive(:list)
          .with(project: "test-project")
          .and_return([])

        azs = location.send(:gcp_azs)
        expect(azs).to be_empty
      end
    end
  end
end
