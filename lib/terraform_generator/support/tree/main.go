package main

// All Go under internal/provider is emitted by clover's generator (rake
// terraform:generate + terraform:schema); rake terraform:check verifies every
// artifact byte-for-byte. The committed provider-code-spec JSON remains the
// semantic schema record, guarded by terraform:schema_diff against the frozen
// legacy baseline.


//go:generate terraform fmt -recursive ./examples/
//go:generate go run github.com/hashicorp/terraform-plugin-docs/cmd/tfplugindocs generate -provider-name ubicloud

import (
	"context"
	"flag"
	"log"

	"github.com/ubicloud/terraform-provider-ubicloud/internal/provider"

	"github.com/hashicorp/terraform-plugin-framework/providerserver"
)

var (
	// these will be set by the goreleaser configuration
	// to appropriate values for the compiled binary.
	version string = "dev"

	// goreleaser can pass other information to the main package, such as the specific commit
	// https://goreleaser.com/cookbooks/using-main.version/
)

func main() {
	var debug bool

	flag.BoolVar(&debug, "debug", false, "set to true to run the provider with support for debuggers like delve")
	flag.Parse()

	opts := providerserver.ServeOpts{
		Address: "registry.terraform.io/ubicloud/ubicloud",
		Debug:   debug,
	}

	err := providerserver.Serve(context.Background(), provider.New(version), opts)

	if err != nil {
		log.Fatal(err.Error())
	}
}
