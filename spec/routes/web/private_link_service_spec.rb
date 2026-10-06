# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "private link service" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:aws_location) { create_private_location(project:) }

  def assemble_pg(name, location_id)
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id:,
      name:,
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
      target_version: "16",
    ).subject
  end

  def assemble_ps(name, location_id)
    Prog::Vnet::SubnetNexus.assemble(project.id, name:, location_id:).subject
  end

  def assemble_pls(name, ps, **)
    Prog::Vnet::PrivateLinkServiceNexus.assemble(
      project_id: project.id, private_subnet_id: ps.id, name:, allowed_principals: ["arn:aws:iam::123456789012:root"],
      postgres_resource_id: nil, ports: [[5432, 5432], [6432, 6432]], ip_address_type: "ipv4", aws_supported_regions: [], aws_allowed_vpc_endpoints: [], **,
    ).subject
  end

  def csrf_token(form_id)
    find("form##{form_id} input[name='_csrf']", visible: false).value
  end

  describe "unauthenticated" do
    it "can not list without login" do
      visit "/private-link-service/aws"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "/private-link-service/aws/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    let(:postgres_project) { Project.create(name: "default") }

    before do
      allow(Config).to receive_messages(postgres_service_project_id: postgres_project.id, private_link_service_enabled: true)
      project.set_ff_private_link_service_aws(true)
      login(user.email)
    end

    it "hides the tab and returns 404 when the installation has private link services disabled, whatever the project flag says" do
      ps = assemble_ps("ps-aws", aws_location.id)
      pls = assemble_pls("pl-1", ps)
      allow(Config).to receive(:private_link_service_enabled).and_return(false)

      visit "#{project.path}/private-subnet"
      expect(page).to have_no_link "AWS service endpoints"

      visit "#{project.path}/private-link-service/aws"
      expect(page.status_code).to eq 404

      visit "#{project.path}/private-link-service/aws/create"
      expect(page.status_code).to eq 404

      visit "#{project.path}#{pls.path}/overview"
      expect(page.status_code).to eq 404
    end

    it "hides the tab and returns 404 when the project feature flag is off" do
      ps = assemble_ps("ps-aws", aws_location.id)
      pls = assemble_pls("pl-1", ps)
      project.set_ff_private_link_service_aws(false)

      visit "#{project.path}/private-subnet"
      expect(page).to have_no_link "AWS service endpoints"

      visit "#{project.path}/private-link-service/aws"
      expect(page.title).to eq("Ubicloud - ResourceNotFound")
      expect(page.status_code).to eq 404

      visit "#{project.path}#{pls.path}/overview"
      expect(page.status_code).to eq 404
    end

    it "ignores provider flags that have no web implementation yet" do
      project.set_ff_private_link_service_aws(false)
      project.set_ff_private_link_service_gcp(true)

      visit "#{project.path}/private-subnet"
      expect(page).to have_no_link "AWS service endpoints"
      expect(page).to have_no_link "GCP Private Service Connect"

      visit "#{project.path}/private-link-service/gcp"
      expect(page.status_code).to eq 404

      visit "#{project.path}/private-link-service/gcp/create"
      expect(page.status_code).to eq 404

      project.set_ff_private_link_service_aws(true)
      visit "#{project.path}/private-link-service/gcp/create"
      expect(page.status_code).to eq 404
    end

    describe "list" do
      it "lists no private link services and links to the create page" do
        visit "#{project.path}/private-link-service"
        expect(page.status_code).to eq 404

        visit "#{project.path}/private-subnet"
        click_link "AWS service endpoints"

        expect(page).to have_current_path("#{project.path}/private-link-service/aws")
        expect(page.title).to eq("Ubicloud - AWS service endpoints")
        expect(page).to have_content "No AWS service endpoints"
        expect(page).to have_content "Expose a PostgreSQL resource to other AWS accounts"

        click_link "Create AWS service endpoint"
        expect(page).to have_current_path("#{project.path}/private-link-service/aws/create")
        expect(page.title).to eq("Ubicloud - Create AWS service endpoint")
        expect(page).to have_field("name")
        expect(page).to have_select("private_subnet_id")
        expect(page).to have_field("allowed_principals[]", type: "text")
        expect(page).to have_button("Add another principal")
        expect(page).to have_button("Remove")
        expect(page).to have_no_field("private_dns_name")
        expect(page).to have_select("postgres_resource_id")
      end

      it "lists private link services with their state, subnet, service name and attached resource" do
        pg = assemble_pg("pg-aws", aws_location.id)
        pls_attached = assemble_pls("pl-attached", pg.private_subnet, postgres_resource_id: pg.id)
        pls_bare = assemble_pls("pl-bare", assemble_ps("ps-aws", aws_location.id))
        pls_bare.private_link_service_aws_resource.update(service_name: "com.amazonaws.vpce.us-west-2.vpce-svc-0123")
        ps_hetzner = assemble_ps("ps-hetzner", Location::HETZNER_FSN1_ID)
        PrivateLinkService.create(name: "pl-hetzner", project_id: project.id, location_id: ps_hetzner.location_id, private_subnet_id: ps_hetzner.id)

        visit "#{project.path}/private-link-service/aws"

        expect(page).to have_content "pl-attached"
        expect(page).to have_content "pg-aws"
        expect(page).to have_content "Provisioning"
        expect(page).to have_content "com.amazonaws.vpce.us-west-2.vpce-svc-0123"
        expect(page).to have_no_content "pl-hetzner"
        expect(page.all("#pl-#{pls_attached.ubid} td").map { it.text.strip }).to include("creating")
        expect(page).to have_link "Create AWS service endpoint"

        click_link "pl-bare"
        expect(page.title).to eq("Ubicloud - pl-bare")
      end

      it "shows the create button only with PrivateLinkService:create permission, not with PrivateSubnet:edit" do
        # Reference the project before wiping ACEs: the let is lazy and would
        # otherwise recreate the default policy after the wipe.
        visit "#{project.path}/private-link-service/aws"
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateLinkService:view"])
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:edit"])

        page.refresh
        expect(page).to have_content "You don't have permission to create AWS service endpoints."
        expect(page).to have_no_link "Create AWS service endpoint"

        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateLinkService:create"])
        page.refresh
        expect(page).to have_link "Create AWS service endpoint"
      end

      it "lists only the services the user may view" do
        ps_one = assemble_ps("ps-one", aws_location.id)
        ps_two = assemble_ps("ps-two", aws_location.id)
        pls_one = assemble_pls("pl-one", ps_one)
        assemble_pls("pl-two", ps_two)

        visit "#{project.path}/private-link-service/aws"
        expect(page).to have_content "pl-one"
        expect(page).to have_content "pl-two"

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateLinkService:view"], object_id: pls_one.id)

        page.refresh
        expect(page).to have_content "pl-one"
        expect(page).to have_no_content "pl-two"
      end
    end

    describe "create" do
      it "offers only AWS private subnets and PostgreSQL resources the user can view and that have no service yet" do
        assemble_pg("pg-aws", aws_location.id)
        assemble_pg("pg-hetzner", Location::HETZNER_FSN1_ID)
        pg_taken = assemble_pg("pg-taken", aws_location.id)
        assemble_pls("pl-taken", pg_taken.private_subnet, postgres_resource_id: pg_taken.id)
        assemble_ps("ps-aws", aws_location.id)
        assemble_ps("ps-hetzner", Location::HETZNER_FSN1_ID)

        visit "#{project.path}/private-link-service/aws/create"

        expect(page).to have_select("postgres_resource_id", options: ["None", "pg-aws"])
        expect(page).to have_select("private_subnet_id", with_options: ["Select private subnet", "ps-aws"])
        expect(page).to have_no_select("private_subnet_id", with_options: ["ps-hetzner"])
        expect(page.all("#private_subnet_id option").count).to eq 4
      end

      it "creates a private link service with an attached resource and shows its overview" do
        pg = assemble_pg("pg-aws", aws_location.id)

        visit "#{project.path}/private-link-service/aws/create"
        fill_in "name", with: "pg-aws-endpoint"
        select pg.private_subnet.name, from: "private_subnet_id"
        fill_in "allowed_principals[]", with: " arn:aws:iam::123456789012:root "
        select "pg-aws", from: "postgres_resource_id"
        click_button "Create AWS service endpoint"

        expect(page.title).to eq("Ubicloud - pg-aws-endpoint")
        expect(page).to have_flash_notice("'pg-aws-endpoint' is being created")

        pls = PrivateLinkService.first(name: "pg-aws-endpoint")
        expect(pls.private_subnet_id).to eq pg.private_subnet_id
        expect(pls.postgres_resource_id).to eq pg.id
        expect(pls.allowed_principals).to eq ["arn:aws:iam::123456789012:root"]
        expect(pls.private_dns_name).to be_nil
        expect(pls.ip_address_type).to eq "ipv4"
        expect(pls.ports.map(&:port).sort).to eq [5432, 6432]
        expect(pls.strand.label).to eq "start"
        expect(DB[:audit_log].where(ubid_type: "pn", action: "create").count).to eq 1

        expect(page).to have_content "creating"
        expect(page).to have_content "pg-aws"
        expect(page).to have_content "5432 -> 5432, 6432 -> 6432"
        expect(page).to have_content "IPv4"
      end

      it "refuses the create page without PrivateLinkService:create" do
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])
        visit "#{project.path}/private-link-service/aws/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
      end

      it "refuses to create without PrivateLinkService:create, even for a user who may edit the subnet" do
        ps = assemble_ps("ps-aws", aws_location.id)
        visit "#{project.path}/private-link-service/aws/create"
        _csrf = csrf_token("form-private-link-service-create")

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:edit"])
        base = {private_subnet_id: ps.ubid, allowed_principals: ["arn:aws:iam::123456789012:root"], ports: ["5432"], target_ports: ["5432"], _csrf:}
        page.driver.post "#{project.path}/private-link-service/aws", base.merge(name: "denied")
        expect(page.status_code).to eq 403
        expect(PrivateLinkService.count).to eq 0

        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateLinkService:create"])
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateSubnet:view"])
        page.driver.post "#{project.path}/private-link-service/aws", base.merge(name: "allowed")
        expect(page.status_code).to eq 302
        expect(PrivateLinkService.first(name: "allowed")).not_to be_nil
      end

      it "creates a private link service without an attached resource" do
        ps = assemble_ps("ps-aws", aws_location.id)

        visit "#{project.path}/private-link-service/aws/create"
        fill_in "name", with: "bare"
        select "ps-aws", from: "private_subnet_id"
        select "Dual stack", from: "ip_address_type"
        fill_in "allowed_principals[]", with: "arn:aws:iam::111111111111:root"
        click_button "Create AWS service endpoint"

        expect(page.title).to eq("Ubicloud - bare")
        pls = PrivateLinkService.first(name: "bare")
        expect(pls.private_subnet_id).to eq ps.id
        expect(pls.postgres_resource_id).to be_nil
        expect(pls.private_dns_name).to be_nil
        expect(pls.ip_address_type).to eq "dual"
        expect(page).to have_content "Dual stack"
        expect(page).to have_content "None"
        expect(page).to have_content "Provisioning"
      end

      it "rejects an invalid name and re-renders the form" do
        ps = assemble_ps("ps-aws", aws_location.id)

        visit "#{project.path}/private-link-service/aws/create"
        fill_in "name", with: "Bad Name!"
        select ps.name, from: "private_subnet_id"
        fill_in "allowed_principals[]", with: "arn:aws:iam::123456789012:root"
        click_button "Create AWS service endpoint"

        expect(page.title).to eq("Ubicloud - Create AWS service endpoint")
        expect(page).to have_content "Name must only contain lowercase letters, numbers, and hyphens"
      end

      it "rejects an IP address type outside the list and re-renders the form" do
        ps = assemble_ps("ps-aws", aws_location.id)

        visit "#{project.path}/private-link-service/aws/create"
        _csrf = csrf_token("form-private-link-service-create")
        page.driver.post "#{project.path}/private-link-service/aws", {name: "bad-type", private_subnet_id: ps.ubid, ip_address_type: "ipv5", allowed_principals: ["arn:aws:iam::123456789012:root"], _csrf:}

        expect(page.status_code).to eq 400
        expect(page.body).to include "Must be one of: ipv4, ipv6, dual"
        expect(PrivateLinkService.count).to eq 0
      end

      it "creates a private link service with custom ports" do
        ps = assemble_ps("ps-aws", aws_location.id)

        visit "#{project.path}/private-link-service/aws/create"
        expect(page).to have_field("ports[]", with: "5432")
        expect(page).to have_field("target_ports[]", with: "6432")

        _csrf = csrf_token("form-private-link-service-create")
        page.driver.post "#{project.path}/private-link-service/aws", {name: "custom-ports", private_subnet_id: ps.ubid, allowed_principals: ["arn:aws:iam::123456789012:root"], ports: ["15432", "16432"], target_ports: ["5432", "6432"], _csrf:}
        expect(page.status_code).to eq 302

        pls = PrivateLinkService.first(name: "custom-ports")
        expect(pls.ports.map { [it.port, it.target_port] }.sort).to eq [[15432, 5432], [16432, 6432]]
      end

      it "rejects mismatched, duplicate or out of range ports" do
        ps = assemble_ps("ps-aws", aws_location.id)

        visit "#{project.path}/private-link-service/aws/create"
        _csrf = csrf_token("form-private-link-service-create")
        base = {name: "ep", private_subnet_id: ps.ubid, allowed_principals: ["arn:aws:iam::123456789012:root"], _csrf:}

        page.driver.post "#{project.path}/private-link-service/aws", base.merge(ports: ["5432", "6432"], target_ports: ["5432"])
        expect(page.status_code).to eq 400
        expect(page.body).to include "Each port needs a target port"

        page.driver.post "#{project.path}/private-link-service/aws", base.merge(ports: ["5432", "5432"], target_ports: ["5432", "6432"])
        expect(page.status_code).to eq 400
        expect(page.body).to include "Ports must be unique"

        page.driver.post "#{project.path}/private-link-service/aws", base.merge(ports: ["0"], target_ports: ["5432"])
        expect(page.status_code).to eq 400
        expect(page.body).to include "Ports must be between 1 and 65535"

        page.driver.post "#{project.path}/private-link-service/aws", base.merge(ports: ["5432"], target_ports: [""])
        expect(page.status_code).to eq 400
        expect(page.body).to include "Ports must be between 1 and 65535"

        page.driver.post "#{project.path}/private-link-service/aws", base.merge(ports: ["70000"], target_ports: ["5432"])
        expect(page.status_code).to eq 400
        expect(page.body).to include "Ports must be between 1 and 65535"
        expect(PrivateLinkService.count).to eq 0
      end

      it "rejects a duplicate name in the same location" do
        ps = assemble_ps("ps-aws", aws_location.id)
        assemble_pls("taken", ps)

        visit "#{project.path}/private-link-service/aws/create"
        fill_in "name", with: "taken"
        select ps.name, from: "private_subnet_id"
        fill_in "allowed_principals[]", with: "arn:aws:iam::123456789012:root"
        click_button "Create AWS service endpoint"

        expect(page.title).to eq("Ubicloud - Create AWS service endpoint")
        expect(page).to have_content "A private link service named 'taken' already exists"
        expect(PrivateLinkService.where(name: "taken").count).to eq 1
      end

      it "rejects a principal that is not * or an IAM ARN of a root, user or role" do
        ps = assemble_ps("ps-aws", aws_location.id)

        visit "#{project.path}/private-link-service/aws/create"
        fill_in "name", with: "bad-principal"
        select ps.name, from: "private_subnet_id"
        fill_in "allowed_principals[]", with: "arn:aws:iam::123456789012:group/admins"
        click_button "Create AWS service endpoint"

        expect(page.title).to eq("Ubicloud - Create AWS service endpoint")
        expect(page).to have_content "invalid: arn:aws:iam::123456789012:group/admins"
        expect(PrivateLinkService.where(name: "bad-principal").count).to eq 0
      end

      it "rejects a private subnet outside AWS or a resource outside the subnet" do
        ps_aws = assemble_ps("ps-aws", aws_location.id)
        ps_hetzner = assemble_ps("ps-hetzner", Location::HETZNER_FSN1_ID)
        pg = assemble_pg("pg-aws", aws_location.id)

        visit "#{project.path}/private-link-service/aws/create"
        _csrf = csrf_token("form-private-link-service-create")
        principals = ["arn:aws:iam::123456789012:root"]

        page.driver.post "#{project.path}/private-link-service/aws", {name: "ep", private_subnet_id: ps_hetzner.ubid, allowed_principals: principals, _csrf:}
        expect(page.status_code).to eq 400
        expect(page.body).to include "Private subnet not found in an AWS location"

        page.driver.post "#{project.path}/private-link-service/aws", {name: "ep", private_subnet_id: ps_aws.ubid, postgres_resource_id: pg.ubid, allowed_principals: principals, _csrf:}
        expect(page.status_code).to eq 400
        expect(page.body).to include "PostgreSQL resource not found in the selected private subnet"

        page.driver.post "#{project.path}/private-link-service/aws", {name: "ep", private_subnet_id: "not-a-ubid", allowed_principals: principals, _csrf:}
        expect(page.status_code).to eq 400
        expect(page.body).to include "flash-error"
        expect(PrivateLinkService.count).to eq 0
      end
    end

    describe "supported regions" do
      let(:ps) { assemble_ps("ps-aws", aws_location.id) }
      let(:pls) { assemble_pls("pl-1", ps) }
      let(:ec2) { Aws::EC2::Client.new(stub_responses: true) }

      before do
        allow(Aws::EC2::Client).to receive(:new).and_return(ec2)
        ec2.stub_responses(:describe_regions, regions: %w[us-west-2 us-east-1 eu-west-1 ap-south-1].map { {region_name: it} })
      end

      it "refuses a region the provider account has not opted in to" do
        ps
        visit "#{project.path}/private-link-service/aws/create"
        _csrf = csrf_token("form-private-link-service-create")
        page.driver.post "#{project.path}/private-link-service/aws", {name: "opt-in", private_subnet_id: ps.ubid, allowed_principals: ["arn:aws:iam::123456789012:root"], ports: ["5432"], target_ports: ["5432"], aws_supported_regions: ["ap-south-2", "us-east-1"], _csrf:}
        expect(page.status_code).to eq 400
        expect(page.body).to include "Not enabled in the provider&#39;s AWS account: ap-south-2"
        expect(PrivateLinkService.first(name: "opt-in")).to be_nil

        expect(ec2).not_to receive(:describe_regions)
        page.driver.post "#{project.path}/private-link-service/aws", {name: "home-only", private_subnet_id: ps.ubid, allowed_principals: ["arn:aws:iam::123456789012:root"], ports: ["5432"], target_ports: ["5432"], aws_supported_regions: ["us-west-2"], _csrf:}
        expect(page.status_code).to eq 302
        expect(PrivateLinkService.first(name: "home-only").private_link_service_aws_resource.supported_regions).to eq []
      end

      it "offers a region dropdown row on the create form and stores the selection without the home region" do
        ps
        visit "#{project.path}/private-link-service/aws/create"
        expect(page.all("select[name='aws_supported_regions[]']").length).to eq 1
        expect(page.all("select[name='aws_supported_regions[]'] option").map(&:value)).to eq [""] + PrivateLinkServiceAwsResource::SUPPORTED_REGIONS
        expect(page).to have_button "Add another region"

        _csrf = csrf_token("form-private-link-service-create")
        page.driver.post "#{project.path}/private-link-service/aws", {name: "regional", private_subnet_id: ps.ubid, allowed_principals: ["arn:aws:iam::123456789012:root"], ports: ["5432"], target_ports: ["5432"], aws_supported_regions: ["us-east-1", "", "us-west-2", "eu-west-1"], _csrf:}
        expect(page.status_code).to eq 302
        expect(PrivateLinkService.first(name: "regional").private_link_service_aws_resource.supported_regions).to eq ["eu-west-1", "us-east-1"]

        page.driver.post "#{project.path}/private-link-service/aws", {name: "bad-region", private_subnet_id: ps.ubid, allowed_principals: ["arn:aws:iam::123456789012:root"], ports: ["5432"], target_ports: ["5432"], aws_supported_regions: ["mars-1"], _csrf:}
        expect(page.status_code).to eq 400
        expect(page.body).to include "Unknown AWS region selected"
        expect(PrivateLinkService.first(name: "bad-region")).to be_nil
      end

      it "shows the regions on the overview and lets settings change them" do
        pls.strand.update(label: "wait")
        aws = pls.private_link_service_aws_resource
        aws.update(supported_regions: Sequel.pg_array(["eu-west-1"], :text))
        visit "#{project.path}#{pls.path}/overview"
        expect(page).to have_content "us-west-2, eu-west-1"

        visit "#{project.path}#{pls.path}/settings"
        expect(page.all("select[name='aws_supported_regions[]']").length).to eq 1
        expect(page.all("select[name='aws_supported_regions[]'] option").map(&:value)).not_to include("us-west-2")
        expect(page.all("select[name='aws_supported_regions[]'] option[selected]").map(&:value)).to eq ["eu-west-1"]

        _csrf = csrf_token("form-private-link-service-supported-regions")
        page.driver.post "#{project.path}#{pls.path}/supported-regions", {aws_supported_regions: ["ap-south-1", "us-east-1"], _csrf:}
        expect(page.status_code).to eq 302
        visit "#{project.path}#{pls.path}/settings"
        expect(page).to have_flash_notice("Supported regions updated, the private link service is being reconciled.")
        expect(aws.reload.supported_regions).to eq ["ap-south-1", "us-east-1"]
        expect(pls.reconcile_set?).to be true
        expect(DB[:audit_log].where(ubid_type: "pn", action: "update").count).to eq 1

        Semaphore.where(strand_id: pls.id).destroy
        page.driver.post "#{project.path}#{pls.path}/supported-regions", {_csrf:}
        expect(aws.reload.supported_regions).to eq []
        expect(pls.reconcile_set?).to be true

        page.driver.post "#{project.path}#{pls.path}/supported-regions", {aws_supported_regions: ["mars-1"], _csrf:}
        expect(page.status_code).to eq 400
        expect(page.body).to include "Unknown AWS region selected"
      end
    end

    describe "show" do
      let(:ps) { assemble_ps("ps-aws", aws_location.id) }
      let(:pls) { assemble_pls("pl-1", ps) }

      it "refuses every action POST without PrivateLinkService:edit" do
        pg = assemble_pg("pg-aws", aws_location.id)
        pls.strand.update(label: "wait")
        pls.update(private_dns_name: "db.example.com")
        visit "#{project.path}#{pls.path}/settings"
        principals_csrf = csrf_token("form-private-link-service-principals")
        regions_csrf = csrf_token("form-private-link-service-supported-regions")
        reconcile_csrf = csrf_token("form-private-link-service-reconcile")
        visit "#{project.path}#{pls.path}/connections"
        endpoints_csrf = csrf_token("form-private-link-service-allowed-vpc-endpoints")
        visit "#{project.path}#{pls.path}/postgres"
        attach_csrf = csrf_token("form-private-link-service-attach")

        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateLinkService:view"])
        [
          ["principals", {allowed_principals: ["*"], _csrf: principals_csrf}],
          ["supported-regions", {aws_supported_regions: ["us-east-1"], _csrf: regions_csrf}],
          ["reconcile", {_csrf: reconcile_csrf}],
          ["allowed-vpc-endpoints", {allowed_vpc_endpoint_ids: ["vpce-0123456789abcdef0"], _csrf: endpoints_csrf}],
          ["attach-postgres", {postgres_resource_id: pg.ubid, _csrf: attach_csrf}],
        ].each do |action, params|
          page.driver.post "#{project.path}#{pls.path}/#{action}", params
          expect(page.status_code).to eq 403
        end
        expect(Semaphore.where(strand_id: pls.id).count).to eq 0
        expect(pls.reload.postgres_resource_id).to be_nil
        expect(DB[:audit_log].where(ubid_type: "pn").count).to eq 0
      end

      it "redirects the bare path to the overview" do
        visit "#{project.path}#{pls.path}"
        expect(page.title).to eq("Ubicloud - pl-1")
        expect(page).to have_current_path("#{project.path}#{pls.path}/overview")
        expect(page).to have_content "arn:aws:iam::123456789012:root"
        expect(page).to have_content "Provisioning"
      end

      it "shows None for principals and targets while nothing is registered" do
        pls.update(allowed_principals: Sequel.pg_array([], :text))
        visit "#{project.path}#{pls.path}/overview"
        expect(page.all(".kv-data-card dd, dd").map { it.text.strip }).to include("None")
        expect(page).to have_no_content "arn:aws:iam"
      end

      it "shows dashes on the PostgreSQL tab for an attached resource that has no primary yet" do
        pg = PostgresResource.create(name: "pg-new", project_id: project.id, location_id: aws_location.id, target_vm_size: "standard-2", target_storage_size_gib: 128, target_version: "16", superuser_password: "x", private_subnet_id: pls.private_subnet_id)
        pls.update(postgres_resource_id: pg.id)
        visit "#{project.path}#{pls.path}/postgres"
        cells = page.all("#pl-pg-#{pg.ubid} td").map { it.text.strip }
        expect(cells).to include("pg-new")
        expect(cells.count("-")).to eq 4
      end

      it "shows the service name, target and approved endpoints once the provider filled them in" do
        pls.private_link_service_aws_resource.update(service_name: "com.amazonaws.vpce.us-west-2.vpce-svc-0123", registered_target_ips: Sequel.pg_array(["10.0.0.5"], :inet))
        PrivateLinkServiceAwsAllowedEndpoint.create(private_link_service_aws_resource_id: pls.id, vpc_endpoint_id: "vpce-0123456789abcdef0", description: "analytics team")
        PrivateLinkServiceAwsAllowedEndpoint.create(private_link_service_aws_resource_id: pls.id, vpc_endpoint_id: "vpce-0123456789abcdef1")
        visit "#{project.path}#{pls.path}/overview"
        expect(page).to have_content "com.amazonaws.vpce.us-west-2.vpce-svc-0123"
        expect(page).to have_content "10.0.0.5"
        expect(page).to have_content "vpce-0123456789abcdef0 (analytics team), vpce-0123456789abcdef1"
      end

      it "shows the private DNS verification state on the overview" do
        visit "#{project.path}#{pls.path}/overview"
        expect(page).to have_content "Not configured"

        aws = pls.private_link_service_aws_resource
        pls.update(private_dns_name: "db.example.com")
        aws.update(private_dns_verification_state: "pendingVerification")
        visit "#{project.path}#{pls.path}/overview"
        expect(page).to have_content "Pending verification"

        aws.update(private_dns_verification_state: "verified")
        visit "#{project.path}#{pls.path}/overview"
        expect(page).to have_content "Verified"
      end

      it "returns 404 for an unknown name or another location" do
        visit "#{project.path}/location/#{aws_location.display_name}/private-link-service/nope/overview"
        expect(page.status_code).to eq 404

        visit "#{project.path}/location/#{Location[Location::HETZNER_FSN1_ID].display_name}/private-link-service/es-1/overview"
        expect(page.status_code).to eq 404
      end
    end

    describe "postgres tab" do
      let(:pg) { assemble_pg("pg-aws", aws_location.id) }

      it "attaches a PostgreSQL resource from the same subnet" do
        pls = assemble_pls("pl-1", pg.private_subnet)
        pls.strand.update(label: "wait")

        visit "#{project.path}#{pls.path}/postgres"
        expect(page).to have_content "No PostgreSQL resource attached"
        select "pg-aws", from: "postgres_resource_id"
        click_button "Attach"

        expect(page).to have_flash_notice("'pg-aws' attached, the private link service is being reconciled.")
        expect(pls.reload.postgres_resource_id).to eq pg.id
        expect(pls.reconcile_set?).to be true
        expect(page).to have_content "Primary"
        expect(page).to have_no_button "Attach"
      end

      it "refuses a resource that already has a private link service" do
        assemble_pls("pl-1", pg.private_subnet, postgres_resource_id: pg.id)
        pls = assemble_pls("pl-2", pg.private_subnet)

        visit "#{project.path}#{pls.path}/postgres"
        expect(page).to have_select("postgres_resource_id", options: ["Select a PostgreSQL resource"])
        _csrf = csrf_token("form-private-link-service-attach")
        page.driver.post "#{project.path}#{pls.path}/attach-postgres", {postgres_resource_id: pg.ubid, _csrf:}
        expect(page.status_code).to eq 400
        expect(page.body).to include "PostgreSQL resource already has a private link service"
        expect(pls.reload.postgres_resource_id).to be_nil
      end

      it "refuses a direct attach while a resource is attached" do
        pls = assemble_pls("pl-1", pg.private_subnet)
        pls.strand.update(label: "wait")

        visit "#{project.path}#{pls.path}/postgres"
        _csrf = csrf_token("form-private-link-service-attach")
        pls.attach_postgres_resource(pg)

        page.driver.post "#{project.path}#{pls.path}/attach-postgres", {postgres_resource_id: pg.ubid, _csrf:}
        expect(page.status_code).to eq 400
        expect(page.body).to include "A PostgreSQL resource is already attached"
        expect(pls.reload.postgres_resource_id).to eq pg.id
      end

      it "rejects a resource from another subnet" do
        pls = assemble_pls("pl-1", assemble_ps("ps-aws", aws_location.id))

        visit "#{project.path}#{pls.path}/postgres"
        expect(page).to have_select("postgres_resource_id", options: ["Select a PostgreSQL resource"])
        _csrf = csrf_token("form-private-link-service-attach")
        page.driver.post "#{project.path}#{pls.path}/attach-postgres", {postgres_resource_id: pg.ubid, _csrf:}
        expect(page.status_code).to eq 400
        expect(page.body).to include "PostgreSQL resource not found in the selected private subnet"

        page.driver.post "#{project.path}#{pls.path}/attach-postgres", {_csrf:}
        expect(page.status_code).to eq 400
        expect(pls.reload.postgres_resource_id).to be_nil
      end

      it "shows the attached resource and its private hostname, with no way to detach it" do
        pls = assemble_pls("pl-1", pg.private_subnet, postgres_resource_id: pg.id)
        pls.strand.update(label: "wait")

        visit "#{project.path}#{pls.path}/postgres"
        expect(page).to have_content "pg-aws"
        expect(page).to have_content pg.private_hostname
        expect(page).to have_no_button "Attach"
        expect(page).to have_no_button "Detach"
        visit "#{project.path}#{pls.path}/settings"
        expect(page).to have_content pg.private_hostname
      end

      it "hides the attach form without PrivateLinkService:edit permission" do
        pls = assemble_pls("pl-1", pg.private_subnet)
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateLinkService:view"])
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["Postgres:view"])

        visit "#{project.path}#{pls.path}/postgres"
        expect(page.status_code).to eq 200
        expect(page).to have_content "No PostgreSQL resource attached"
        expect(page).to have_no_button "Attach"
      end
    end

    describe "connections tab" do
      let(:ps) { assemble_ps("ps-aws", aws_location.id) }
      let(:pls) { assemble_pls("pl-1", ps) }
      let(:aws) { pls.private_link_service_aws_resource }

      def approve(vpc_endpoint_id, description = "")
        PrivateLinkServiceAwsAllowedEndpoint.create(private_link_service_aws_resource_id: aws.id, vpc_endpoint_id:, description:)
      end

      it "offers an empty approved list and no connection table" do
        visit "#{project.path}#{pls.path}/connections"
        expect(page.status_code).to eq 200
        expect(page).to have_field("allowed_vpc_endpoint_ids[]", type: "text", with: "")
        expect(page).to have_field("allowed_vpc_endpoint_descriptions[]", type: "text", with: "")
        expect(page).to have_button "Apply"
        expect(page).to have_no_button "Refresh"
        expect(page).to have_no_content "Consumer connections"
      end

      it "shows the approved endpoints with their descriptions in the form" do
        approve("vpce-0123456789abcdef0", "analytics team")
        visit "#{project.path}#{pls.path}/connections"

        expect(page).to have_field("allowed_vpc_endpoint_ids[]", with: "vpce-0123456789abcdef0")
        expect(page).to have_field("allowed_vpc_endpoint_descriptions[]", with: "analytics team")
      end

      it "applies the approved endpoint list with descriptions and asks for a connection reconcile" do
        pls.strand.update(label: "wait")
        visit "#{project.path}#{pls.path}/connections"
        fill_in "allowed_vpc_endpoint_ids[]", with: " vpce-0123456789abcdef0 "
        fill_in "allowed_vpc_endpoint_descriptions[]", with: " Analytics team, production VPC "
        click_button "Apply"

        expect(page).to have_flash_notice(/Approved endpoints updated/)
        expect(aws.allowed_endpoints.map { [it.vpc_endpoint_id, it.description] }).to eq [["vpce-0123456789abcdef0", "Analytics team, production VPC"]]
        expect(pls.reload.reconcile_connections_set?).to be true
        expect(DB[:audit_log].where(ubid_type: "pn", action: "update").count).to eq 1

        _csrf = csrf_token("form-private-link-service-allowed-vpc-endpoints")
        page.driver.post "#{project.path}#{pls.path}/allowed-vpc-endpoints", {allowed_vpc_endpoint_ids: ["", "vpce-0123456789abcdef1"], allowed_vpc_endpoint_descriptions: ["orphan note", ""], _csrf:}
        expect(page.status_code).to eq 302
        expect(aws.reload.allowed_endpoints.map { [it.vpc_endpoint_id, it.description] }).to eq [["vpce-0123456789abcdef1", ""]]

        page.driver.post "#{project.path}#{pls.path}/allowed-vpc-endpoints", {_csrf:}
        expect(page.status_code).to eq 302
        expect(aws.reload.allowed_endpoints).to eq []
      end

      it "rejects an entry that is not a VPC endpoint id, a repeated id or a bad description, keeping the stored list" do
        approve("vpce-0123456789abcdef0", "keep")
        visit "#{project.path}#{pls.path}/connections"
        fill_in "allowed_vpc_endpoint_ids[]", with: "vpce-nope"
        click_button "Apply"

        expect(page.status_code).to eq 400
        expect(page).to have_content "invalid: vpce-nope"

        _csrf = csrf_token("form-private-link-service-allowed-vpc-endpoints")
        page.driver.post "#{project.path}#{pls.path}/allowed-vpc-endpoints", {allowed_vpc_endpoint_ids: ["vpce-0123456789abcdef0", "vpce-0123456789abcdef0"], allowed_vpc_endpoint_descriptions: ["a", "b"], _csrf:}
        expect(page.status_code).to eq 400
        expect(page.body).to include "repeated: vpce-0123456789abcdef0"

        page.driver.post "#{project.path}#{pls.path}/allowed-vpc-endpoints", {allowed_vpc_endpoint_ids: ["vpce-0123456789abcdef0"], allowed_vpc_endpoint_descriptions: ["two\nlines"], _csrf:}
        expect(page.status_code).to eq 400
        expect(page.body).to include "one line of at most 255 printable characters"

        expect(aws.reload.allowed_endpoints.map { [it.vpc_endpoint_id, it.description] }).to eq [["vpce-0123456789abcdef0", "keep"]]
        expect(pls.reconcile_connections_set?).to be false
      end

      it "shows the approved endpoints read-only without PrivateLinkService:edit permission" do
        approve("vpce-0123456789abcdef0", "analytics team")
        approve("vpce-0123456789abcdef1")
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateLinkService:view"])

        visit "#{project.path}#{pls.path}/connections"
        expect(page.status_code).to eq 200
        expect(page).to have_no_button "Apply"
        expect(page).to have_no_field "allowed_vpc_endpoint_ids[]"
        expect(page.find_by_id("pl-allowed-vpce-0123456789abcdef0").text).to eq "vpce-0123456789abcdef0 - analytics team"
        expect(page.find_by_id("pl-allowed-vpce-0123456789abcdef1").text).to eq "vpce-0123456789abcdef1"

        PrivateLinkServiceAwsAllowedEndpoint.where(private_link_service_aws_resource_id: aws.id).destroy
        page.refresh
        expect(page).to have_content "No endpoint approved yet"
      end
    end

    describe "settings" do
      let(:ps) { assemble_ps("ps-aws", aws_location.id) }
      let(:pls) { assemble_pls("pl-1", ps) }

      it "updates allowed principals and asks for them to be applied" do
        pls.strand.update(label: "wait")
        visit "#{project.path}#{pls.path}/settings"
        expect(page).to have_field("allowed_principals[]", with: "arn:aws:iam::123456789012:root")

        _csrf = csrf_token("form-private-link-service-principals")
        page.driver.post "#{project.path}#{pls.path}/principals", {allowed_principals: [" arn:aws:iam::222222222222:root ", "arn:aws:iam::333333333333:role/app"], _csrf:}
        expect(page.status_code).to eq 302
        visit "#{project.path}#{pls.path}/settings"

        expect(page).to have_flash_notice("Allowed principals updated, they are being applied to the private link service.")
        expect(pls.reload.allowed_principals).to eq ["arn:aws:iam::222222222222:root", "arn:aws:iam::333333333333:role/app"]
        expect(pls.update_permissions_set?).to be true
        expect(pls.reconcile_set?).to be false
        expect(DB[:audit_log].where(ubid_type: "pn", action: "update").count).to eq 1
      end

      it "re-renders settings when no principal is given" do
        visit "#{project.path}#{pls.path}/settings"
        _csrf = csrf_token("form-private-link-service-principals")
        page.driver.post "#{project.path}#{pls.path}/principals", {_csrf:}
        expect(page.status_code).to eq 400
        expect(page.body).to include "flash-error"
        expect(pls.reload.allowed_principals).to eq ["arn:aws:iam::123456789012:root"]
      end

      it "shows an empty principal row when none are set" do
        pls.update(allowed_principals: Sequel.pg_array([], :text))
        visit "#{project.path}#{pls.path}/settings"
        expect(page).to have_field("allowed_principals[]", with: "")
      end

      it "deletes the private link service" do
        visit "#{project.path}#{pls.path}/settings"
        click_button "Delete"

        expect(page.title).to eq("Ubicloud - AWS service endpoints")
        expect(page).to have_flash_notice("Private link service 'pl-1' scheduled for deletion.")
        expect(pls.reload.destroy_set?).to be true
        expect(page.all("#pl-#{pls.ubid} td").map { it.text.strip }).to include("deleting")
        expect(DB[:audit_log].where(ubid_type: "pn", action: "destroy").count).to eq 1
      end

      it "shows the derived private DNS name read-only with its verification state and TXT record" do
        allow(Config).to receive(:postgres_service_project_id).and_return(project.id)
        pg = assemble_pg("pg-aws", aws_location.id)
        zone = DnsZone.create(project_id: project.id, name: pg.hostname_suffix)
        server = DnsServer.create(name: "ns.#{pg.hostname_suffix}")
        zone.add_dns_server(server)
        server.add_vm(create_vm(project_id: project.id, name: "dns-vm"))
        pls = assemble_pls("pl-1", pg.private_subnet, postgres_resource_id: pg.id)
        aws = pls.private_link_service_aws_resource
        aws.update(private_dns_verification_state: "pendingVerification", private_dns_verification_name: "_abc123", private_dns_verification_value: "vpce:xyz789")

        visit "#{project.path}#{pls.path}/settings"
        expect(page).to have_content pg.cert_private_hostname
        expect(page).to have_content pg.private_hostname
        expect(page).to have_content "Pending verification"
        expect(page).to have_content "_abc123"
        expect(page).to have_content "vpce:xyz789"
        expect(page).to have_content "published automatically"
        expect(page).to have_no_field "private_dns_name"

        pls.strand.update(label: "wait")
        click_button "Verify"
        expect(page).to have_flash_notice("The private link service is being reconciled and the private DNS record checked again.")
        expect(pls.reload.reconcile_set?).to be true
        expect(DB[:audit_log].where(ubid_type: "pn", action: "update").count).to eq 1

        aws.update(private_dns_verification_state: "verified")
        visit "#{project.path}#{pls.path}/settings"
        expect(page).to have_content "Verified"
        expect(page).to have_no_content "published automatically"
        expect(page).to have_no_button "Verify"

        visit "#{project.path}#{pls.path}/overview"
        expect(page).to have_content "Private Hostname"
        expect(page).to have_content pg.private_hostname

        pls.update(postgres_resource_id: nil)
        visit "#{project.path}#{pls.path}/settings"
        expect(page).to have_content "Attach a PostgreSQL resource"
      end

      it "explains that there is no private DNS name without a resource whose zone Ubicloud serves" do
        visit "#{project.path}#{pls.path}/settings"
        expect(page).to have_content "No private DNS name"
        expect(page).to have_no_field "private_dns_name"
      end

      it "shows the validation error and keeps the stored principals when a new one is not an IAM ARN" do
        visit "#{project.path}#{pls.path}/settings"
        fill_in "allowed_principals[]", with: "arn:aws:sts::123456789012:assumed-role/app/session"
        click_button "Save principals"

        expect(page).to have_content "invalid: arn:aws:sts::123456789012:assumed-role/app/session"
        expect(pls.reload.allowed_principals).to eq ["arn:aws:iam::123456789012:root"]
        expect(pls.update_permissions_set?).to be false
      end

      it "gates the settings cards on PrivateLinkService:edit and the delete button on PrivateLinkService:delete" do
        pls
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateLinkService:view"])

        visit "#{project.path}#{pls.path}/settings"
        expect(page.status_code).to eq 200
        expect(page).to have_no_button "Save principals"
        expect(page).to have_no_css ".delete-btn"

        edit_ace = AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateLinkService:edit"])
        page.refresh
        expect(page).to have_button "Save principals"
        expect(page).to have_no_css ".delete-btn"

        edit_ace.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: user.id, action_id: ActionType::NAME_MAP["PrivateLinkService:delete"])
        page.refresh
        expect(page).to have_no_button "Save principals"
        expect(page).to have_css ".delete-btn"
      end
    end
  end
end
