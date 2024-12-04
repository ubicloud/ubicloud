# frozen_string_literal: true

class Prog::Kubernetes::KubernetesClusterNexus < Prog::Base
  subject_is :kubernetes_cluster

  def self.assemble(name:, kubernetes_version:, subnet:, project_id:, location:, replica: 3)
    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing project"
      end

      kc = KubernetesCluster.create_with_id(
        name: name,
        kubernetes_version: kubernetes_version,
        replica: replica,
        subnet: subnet,
        location: location
      )
      kc.associate_with_project(project)
      Strand.create(prog: "Kubernetes::KubernetesClusterNexus", label: "start") { _1.id = kc.id }
    end
  end

  def curl(method, url, token, data = nil)
    command = ["curl", "-s", "-X", method]
    command += ["-H", "Authorization: Bearer #{token}", "-H", "Content-Type: application/json"]
    command += ["-k", url.to_s]
    command += ["-d", data.to_json] if data
    JSON.parse(`#{command.join(" ")}`, symbolize_names: true)
  end

  def render_template(template, context)
    puts template, context
    ERB.new(template).result_with_hash(context)
  end

  def specs_match?(desired, current)
    desired.all? do |key, value|
      current_value = current[key]
      value.is_a?(Hash) ? specs_match?(value, current_value || {}) : value == current_value
    end
  end

  label def start
    context = {
      name: kubernetes_cluster.name,
      namespace: "default",
      location: kubernetes_cluster.location,
      project_id: kubernetes_cluster.projects.first.ubid,
      subnet: kubernetes_cluster.subnet,
      replica: kubernetes_cluster.replica,
      version: kubernetes_cluster.kubernetes_version,
      server_size: "standard-4",
      storage_size_gb: 40
    }
    manifests = [
      {
        file: <<~YAML,
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: UbicloudCluster
metadata:
  name: <%= name %>
  namespace: <%= namespace %>
spec:
  location: <%= location %>
  projectID: <%= project_id %>
  subnet: <%= subnet %>
        YAML
        url: "/apis/infrastructure.cluster.x-k8s.io/v1beta1/namespaces/#{context[:namespace]}/ubicloudclusters/#{context[:name]}"
      },
      {
        file: <<~YAML,
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: <%= name %>
  namespace: <%= namespace %>
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["10.244.0.0/16"]
    services:
      cidrBlocks: ["10.96.0.0/12"]
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: KubeadmControlPlane
    name: <%= name %>
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: UbicloudCluster
    name: <%= name %>
        YAML
        url: "/apis/cluster.x-k8s.io/v1beta1/namespaces/#{context[:namespace]}/clusters/#{context[:name]}"
      },
      {
        file: <<~YAML,
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
metadata:
  name: <%= name %>
  namespace: <%= namespace %>
spec:
  replicas: <%= replica %>
  version: <%= version %>
  machineTemplate:
    infrastructureRef:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
      kind: UbicloudMachineTemplate
      name: <%= name %>-control-plane
  kubeadmConfigSpec:
    clusterConfiguration:
      apiServer:
        extraArgs:
          enable-admission-plugins: "NodeRestriction"
      controllerManager: {}
      scheduler: {}
      networking:
        podSubnet: "10.244.0.0/16"
        serviceSubnet: "10.96.0.0/12"
    initConfiguration: {}
    joinConfiguration: {}
        YAML
        url: "/apis/controlplane.cluster.x-k8s.io/v1beta1/namespaces/#{context[:namespace]}/kubeadmcontrolplanes/#{context[:name]}"
      },
      {
        file: <<~YAML,
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: UbicloudMachineTemplate
metadata:
  name: <%= name %>-control-plane
  namespace: <%= namespace %>
spec:
  template:
    spec:
      serverSize: "<%= server_size %>"
      storageSizeGB: <%= storage_size_gb %>
        YAML
        url: "/apis/infrastructure.cluster.x-k8s.io/v1beta1/namespaces/#{context[:namespace]}/ubicloudmachinetemplates/#{context[:name]}-control-plane"
      }
    ]
    manifests.each do |manifest|
      yaml_content = render_template(manifest[:file], context)
      resource = YAML.safe_load(yaml_content, symbolize_names: true)
      resource_url = "#{Config.management_k8s_url}#{manifest[:url]}"

      existing_resource = begin
        curl("GET", resource_url, config.management_k8s_token)
      rescue
        nil
      end

      if existing_resource
        current_spec = existing_resource[:spec] || {}
        desired_spec = resource[:spec] || {}
        if specs_match?(desired_spec, current_spec)
          puts "Resource already up-to-date: #{resource[:kind]} #{resource[:metadata][:name]}"
        else
          puts "Updating resource: #{resource[:kind]} #{resource[:metadata][:name]}"
          curl("PUT", resource_url, config.management_k8s_token, resource)
        end
      else
        puts "Creating resource: #{resource[:kind]} #{resource[:metadata][:name]}"
        curl("POST", resource_url.gsub(%r{/[^/]+$}, ""), config.management_k8s_token, resource)
      end
    end

    hop_wait
  end

  label def wait
    nap 30
  end

  label def destroy
    pop "done"
  end
end
