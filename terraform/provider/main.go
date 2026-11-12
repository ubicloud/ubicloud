package main

import (
	"context"
	"log"

	"github.com/hashicorp/terraform-plugin-framework/providerserver"

	"github.com/ubicloud/terraform-provider-ubicloud/internal/provider"
)

// version is set at release, with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	err := providerserver.Serve(context.Background(), provider.New(version), providerserver.ServeOpts{Address: "registry.terraform.io/ubicloud/ubicloud"})
	if err != nil {
		log.Fatal(err)
	}
}
