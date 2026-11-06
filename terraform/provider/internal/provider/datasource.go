package provider

import (
	"context"
	"maps"
	"net/http"

	"github.com/hashicorp/terraform-plugin-framework-validators/datasourcevalidator"
	"github.com/hashicorp/terraform-plugin-framework/datasource"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-go/tftypes"
)

type genericDataSource struct {
	t *typeDesc
	c *client
}

var (
	_ datasource.DataSourceWithConfigure        = (*genericDataSource)(nil)
	_ datasource.DataSourceWithConfigValidators = (*genericDataSource)(nil)
)

func (d *genericDataSource) Metadata(_ context.Context, _ datasource.MetadataRequest, resp *datasource.MetadataResponse) {
	resp.TypeName = d.t.typeName()
}

func (d *genericDataSource) Schema(_ context.Context, _ datasource.SchemaRequest, resp *datasource.SchemaResponse) {
	resp.Schema = datasourceSchema(d.t)
}

func (d *genericDataSource) Configure(_ context.Context, req datasource.ConfigureRequest, _ *datasource.ConfigureResponse) {
	if c, ok := req.ProviderData.(*client); ok {
		d.c = c
	}
}

func (d *genericDataSource) ConfigValidators(context.Context) []datasource.ConfigValidator {
	if len(d.t.lookup) < 2 {
		return nil
	}
	var exprs []path.Expression
	for _, n := range d.t.lookup {
		exprs = append(exprs, path.MatchRoot(n))
	}
	return []datasource.ConfigValidator{datasourcevalidator.ExactlyOneOf(exprs...)}
}

// Read gets the item path, with the given lookup value in place of its last
// placeholder. A datasource whose item path has only {project_id} takes no
// lookup value.
func (d *genericDataSource) Read(ctx context.Context, req datasource.ReadRequest, resp *datasource.ReadResponse) {
	cfg := valuesOf(req.Config.Raw)
	ctx, cancel := context.WithTimeout(ctx, readTimeout)
	defer cancel()
	vals := maps.Clone(cfg)
	if ids := d.t.identity(); len(ids) > 0 {
		for _, n := range d.t.lookup {
			if !cfg[n].IsNull() {
				vals[ids[len(ids)-1]] = cfg[n]
			}
		}
	}
	item, err := d.c.fill(d.t.item, vals)
	var body map[string]any
	if err == nil {
		body, err = d.c.do(ctx, request{method: http.MethodGet, path: item})
	}
	var state values
	if err == nil {
		state, err = d.t.state(body, cfg)
	}
	if err != nil {
		report(&resp.Diagnostics, &d.t.objectDesc, "Error reading "+d.t.typeName(), err)
		return
	}
	for _, a := range d.t.attrs {
		if a.has(writeOnly) {
			delete(state, a.name)
		}
	}
	resp.State.Raw = tftypes.NewValue(resp.State.Schema.Type().TerraformType(ctx), known(state))
}
