package provider

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/hashicorp/terraform-plugin-framework/datasource"
	"github.com/hashicorp/terraform-plugin-framework/provider"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/tfsdk"
	"github.com/hashicorp/terraform-plugin-go/tftypes"
)

func configure(t *testing.T, settings values) *provider.ConfigureResponse {
	t.Helper()
	ctx := context.Background()
	p := New("1.2.3")()
	var sresp provider.SchemaResponse
	p.Schema(ctx, provider.SchemaRequest{}, &sresp)
	typ := sresp.Schema.Type().TerraformType(ctx).(tftypes.Object)
	vals := values{}
	for n := range typ.AttributeTypes {
		vals[n] = tftypes.NewValue(tftypes.String, nil)
		if v, ok := settings[n]; ok {
			vals[n] = v
		}
	}
	var resp provider.ConfigureResponse
	p.Configure(ctx, provider.ConfigureRequest{Config: tfsdk.Config{Schema: sresp.Schema, Raw: tftypes.NewValue(typ, vals)}}, &resp)
	return &resp
}

func TestConfigure(t *testing.T) {
	t.Setenv("UBICLOUD_API_TOKEN", "from-env")
	t.Setenv("UBICLOUD_API_ENDPOINT", "")
	t.Setenv("UBICLOUD_PROJECT_ID", "")
	resp := configure(t, values{"project_id": tfStr("p1"), "poll_interval": tfStr("20ms")})
	checkDiags(t, resp.Diagnostics, "")
	c := resp.ResourceData.(*client)
	if c.endpoint != "https://api.ubicloud.com" || c.token != "from-env" || c.projectID != "p1" || c.poll != 20*time.Millisecond || c.userAgent != "terraform-provider-ubicloud/1.2.3" {
		t.Errorf("client %+v", c)
	}

	t.Setenv("UBICLOUD_API_TOKEN", "")
	resp = configure(t, values{"api_endpoint": unknownStr, "poll_interval": tfStr("soon")})
	checkDiags(t, resp.Diagnostics, "Unknown provider setting: The provider is configured before any resource is created, so api_endpoint cannot depend on one.")
	checkDiags(t, resp.Diagnostics, "Missing api_token")
	checkDiags(t, resp.Diagnostics, "Missing project_id")
	checkDiags(t, resp.Diagnostics, "Invalid poll_interval")
}

func TestRegistry(t *testing.T) {
	saved := registry
	defer func() { registry = saved }()
	registry = nil
	for _, ty := range []*typeDesc{part(), scope(), gadget()} {
		register(ty)
	}
	ctx := context.Background()
	p := New("test")()
	var meta provider.MetadataResponse
	p.Metadata(ctx, provider.MetadataRequest{}, &meta)
	if meta.TypeName != "ubicloud" || meta.Version != "test" {
		t.Errorf("provider metadata %+v", meta)
	}
	c := &client{}
	var names []string
	for _, f := range p.Resources(ctx) {
		r := f().(*genericResource)
		var m resource.MetadataResponse
		r.Metadata(ctx, resource.MetadataRequest{}, &m)
		var s resource.SchemaResponse
		r.Schema(ctx, resource.SchemaRequest{}, &s)
		var ids resource.IdentitySchemaResponse
		r.IdentitySchema(ctx, resource.IdentitySchemaRequest{}, &ids)
		r.Configure(ctx, resource.ConfigureRequest{}, nil)
		r.Configure(ctx, resource.ConfigureRequest{ProviderData: c}, nil)
		if s.Schema.Attributes["id"] == nil || ids.IdentitySchema.Attributes["id"] == nil || r.c != c {
			t.Errorf("resource %s: schema, identity or client missing", m.TypeName)
		}
		names = append(names, m.TypeName)
	}
	for _, f := range p.DataSources(ctx) {
		d := f().(*genericDataSource)
		var m datasource.MetadataResponse
		d.Metadata(ctx, datasource.MetadataRequest{}, &m)
		var s datasource.SchemaResponse
		d.Schema(ctx, datasource.SchemaRequest{}, &s)
		d.Configure(ctx, datasource.ConfigureRequest{}, nil)
		d.Configure(ctx, datasource.ConfigureRequest{ProviderData: c}, nil)
		if s.Schema.Attributes["id"] == nil || d.c != c {
			t.Errorf("datasource %s: schema or client missing", m.TypeName)
		}
		names = append(names, "data "+m.TypeName)
	}
	if got := strings.Join(names, ", "); got != "ubicloud_part, ubicloud_gadget, data ubicloud_part, data ubicloud_scope, data ubicloud_gadget" {
		t.Errorf("registered %s", got)
	}
}
