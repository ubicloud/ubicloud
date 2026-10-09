# frozen_string_literal: true

RSpec.describe Prog::Vnet::Aws::PrivateLinkServiceNexus do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-prj") }

  let(:aws_location) do
    loc = Location.create(
      name: "us-west-2", provider: "aws", project_id: project.id,
      display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true,
    )
    LocationCredentialAws.create_with_id(loc, access_key: "stubbed-akid", secret_key: "stubbed-secret")
    loc
  end

  let(:pls) do
    ps = PrivateSubnet.create(name: "test-ps", project_id: project.id, location_id: aws_location.id, net4: "10.0.0.0/26", net6: "fdfa::/64")
    ps_aws = PrivateSubnetAwsResource.create_with_id(ps, vpc_id: "vpc-0123456789abcdef0", user_security_group_id: "sg-0123456789abcdef0")
    %w[a b].each_with_index do |az, i|
      az_row = LocationAz.create(location_id: aws_location.id, az:, zone_id: "usw2-az#{i + 1}")
      AwsSubnet.create(private_subnet_aws_resource_id: ps_aws.id, location_aws_az_id: az_row.id, subnet_id: "subnet-#{az}", ipv4_cidr: "10.0.#{i}.0/24", ipv6_cidr: "fdfa:#{i}::/64")
    end
    pls = PrivateLinkService.create(name: "test-es", project_id: project.id, location_id: ps.location_id, private_subnet_id: ps.id)
    PrivateLinkServicePort.import([:private_link_service_id, :port, :target_port], [[pls.id, 5432, 5432], [pls.id, 6432, 6432]])
    PrivateLinkServiceAwsResource.create_with_id(pls)
    PrivateLinkServicePortAwsResource.import([:id], pls.ports_dataset.select_map(:id).zip)
    pls
  end

  let(:st) { Strand.create_with_id(pls, prog: "Vnet::Aws::PrivateLinkServiceNexus", label: "start") }
  let(:nlb_arn) { "arn:aws:elasticloadbalancing:us-west-2:123456789012:loadbalancer/net/pls-x/abc" }

  let(:elbv2) { Aws::ElasticLoadBalancingV2::Client.new(stub_responses: true) }
  let(:ec2) { Aws::EC2::Client.new(stub_responses: true) }

  before do
    aws_credentials = Aws::Credentials.new("stubbed-akid", "stubbed-secret")
    allow(Aws::Credentials).to receive(:new).with("stubbed-akid", "stubbed-secret").and_return(aws_credentials)
    allow(Aws::ElasticLoadBalancingV2::Client).to receive(:new).with(credentials: aws_credentials, region: "us-west-2").and_return(elbv2)
    allow(Aws::EC2::Client).to receive(:new).with(credentials: aws_credentials, region: "us-west-2").and_return(ec2)
  end

  def port(number)
    pls.ports_dataset.first(port: number)
  end

  def aws
    PrivateLinkServiceAwsResource[pls.id]
  end

  def nlb_port(number)
    port(number).private_link_service_port_aws_resource
  end

  # What AWS reports for an endpoint service configuration.
  def service_configuration(service_id: "vpce-svc-0123456789abcdef0", state: "Available", private_dns_name: nil, dns: nil, acceptance_required: true, regions: [], closed_regions: [])
    supported_regions = regions.map { {region: it, service_state: "Available"} } + closed_regions.map { {region: it, service_state: "Closed"} }
    {service_id:, service_name: "com.amazonaws.vpce.us-west-2.#{service_id}", service_state: state,
     acceptance_required:, supported_regions:, private_dns_name:, private_dns_name_configuration: dns}
  end

  def configuration(private_dns_name: nil, dns: nil)
    {service_configurations: [service_configuration(service_id: "vpce-svc-1", private_dns_name:, dns:)]}
  end

  def txt(state)
    {state:, type: "TXT", name: "_abc123", value: "vpce:xyz789"}
  end

  def managed_zone(with_vm: true)
    zone = DnsZone.create(project_id: project.id, name: "c0.example.com")
    Strand.create_with_id(zone, prog: "DnsZone::DnsZoneNexus", label: "wait")
    server = DnsServer.create(name: "ns.c0.example.com")
    zone.add_dns_server(server)
    server.add_vm(create_vm(project_id: project.id, name: "dns-vm")) if with_vm
    zone
  end

  def settle_records(zone)
    zone.records_dataset.update(created_at: Time.now - described_class::PRIVATE_DNS_RECORD_SETTLE_SECONDS - 1)
  end

  # Returns the primary's VM.
  def attach_postgres_primary
    allow(Config).to receive(:postgres_service_project_id).and_return(Project.create(name: "postgres-service").id)
    pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id, location_id: pls.location.id, name: "pg-aws",
      target_vm_size: "standard-2", target_storage_size_gib: 128, target_version: "16",
    ).subject
    pg.update(private_subnet_id: pls.private_subnet_id)
    pls.attach_postgres_resource(pg)
    pg.representative_server.vm
  end

  it "classifies every label: the ones from wait up to destroy as background, destroy and after as teardown" do
    labels = described_class.labels.map(&:to_s)
    expect(labels.drop_while { it != "wait" }.take_while { it != "destroy" }).to match_array(described_class::BACKGROUND_LABELS)
    expect(labels.drop_while { it != "destroy" }).to eq described_class::DESTROY_LABELS
  end

  describe "#start" do
    before { Strand.create_with_id(pls.private_subnet, prog: "Vnet::Aws::VpcNexus", label: "start") }

    it "naps until the private subnet is ready" do
      expect { nx.start }.to nap(10)
    end

    it "registers a deadline and starts the reconcile chain once the subnet waits" do
      pls.private_subnet.strand.update(label: "wait")
      expect(nx).to receive(:register_deadline).with("wait", 15 * 60)
      expect { nx.start }.to hop("ensure_target_groups")
    end
  end

  describe "#wait" do
    it "naps for hours without a private DNS name to verify" do
      expect { nx.wait }.to nap(5 * 60 * 60)
    end

    it "naps for hours once the private DNS name is verified" do
      pls.update(private_dns_name: "db.example.com")
      aws.update(private_dns_verification_state: "verified")
      expect { nx.wait }.to nap(5 * 60 * 60)
    end

    it "runs the reconcile chain again when requested, under a deadline back to wait" do
      nx.incr_reconcile
      expect(nx).to receive(:register_deadline).with("wait", 15 * 60)
      expect { nx.wait }.to hop("ensure_target_groups")
      expect(pls.reconcile_set?).to be false
    end

    it "hops to update_permissions under a deadline when a principals change is requested" do
      nx.incr_update_permissions
      expect(nx).to receive(:register_deadline).with("wait", 10 * 60)
      expect(ec2).not_to receive(:describe_vpc_endpoint_service_permissions)

      expect { nx.wait }.to hop("update_permissions")
      expect(pls.update_permissions_set?).to be true
    end

    it "hops to reconcile_connections under a deadline when the approved endpoints changed, keeping the request for that label" do
      nx.incr_reconcile_connections
      expect(nx).to receive(:register_deadline).with("wait", 10 * 60)
      expect(ec2).not_to receive(:describe_vpc_endpoint_connections)

      expect { nx.wait }.to hop("reconcile_connections")
      expect(pls.reconcile_connections_set?).to be true
    end

    it "hops to verify_private_dns when a check is due" do
      pls.update(private_dns_name: "db.example.com")
      expect { nx.wait }.to hop("verify_private_dns")
    end

    it "naps until the next private DNS check while the name is unverified" do
      pls.update(private_dns_name: "db.example.com")
      aws.update(private_dns_verification_attempted_at: Time.now)
      expect { nx.wait }.to nap(30 * 60)
    end
  end

  describe "#destroy" do
    it "registers a deadline, resolves a failed-NLB page and starts the teardown chain" do
      pls.incr_destroy
      Prog::PageNexus.assemble("NLB failed", ["PrivateLinkServiceNlbFailed", pls.id], [pls.ubid], resource_id: pls.id)
      expect(nx).to receive(:register_deadline).with(nil, 15 * 60)
      expect { nx.destroy }.to hop("recover_unrecorded_ids")
      expect(pls.destroy_set?).to be false
      expect(Page.from_tag_parts("PrivateLinkServiceNlbFailed", pls.id).resolve_set?).to be true
    end

    it "starts the teardown chain when no page is open" do
      pls.incr_destroy
      expect { nx.destroy }.to hop("recover_unrecorded_ids")
      expect(Page.where(resource_id: pls.id).count).to eq 0
    end
  end

  describe "#recover_unrecorded_ids" do
    let(:tail) { pls.ubid[-20..] }
    let(:nlb_arn) { "arn:aws:elasticloadbalancing:us-west-2:123456789012:loadbalancer/net/pl-#{tail}/abc" }

    it "records the NLB, target groups, listeners and endpoint service found by name or tag when nothing is recorded" do
      elbv2.stub_responses(:describe_load_balancers, ->(ctx) {
        expect(ctx.params[:names]).to eq ["pl-#{tail}"]
        {load_balancers: [{load_balancer_arn: nlb_arn}]}
      })
      elbv2.stub_responses(:describe_target_groups, ->(ctx) {
        expect(ctx.params[:names]).to match([/\Apl-\d+-#{tail}\z/])
        {target_groups: [{target_group_arn: "arn:tg:#{ctx.params[:names].first}"}]}
      })
      elbv2.stub_responses(:describe_listeners, ->(ctx) {
        expect(ctx.params[:load_balancer_arn]).to eq nlb_arn
        {listeners: [{listener_arn: "arn:listener:5432", port: 5432}, {listener_arn: "arn:listener:6432", port: 6432}]}
      })
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, ->(ctx) {
        expect(ctx.params[:filters]).to eq [{name: "tag:ubid", values: [pls.ubid]}]
        {service_configurations: [service_configuration(service_id: "vpce-svc-old", state: "Deleted", dns: txt("pendingVerification")), service_configuration(service_id: "vpce-svc-recovered", dns: txt("pendingVerification"))]}
      })
      allow(Clog).to receive(:emit).and_call_original
      expect(Clog).to receive(:emit).with("private link service recovered an unrecorded AWS resource", hash_including(private_link_service_recovered: hash_including(ubid: pls.ubid))).exactly(6).times.and_call_original

      expect { nx.recover_unrecorded_ids }.to hop("delete_endpoint_service")
      row = aws
      expect(row.nlb_arn).to eq nlb_arn
      expect(nlb_port(5432).target_group_arn).to eq "arn:tg:pl-5432-#{tail}"
      expect(nlb_port(6432).target_group_arn).to eq "arn:tg:pl-6432-#{tail}"
      expect(nlb_port(5432).listener_arn).to eq "arn:listener:5432"
      expect(nlb_port(6432).listener_arn).to eq "arn:listener:6432"
      expect(row.service_id).to eq "vpce-svc-recovered"
      expect(row.service_name).to eq "com.amazonaws.vpce.us-west-2.vpce-svc-recovered"
      expect(row.private_dns_verification_name).to eq "_abc123"
    end

    it "leaves ids empty when AWS knows nothing under the derived names or tag" do
      elbv2.stub_responses(:describe_load_balancers, "LoadBalancerNotFound")
      elbv2.stub_responses(:describe_target_groups, "TargetGroupNotFound")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, service_configurations: [])
      expect(elbv2).not_to receive(:describe_listeners)

      expect { nx.recover_unrecorded_ids }.to hop("delete_endpoint_service")
      expect(aws.nlb_arn).to be_nil
      expect(aws.service_id).to be_nil
      expect(nlb_port(5432).target_group_arn).to be_nil
      expect(nlb_port(5432).listener_arn).to be_nil
    end

    it "asks AWS nothing when every id is recorded" do
      aws.update(nlb_arn:, service_id: "vpce-svc-1")
      [5432, 6432].each { nlb_port(it).update(target_group_arn: "arn:tg:#{it}", listener_arn: "arn:listener:#{it}") }
      expect(elbv2).not_to receive(:describe_load_balancers)
      expect(elbv2).not_to receive(:describe_target_groups)
      expect(elbv2).not_to receive(:describe_listeners)
      expect(ec2).not_to receive(:describe_vpc_endpoint_service_configurations)

      expect { nx.recover_unrecorded_ids }.to hop("delete_endpoint_service")
    end

    it "recovers only the listeners the NLB actually has" do
      aws.update(nlb_arn:, service_id: "vpce-svc-1")
      [5432, 6432].each { nlb_port(it).update(target_group_arn: "arn:tg:#{it}") }
      elbv2.stub_responses(:describe_listeners, listeners: [{listener_arn: "arn:listener:5432", port: 5432}])

      expect { nx.recover_unrecorded_ids }.to hop("delete_endpoint_service")
      expect(nlb_port(5432).listener_arn).to eq "arn:listener:5432"
      expect(nlb_port(6432).listener_arn).to be_nil
    end

    it "treats a recorded NLB that AWS no longer has as having no listeners" do
      aws.update(nlb_arn:, service_id: "vpce-svc-1")
      [5432, 6432].each { nlb_port(it).update(target_group_arn: "arn:tg:#{it}") }
      elbv2.stub_responses(:describe_listeners, "LoadBalancerNotFound")

      expect { nx.recover_unrecorded_ids }.to hop("delete_endpoint_service")
      expect(nlb_port(5432).listener_arn).to be_nil
    end
  end

  describe "#update_permissions" do
    before { aws.update(service_id: "vpce-svc-1") }

    it "applies the principals change, clears the request and returns to wait" do
      pls.update(allowed_principals: Sequel.pg_array(["arn:aws:iam::222222222222:root"], :text))
      nx.incr_update_permissions
      ec2.stub_responses(:describe_vpc_endpoint_service_permissions, allowed_principals: [{principal: "arn:aws:iam::111111111111:root", principal_type: "Account"}])
      ec2.stub_responses(:modify_vpc_endpoint_service_permissions, {})
      expect(ec2).to receive(:modify_vpc_endpoint_service_permissions).with(
        service_id: "vpce-svc-1",
        add_allowed_principals: ["arn:aws:iam::222222222222:root"],
        remove_allowed_principals: ["arn:aws:iam::111111111111:root"],
      ).and_call_original

      expect { nx.update_permissions }.to hop("wait")
      expect(pls.update_permissions_set?).to be false
      expect(pls.reconcile_set?).to be false
    end

    it "raises and keeps the request when AWS refuses, so the retry and the deadline see it" do
      nx.incr_update_permissions
      ec2.stub_responses(:describe_vpc_endpoint_service_permissions, "InvalidVpcEndpointServiceId.NotFound")

      expect { nx.update_permissions }.to raise_error(Aws::EC2::Errors::InvalidVpcEndpointServiceIdNotFound)
      expect(pls.update_permissions_set?).to be true
    end
  end

  describe "#reconcile_connections" do
    def connection(id, state, owner: "111111111111")
      {vpc_endpoint_id: id, vpc_endpoint_state: state, vpc_endpoint_owner: owner, ip_address_type: "ipv4", creation_timestamp: Time.utc(2026, 9, 21, 12, 0, 0), service_id: "vpce-svc-1"}
    end

    def approve(*ids, description: "")
      ids.each { PrivateLinkServiceAwsAllowedEndpoint.create(private_link_service_aws_resource_id: aws.id, vpc_endpoint_id: it, description:) }
    end

    it "clears the request and returns to wait without touching AWS before the service exists" do
      nx.incr_reconcile_connections
      expect(ec2).not_to receive(:describe_vpc_endpoint_connections)

      expect { nx.reconcile_connections }.to hop("wait")
      expect(pls.reconcile_connections_set?).to be false
    end

    it "logs every connection AWS lists with what it means and the owner's note, deciding nothing when nothing needs it" do
      aws.update(service_id: "vpce-svc-1")
      approve("vpce-a", description: "analytics team")
      approve("vpce-b")
      ec2.stub_responses(:describe_vpc_endpoint_connections, ->(ctx) {
        expect(ctx.params[:filters]).to eq [{name: "service-id", values: ["vpce-svc-1"]}]
        {vpc_endpoint_connections: [connection("vpce-a", "available"), connection("vpce-b", "rejected", owner: "222222222222"), connection("vpce-x", "pendingAcceptance"), connection("vpce-y", "deleted")]}
      })
      expect(ec2).to receive(:describe_vpc_endpoint_connections).once.and_call_original
      expect(ec2).not_to receive(:accept_vpc_endpoint_connections)
      expect(ec2).not_to receive(:reject_vpc_endpoint_connections)
      expect(Clog).to receive(:emit).with("private link service connections reconciled", {private_link_service_connections: {
        ubid: pls.ubid, allowed: {"vpce-a" => "analytics team", "vpce-b" => ""}, accept: [], reject: [],
        connections: [
          {id: "vpce-a", owner: "111111111111", state: "available", ip_address_type: "ipv4", created_at: Time.utc(2026, 9, 21, 12, 0, 0), note: "analytics team"},
          {id: "vpce-b", owner: "222222222222", state: "rejected", ip_address_type: "ipv4", created_at: Time.utc(2026, 9, 21, 12, 0, 0), note: ""},
          {id: "vpce-x", owner: "111111111111", state: "pendingAcceptance", ip_address_type: "ipv4", created_at: Time.utc(2026, 9, 21, 12, 0, 0), note: nil},
          {id: "vpce-y", owner: "111111111111", state: "deleted", ip_address_type: "ipv4", created_at: Time.utc(2026, 9, 21, 12, 0, 0), note: nil},
        ],
      }}).and_call_original

      expect { nx.reconcile_connections }.to hop("wait")
    end

    it "accepts waiting connections from approved endpoints, rejects established ones from any other, leaves unapproved waiting ones alone and logs refusals" do
      aws.update(service_id: "vpce-svc-1")
      approve("vpce-a", "vpce-b", "vpce-ok")
      ec2.stub_responses(:describe_vpc_endpoint_connections, vpc_endpoint_connections: [
        connection("vpce-a", "pendingAcceptance"), connection("vpce-b", "pendingAcceptance"),
        connection("vpce-c", "available"), connection("vpce-d", "pendingAcceptance"), connection("vpce-e", "pending"),
        connection("vpce-ok", "available"), connection("vpce-old", "rejected"), connection("vpce-dead", "deleted"),
      ])
      ec2.stub_responses(:accept_vpc_endpoint_connections, unsuccessful: [{resource_id: "vpce-b", error: {code: "InvalidState", message: "already rejected"}}])
      ec2.stub_responses(:reject_vpc_endpoint_connections, unsuccessful: [])
      expect(ec2).to receive(:accept_vpc_endpoint_connections).with(service_id: "vpce-svc-1", vpc_endpoint_ids: ["vpce-a", "vpce-b"]).and_call_original
      expect(ec2).to receive(:reject_vpc_endpoint_connections).with(service_id: "vpce-svc-1", vpc_endpoint_ids: ["vpce-c", "vpce-e"]).and_call_original
      expect(Clog).to receive(:emit).with("private link service connections reconciled", hash_including(private_link_service_connections: hash_including(accept: ["vpce-a", "vpce-b"], reject: ["vpce-c", "vpce-e"]))).and_call_original
      expect(Clog).to receive(:emit).with("private link service connection decisions refused", {private_link_service_connections_refused: {ubid: pls.ubid, refused: [{id: "vpce-b", code: "InvalidState", message: "already rejected"}]}}).and_call_original

      expect { nx.reconcile_connections }.to hop("wait")
    end

    it "raises and keeps the request when AWS refuses the decision, so the retry and the deadline see it" do
      aws.update(service_id: "vpce-svc-1")
      approve("vpce-a")
      nx.incr_reconcile_connections
      ec2.stub_responses(:describe_vpc_endpoint_connections, vpc_endpoint_connections: [connection("vpce-a", "pendingAcceptance")])
      ec2.stub_responses(:accept_vpc_endpoint_connections, "UnauthorizedOperation")

      expect { nx.reconcile_connections }.to raise_error(Aws::EC2::Errors::UnauthorizedOperation)
      expect(pls.reconcile_connections_set?).to be true
    end

    it "walks every page of the connection list" do
      aws.update(service_id: "vpce-svc-1")
      ec2.stub_responses(:describe_vpc_endpoint_connections, {vpc_endpoint_connections: [connection("vpce-p1", "rejected")], next_token: "t"}, {vpc_endpoint_connections: [connection("vpce-p2", "rejected")]})
      expect(Clog).to receive(:emit).with("private link service connections reconciled", hash_including(private_link_service_connections: hash_including(connections: [hash_including(id: "vpce-p1"), hash_including(id: "vpce-p2")]))).and_call_original

      expect { nx.reconcile_connections }.to hop("wait")
    end
  end

  describe "#ensure_connections" do
    it "converges the connections as part of the chain and goes on to the private DNS step" do
      aws.update(service_id: "vpce-svc-1")
      ec2.stub_responses(:describe_vpc_endpoint_connections, vpc_endpoint_connections: [])

      expect { nx.ensure_connections }.to hop("ensure_private_dns_name")
    end
  end

  describe "#ensure_target_groups" do
    it "creates one TCP target group per port in the subnet's VPC and records the ARNs" do
      elbv2.stub_responses(:create_target_group, ->(ctx) {
        p = ctx.params
        expect(p[:protocol]).to eq "TCP"
        expect(p[:target_type]).to eq "ip"
        expect(p[:ip_address_type]).to eq "ipv4"
        expect(p[:vpc_id]).to eq "vpc-0123456789abcdef0"
        expect(p[:health_check_protocol]).to eq "TCP"
        expect(p[:health_check_port]).to eq p[:port].to_s
        expect(p[:name]).to match(/\Apl-#{p[:port]}-[a-z0-9]{20}\z/)
        expect(p[:name].length).to be <= 32
        expect(p[:tags]).to include({key: "Ubicloud", value: Config.provider_resource_tag_value}, {key: "ubid", value: pls.ubid})
        {target_groups: [{target_group_arn: "arn:aws:elasticloadbalancing:us-west-2:123456789012:targetgroup/#{p[:name]}/abc"}]}
      })
      expect(elbv2).not_to receive(:modify_target_group_attributes)

      expect { nx.ensure_target_groups }.to hop("ensure_target_group_attributes")
      expect(nlb_port(5432).target_group_arn).to end_with("targetgroup/pl-5432-#{pls.ubid[-20..]}/abc")
      expect(nlb_port(6432).target_group_arn).to end_with("targetgroup/pl-6432-#{pls.ubid[-20..]}/abc")
    end

    it "creates IPv6 target groups for an IPv6 service" do
      pls.update(ip_address_type: "ipv6")
      elbv2.stub_responses(:create_target_group, ->(ctx) {
        expect(ctx.params[:ip_address_type]).to eq "ipv6"
        {target_groups: [{target_group_arn: "arn:aws:elasticloadbalancing:us-west-2:123456789012:targetgroup/#{ctx.params[:name]}/abc"}]}
      })

      expect { nx.ensure_target_groups }.to hop("ensure_target_group_attributes")
      expect(nlb_port(5432).target_group_arn).to end_with("targetgroup/pl-5432-#{pls.ubid[-20..]}/abc")
    end

    it "skips creation for ports that already have a target group" do
      nlb_port(5432).update(target_group_arn: "arn:existing")
      elbv2.stub_responses(:create_target_group, target_groups: [{target_group_arn: "arn:new"}])
      expect(elbv2).to receive(:create_target_group).once.and_call_original

      expect { nx.ensure_target_groups }.to hop("ensure_target_group_attributes")
      expect(nlb_port(5432).target_group_arn).to eq "arn:existing"
      expect(nlb_port(6432).target_group_arn).to eq "arn:new"
    end

    it "recovers a target group created by an earlier run that died before recording it" do
      elbv2.stub_responses(:create_target_group, "DuplicateTargetGroupName")
      elbv2.stub_responses(:describe_target_groups, ->(ctx) {
        {target_groups: [{target_group_arn: "arn:recovered:#{ctx.params[:names].first}"}]}
      })
      expect(Clog).to receive(:emit).with("private link service recovered an unrecorded AWS resource", {private_link_service_recovered: {ubid: pls.ubid, kind: "target_group", id: "arn:recovered:pl-5432-#{pls.ubid[-20..]}", port: 5432}}).and_call_original
      expect(Clog).to receive(:emit).with("private link service recovered an unrecorded AWS resource", {private_link_service_recovered: {ubid: pls.ubid, kind: "target_group", id: "arn:recovered:pl-6432-#{pls.ubid[-20..]}", port: 6432}}).and_call_original

      expect { nx.ensure_target_groups }.to hop("ensure_target_group_attributes")
      expect(nlb_port(5432).target_group_arn).to eq "arn:recovered:pl-5432-#{pls.ubid[-20..]}"
    end
  end

  describe "#ensure_target_group_attributes" do
    before do
      nlb_port(5432).update(target_group_arn: "arn:tg:5432")
      nlb_port(6432).update(target_group_arn: "arn:tg:6432")
    end

    it "disables the deregistration delay and terminates connections on every target group that lacks them" do
      described = []
      elbv2.stub_responses(:describe_target_group_attributes, ->(ctx) {
        described << ctx.params[:target_group_arn]
        {attributes: [{key: "deregistration_delay.timeout_seconds", value: "300"}, {key: "deregistration_delay.connection_termination.enabled", value: "false"}]}
      })
      modified = []
      elbv2.stub_responses(:modify_target_group_attributes, ->(ctx) {
        modified << ctx.params[:target_group_arn]
        expect(ctx.params[:attributes]).to contain_exactly(
          {key: "deregistration_delay.timeout_seconds", value: "0"},
          {key: "deregistration_delay.connection_termination.enabled", value: "true"},
        )
        {}
      })

      expect { nx.ensure_target_group_attributes }.to hop("ensure_targets")
      expect(described).to contain_exactly("arn:tg:5432", "arn:tg:6432")
      expect(modified).to contain_exactly("arn:tg:5432", "arn:tg:6432")
    end

    it "only sends the attributes that differ and skips target groups that already match" do
      elbv2.stub_responses(:describe_target_group_attributes, ->(ctx) {
        if ctx.params[:target_group_arn] == "arn:tg:5432"
          {attributes: [{key: "deregistration_delay.timeout_seconds", value: "0"}, {key: "deregistration_delay.connection_termination.enabled", value: "true"}]}
        else
          {attributes: [{key: "deregistration_delay.timeout_seconds", value: "0"}, {key: "deregistration_delay.connection_termination.enabled", value: "false"}]}
        end
      })
      elbv2.stub_responses(:modify_target_group_attributes, {})
      expect(elbv2).to receive(:modify_target_group_attributes).once.with(target_group_arn: "arn:tg:6432", attributes: [{key: "deregistration_delay.connection_termination.enabled", value: "true"}]).and_call_original

      expect { nx.ensure_target_group_attributes }.to hop("ensure_targets")
    end

    it "raises when describing the target group attributes is denied, without trying to modify them" do
      elbv2.stub_responses(:describe_target_group_attributes, "AccessDenied")
      expect(elbv2).not_to receive(:modify_target_group_attributes)

      expect { nx.ensure_target_group_attributes }.to raise_error(Aws::ElasticLoadBalancingV2::Errors::AccessDenied)
    end

    it "raises when setting the target group attributes is denied, so the strand retries" do
      elbv2.stub_responses(:describe_target_group_attributes, attributes: [])
      elbv2.stub_responses(:modify_target_group_attributes, "AccessDenied")

      expect { nx.ensure_target_group_attributes }.to raise_error(Aws::ElasticLoadBalancingV2::Errors::AccessDenied)
    end
  end

  describe "#ensure_targets" do
    def health(*targets, state: "healthy")
      {target_health_descriptions: targets.map { |id, port| {target: {id:, port:}, target_health: {state:}} }}
    end

    before do
      nlb_port(5432).update(target_group_arn: "arn:tg-5432")
      nlb_port(6432).update(target_group_arn: "arn:tg-6432")
    end

    it "registers the PostgreSQL primary's private IPv4 on every port's target group and records it" do
      ip = attach_postgres_primary.private_ipv4.to_s
      elbv2.stub_responses(:describe_target_health, health)
      elbv2.stub_responses(:register_targets, {})
      expect(elbv2).to receive(:register_targets).with(target_group_arn: "arn:tg-5432", targets: [{id: ip, port: 5432}]).and_call_original
      expect(elbv2).to receive(:register_targets).with(target_group_arn: "arn:tg-6432", targets: [{id: ip, port: 6432}]).and_call_original
      expect(elbv2).not_to receive(:deregister_targets)

      expect { nx.ensure_targets }.to hop("ensure_nlb")
      expect(aws.registered_target_ips.map(&:to_s)).to eq [ip]
    end

    it "registers the primary's IPv6 on an IPv6 service" do
      pls.update(ip_address_type: "ipv6")
      attach_postgres_primary.update(ephemeral_net6: "2600:1f14:abc:de00::10/128")
      ip = "2600:1f14:abc:de00::10"
      elbv2.stub_responses(:describe_target_health, health)
      elbv2.stub_responses(:register_targets, {})
      expect(elbv2).to receive(:register_targets).with(target_group_arn: "arn:tg-5432", targets: [{id: ip, port: 5432}]).and_call_original
      expect(elbv2).to receive(:register_targets).with(target_group_arn: "arn:tg-6432", targets: [{id: ip, port: 6432}]).and_call_original

      expect { nx.ensure_targets }.to hop("ensure_nlb")
      expect(aws.registered_target_ips.map(&:to_s)).to eq [ip]
    end

    it "waits for the primary's IPv6 on an IPv6 service, which lands only once the instance runs" do
      pls.update(ip_address_type: "ipv6")
      attach_postgres_primary.update(ephemeral_net6: nil)
      expect(elbv2).not_to receive(:describe_target_health)
      expect(elbv2).not_to receive(:register_targets)

      expect { nx.ensure_targets }.to nap(10)
      expect(aws.registered_target_ips).to eq []
    end

    it "waits for a primary whose VM has no user NIC yet" do
      attach_postgres_primary.user_nic.update(vm_id: nil)
      expect(elbv2).not_to receive(:register_targets)

      expect { nx.ensure_targets }.to nap(10)
      expect(aws.registered_target_ips).to eq []
    end

    it "moves the target after a failover: deregisters the old primary and registers the new one" do
      ip = attach_postgres_primary.private_ipv4.to_s
      elbv2.stub_responses(:describe_target_health, ->(ctx) { health(["172.25.1.233", (ctx.params[:target_group_arn] == "arn:tg-5432") ? 5432 : 6432]) })
      elbv2.stub_responses(:register_targets, {})
      elbv2.stub_responses(:deregister_targets, {})
      expect(elbv2).to receive(:register_targets).with(target_group_arn: "arn:tg-5432", targets: [{id: ip, port: 5432}]).and_call_original
      expect(elbv2).to receive(:register_targets).with(target_group_arn: "arn:tg-6432", targets: [{id: ip, port: 6432}]).and_call_original
      expect(elbv2).to receive(:deregister_targets).with(target_group_arn: "arn:tg-5432", targets: [{id: "172.25.1.233", port: 5432}]).and_call_original
      expect(elbv2).to receive(:deregister_targets).with(target_group_arn: "arn:tg-6432", targets: [{id: "172.25.1.233", port: 6432}]).and_call_original

      expect { nx.ensure_targets }.to hop("ensure_nlb")
      expect(aws.registered_target_ips.map(&:to_s)).to eq [ip]
    end

    it "does nothing when the registered set already matches" do
      ip = attach_postgres_primary.private_ipv4.to_s
      elbv2.stub_responses(:describe_target_health, ->(ctx) { health([ip, (ctx.params[:target_group_arn] == "arn:tg-5432") ? 5432 : 6432]) })
      expect(elbv2).not_to receive(:register_targets)
      expect(elbv2).not_to receive(:deregister_targets)

      expect { nx.ensure_targets }.to hop("ensure_nlb")
    end

    it "deregisters everything when there is no target, and skips ports without a target group" do
      nlb_port(6432).update(target_group_arn: nil)
      elbv2.stub_responses(:describe_target_health, health(["172.25.1.233", 5432]))
      elbv2.stub_responses(:deregister_targets, {})
      expect(elbv2).to receive(:describe_target_health).once.and_call_original
      expect(elbv2).to receive(:deregister_targets).once.and_call_original

      expect { nx.ensure_targets }.to hop("ensure_nlb")
      expect(aws.registered_target_ips).to eq []
    end

    it "re-registers a wanted target that is still draining from an earlier detach" do
      ip = attach_postgres_primary.private_ipv4.to_s
      elbv2.stub_responses(:describe_target_health, ->(ctx) { health([ip, (ctx.params[:target_group_arn] == "arn:tg-5432") ? 5432 : 6432], state: "draining") })
      elbv2.stub_responses(:register_targets, {})
      expect(elbv2).to receive(:register_targets).twice.and_call_original
      expect(elbv2).not_to receive(:deregister_targets)

      expect { nx.ensure_targets }.to hop("ensure_nlb")
    end

    it "does not deregister a target that is already draining" do
      elbv2.stub_responses(:describe_target_health, health(["172.25.1.233", 5432], state: "draining"))
      expect(elbv2).not_to receive(:deregister_targets)

      expect { nx.ensure_targets }.to hop("ensure_nlb")
    end

    it "tolerates a stale target that AWS already dropped" do
      elbv2.stub_responses(:describe_target_health, health(["172.25.1.233", 5432]))
      elbv2.stub_responses(:deregister_targets, "InvalidTarget")

      expect { nx.ensure_targets }.to hop("ensure_nlb")
    end
  end

  describe "#ensure_nlb" do
    it "creates an internal cross-zone NLB over the AZ subnets and records it" do
      elbv2.stub_responses(:create_load_balancer, ->(ctx) {
        p = ctx.params
        expect(p[:type]).to eq "network"
        expect(p[:scheme]).to eq "internal"
        expect(p[:ip_address_type]).to eq "ipv4"
        expect(p[:subnets]).to contain_exactly("subnet-a", "subnet-b")
        expect(p[:name]).to eq "pl-#{pls.ubid[-20..]}"
        expect(p[:tags]).to include({key: "ubid", value: pls.ubid})
        expect(p[:security_groups]).to eq ["sg-0123456789abcdef0"]
        {load_balancers: [{load_balancer_arn: nlb_arn}]}
      })
      expect(elbv2).not_to receive(:modify_load_balancer_attributes)

      expect { nx.ensure_nlb }.to hop("ensure_nlb_attributes")
      expect(aws.nlb_arn).to eq nlb_arn
    end

    it "uses the subnet's user security group without asking AWS about the primary's interface" do
      attach_postgres_primary
      expect(ec2).not_to receive(:describe_network_interfaces)
      elbv2.stub_responses(:create_load_balancer, ->(ctx) {
        expect(ctx.params[:security_groups]).to eq ["sg-0123456789abcdef0"]
        {load_balancers: [{load_balancer_arn: nlb_arn}]}
      })

      expect { nx.ensure_nlb }.to hop("ensure_nlb_attributes")
    end

    it "creates the NLB without security groups when the subnet has none yet" do
      pls.private_subnet.private_subnet_aws_resource.update(user_security_group_id: nil)
      elbv2.stub_responses(:create_load_balancer, ->(ctx) {
        expect(ctx.params).not_to have_key(:security_groups)
        {load_balancers: [{load_balancer_arn: nlb_arn}]}
      })

      expect { nx.ensure_nlb }.to hop("ensure_nlb_attributes")
    end

    it "creates a dual-stack NLB when the service advertises IPv6" do
      pls.update(ip_address_type: "dual")
      elbv2.stub_responses(:create_load_balancer, ->(ctx) {
        expect(ctx.params[:ip_address_type]).to eq "dualstack"
        {load_balancers: [{load_balancer_arn: nlb_arn}]}
      })

      expect { nx.ensure_nlb }.to hop("ensure_nlb_attributes")
    end

    it "recovers an NLB created by an earlier run that died before recording it" do
      elbv2.stub_responses(:create_load_balancer, "DuplicateLoadBalancerName")
      elbv2.stub_responses(:describe_load_balancers, load_balancers: [{load_balancer_arn: nlb_arn}])
      expect(Clog).to receive(:emit).with("private link service recovered an unrecorded AWS resource", {private_link_service_recovered: {ubid: pls.ubid, kind: "nlb", id: nlb_arn}}).and_call_original

      expect { nx.ensure_nlb }.to hop("ensure_nlb_attributes")
      expect(aws.nlb_arn).to eq nlb_arn
    end

    it "skips creation when the NLB is already recorded" do
      aws.update(nlb_arn:)
      expect(elbv2).not_to receive(:create_load_balancer)

      expect { nx.ensure_nlb }.to hop("ensure_nlb_attributes")
    end

    it "naps until the private subnet's AWS subnets exist" do
      AwsSubnet.where(private_subnet_aws_resource_id: pls.private_subnet_id).update(subnet_id: nil)
      expect(elbv2).not_to receive(:create_load_balancer)

      expect { nx.ensure_nlb }.to nap(10)
    end
  end

  describe "#ensure_nlb_attributes" do
    before { aws.update(nlb_arn:) }

    it "enables cross-zone balancing when AWS reports it off" do
      elbv2.stub_responses(:describe_load_balancer_attributes, ->(ctx) {
        expect(ctx.params[:load_balancer_arn]).to eq nlb_arn
        {attributes: [{key: "load_balancing.cross_zone.enabled", value: "false"}, {key: "deletion_protection.enabled", value: "false"}]}
      })
      elbv2.stub_responses(:modify_load_balancer_attributes, {})
      expect(elbv2).to receive(:modify_load_balancer_attributes).with(load_balancer_arn: nlb_arn, attributes: [{key: "load_balancing.cross_zone.enabled", value: "true"}]).and_call_original

      expect { nx.ensure_nlb_attributes }.to hop("wait_nlb_active")
    end

    it "only describes when cross-zone balancing is already on" do
      elbv2.stub_responses(:describe_load_balancer_attributes, attributes: [{key: "load_balancing.cross_zone.enabled", value: "true"}])
      expect(elbv2).not_to receive(:modify_load_balancer_attributes)

      expect { nx.ensure_nlb_attributes }.to hop("wait_nlb_active")
    end

    it "raises when describing the NLB attributes is denied, keeping the recorded NLB" do
      elbv2.stub_responses(:describe_load_balancer_attributes, "AccessDenied")
      expect(elbv2).not_to receive(:modify_load_balancer_attributes)

      expect { nx.ensure_nlb_attributes }.to raise_error(Aws::ElasticLoadBalancingV2::Errors::AccessDenied)
      expect(aws.nlb_arn).to eq nlb_arn
    end

    it "raises when enabling cross-zone balancing is denied, so the strand retries" do
      elbv2.stub_responses(:describe_load_balancer_attributes, attributes: [])
      elbv2.stub_responses(:modify_load_balancer_attributes, "AccessDenied")

      expect { nx.ensure_nlb_attributes }.to raise_error(Aws::ElasticLoadBalancingV2::Errors::AccessDenied)
    end
  end

  describe "#wait_nlb_active" do
    before { aws.update(nlb_arn: "arn:nlb") }

    def failed_page
      Page.from_tag_parts("PrivateLinkServiceNlbFailed", pls.id)
    end

    it "hops to ensure_listeners once active" do
      elbv2.stub_responses(:describe_load_balancers, load_balancers: [{state: {code: "active"}}])
      expect { nx.wait_nlb_active }.to hop("ensure_listeners")
    end

    it "treats an impaired NLB as active, with a log line" do
      elbv2.stub_responses(:describe_load_balancers, load_balancers: [{state: {code: "active_impaired", reason: "AZ usw2-az2 is unhealthy"}}])
      expect(Clog).to receive(:emit).with("private link service NLB active but impaired", hash_including(private_link_service_nlb_impaired: hash_including(reason: "AZ usw2-az2 is unhealthy"))).and_call_original
      expect { nx.wait_nlb_active }.to hop("ensure_listeners")
    end

    it "naps while provisioning" do
      elbv2.stub_responses(:describe_load_balancers, load_balancers: [{state: {code: "provisioning"}}])
      expect { nx.wait_nlb_active }.to nap(10)
    end

    it "logs and naps longer on a state it does not know" do
      elbv2.stub_responses(:describe_load_balancers, load_balancers: [{state: {code: "mystery"}}])
      expect(Clog).to receive(:emit).with("private link service NLB in unknown state", hash_including(private_link_service_nlb_state: hash_including(state: "mystery"))).and_call_original
      expect { nx.wait_nlb_active }.to nap(30)
    end

    it "pages with AWS's reason when provisioning failed, and resolves the page once the NLB is active" do
      elbv2.stub_responses(:describe_load_balancers, load_balancers: [{state: {code: "failed", reason: "Insufficient capacity in subnet-a"}}])
      expect { nx.wait_nlb_active }.to nap(60)
      page = failed_page
      expect(page.summary).to eq "Private link service #{pls.ubid} NLB failed to provision: Insufficient capacity in subnet-a"
      expect(page.details["reason"]).to eq "Insufficient capacity in subnet-a"
      expect(page.details["arn"]).to eq "arn:nlb"

      expect { nx.wait_nlb_active }.to nap(60)
      expect(Page.active.where(tag: page.tag).count).to eq 1

      elbv2.stub_responses(:describe_load_balancers, load_balancers: [{state: {code: "active"}}])
      expect { nx.wait_nlb_active }.to hop("ensure_listeners")
      expect(page.reload.resolve_set?).to be true
    end
  end

  describe "#ensure_listeners" do
    before do
      aws.update(nlb_arn: "arn:nlb")
      nlb_port(5432).update(target_group_arn: "arn:tg-5432")
      nlb_port(6432).update(target_group_arn: "arn:tg-6432")
    end

    it "creates one TCP listener per port forwarding to its target group and records the ARNs" do
      elbv2.stub_responses(:create_listener, ->(ctx) {
        p = ctx.params
        expect(p[:load_balancer_arn]).to eq "arn:nlb"
        expect(p[:protocol]).to eq "TCP"
        expect(p[:default_actions]).to eq [{type: "forward", target_group_arn: "arn:tg-#{p[:port]}"}]
        {listeners: [{listener_arn: "arn:listener-#{p[:port]}"}]}
      })

      expect { nx.ensure_listeners }.to hop("ensure_endpoint_service")
      expect(nlb_port(5432).listener_arn).to eq "arn:listener-5432"
      expect(nlb_port(6432).listener_arn).to eq "arn:listener-6432"
    end

    it "recovers a listener created by an earlier run by matching its port" do
      elbv2.stub_responses(:create_listener, "DuplicateListener")
      elbv2.stub_responses(:describe_listeners, listeners: [{listener_arn: "arn:recovered-6432", port: 6432}, {listener_arn: "arn:recovered-5432", port: 5432}])
      expect(Clog).to receive(:emit).with("private link service recovered an unrecorded AWS resource", {private_link_service_recovered: {ubid: pls.ubid, kind: "listener", id: "arn:recovered-5432", port: 5432}}).and_call_original
      expect(Clog).to receive(:emit).with("private link service recovered an unrecorded AWS resource", {private_link_service_recovered: {ubid: pls.ubid, kind: "listener", id: "arn:recovered-6432", port: 6432}}).and_call_original

      expect { nx.ensure_listeners }.to hop("ensure_endpoint_service")
      expect(nlb_port(5432).listener_arn).to eq "arn:recovered-5432"
      expect(nlb_port(6432).listener_arn).to eq "arn:recovered-6432"
    end

    it "skips ports that already have a listener" do
      nlb_port(5432).update(listener_arn: "arn:existing")
      elbv2.stub_responses(:create_listener, listeners: [{listener_arn: "arn:new"}])
      expect(elbv2).to receive(:create_listener).once.and_call_original

      expect { nx.ensure_listeners }.to hop("ensure_endpoint_service")
      expect(nlb_port(5432).listener_arn).to eq "arn:existing"
      expect(nlb_port(6432).listener_arn).to eq "arn:new"
    end
  end

  describe "#ensure_endpoint_service" do
    before { aws.update(nlb_arn:) }

    it "creates the service configuration on the NLB and records id and name" do
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, ->(ctx) {
        expect(ctx.params[:filters]).to eq [{name: "tag:ubid", values: [pls.ubid]}]
        {service_configurations: []}
      })
      ec2.stub_responses(:create_vpc_endpoint_service_configuration, ->(ctx) {
        p = ctx.params
        expect(p[:network_load_balancer_arns]).to eq [nlb_arn]
        expect(p[:acceptance_required]).to be true
        expect(p[:supported_ip_address_types]).to eq ["ipv4"]
        expect(p[:client_token]).to eq pls.ubid
        expect(p).not_to have_key(:private_dns_name)
        expect(p).not_to have_key(:supported_regions)
        expect(p[:tag_specifications]).to eq [{resource_type: "vpc-endpoint-service", tags: Util.aws_tags("pl-#{pls.ubid[-20..]}", {"ubid" => pls.ubid})}]
        {service_configuration: service_configuration(state: "Pending")}
      })

      expect { nx.ensure_endpoint_service }.to hop("ensure_service_configuration")
      row = aws
      expect(row.service_id).to eq "vpce-svc-0123456789abcdef0"
      expect(row.service_name).to eq "com.amazonaws.vpce.us-west-2.vpce-svc-0123456789abcdef0"
      expect(row.private_dns_verification_state).to be_nil
    end

    it "passes IPv6, the private DNS name and extra regions through and records the TXT verification record" do
      pls.update(private_dns_name: "db.example.com", ip_address_type: "dual")
      aws.update(supported_regions: Sequel.pg_array(["eu-west-1", "us-east-1"], :text))
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, service_configurations: [])
      ec2.stub_responses(:create_vpc_endpoint_service_configuration, ->(ctx) {
        p = ctx.params
        expect(p[:acceptance_required]).to be true
        expect(p[:supported_ip_address_types]).to eq ["ipv4", "ipv6"]
        expect(p[:private_dns_name]).to eq "db.example.com"
        expect(p[:supported_regions]).to eq ["eu-west-1", "us-east-1"]
        {service_configuration: service_configuration(regions: ["eu-west-1", "us-east-1"], dns: txt("pendingVerification"))}
      })

      expect { nx.ensure_endpoint_service }.to hop("ensure_service_configuration")
      row = aws
      expect(row.private_dns_verification_state).to eq "pendingVerification"
      expect(row.private_dns_verification_name).to eq "_abc123"
      expect(row.private_dns_verification_value).to eq "vpce:xyz789"
    end

    it "adopts a live service created by an earlier run that died before recording it, ignoring deleted ones" do
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, service_configurations: [
        service_configuration(service_id: "vpce-svc-old", state: "Deleted"),
        service_configuration,
      ])
      expect(ec2).not_to receive(:create_vpc_endpoint_service_configuration)

      expect { nx.ensure_endpoint_service }.to hop("ensure_service_configuration")
      expect(aws.service_id).to eq "vpce-svc-0123456789abcdef0"
    end

    it "asks AWS nothing when the service is already recorded" do
      aws.update(service_id: "vpce-svc-0123456789abcdef0")
      expect(ec2).not_to receive(:describe_vpc_endpoint_service_configurations)
      expect(ec2).not_to receive(:create_vpc_endpoint_service_configuration)

      expect { nx.ensure_endpoint_service }.to hop("ensure_service_configuration")
    end
  end

  describe "#ensure_service_configuration" do
    it "only describes the service when its configuration already matches the database" do
      aws.update(service_id: "vpce-svc-0123456789abcdef0", supported_regions: Sequel.pg_array(["us-east-1"], :text))
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, ->(ctx) {
        expect(ctx.params[:service_ids]).to eq ["vpce-svc-0123456789abcdef0"]
        {service_configurations: [service_configuration(regions: ["us-east-1"])]}
      })
      expect(ec2).not_to receive(:modify_vpc_endpoint_service_configuration)

      expect { nx.ensure_service_configuration }.to hop("ensure_permissions")
    end

    it "turns acceptance back on and converges supported regions onto the database in one modify call" do
      aws.update(service_id: "vpce-svc-0123456789abcdef0", supported_regions: Sequel.pg_array(["eu-west-1", "us-east-1"], :text))
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, service_configurations: [service_configuration(acceptance_required: false, regions: ["us-east-1", "ap-south-1"])])
      ec2.stub_responses(:modify_vpc_endpoint_service_configuration, {})
      expect(ec2).to receive(:modify_vpc_endpoint_service_configuration).with(
        service_id: "vpce-svc-0123456789abcdef0", acceptance_required: true, add_supported_regions: ["eu-west-1"], remove_supported_regions: ["ap-south-1"],
      ).and_call_original

      expect { nx.ensure_service_configuration }.to hop("ensure_permissions")
    end

    it "only removes regions when the database has none, ignoring the home region AWS reports" do
      aws.update(service_id: "vpce-svc-0123456789abcdef0")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, service_configurations: [service_configuration(regions: ["us-west-2", "us-east-1"])])
      ec2.stub_responses(:modify_vpc_endpoint_service_configuration, {})
      expect(ec2).to receive(:modify_vpc_endpoint_service_configuration).with(service_id: "vpce-svc-0123456789abcdef0", remove_supported_regions: ["us-east-1"]).and_call_original

      expect { nx.ensure_service_configuration }.to hop("ensure_permissions")
    end

    it "treats Closed regions as unsupported: re-adds a wanted one and never tries to remove one" do
      aws.update(service_id: "vpce-svc-0123456789abcdef0", supported_regions: Sequel.pg_array(["us-east-2"], :text))
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, service_configurations: [service_configuration(regions: ["us-west-2", "us-east-1"], closed_regions: ["us-east-2", "us-west-1"])])
      ec2.stub_responses(:modify_vpc_endpoint_service_configuration, {})
      expect(ec2).to receive(:modify_vpc_endpoint_service_configuration).with(
        service_id: "vpce-svc-0123456789abcdef0", add_supported_regions: ["us-east-2"], remove_supported_regions: ["us-east-1"],
      ).and_call_original

      expect { nx.ensure_service_configuration }.to hop("ensure_permissions")
    end
  end

  describe "#ensure_permissions" do
    before do
      aws.update(service_id: "vpce-svc-1")
      pls.update(allowed_principals: Sequel.pg_array(["arn:aws:iam::111111111111:root", "arn:aws:iam::222222222222:role/app"], :text))
    end

    def permissions(*principals, next_token: nil)
      {allowed_principals: principals.map { {principal: it, principal_type: "Account"} }, next_token:}
    end

    it "adds missing principals and removes stale ones in one call" do
      ec2.stub_responses(:describe_vpc_endpoint_service_permissions, ->(ctx) {
        expect(ctx.params[:service_id]).to eq "vpce-svc-1"
        permissions("arn:aws:iam::111111111111:root", "arn:aws:iam::333333333333:root")
      })
      ec2.stub_responses(:modify_vpc_endpoint_service_permissions, {})
      expect(ec2).to receive(:modify_vpc_endpoint_service_permissions).with(
        service_id: "vpce-svc-1",
        add_allowed_principals: ["arn:aws:iam::222222222222:role/app"],
        remove_allowed_principals: ["arn:aws:iam::333333333333:root"],
      ).and_call_original

      expect { nx.ensure_permissions }.to hop("ensure_connections")
    end

    it "only adds when nothing is stale, reading every page of the current list" do
      pls.update(allowed_principals: Sequel.pg_array(["*"], :text))
      ec2.stub_responses(:describe_vpc_endpoint_service_permissions, permissions("arn:aws:iam::111111111111:root", next_token: "page2"), permissions("arn:aws:iam::222222222222:role/app"))
      ec2.stub_responses(:modify_vpc_endpoint_service_permissions, {})
      expect(ec2).to receive(:modify_vpc_endpoint_service_permissions).with(
        service_id: "vpce-svc-1",
        add_allowed_principals: ["*"],
        remove_allowed_principals: ["arn:aws:iam::111111111111:root", "arn:aws:iam::222222222222:role/app"],
      ).and_call_original

      expect { nx.ensure_permissions }.to hop("ensure_connections")
    end

    it "only removes when the column is empty" do
      pls.update(allowed_principals: Sequel.pg_array([], :text))
      ec2.stub_responses(:describe_vpc_endpoint_service_permissions, permissions("arn:aws:iam::111111111111:root"))
      ec2.stub_responses(:modify_vpc_endpoint_service_permissions, {})
      expect(ec2).to receive(:modify_vpc_endpoint_service_permissions).with(service_id: "vpce-svc-1", remove_allowed_principals: ["arn:aws:iam::111111111111:root"]).and_call_original

      expect { nx.ensure_permissions }.to hop("ensure_connections")
    end

    it "only adds when AWS has none yet" do
      ec2.stub_responses(:describe_vpc_endpoint_service_permissions, permissions)
      ec2.stub_responses(:modify_vpc_endpoint_service_permissions, {})
      expect(ec2).to receive(:modify_vpc_endpoint_service_permissions).with(service_id: "vpce-svc-1", add_allowed_principals: ["arn:aws:iam::111111111111:root", "arn:aws:iam::222222222222:role/app"]).and_call_original

      expect { nx.ensure_permissions }.to hop("ensure_connections")
    end

    it "does nothing when AWS already matches, regardless of order" do
      ec2.stub_responses(:describe_vpc_endpoint_service_permissions, permissions("arn:aws:iam::222222222222:role/app", "arn:aws:iam::111111111111:root"))
      expect(ec2).not_to receive(:modify_vpc_endpoint_service_permissions)

      expect { nx.ensure_permissions }.to hop("ensure_connections")
    end
  end

  describe "#ensure_private_dns_name" do
    before { aws.update(service_id: "vpce-svc-1") }

    it "leaves the name alone and goes on to verification when it already matches" do
      pls.update(private_dns_name: "db.example.com")
      aws.update(private_dns_verification_state: "pendingVerification", private_dns_verification_name: "_abc123", private_dns_verification_value: "vpce:xyz789")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration(private_dns_name: "db.example.com", dns: txt("pendingVerification")))
      expect(ec2).not_to receive(:modify_vpc_endpoint_service_configuration)

      expect { nx.ensure_private_dns_name }.to hop("verify_private_dns")
      expect(aws.private_dns_verification_name).to eq "_abc123"
    end

    it "asks AWS nothing beyond the describe when neither side has a name" do
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration)
      expect(ec2).not_to receive(:modify_vpc_endpoint_service_configuration)

      expect { nx.ensure_private_dns_name }.to hop("verify_private_dns")
      expect(aws.private_dns_verification_state).to be_nil
    end

    it "removes a TXT record left behind when the name is already gone from the service" do
      zone = managed_zone
      zone.insert_record(record_name: "_abc123.db.c0.example.com", type: "TXT", ttl: 60, data: "vpce:xyz789")
      aws.update(private_dns_verification_state: "verified", private_dns_verification_name: "_abc123", private_dns_verification_value: "vpce:xyz789", private_dns_txt_record_name: "_abc123.db.c0.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration)
      expect(ec2).not_to receive(:modify_vpc_endpoint_service_configuration)

      expect { nx.ensure_private_dns_name }.to hop("verify_private_dns")
      expect(zone.records_dataset.where(tombstoned: true).map { [it.name, it.data] }).to eq [["_abc123.db.c0.example.com.", "vpce:xyz789"]]
      row = aws
      expect(row.private_dns_txt_record_name).to be_nil
      expect([row.private_dns_verification_state, row.private_dns_verification_name, row.private_dns_verification_value]).to all(be_nil)
    end

    it "sets a new name on the service and leaves recording the TXT record to verification" do
      pls.update(private_dns_name: "db.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration)
      ec2.stub_responses(:modify_vpc_endpoint_service_configuration, {})
      expect(ec2).to receive(:modify_vpc_endpoint_service_configuration).with(service_id: "vpce-svc-1", private_dns_name: "db.example.com").and_call_original
      expect(ec2).to receive(:describe_vpc_endpoint_service_configurations).once.and_call_original

      expect { nx.ensure_private_dns_name }.to hop("verify_private_dns")
      expect(aws.private_dns_verification_name).to be_nil
    end

    it "removes the name from the service and clears the record when the column is empty" do
      aws.update(private_dns_verification_state: "verified", private_dns_verification_name: "_abc123", private_dns_verification_value: "vpce:xyz789")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration(private_dns_name: "old.example.com", dns: txt("verified")))
      ec2.stub_responses(:modify_vpc_endpoint_service_configuration, {})
      expect(ec2).to receive(:modify_vpc_endpoint_service_configuration).with(service_id: "vpce-svc-1", remove_private_dns_name: true).and_call_original

      expect { nx.ensure_private_dns_name }.to hop("verify_private_dns")
      row = aws
      expect([row.private_dns_verification_state, row.private_dns_verification_name, row.private_dns_verification_value]).to all(be_nil)
    end

    it "removes the TXT record published for the previous name when the name changes" do
      zone = managed_zone
      zone.insert_record(record_name: "_abc123.old.c0.example.com", type: "TXT", ttl: 60, data: "vpce:xyz789")
      aws.update(private_dns_verification_state: "verified", private_dns_verification_name: "_abc123", private_dns_verification_value: "vpce:xyz789", private_dns_txt_record_name: "_abc123.old.c0.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration(private_dns_name: "old.c0.example.com", dns: txt("verified")))
      ec2.stub_responses(:modify_vpc_endpoint_service_configuration, {})

      expect { nx.ensure_private_dns_name }.to hop("verify_private_dns")
      expect(zone.records_dataset.where(tombstoned: true).map { [it.name, it.data] }).to eq [["_abc123.old.c0.example.com.", "vpce:xyz789"]]
      expect(aws.private_dns_txt_record_name).to be_nil
    end
  end

  describe "#verify_private_dns" do
    it "records the attempt and hops back to wait without touching AWS when the service or the name is missing" do
      expect(ec2).not_to receive(:describe_vpc_endpoint_service_configurations)
      expect { nx.verify_private_dns }.to hop("wait")
      expect(aws.private_dns_verification_attempted_at).not_to be_nil
    end

    it "refreshes the state and does not ask AWS once verified" do
      aws.update(service_id: "vpce-svc-1")
      pls.update(private_dns_name: "db.c0.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration(private_dns_name: "db.c0.example.com", dns: txt("verified")))
      expect(ec2).not_to receive(:start_vpc_endpoint_service_private_dns_verification)

      expect { nx.verify_private_dns }.to hop("wait")
      row = aws
      expect(row.private_dns_verification_state).to eq "verified"
      expect(row.private_dns_verification_attempted_at).not_to be_nil
    end

    it "asks AWS to check the record even when no zone Ubicloud serves contains the name" do
      aws.update(service_id: "vpce-svc-1")
      pls.update(private_dns_name: "db.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration(private_dns_name: "db.example.com", dns: txt("pendingVerification")))
      ec2.stub_responses(:start_vpc_endpoint_service_private_dns_verification, {})
      expect(ec2).to receive(:start_vpc_endpoint_service_private_dns_verification).with(service_id: "vpce-svc-1").and_call_original

      expect { nx.verify_private_dns }.to hop("wait")
      expect(aws.private_dns_verification_attempted_at).not_to be_nil
    end

    it "asks AWS to check the record and publishes nothing while the zone has no DNS server VMs" do
      zone = managed_zone(with_vm: false)
      aws.update(service_id: "vpce-svc-1")
      pls.update(private_dns_name: "db.c0.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration(private_dns_name: "db.c0.example.com", dns: txt("pendingVerification")))
      ec2.stub_responses(:start_vpc_endpoint_service_private_dns_verification, {})
      expect(ec2).to receive(:start_vpc_endpoint_service_private_dns_verification).with(service_id: "vpce-svc-1").and_call_original

      expect { nx.verify_private_dns }.to hop("wait")
      expect(zone.records_dataset.count).to eq 0
    end

    it "does not ask AWS before it issued the TXT record" do
      aws.update(service_id: "vpce-svc-1")
      pls.update(private_dns_name: "db.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration(private_dns_name: "db.example.com"))
      expect(ec2).not_to receive(:start_vpc_endpoint_service_private_dns_verification)

      expect { nx.verify_private_dns }.to hop("wait")
      expect(aws.private_dns_verification_attempted_at).not_to be_nil
    end

    it "does not publish in a zone Ubicloud serves before AWS issued the TXT record" do
      zone = managed_zone
      aws.update(service_id: "vpce-svc-1")
      pls.update(private_dns_name: "db.c0.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration(private_dns_name: "db.c0.example.com"))
      expect(ec2).not_to receive(:start_vpc_endpoint_service_private_dns_verification)

      expect { nx.verify_private_dns }.to hop("wait")
      expect(zone.records_dataset.count).to eq 0
    end

    it "publishes the record in a zone Ubicloud serves and naps until it has settled before asking AWS" do
      zone = managed_zone
      aws.update(service_id: "vpce-svc-1")
      pls.update(private_dns_name: "db.c0.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration(private_dns_name: "db.c0.example.com", dns: txt("pendingVerification")))
      expect(ec2).not_to receive(:start_vpc_endpoint_service_private_dns_verification)

      expect { nx.verify_private_dns }.to nap(described_class::PRIVATE_DNS_RECORD_SETTLE_SECONDS)
      expect(zone.records_dataset.map { [it.name, it.type, it.ttl, it.data, it.tombstoned] }).to eq [["_abc123.db.c0.example.com.", "TXT", 60, "vpce:xyz789", false]]
      expect(zone.refresh_dns_servers_set?).to be true
      row = aws
      expect(row.private_dns_verification_attempted_at).to be_nil
      expect(row.private_dns_txt_record_name).to eq "_abc123.db.c0.example.com"

      expect { nx.verify_private_dns }.to nap(described_class::PRIVATE_DNS_RECORD_SETTLE_SECONDS)
      expect(zone.records_dataset.count).to eq 1
    end

    it "asks AWS to check a settled record in a zone Ubicloud serves" do
      zone = managed_zone
      zone.insert_record(record_name: "_abc123.db.c0.example.com", type: "TXT", ttl: 60, data: "vpce:xyz789")
      settle_records(zone)
      aws.update(service_id: "vpce-svc-1")
      pls.update(private_dns_name: "db.c0.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration(private_dns_name: "db.c0.example.com", dns: txt("pendingVerification")))
      ec2.stub_responses(:start_vpc_endpoint_service_private_dns_verification, {})
      expect(ec2).to receive(:start_vpc_endpoint_service_private_dns_verification).with(service_id: "vpce-svc-1").and_call_original

      expect { nx.verify_private_dns }.to hop("wait")
      expect(zone.records_dataset.count).to eq 1
      row = aws
      expect(row.private_dns_verification_attempted_at).not_to be_nil
      expect(row.private_dns_txt_record_name).to eq "_abc123.db.c0.example.com"
    end

    it "tombstones a stale TXT record before publishing the value AWS issued" do
      zone = managed_zone
      zone.insert_record(record_name: "_abc123.db.c0.example.com", type: "TXT", ttl: 60, data: "vpce:old")
      settle_records(zone)
      aws.update(service_id: "vpce-svc-1")
      pls.update(private_dns_name: "db.c0.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration(private_dns_name: "db.c0.example.com", dns: txt("pendingVerification")))
      expect(ec2).not_to receive(:start_vpc_endpoint_service_private_dns_verification)

      expect { nx.verify_private_dns }.to nap(described_class::PRIVATE_DNS_RECORD_SETTLE_SECONDS)
      expect(zone.records_dataset.where(tombstoned: true).select_map(:data)).to eq ["vpce:old"]
      expect(zone.records_dataset.where(tombstoned: false, data: "vpce:xyz789").count).to eq 1
    end

    it "removes the record published under a previous TXT name before publishing the one AWS issues now" do
      zone = managed_zone
      zone.insert_record(record_name: "_old.db.c0.example.com", type: "TXT", ttl: 60, data: "vpce:old")
      aws.update(service_id: "vpce-svc-1", private_dns_txt_record_name: "_old.db.c0.example.com")
      pls.update(private_dns_name: "db.c0.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, configuration(private_dns_name: "db.c0.example.com", dns: txt("pendingVerification")))
      expect(ec2).not_to receive(:start_vpc_endpoint_service_private_dns_verification)

      expect { nx.verify_private_dns }.to nap(described_class::PRIVATE_DNS_RECORD_SETTLE_SECONDS)
      expect(zone.records_dataset.where(tombstoned: true).map { [it.name, it.data] }).to eq [["_old.db.c0.example.com.", "vpce:old"]]
      expect(zone.records_dataset.where(tombstoned: false, name: "_abc123.db.c0.example.com.").count).to eq 1
      expect(aws.private_dns_txt_record_name).to eq "_abc123.db.c0.example.com"
    end
  end

  describe "#wait_service_gone with a published private DNS record" do
    it "removes the TXT record this service published, even from a zone that lost its DNS server VMs" do
      zone = managed_zone(with_vm: false)
      zone.insert_record(record_name: "_abc123.db.c0.example.com", type: "TXT", ttl: 60, data: "vpce:xyz789")
      pls.update(private_dns_name: "db.c0.example.com")
      aws.update(service_id: "vpce-svc-1", private_dns_verification_name: "_abc123", private_dns_verification_value: "vpce:xyz789", private_dns_txt_record_name: "_abc123.db.c0.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, {service_configurations: [{service_id: "vpce-svc-1", service_state: "Deleted"}]})

      expect { nx.wait_service_gone }.to hop("delete_listeners")
      expect(zone.records_dataset.where(tombstoned: true).map { [it.name, it.data] }).to eq [["_abc123.db.c0.example.com.", "vpce:xyz789"]]
      row = aws
      expect(row.private_dns_verification_name).to eq "_abc123"
      expect(row.private_dns_txt_record_name).to be_nil
    end

    it "forgets a published record whose zone is gone" do
      aws.update(service_id: "vpce-svc-1", private_dns_txt_record_name: "_abc123.db.gone.example.com")
      ec2.stub_responses(:describe_vpc_endpoint_service_configurations, {service_configurations: [{service_id: "vpce-svc-1", service_state: "Deleted"}]})

      expect { nx.wait_service_gone }.to hop("delete_listeners")
      expect(aws.private_dns_txt_record_name).to be_nil
    end
  end

  describe "destroy chain" do
    describe "#delete_endpoint_service" do
      it "hops straight on without a recorded service" do
        expect(ec2).not_to receive(:delete_vpc_endpoint_service_configurations)
        expect { nx.delete_endpoint_service }.to hop("wait_service_gone")
      end

      it "deletes the service configuration" do
        aws.update(service_id: "vpce-svc-1")
        ec2.stub_responses(:delete_vpc_endpoint_service_configurations, ->(ctx) {
          expect(ctx.params[:service_ids]).to eq ["vpce-svc-1"]
          {unsuccessful: []}
        })

        expect { nx.delete_endpoint_service }.to hop("wait_service_gone")
      end

      it "treats a not-found failure as already deleted" do
        aws.update(service_id: "vpce-svc-1")
        ec2.stub_responses(:delete_vpc_endpoint_service_configurations, unsuccessful: [{resource_id: "vpce-svc-1", error: {code: "InvalidVpcEndpointServiceId.NotFound", message: "gone"}}])
        expect(ec2).not_to receive(:describe_vpc_endpoint_connections)

        expect { nx.delete_endpoint_service }.to hop("wait_service_gone")
      end

      it "rejects live consumer connections and naps when the service is still in use" do
        aws.update(service_id: "vpce-svc-1")
        ec2.stub_responses(:delete_vpc_endpoint_service_configurations, unsuccessful: [{resource_id: "vpce-svc-1", error: {code: "ExistingVpcEndpointConnections", message: "in use"}}])
        ec2.stub_responses(:describe_vpc_endpoint_connections, ->(ctx) {
          expect(ctx.params[:filters]).to eq [{name: "service-id", values: ["vpce-svc-1"]}]
          {vpc_endpoint_connections: [
            {vpc_endpoint_id: "vpce-a", vpc_endpoint_state: "available"},
            {vpc_endpoint_id: "vpce-b", vpc_endpoint_state: "pendingAcceptance"},
            {vpc_endpoint_id: "vpce-c", vpc_endpoint_state: "rejected"},
          ]}
        })
        ec2.stub_responses(:reject_vpc_endpoint_connections, {})
        expect(ec2).to receive(:reject_vpc_endpoint_connections).with(service_id: "vpce-svc-1", vpc_endpoint_ids: ["vpce-a", "vpce-b"]).and_call_original

        expect { nx.delete_endpoint_service }.to nap(10)
      end

      it "naps without rejecting when the failure is not about connections and none are open" do
        aws.update(service_id: "vpce-svc-1")
        ec2.stub_responses(:delete_vpc_endpoint_service_configurations, unsuccessful: [{resource_id: "vpce-svc-1", error: {code: "IncorrectState", message: "pending"}}])
        ec2.stub_responses(:describe_vpc_endpoint_connections, vpc_endpoint_connections: [{vpc_endpoint_id: "vpce-c", vpc_endpoint_state: "deleted"}])
        expect(ec2).not_to receive(:reject_vpc_endpoint_connections)

        expect { nx.delete_endpoint_service }.to nap(10)
      end
    end

    describe "#wait_service_gone" do
      it "naps while the service is still deleting" do
        aws.update(service_id: "vpce-svc-1")
        ec2.stub_responses(:describe_vpc_endpoint_service_configurations, service_configurations: [{service_id: "vpce-svc-1", service_state: "Deleting"}])

        expect { nx.wait_service_gone }.to nap(10)
      end

      it "moves on once AWS reports the service deleted, keeping the recorded ids for the deleted_record" do
        aws.update(service_id: "vpce-svc-1", service_name: "com.amazonaws.vpce.us-west-2.vpce-svc-1", private_dns_verification_state: "verified", private_dns_verification_name: "_a", private_dns_verification_value: "vpce:b")
        ec2.stub_responses(:describe_vpc_endpoint_service_configurations, service_configurations: [{service_id: "vpce-svc-1", service_state: "Deleted"}])

        expect { nx.wait_service_gone }.to hop("delete_listeners")
        row = aws
        expect([row.service_id, row.service_name, row.private_dns_verification_state]).to eq ["vpce-svc-1", "com.amazonaws.vpce.us-west-2.vpce-svc-1", "verified"]
      end

      it "moves on when AWS no longer knows the service" do
        aws.update(service_id: "vpce-svc-1")
        ec2.stub_responses(:describe_vpc_endpoint_service_configurations, "InvalidVpcEndpointServiceIdNotFound")

        expect { nx.wait_service_gone }.to hop("delete_listeners")
        expect(aws.service_id).to eq "vpce-svc-1"
      end

      it "moves on when the describe call returns nothing" do
        aws.update(service_id: "vpce-svc-1")
        ec2.stub_responses(:describe_vpc_endpoint_service_configurations, service_configurations: [])

        expect { nx.wait_service_gone }.to hop("delete_listeners")
      end

      it "hops straight on without a recorded service" do
        expect(ec2).not_to receive(:describe_vpc_endpoint_service_configurations)
        expect { nx.wait_service_gone }.to hop("delete_listeners")
      end
    end

    describe "#delete_listeners" do
      it "deletes recorded listeners, keeps the ARNs and hops on" do
        nlb_port(5432).update(listener_arn: "arn:listener-5432")
        elbv2.stub_responses(:delete_listener, {})
        expect(elbv2).to receive(:delete_listener).with(listener_arn: "arn:listener-5432").once.and_call_original

        expect { nx.delete_listeners }.to hop("delete_target_groups")
        expect(nlb_port(5432).listener_arn).to eq "arn:listener-5432"
      end

      it "tolerates a listener that is already gone" do
        nlb_port(5432).update(listener_arn: "arn:listener-5432")
        elbv2.stub_responses(:delete_listener, "ListenerNotFound")

        expect { nx.delete_listeners }.to hop("delete_target_groups")
        expect(nlb_port(5432).listener_arn).to eq "arn:listener-5432"
      end
    end

    describe "#delete_target_groups" do
      it "deletes recorded target groups, keeps the ARNs and hops on" do
        nlb_port(5432).update(target_group_arn: "arn:tg-5432")
        elbv2.stub_responses(:delete_target_group, {})
        expect(elbv2).to receive(:delete_target_group).with(target_group_arn: "arn:tg-5432").once.and_call_original

        expect { nx.delete_target_groups }.to hop("delete_nlb")
        expect(nlb_port(5432).target_group_arn).to eq "arn:tg-5432"
        expect(nlb_port(6432).target_group_arn).to be_nil
      end

      it "tolerates a target group that is already gone" do
        nlb_port(5432).update(target_group_arn: "arn:tg-5432")
        elbv2.stub_responses(:delete_target_group, "TargetGroupNotFound")

        expect { nx.delete_target_groups }.to hop("delete_nlb")
        expect(nlb_port(5432).target_group_arn).to eq "arn:tg-5432"
      end
    end

    describe "#delete_nlb" do
      it "deletes the NLB and hops to wait for it to disappear" do
        aws.update(nlb_arn: "arn:nlb")
        elbv2.stub_responses(:delete_load_balancer, {})
        expect(elbv2).to receive(:delete_load_balancer).with(load_balancer_arn: "arn:nlb").and_call_original

        expect { nx.delete_nlb }.to hop("wait_nlb_gone")
      end

      it "tolerates an NLB that is already gone" do
        aws.update(nlb_arn: "arn:nlb")
        elbv2.stub_responses(:delete_load_balancer, "LoadBalancerNotFound")

        expect { nx.delete_nlb }.to hop("wait_nlb_gone")
      end

      it "naps while the NLB is still in use by the private link service" do
        aws.update(nlb_arn: "arn:nlb")
        elbv2.stub_responses(:delete_load_balancer, "ResourceInUse")

        expect { nx.delete_nlb }.to nap(10)
      end

      it "hops straight on without an NLB" do
        expect(elbv2).not_to receive(:delete_load_balancer)
        expect { nx.delete_nlb }.to hop("wait_nlb_gone")
      end
    end

    describe "#wait_nlb_gone" do
      it "naps while the NLB still exists" do
        aws.update(nlb_arn: "arn:nlb")
        elbv2.stub_responses(:describe_load_balancers, load_balancers: [{state: {code: "active"}}])

        expect { nx.wait_nlb_gone }.to nap(10)
      end

      it "moves on to the port check once the NLB is gone, keeping its ARN" do
        aws.update(nlb_arn: "arn:nlb")
        elbv2.stub_responses(:describe_load_balancers, "LoadBalancerNotFound")

        expect { nx.wait_nlb_gone }.to hop("wait_ports_gone")
        expect(aws.nlb_arn).to eq "arn:nlb"
      end

      it "moves on immediately without an NLB" do
        expect(elbv2).not_to receive(:describe_load_balancers)
        expect { nx.wait_nlb_gone }.to hop("wait_ports_gone")
      end
    end

    describe "#wait_ports_gone" do
      it "naps while AWS still knows a listener" do
        nlb_port(5432).update(listener_arn: "arn:listener-5432", target_group_arn: "arn:tg-5432")
        elbv2.stub_responses(:describe_listeners, listeners: [{listener_arn: "arn:listener-5432"}])
        expect(elbv2).not_to receive(:describe_target_groups)

        expect { nx.wait_ports_gone }.to nap(10)
        expect(PrivateLinkService[pls.id]).not_to be_nil
      end

      it "naps while AWS still knows a target group" do
        nlb_port(5432).update(listener_arn: "arn:listener-5432", target_group_arn: "arn:tg-5432")
        elbv2.stub_responses(:describe_listeners, "ListenerNotFound")
        elbv2.stub_responses(:describe_target_groups, target_groups: [{target_group_arn: "arn:tg-5432"}])

        expect { nx.wait_ports_gone }.to nap(10)
        expect(PrivateLinkService[pls.id]).not_to be_nil
      end

      it "destroys the service with its companion rows once AWS answers NotFound for every port, keeping the service's ids in deleted_record" do
        aws.update(nlb_arn: "arn:nlb", service_id: "vpce-svc-1")
        nlb_port(5432).update(listener_arn: "arn:listener-5432", target_group_arn: "arn:tg-5432")
        nlb_port(6432).update(listener_arn: "arn:listener-6432", target_group_arn: "arn:tg-6432")
        elbv2.stub_responses(:describe_listeners, "ListenerNotFound")
        elbv2.stub_responses(:describe_target_groups, "TargetGroupNotFound")
        pls_id = pls.id
        port_ids = pls.ports.map(&:id)
        expect(port_ids.length).to eq 2

        expect { nx.wait_ports_gone }.to exit({"msg" => "private link service destroyed"})
        expect(PrivateLinkService[pls_id]).to be_nil
        expect(PrivateLinkServiceAwsResource[pls_id]).to be_nil
        expect(PrivateLinkServicePort.where(private_link_service_id: pls_id).count).to eq 0
        expect(PrivateLinkServicePortAwsResource.where(id: port_ids).count).to eq 0

        aws_record = DeletedRecord.find_by_id(pls_id, model_name: "PrivateLinkServiceAwsResource")
        expect(aws_record[:model_values].values_at("nlb_arn", "service_id")).to eq ["arn:nlb", "vpce-svc-1"]
        expect(DB[:deleted_record].where(model_name: "PrivateLinkServicePortAwsResource").count).to eq 0
      end

      it "destroys the service immediately when no port ever reached AWS" do
        expect(elbv2).not_to receive(:describe_listeners)
        expect(elbv2).not_to receive(:describe_target_groups)
        expect { nx.wait_ports_gone }.to exit({"msg" => "private link service destroyed"})
        expect(PrivateLinkService[pls.id]).to be_nil
      end
    end
  end
end
