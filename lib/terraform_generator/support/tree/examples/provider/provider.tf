terraform {
  required_providers {
    ubicloud = {
      source  = "ubicloud/ubicloud"
      version = "~> 0.1"
    }
  }
}

provider "ubicloud" {
  # Instead of setting api_token here, define a UBICLOUD_API_TOKEN
  # environment variable, e.g. by adding the following line to .bashrc:
  # export UBICLOUD_API_TOKEN="Your API TOKEN"
  api_token = "Your API TOKEN"
}

# Create a virtual machine
resource "ubicloud_vm" "web" {
  # ...
}
