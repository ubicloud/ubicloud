package main

import (
	"fmt"
	"os"

	ubicloudBuilder "github.com/ubicloud/packer-plugin-ubicloud/builder/ubicloud"

	"github.com/hashicorp/packer-plugin-sdk/plugin"
	"github.com/hashicorp/packer-plugin-sdk/version"
)

var pluginVersion = version.NewPluginVersion("0.1.0", "", "")

func main() {
	pps := plugin.NewSet()
	pps.RegisterBuilder(plugin.DEFAULT_NAME, new(ubicloudBuilder.Builder))
	pps.SetVersion(pluginVersion)
	err := pps.Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
}
