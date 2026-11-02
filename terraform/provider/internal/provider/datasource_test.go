package provider

import (
	"context"
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/datasource"
	dschema "github.com/hashicorp/terraform-plugin-framework/datasource/schema"
	"github.com/hashicorp/terraform-plugin-framework/tfsdk"
	"github.com/hashicorp/terraform-plugin-go/tftypes"
)

// scope is a datasource of the provider's scope, which takes no lookup.
func scope() *typeDesc {
	t := newType("scope", "/{project_id}", "The scope")
	t.datasource()
	t.attr("id", str, computed, "ID")
	t.attr("name", str, computed, "Name")
	return t
}

func readDataSource(t *testing.T, ty *typeDesc, api *fakeAPI, config values) *datasource.ReadResponse {
	t.Helper()
	ctx := context.Background()
	s := datasourceSchema(ty)
	typ := s.Type().TerraformType(ctx).(tftypes.Object)
	full := values{}
	for n, at := range typ.AttributeTypes {
		full[n] = tftypes.NewValue(at, nil)
		if v, ok := config[n]; ok {
			full[n] = v
		}
	}
	resp := &datasource.ReadResponse{State: tfsdk.State{Schema: s, Raw: tftypes.NewValue(typ, nil)}}
	d := &genericDataSource{ty, api.client()}
	d.Read(ctx, datasource.ReadRequest{Config: tfsdk.Config{Schema: s, Raw: tftypes.NewValue(typ, full)}}, resp)
	return resp
}

func TestDataSourceSchema(t *testing.T) {
	attrs := datasourceSchema(part()).Attributes
	if _, ok := attrs["label"]; !ok {
		t.Errorf("label is missing")
	}
	for name, want := range map[string]string{"location": "required", "gadget_id": "required", "id": "computed"} {
		a := attrs[name]
		if got := map[bool]string{true: "required", false: "computed"}[a.IsRequired()]; got != want || a.IsOptional() {
			t.Errorf("%s is %s, want %s", name, got, want)
		}
	}
	attrs = datasourceSchema(gadget()).Attributes
	if _, ok := attrs["secret"]; ok {
		t.Errorf("the write-only secret is in the datasource")
	}
	for _, name := range []string{"id", "name"} {
		if a := attrs[name].(dschema.StringAttribute); !a.Optional || !a.Computed {
			t.Errorf("lookup %s is not optional and computed", name)
		}
	}
	if n := len((&genericDataSource{t: gadget()}).ConfigValidators(context.Background())); n != 1 {
		t.Errorf("%d config validators, want one for exactly one lookup", n)
	}
	if (&genericDataSource{t: scope()}).ConfigValidators(context.Background()) != nil {
		t.Errorf("a datasource without a lookup has config validators")
	}
}

func TestDataSourceRead(t *testing.T) {
	api := newFakeAPI(t, map[string][]reply{
		"GET /p1/location/l1/gadget/web": {{200, running, ""}},
		"GET /p1":                        {{200, `{"id":"p1","name":"default"}`, ""}},
	})
	resp := readDataSource(t, gadget(), api, values{"location": tfStr("l1"), "name": tfStr("web")})
	checkDiags(t, resp.Diagnostics, "")
	if got := show(resp.State.Raw, "id", "location", "name", "size", "state"); got != "id=g1 location=l1 name=web size=2 state=running" {
		t.Errorf("state %s", got)
	}
	resp = readDataSource(t, scope(), api, nil)
	if got := show(resp.State.Raw, "id", "name"); got != "id=p1 name=default" {
		t.Errorf("state %s", got)
	}
	resp = readDataSource(t, gadget(), api, values{"location": tfStr("l1"), "id": tfStr("g9")})
	checkDiags(t, resp.Diagnostics, "Error reading ubicloud_gadget: GET /p1/location/l1/gadget/g9: 404 ResourceNotFound: not found")
}
