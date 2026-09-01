package provider

import (
	"fmt"
	"math/rand"
	"os"
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/providerserver"
	"github.com/hashicorp/terraform-plugin-go/tfprotov6"
)

const (
	providerConfig = `
provider "ubicloud" {
}
`
)

var (
	testAccProtoV6ProviderFactories = map[string]func() (tfprotov6.ProviderServer, error){
		"ubicloud": providerserver.NewProtocol6WithError(New("test")()),
	}
)

const TestAccNamePrefix = "tf-acc"

func testAccPreCheck(t *testing.T) {
	if v := os.Getenv("UBICLOUD_API_TOKEN"); v == "" {
		t.Fatal("UBICLOUD_API_TOKEN must be set for acceptance tests")
	}

	if v := os.Getenv("UBICLOUD_ACC_TEST_PROJECT"); v == "" {
		t.Fatal("UBICLOUD_ACC_TEST_PROJECT must be set for acceptance tests")
	}

	if v := os.Getenv("UBICLOUD_ACC_TEST_LOCATION"); v == "" {
		t.Fatal("UBICLOUD_ACC_TEST_LOCATION must be set for acceptance tests")
	}
}

func requireAccEnv(t *testing.T, name string) {
	if v := os.Getenv(name); v == "" {
		t.Fatalf("%s must be set for acceptance tests", name)
	}
}

func GetTestAccProjectId() string {
	return os.Getenv("UBICLOUD_ACC_TEST_PROJECT")
}

func GetTestAccLocation() string {
	return os.Getenv("UBICLOUD_ACC_TEST_LOCATION")
}

func GetTestAccFirewallId() string {
	return os.Getenv("UBICLOUD_ACC_TEST_FIREWALL")
}

func GetTestAccPrivateSubnetId() string {
	return os.Getenv("UBICLOUD_ACC_TEST_PRIVATE_SUBNET")
}

func GetRandomResourceName(resType string) string {
	var letters = []rune("abcdefghijklmnopqrstuvwxyz")
	b := make([]rune, 8)
	for i := range b {
		b[i] = letters[rand.Intn(len(letters))]
	}
	return fmt.Sprintf("%s-%s-%s", TestAccNamePrefix, resType, string(b))
}
