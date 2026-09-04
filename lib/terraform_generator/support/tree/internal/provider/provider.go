package provider

import (
	"context"
	"os"


	"github.com/hashicorp/terraform-plugin-framework/datasource"
	"github.com/hashicorp/terraform-plugin-framework/function"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/provider"
	"github.com/hashicorp/terraform-plugin-framework/provider/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

// Ensure UbicloudProvider satisfies various provider interfaces.
var _ provider.Provider = &ubicloudProvider{}
var _ provider.ProviderWithFunctions = &ubicloudProvider{}

type UbicloudClient struct {
	endpoint string
	token    string
}

type ubicloudProvider struct {
	// version is set to the provider version on release, "dev" when the
	// provider is built and ran locally, and "test" when running acceptance
	// testing.
	version string
}

// UbicloudProviderModel describes the provider data model.
type ubicloudProviderModel struct {
	Endpoint types.String `tfsdk:"api_endpoint"`
	Token    types.String `tfsdk:"api_token"`
}

func (p *ubicloudProvider) Metadata(ctx context.Context, req provider.MetadataRequest, resp *provider.MetadataResponse) {
	resp.TypeName = "ubicloud"
	resp.Version = p.version
}

func (p *ubicloudProvider) Schema(ctx context.Context, req provider.SchemaRequest, resp *provider.SchemaResponse) {
	resp.Schema = schema.Schema{
		Attributes: map[string]schema.Attribute{
			"api_endpoint": schema.StringAttribute{
				MarkdownDescription: "Ubicloud endpoint. If not set checks env for `UBICLOUD_API_ENDPOINT`. Default: `https://api.ubicloud.com`.",
				Optional:            true,
			},
			"api_token": schema.StringAttribute{
				MarkdownDescription: "Ubicloud token. If not set checks env for `UBICLOUD_API_TOKEN`.",
				Optional:            true,
				Sensitive:           true,
			},
		},
	}
}

func (p *ubicloudProvider) Configure(ctx context.Context, req provider.ConfigureRequest, resp *provider.ConfigureResponse) {
	// Retrieve provider data from configuration
	var config ubicloudProviderModel
	diags := req.Config.Get(ctx, &config)
	resp.Diagnostics.Append(diags...)
	if resp.Diagnostics.HasError() {
		return
	}
	// If practitioner provided a configuration value for any of the
	// attributes, it must be a known value.
	if config.Endpoint.IsUnknown() {
		resp.Diagnostics.AddAttributeError(
			path.Root("api_endpoint"),
			"Unknown Ubicloud API endpoint",
			"The provider cannot create the Ubicloud API client as there is an unknown configuration value for the Ubicloud API username. "+
				"Either target apply the source of the value first, set the value statically in the configuration, or use the UBICLOUD_API_ENDPOINT environment variable.",
		)
	}
	if config.Token.IsUnknown() {
		resp.Diagnostics.AddAttributeError(
			path.Root("api_token"),
			"Unknown Ubicloud token",
			"The provider cannot create the Ubicloud API client as there is an unknown configuration value for the Ubicloud API token. "+
				"Either target apply the source of the value first, set the value statically in the configuration, or use the UBICLOUD_API_TOKEN environment variable.",
		)
	}
	if resp.Diagnostics.HasError() {
		return
	}
	// Default values to environment variables, but override
	// with Terraform configuration value if set.
	endpoint := os.Getenv("UBICLOUD_API_ENDPOINT")
	token := os.Getenv("UBICLOUD_API_TOKEN")
	if !config.Endpoint.IsNull() {
		endpoint = config.Endpoint.ValueString()
	}
	if !config.Token.IsNull() {
		token = config.Token.ValueString()
	}

	// If any of the expected configurations are missing, return
	// errors with provider-specific guidance.
	if endpoint == "" {
		endpoint = "https://api.ubicloud.com"
	}
	if token == "" {
		resp.Diagnostics.AddAttributeError(
			path.Root("api_token"),
			"Missing Ubicloud API token",
			"The provider cannot create the Ubicloud API client as there is a missing or empty value for the Ubicloud API token. "+
				"Set the token value in the configuration or use the UBICLOUD_API_TOKEN environment variable. "+
				"If either is already set, ensure the value is not empty.",
		)
	}
	if resp.Diagnostics.HasError() {
		return
	}
	ubicloudClient := UbicloudClient{
		endpoint: endpoint,
		token:    token,
	}

	resp.DataSourceData = ubicloudClient
	resp.ResourceData = ubicloudClient
}

func (p *ubicloudProvider) Resources(ctx context.Context) []func() resource.Resource {
	return generatedResources()
}

func (p *ubicloudProvider) DataSources(ctx context.Context) []func() datasource.DataSource {
	return generatedDataSources()
}

func (p *ubicloudProvider) Functions(ctx context.Context) []func() function.Function {
	return []func() function.Function{}
}

func New(version string) func() provider.Provider {
	return func() provider.Provider {
		return &ubicloudProvider{
			version: version,
		}
	}
}
