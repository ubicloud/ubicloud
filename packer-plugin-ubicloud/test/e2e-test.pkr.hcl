packer {
  required_plugins {
    ubicloud = {
      version = ">= 0.1.0"
      source  = "github.com/ubicloud/ubicloud"
    }
  }
}

variable "api_token" {
  type    = string
  default = env("UBICLOUD_API_TOKEN")
}

variable "project_id" {
  type    = string
  default = env("UBICLOUD_PROJECT_ID")
}

variable "api_url" {
  type    = string
  default = env("UBICLOUD_API_URL")
}

source "ubicloud" "e2e-test" {
  api_token  = var.api_token
  api_url    = var.api_url
  project_id = var.project_id
  location   = "eu-central-h1"
  boot_image = "ubuntu-noble"
  vm_size    = "standard-2"
  vm_arch    = "arm64"
  image_name = "packer-e2e-test"
  image_description = "Packer plugin E2E test image"

  ssh_username = "ubi"
  ssh_private_key_file = "~/.ssh/id_ed25519"

  # Jump through the data plane host to reach the VM's IPv6
  ssh_bastion_host = "65.109.109.143"
  ssh_bastion_username = "rhizome"
  ssh_bastion_private_key_file = "~/.ssh/id_ed25519"
}

build {
  sources = ["source.ubicloud.e2e-test"]

  provisioner "shell" {
    inline = [
      "echo 'PACKER_E2E_MARKER_FILE' | sudo tee /etc/packer-e2e-marker",
      "cat /etc/packer-e2e-marker",
      "uname -a",
      "echo 'Packer provisioning complete'",
    ]
  }
}
