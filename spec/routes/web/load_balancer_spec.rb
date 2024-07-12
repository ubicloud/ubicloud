# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "load balancer" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: []) }

  let(:lb) do
    ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-hel1").subject
    lb = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-1", src_port: 80, dst_port: 80, health_check_endpoint: "/up")
    lb.associate_with_project(project)
    lb
  end

  let(:lb_wo_permission) {
    ps = Prog::Vnet::SubnetNexus.assemble(project_wo_permissions.id, name: "dummy-ps-2", location: "hetzner-hel1").subject
    lb = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-2", src_port: 80, dst_port: 80, health_check_endpoint: "/up")
    lb.associate_with_project(project_wo_permissions)
    lb
  }

  describe "unauthenticated" do
    it "can not list without login" do
      visit "/load-balancer"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "/load-balancer/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "list" do
      it "can list no load balancers" do
        visit "#{project.path}/load-balancer"

        expect(page.title).to eq("Ubicloud - Load Balancers")
        expect(page).to have_content "No Load Balancers"

        click_link "New Load Balancer"
        expect(page.title).to eq("Ubicloud - Create Load Balancer")
      end

      it "can not list load balancers when does not have permissions" do
        lb
        lb_wo_permission
        visit "#{project.path}/load-balancer"

        expect(page.title).to eq("Ubicloud - Load Balancers")
        expect(page).to have_content lb.name
        expect(page).to have_no_content lb_wo_permission.name
      end
    end

    describe "create" do
      it "can create new load balancer" do
        project
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-hel1").subject
        visit "#{project.path}/load-balancer/create"

        expect(page.title).to eq("Ubicloud - Create Load Balancer")
        name = "dummy-lb-1"
        fill_in "Name", with: name
        fill_in "Source Port", with: 80
        fill_in "Destination Port", with: 8000
        select "round-robin", from: "algorithm"
        fill_in "Health Check Endpoint", with: "/up"
        fill_in "Health Check Interval", with: 5
        fill_in "Health Check Timeout", with: 3
        fill_in "Health Check Healthy Threshold", with: 5
        fill_in "Health Check Unhealthy Threshold", with: 3
        select ps.name, from: "private_subnet_id"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content "'#{name}' is created"
        expect(LoadBalancer.count).to eq(1)
        expect(LoadBalancer.first.projects.first.id).to eq(project.id)
      end

      it "can not create load balancer with invalid name" do
        project
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-hel1").subject
        visit "#{project.path}/load-balancer/create"

        expect(page.title).to eq("Ubicloud - Create Load Balancer")

        fill_in "Name", with: "invalid name"
        fill_in "Source Port", with: 80
        fill_in "Destination Port", with: 8000
        select "round-robin", from: "algorithm"
        fill_in "Health Check Endpoint", with: "/up"
        fill_in "Health Check Interval", with: 5
        fill_in "Health Check Timeout", with: 3
        fill_in "Health Check Healthy Threshold", with: 5
        fill_in "Health Check Unhealthy Threshold", with: 3
        select ps.name, from: "private_subnet_id"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Load Balancer")
        expect(page).to have_content "Name must only contain"
        expect((find "input[name=name]")["value"]).to eq("invalid name")
      end

      it "can not create load balancer in a project when does not have permissions" do
        Prog::Vnet::SubnetNexus.assemble(project_wo_permissions.id, name: "dummy-ps-1", location: "hetzner-hel1").subject
        visit "#{project_wo_permissions.path}/load-balancer/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end
    end
  end
end
