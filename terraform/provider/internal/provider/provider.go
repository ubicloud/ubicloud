// Package provider is the Ubicloud terraform provider. The engine in its
// hand-written files serves every type the generated *_gen.go files register.
package provider

import (
	"cmp"
	"context"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/hashicorp/terraform-plugin-framework/datasource"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/provider"
	pschema "github.com/hashicorp/terraform-plugin-framework/provider/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

type ubicloudProvider struct{ version string }

func New(version string) func() provider.Provider {
	return func() provider.Provider { return &ubicloudProvider{version} }
}

func (p *ubicloudProvider) Metadata(_ context.Context, _ provider.MetadataRequest, resp *provider.MetadataResponse) {
	resp.TypeName, resp.Version = "ubicloud", p.version
}

func (p *ubicloudProvider) Schema(_ context.Context, _ provider.SchemaRequest, resp *provider.SchemaResponse) {
	resp.Schema = pschema.Schema{Attributes: map[string]pschema.Attribute{
		"api_endpoint": pschema.StringAttribute{
			Optional:    true,
			Description: "The API endpoint. Defaults to the UBICLOUD_API_ENDPOINT environment variable, else https://api.ubicloud.com.",
		},
		"api_token": pschema.StringAttribute{
			Optional:    true,
			Sensitive:   true,
			Description: "The API token. Defaults to the UBICLOUD_API_TOKEN environment variable.",
		},
		"project_id": pschema.StringAttribute{
			Optional:    true,
			Description: "The ID of the project that every resource and data source belongs to. Defaults to the UBICLOUD_PROJECT_ID environment variable.",
		},
		"poll_interval": pschema.StringAttribute{
			Optional:    true,
			Description: "How long to wait before reading an object again while it is still changing, as a duration such as 5s. The wait doubles each time, up to six times this value. Defaults to 5s.",
		},
	}}
}

func (p *ubicloudProvider) Configure(ctx context.Context, req provider.ConfigureRequest, resp *provider.ConfigureResponse) {
	setting := func(name string) string {
		var v types.String
		resp.Diagnostics.Append(req.Config.GetAttribute(ctx, path.Root(name), &v)...)
		if v.IsUnknown() {
			resp.Diagnostics.AddAttributeError(path.Root(name), "Unknown provider setting",
				"The provider is configured before any resource is created, so "+name+" cannot depend on one.")
		}
		return v.ValueString()
	}
	c := &client{
		endpoint:  strings.TrimSuffix(cmp.Or(setting("api_endpoint"), os.Getenv("UBICLOUD_API_ENDPOINT"), "https://api.ubicloud.com"), "/"),
		token:     cmp.Or(setting("api_token"), os.Getenv("UBICLOUD_API_TOKEN")),
		projectID: cmp.Or(setting("project_id"), os.Getenv("UBICLOUD_PROJECT_ID")),
		userAgent: "terraform-provider-ubicloud/" + p.version,
		http:      &http.Client{Timeout: time.Minute},
	}
	interval, err := time.ParseDuration(cmp.Or(setting("poll_interval"), "5s"))
	if err != nil || interval <= 0 {
		resp.Diagnostics.AddAttributeError(path.Root("poll_interval"), "Invalid poll_interval", "poll_interval must be a positive duration, such as 5s.")
	}
	c.poll = interval
	if c.token == "" {
		resp.Diagnostics.AddAttributeError(path.Root("api_token"), "Missing api_token", "Set api_token or the UBICLOUD_API_TOKEN environment variable.")
	}
	if c.projectID == "" {
		resp.Diagnostics.AddAttributeError(path.Root("project_id"), "Missing project_id", "Set project_id or the UBICLOUD_PROJECT_ID environment variable.")
	}
	resp.ResourceData, resp.DataSourceData = c, c
}

func (p *ubicloudProvider) Resources(context.Context) (rs []func() resource.Resource) {
	for _, t := range registry {
		if t.createOp != nil {
			rs = append(rs, func() resource.Resource { return &genericResource{t: t} })
		}
	}
	return rs
}

func (p *ubicloudProvider) DataSources(context.Context) (ds []func() datasource.DataSource) {
	for _, t := range registry {
		ds = append(ds, func() datasource.DataSource { return &genericDataSource{t: t} })
	}
	return ds
}
