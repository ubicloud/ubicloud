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
    command = ["curl", "-s", "-X#{method}"]
    command += ["-H", "\"Authorization: Bearer #{token}\"", "-H", "\"Content-Type: application/json\""]
    command += ["-k", url.to_s]
    command += ["-d", "'#{data.to_json}'"] if data
    JSON.parse(`#{command.join(" ")}`, symbolize_names: true)
  end

  def specs_match?(desired, current)
    desired.all? do |key, value|
      current_value = current[key]
      value.is_a?(Hash) ? specs_match?(value, current_value || {}) : value == current_value
    end
  end

  label def start
    manifests = [
      {
        file: <<~YAML,
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: UbicloudCluster
metadata:
  name: #{kubernetes_cluster.name}
  namespace: default
spec:
  location: #{kubernetes_cluster.location}
  projectID: #{kubernetes_cluster.projects.first.ubid}
  subnet: #{kubernetes_cluster.subnet}
        YAML
        url: "/apis/infrastructure.cluster.x-k8s.io/v1beta1/namespaces/default/ubicloudclusters/#{kubernetes_cluster.name}"
      },
      {
        file: <<~YAML,
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: #{kubernetes_cluster.name}
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["10.244.0.0/16"]
    services:
      cidrBlocks: ["10.96.0.0/12"]
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: KubeadmControlPlane
    name: #{kubernetes_cluster.name}
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: UbicloudCluster
    name: #{kubernetes_cluster.name}
        YAML
        url: "/apis/cluster.x-k8s.io/v1beta1/namespaces/default/clusters/#{kubernetes_cluster.name}"
      },
      {
        file: <<~YAML,
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
metadata:
  name: #{kubernetes_cluster.name}
  namespace: default
spec:
  replicas: #{kubernetes_cluster.replica}
  version: #{kubernetes_cluster.kubernetes_version}
  machineTemplate:
    infrastructureRef:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
      kind: UbicloudMachineTemplate
      name: #{kubernetes_cluster.name}-control-plane
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
        url: "/apis/controlplane.cluster.x-k8s.io/v1beta1/namespaces/default/kubeadmcontrolplanes/#{kubernetes_cluster.name}"
      },
      {
        file: <<~YAML,
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: UbicloudMachineTemplate
metadata:
  name: #{kubernetes_cluster.name}-control-plane
  namespace: default
spec:
  template:
    spec:
      serverSize: "standard-4"
      storageSizeGB: 40
        YAML
        url: "/apis/infrastructure.cluster.x-k8s.io/v1beta1/namespaces/default/ubicloudmachinetemplates/#{kubernetes_cluster.name}-control-plane"
      }
    ]
    manifests.each do |manifest|
      resource = YAML.safe_load(manifest[:file], symbolize_names: true)
      resource_url = "#{Config.management_k8s_url}#{manifest[:url]}"

      response = begin
        curl("GET", resource_url, Config.management_k8s_token)
      rescue => ex
        Clog.emit("could not execute curl command: #{ex}")
        next
      end

      if !response.key?(:code) # meaning 200 status code
        current_spec = response[:spec] || {}
        desired_spec = resource[:spec] || {}
        if specs_match?(desired_spec, current_spec)
          Clog.emit("Resource already up-to-date: #{resource[:kind]} #{resource[:metadata][:name]}")
        else
          Clog.emit("Updating resource: #{resource[:kind]} #{resource[:metadata][:name]}")
          resource[:metadata][:resourceVersion] = response[:metadata][:resourceVersion]
          curl("PUT", resource_url, Config.management_k8s_token, resource)
        end
      elsif response[:code] == 404
        Clog.emit("Creating resource: #{resource[:kind]} #{resource[:metadata][:name]}")
        curl("POST", resource_url.gsub(%r{/[^/]+$}, ""), Config.management_k8s_token, resource)
      else
        Clog.emit("Got response code other than 200 and 404. Response: #{response}")
      end
    end

    nap 30
  end

  label def wait
    hop_start
  end

  label def destroy
    pop "done"
  end
end
