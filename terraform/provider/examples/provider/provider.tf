terraform {
  required_providers {
    ubicloud = {
      source = "ubicloud/ubicloud"
    }
  }
}

# It is better to set the API token in UBICLOUD_API_TOKEN than to write it here.
provider "ubicloud" {
  project_id = "pjkkmx0f2vke4h36nk9cm8v8q0"
}
