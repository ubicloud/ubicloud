# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe LoadBalancerVmPort do
  subject(:lb_vm_port) {
    dz = DnsZone.create(name: "test-dns-zone", project_id: prj.id)
    cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
    lb = Prog::Vnet::LoadBalancerNexus.assemble_with_multiple_ports(private_subnet.id, name: "test-lb", ports: [[80, 8080]]).subject
    lb.add_cert(cert)
    lb.add_vm(vm)
    lb.vm_ports.first
  }

  let(:private_subnet) {
    Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps", ipv4_range: "192.168.1.0/24").subject
  }

  let(:vm) {
    nic = Prog::Vnet::NicNexus.assemble(private_subnet.id, name: "test-vm-nic", ipv4_addr: "192.168.1.1").subject
    Prog::Vm::Nexus.assemble("pub key", prj.id, name: "test-vm", private_subnet_id: private_subnet.id, nic_id: nic.id).subject
  }

  let(:prj) {
    Project.create(name: "test-prj")
  }

  describe "#health_probe" do
    let(:vmh) {
      session = instance_double(Sshable, start_fresh_session: "session")
      instance_double(VmHost, sshable: session)
    }

    before do
      allow(lb_vm_port.load_balancer_vm.vm).to receive_messages(vm_host: vmh, ephemeral_net6: NetAddr::IPv6Net.parse("2a01:4f8:10a:128b:814c::/79"))
      lb_vm_port.update(state: "up")
    end

    describe "#init_health_monitor_session" do
      it "returns a hash with an ssh_session" do
        expect(lb_vm_port.init_health_monitor_session).to eq({ssh_session: "session"})
      end
    end

    describe "health_check_cmd" do
      it "returns the correct command" do
        lb = lb_vm_port.load_balancer_port.load_balancer
        lb.update(health_check_protocol: "http")
        expect(lb_vm_port.health_check_cmd(:ipv4)).to eq("sudo ip netns exec #{vm.inhost_name} curl --insecure --resolve #{lb.hostname}:8080:192.168.1.1 --max-time 15 --silent --output /dev/null --write-out '%{http_code}' http://#{lb.hostname}:8080/up")
        expect(lb_vm_port.health_check_cmd(:ipv6)).to eq("sudo ip netns exec #{vm.inhost_name} curl --insecure --resolve #{lb.hostname}:8080:[2a01:4f8:10a:128b:814c::2] --max-time 15 --silent --output /dev/null --write-out '%{http_code}' http://#{lb.hostname}:8080/up")

        lb.update(health_check_protocol: "tcp")
        expect(lb_vm_port.health_check_cmd(:ipv4)).to eq("sudo ip netns exec #{vm.inhost_name} nc -z -w 15 192.168.1.1 8080 >/dev/null 2>&1 && echo 200 || echo 400")
        expect(lb_vm_port.health_check_cmd(:ipv6)).to eq("sudo ip netns exec #{vm.inhost_name} nc -z -w 15 2a01:4f8:10a:128b:814c::2 8080 >/dev/null 2>&1 && echo 200 || echo 400")

        lb.update(health_check_protocol: "https")
        expect(lb_vm_port.health_check_cmd(:ipv4)).to eq("sudo ip netns exec #{vm.inhost_name} curl --insecure --resolve #{lb.hostname}:8080:192.168.1.1 --max-time 15 --silent --output /dev/null --write-out '%{http_code}' https://#{lb.hostname}:8080/up")
        expect(lb_vm_port.health_check_cmd(:ipv6)).to eq("sudo ip netns exec #{vm.inhost_name} curl --insecure --resolve #{lb.hostname}:8080:[2a01:4f8:10a:128b:814c::2] --max-time 15 --silent --output /dev/null --write-out '%{http_code}' https://#{lb.hostname}:8080/up")
      end
    end

    describe "#health_check" do
      let(:session) {
        {ssh_session: instance_double(Net::SSH::Connection::Session)}
      }

      it "returns up for ipv4 checks when ipv4 is not enabled and performs the ipv6 check" do
        lb = lb_vm_port.load_balancer_port.load_balancer
        lb.update(stack: "ipv6")
        expect(vm).not_to receive(:vm_host)
        expect(lb_vm_port).to receive(:health_check_cmd).with(:ipv6).and_return("healthcheck command ipv6").at_least(:once)
        expect(session[:ssh_session]).to receive(:exec!).with("healthcheck command ipv6").and_return("400")
        expect(lb_vm_port.health_check(session:)).to eq(["up", "down"])
      end

      it "returns up for ipv6 checks when ipv6 is not enabled and performs the ipv4 check" do
        lb = lb_vm_port.load_balancer_port.load_balancer
        lb.update(stack: "ipv4")
        expect(vm).not_to receive(:vm_host)
        expect(lb_vm_port).to receive(:health_check_cmd).with(:ipv4).and_return("healthcheck command ipv4").at_least(:once)
        expect(session[:ssh_session]).to receive(:exec!).with("healthcheck command ipv4").and_return("400")
        expect(lb_vm_port.health_check(session:)).to eq(["down", "up"])
      end

      it "runs the health check command and returns the result for both when dual stack" do
        expect(lb_vm_port).to receive(:health_check_cmd).with(:ipv4).and_return("healthcheck command ipv4").at_least(:once)
        expect(lb_vm_port).to receive(:health_check_cmd).with(:ipv6).and_return("healthcheck command ipv6").at_least(:once)
        expect(session[:ssh_session]).to receive(:exec!).with("healthcheck command ipv4").and_return("200").at_least(:once)
        expect(session[:ssh_session]).to receive(:exec!).with("healthcheck command ipv6").and_return("200")
        expect(lb_vm_port.health_check(session:)).to eq(["up", "up"])

        expect(session[:ssh_session]).to receive(:exec!).with("healthcheck command ipv6").and_return("400")
        expect(lb_vm_port.health_check(session:)).to eq(["up", "down"])
      end

      it "returns down if the health check command raises an exception" do
        expect(lb_vm_port).to receive(:health_check_cmd).and_return("healthcheck command").at_least(:once)
        expect(session[:ssh_session]).to receive(:exec!).with("healthcheck command").and_raise("error").at_least(:once)
        expect(lb_vm_port.health_check(session:)).to eq(["down", "down"])
      end
    end

    [IOError.new("closed stream"), Errno::ECONNRESET.new("Connection reset by peer - recvfrom(2)")].each do |ex|
      describe "#check_probe", "stale connection retry behavior with #{ex.class}" do
        let(:session) { {ssh_session: instance_double(Net::SSH::Connection::Session)} }

        it "is down if :last_pulse is not set, even with a qualifying exception" do
          expect(session[:ssh_session]).to receive(:exec!).and_raise(ex)
          expect(lb_vm_port.check_probe(session, :ipv6)).to eq("down")
        end

        it "does not retry if the connection is fresh" do
          session[:last_pulse] = Time.now - 1
          expect(session[:ssh_session]).to receive(:exec!).and_raise(ex)
          expect(lb_vm_port.check_probe(session, :ipv6)).to eq("down")
        end

        it "is up on a retry on a stale connection that works the second time" do
          session[:last_pulse] = Time.now - 10
          expect(session[:ssh_session]).to receive(:exec!).and_raise(ex)
          second_ssh = instance_double(Net::SSH::Connection::Session)
          expect(second_ssh).to receive(:exec!).and_return("200")
          expect(lb_vm_port).to receive(:init_health_monitor_session).and_return(ssh_session: second_ssh)

          expect(lb_vm_port.check_probe(session, :ipv6)).to eq("up")

          expect(session[:ssh_session]).to eq(second_ssh)
        end

        it "is down if consecutive errors are raised even on a stale connection" do
          session[:last_pulse] = Time.now - 10

          expect(session[:ssh_session]).to receive(:exec!).and_raise(ex)

          second_ssh = instance_double(Net::SSH::Connection::Session)
          expect(second_ssh).to receive(:exec!).and_raise(ex)
          expect(lb_vm_port).to receive(:init_health_monitor_session).and_return(ssh_session: second_ssh)

          expect(lb_vm_port.check_probe(session, :ipv6)).to eq("down")
        end

        it "is down for a matching exception without a matching message" do
          session[:last_pulse] = Time.now - 10
          expect(session[:ssh_session]).to receive(:exec!).and_raise(ex.class.new("something else"))
          expect(lb_vm_port.check_probe(session, :ipv6)).to eq("down")
        end
      end
    end

    describe "#check_probe" do
      it "raises an exception if health check type is not valid" do
        expect { lb_vm_port.check_probe(nil, :invalid) }.to raise_error("Invalid type: invalid")
      end
    end

    describe "#check_pulse" do
      let(:session) {
        {ssh_session: instance_double(Sshable)}
      }

      it "doesn't perform update if the state is up and the pulse is also up" do
        lb_vm_port.update(state: "up")
        expect(lb_vm_port).to receive(:health_check).with(session:).and_return(["up", "up"])
        expect(lb_vm_port).not_to receive(:update)
        expect(lb_vm_port.load_balancer_port.load_balancer).not_to receive(:incr_update_load_balancer)
        expect(lb_vm_port.check_pulse(session:, previous_pulse: {reading: "up", reading_rpt: 1, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})).to eq({ipv4: "up", ipv6: "up", reading: "up", reading_rpt: 2, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})
      end

      it "doesn't perform update if the state is up, the pulse is down, but the reading repeat is below the threshold" do
        lb_vm_port.update(state: "up")
        expect(lb_vm_port).to receive(:health_check).with(session:).and_return(["down", "up"])
        expect(lb_vm_port).not_to receive(:update)
        expect(lb_vm_port.load_balancer_port.load_balancer).not_to receive(:incr_update_load_balancer)
        expect(Time).to receive(:now).and_return(Time.parse("2025-01-28 13:15:20.049434 +0100")).at_least(:once)
        expect(lb_vm_port.check_pulse(session:, previous_pulse: {reading: "up", reading_rpt: 1, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})).to eq({ipv4: "down", ipv6: "up", reading: "down", reading_rpt: 1, reading_chg: Time.parse("2025-01-28 13:15:20.049434 +0100")})
      end

      it "doesn't perform update if the state is up, the pulse is down, but the reading count is above the threshold but the reading change is too recent" do
        lb_vm_port.update(state: "up")
        lb_vm_port.load_balancer_port.load_balancer.update(health_check_down_threshold: 3)
        lb_vm_port.load_balancer_port.load_balancer.update(health_check_interval: 30)
        expect(lb_vm_port).to receive(:health_check).with(session:).and_return(["down", "up"])
        expect(lb_vm_port).not_to receive(:update)
        expect(lb_vm_port.load_balancer_port.load_balancer).not_to receive(:incr_update_load_balancer)
        expect(Time).to receive(:now).and_return(Time.parse("2025-01-28 13:15:20.049434 +0100")).at_least(:once)
        expect(lb_vm_port.check_pulse(session:, previous_pulse: {reading: "down", reading_rpt: 4, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})).to eq({ipv4: "down", ipv6: "up", reading: "down", reading_rpt: 5, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})
      end

      it "doesn't perform update if the state is up, the pulse is up, but the reading count is above the threshold but the reading didn't change recently but the load balancer is set to update" do
        lb_vm_port.update(state: "up")
        lb_vm_port.load_balancer_port.load_balancer.update(health_check_down_threshold: 3)
        lb_vm_port.load_balancer_port.load_balancer.update(health_check_interval: 30)
        expect(lb_vm_port).to receive(:health_check).with(session:).and_return(["up", "down"])
        expect(lb_vm_port).not_to receive(:update)
        expect(Time).to receive(:now).and_return(Time.parse("2025-01-28 13:15:50.049434 +0100")).at_least(:once)
        lb_vm_port.load_balancer_port.load_balancer.incr_update_load_balancer
        expect(lb_vm_port.check_pulse(session:, previous_pulse: {reading: "down", reading_rpt: 4, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})).to eq({ipv4: "up", ipv6: "down", reading: "down", reading_rpt: 5, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})
      end

      it "performs update if the state is down, the pulse is up, the reading count is above the threshold and the reading didn't change recently and the load balancer is not set to update" do
        lb_vm_port.update(state: "up")
        lb_vm_port.load_balancer_port.load_balancer.update(health_check_down_threshold: 3)
        lb_vm_port.load_balancer_port.load_balancer.update(health_check_interval: 30)
        expect(lb_vm_port).to receive(:health_check).with(session:).and_return(["up", "down"])
        expect(lb_vm_port).to receive(:update).with(state: "down")
        expect(lb_vm_port.load_balancer_port.load_balancer).to receive(:incr_update_load_balancer)
        expect(Time).to receive(:now).and_return(Time.parse("2025-01-28 13:15:50.049434 +0100")).at_least(:once)
        expect(lb_vm_port.check_pulse(session:, previous_pulse: {reading: "down", reading_rpt: 4, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})).to eq({ipv4: "up", ipv6: "down", reading: "down", reading_rpt: 5, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})
      end

      it "doesn't perform update if the state is down and the pulse is also down" do
        lb_vm_port.update(state: "down")
        expect(lb_vm_port).to receive(:health_check).with(session:).and_return(["down", "down"])
        expect(lb_vm_port).not_to receive(:update)
        expect(lb_vm_port.load_balancer_port.load_balancer).not_to receive(:incr_update_load_balancer)
        expect(lb_vm_port.check_pulse(session:, previous_pulse: {reading: "down", reading_rpt: 1, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})).to eq({ipv4: "down", ipv6: "down", reading: "down", reading_rpt: 2, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})
      end

      it "doesn't perform update if the state is down, the pulse is up, but the reading repeat is below the threshold" do
        lb_vm_port.update(state: "down")
        expect(lb_vm_port).to receive(:health_check).with(session:).and_return(["up", "up"])
        expect(lb_vm_port).not_to receive(:update)
        expect(lb_vm_port.load_balancer_port.load_balancer).not_to receive(:incr_update_load_balancer)
        expect(Time).to receive(:now).and_return(Time.parse("2025-01-28 13:15:20.049434 +0100")).at_least(:once)
        expect(lb_vm_port.check_pulse(session:, previous_pulse: {reading: "down", reading_rpt: 1, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})).to eq({ipv4: "up", ipv6: "up", reading: "up", reading_rpt: 1, reading_chg: Time.parse("2025-01-28 13:15:20.049434 +0100")})
      end

      it "doesn't perform update if the state is down, the pulse is up, but the reading count is above the threshold and the reading change is too recent" do
        lb_vm_port.update(state: "down")
        lb_vm_port.load_balancer_port.load_balancer.update(health_check_down_threshold: 3)
        lb_vm_port.load_balancer_port.load_balancer.update(health_check_interval: 30)
        expect(lb_vm_port).to receive(:health_check).with(session:).and_return(["up", "up"])
        expect(lb_vm_port).not_to receive(:update)
        expect(lb_vm_port.load_balancer_port.load_balancer).not_to receive(:incr_update_load_balancer)
        expect(Time).to receive(:now).and_return(Time.parse("2025-01-28 13:15:20.049434 +0100")).at_least(:once)
        expect(lb_vm_port.check_pulse(session:, previous_pulse: {reading: "up", reading_rpt: 4, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})).to eq({ipv4: "up", ipv6: "up", reading: "up", reading_rpt: 5, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})
      end

      it "doesn't perform update if the state is down, the pulse is up, the reading count is above the threshold and the reading change is too recent and the load balancer is set to update" do
        lb_vm_port.update(state: "down")
        lb_vm_port.load_balancer_port.load_balancer.update(health_check_down_threshold: 3)
        lb_vm_port.load_balancer_port.load_balancer.update(health_check_interval: 30)
        expect(lb_vm_port).to receive(:health_check).with(session:).and_return(["up", "up"])
        expect(lb_vm_port).not_to receive(:update)
        expect(Time).to receive(:now).and_return(Time.parse("2025-01-28 13:15:50.049434 +0100")).at_least(:once)
        lb_vm_port.load_balancer_port.load_balancer.incr_update_load_balancer
        expect(lb_vm_port.check_pulse(session:, previous_pulse: {reading: "up", reading_rpt: 4, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})).to eq({ipv4: "up", ipv6: "up", reading: "up", reading_rpt: 5, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})
      end

      it "performs update if the state is down, the pulse is up, the reading count is above the threshold and the reading change is too recent and the load balancer is not set to update" do
        lb_vm_port.update(state: "down")
        lb_vm_port.load_balancer_port.load_balancer.update(health_check_down_threshold: 3)
        lb_vm_port.load_balancer_port.load_balancer.update(health_check_interval: 30)
        expect(lb_vm_port).to receive(:health_check).with(session:).and_return(["up", "up"])
        expect(lb_vm_port).to receive(:update).with(state: "up")
        expect(lb_vm_port.load_balancer_port.load_balancer).to receive(:incr_update_load_balancer)
        expect(Time).to receive(:now).and_return(Time.parse("2025-01-28 13:15:50.049434 +0100")).at_least(:once)
        expect(lb_vm_port.check_pulse(session:, previous_pulse: {reading: "up", reading_rpt: 4, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})).to eq({ipv4: "up", ipv6: "up", reading: "up", reading_rpt: 5, reading_chg: Time.parse("2025-01-28 13:15:10.049434 +0100")})
      end
    end
  end
end
