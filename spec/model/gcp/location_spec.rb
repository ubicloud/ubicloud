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
    before { PgGceImage.dataset.destroy }

    describe "#pg_gce_image" do
      it "returns a GCE image path using the configured hosting project" do
        expect(Config).to receive(:postgres_gce_image_gcp_project_id).and_return("image-hosting-project")
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2404-x64-20260218",
          arch: "x64",
          pg_versions: ["16", "17", "18"],
        )

        expect(location.pg_gce_image("x64", "17")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2404-x64-20260218",
        )
      end

      it "raises when no matching PgGceImage is found for arch" do
        expect { location.pg_gce_image("x64", "17") }.to raise_error(
          RuntimeError, /No GCE image found for arch x64 and pg_version 17/,
        )
      end

      it "raises when no image supports the requested pg_version" do
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2404-x64-20260218",
          arch: "x64",
          pg_versions: ["16", "17", "18"],
        )
        expect { location.pg_gce_image("x64", "99") }.to raise_error(
          RuntimeError, /No GCE image found for arch x64 and pg_version 99/,
        )
      end

      it "prefers a dual-version image when target_version is supplied for an upgrade" do
        expect(Config).to receive(:postgres_gce_image_gcp_project_id).twice.and_return("image-hosting-project")
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2204-x64-20260223",
          arch: "x64",
          pg_versions: ["16", "17", "18"],
        )
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2204-x64-20260501",
          arch: "x64",
          pg_versions: ["18", "19"],
        )

        expect(location.pg_gce_image("x64", "18")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2204-x64-20260223",
        )
        expect(location.pg_gce_image("x64", "18", target_version: "19")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2204-x64-20260501",
        )
      end

      it "raises when no dual-version image exists for an upgrade (fail fast)" do
        PgGceImage.create(
          gce_image_name: "pg-17-x86-a",
          arch: "x86_64",
          pg_versions: ["17"],
        )
        PgGceImage.create(
          gce_image_name: "pg-18-x86-b",
          arch: "x86_64",
          pg_versions: ["18"],
        )

        expect {
          location.pg_gce_image("x86_64", "17", target_version: "18")
        }.to raise_error(
          RuntimeError,
          /No dual-version GCE image found for arch x86_64 covering pg_version=17 \+ target_version=18/,
        )
      end

      it "still falls back to a current-only image when target_version is nil" do
        expect(Config).to receive(:postgres_gce_image_gcp_project_id).and_return("image-hosting-project")
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2204-x64-20260223",
          arch: "x64",
          pg_versions: ["16", "17", "18"],
        )

        expect(location.pg_gce_image("x64", "18")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2204-x64-20260223",
        )
      end

      it "ignores target_version when it equals pg_version (no upgrade in progress)" do
        expect(Config).to receive(:postgres_gce_image_gcp_project_id).and_return("image-hosting-project")
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2204-x64-20260223",
          arch: "x64",
          pg_versions: ["16", "17", "18"],
        )
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2204-x64-20260501",
          arch: "x64",
          pg_versions: ["18", "19"],
        )

        expect(location.pg_gce_image("x64", "18", target_version: "18")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2204-x64-20260223",
        )
      end

      it "raises the dual-version fail-fast error when an upgrade call cannot find any overlapping image" do
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2204-x64-20260223",
          arch: "x64",
          pg_versions: ["16", "17", "18"],
        )

        expect {
          location.pg_gce_image("x64", "99", target_version: "19")
        }.to raise_error(
          RuntimeError,
          /No dual-version GCE image found for arch x64 covering pg_version=99 \+ target_version=19/,
        )
      end

      it "selects the image whose pg_versions contains the requested version when multiple rows share an arch" do
        expect(Config).to receive(:postgres_gce_image_gcp_project_id).twice.and_return("image-hosting-project")
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2204-x64-20260218",
          arch: "x64",
          pg_versions: ["16", "17", "18"],
        )
        PgGceImage.create(
          gce_image_name: "postgres-ubuntu-2404-x64-20270101",
          arch: "x64",
          pg_versions: ["19"],
        )

        expect(location.pg_gce_image("x64", "17")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2204-x64-20260218",
        )
        expect(location.pg_gce_image("x64", "19")).to eq(
          "projects/image-hosting-project/global/images/postgres-ubuntu-2404-x64-20270101",
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
        expect(location.location_credential_gcp).to receive(:zones_client).and_return(zones_client)

        zone_a = Google::Cloud::Compute::V1::Zone.new(name: "us-central1-a")
        zone_b = Google::Cloud::Compute::V1::Zone.new(name: "us-central1-b")
        zone_c = Google::Cloud::Compute::V1::Zone.new(name: "us-central1-c")
        zone_f = Google::Cloud::Compute::V1::Zone.new(name: "us-central1-f")
        zone_other = Google::Cloud::Compute::V1::Zone.new(name: "us-east1-a")
        zone_down = Google::Cloud::Compute::V1::Zone.new(name: "us-central1-d")

        expect(zones_client).to receive(:list)
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
        expect(location.location_credential_gcp).to receive(:zones_client).and_return(zones_client)
        expect(zones_client).to receive(:list)
          .with(project: "test-project")
          .and_return([])

        azs = location.send(:gcp_azs)
        expect(azs).to be_empty
      end
    end
  end
end
