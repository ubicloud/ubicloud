package provider

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/tfsdk"
	"github.com/hashicorp/terraform-plugin-go/tftypes"
)

// genericResource serves every resource type. It holds the control flow, and
// the type's descriptor holds the facts.
type genericResource struct {
	t *typeDesc
	c *client
}

var (
	_ resource.ResourceWithConfigure   = (*genericResource)(nil)
	_ resource.ResourceWithIdentity    = (*genericResource)(nil)
	_ resource.ResourceWithImportState = (*genericResource)(nil)
)

// defaultTimeouts holds the timeouts block's defaults, which are the same for
// every type. The block does not cover reads; readTimeout bounds those.
var defaultTimeouts = map[string]time.Duration{"create": 120 * time.Minute, "update": 120 * time.Minute, "delete": 60 * time.Minute}

const readTimeout = 10 * time.Minute

func (r *genericResource) Metadata(_ context.Context, _ resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = r.t.typeName()
}

func (r *genericResource) Schema(ctx context.Context, _ resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = resourceSchema(ctx, r.t)
}

func (r *genericResource) IdentitySchema(_ context.Context, _ resource.IdentitySchemaRequest, resp *resource.IdentitySchemaResponse) {
	resp.IdentitySchema = identitySchema(r.t)
}

func (r *genericResource) Configure(_ context.Context, req resource.ConfigureRequest, _ *resource.ConfigureResponse) {
	if c, ok := req.ProviderData.(*client); ok {
		r.c = c
	}
}

// Create sends the create and immediately writes the keys, the id and the
// planned inputs, so that a later failure leaves a resource that terraform
// taints rather than an object it does not know about. It then settles, runs
// each verb that owns a configured attribute the create does not carry,
// settling after each, and writes the state from the last read.
func (r *genericResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	plan := valuesOf(req.Plan.Raw)
	ctx, cancel := context.WithTimeout(ctx, deadline(plan, "create"))
	defer cancel()
	id, err := r.post(ctx, plan)
	if err != nil {
		r.fail(&resp.Diagnostics, "create", err)
		return
	}
	state := maps.Clone(plan)
	state["id"] = tftypes.NewValue(tftypes.String, id)
	r.write(ctx, &resp.State, resp.Identity, state)
	item, _ := r.c.fill(r.t.item, state)
	body, err := r.settle(ctx, item)
	op := r.t.createOp
	carried := append(placeholders(op.path), op.body...)
	for i, v := range r.t.verbs {
		configured := func(n string) bool {
			return !slices.Contains(carried, n) && plan[n].IsFullyKnown() && !plan[n].IsNull()
		}
		if err != nil || !slices.ContainsFunc(r.t.owned(i), configured) {
			continue
		}
		if state, err = r.t.state(body, plan); err == nil {
			_, err = r.c.do(ctx, request{method: v.method, path: item + v.path, body: r.t.body(v.body, plan, state)})
		}
		if err == nil {
			body, err = r.settle(ctx, item)
		}
	}
	if err == nil {
		state, err = r.t.state(body, plan)
	}
	if err != nil {
		r.fail(&resp.Diagnostics, "create", err)
		return
	}
	r.write(ctx, &resp.State, resp.Identity, state)
}

// post sends the create and returns the new object's id. If the outcome is
// unknown and the type is named, the name serves as the create's idempotency
// key: post looks the object up by name and adopts it, or on a 404 sends the
// create again, until the deadline. If a repeated create is refused because
// the name is taken, the object exists, so post looks it up again. A type
// without a name has no such key, so the failure is reported.
func (r *genericResource) post(ctx context.Context, plan values) (string, error) {
	op := r.t.createOp
	path, err := r.c.fill(op.path, plan)
	if err != nil {
		return "", err
	}
	create := request{method: op.method, path: path, body: r.t.body(op.body, plan, nil), once: true}
	id, lost := r.c.id(ctx, create)
	if !errors.As(lost, new(*ambiguousError)) {
		return id, lost
	}
	if !r.t.named() {
		return "", r.unknown(lost, plan, path)
	}
	byName := maps.Clone(plan)
	byName["id"] = plan["name"]
	item, _ := r.c.fill(r.t.item, byName)
	for {
		id, err := r.c.id(ctx, request{method: http.MethodGet, path: item})
		switch {
		case err == nil:
			return id, nil
		case !isNotFound(err):
			return "", r.unknown(errors.Join(lost, err), plan, path)
		}
		id, err = r.c.id(ctx, create)
		switch {
		case err == nil:
			return id, nil
		case errors.As(err, new(*ambiguousError)) || taken(err):
			err = sleep(ctx, r.c.poll)
		case errors.As(err, new(*apiError)) && ctx.Err() == nil:
			return "", err
		}
		if err != nil {
			return "", r.unknown(errors.Join(lost, err), plan, path)
		}
	}
}

// unknown reports the failure of a create whose outcome is unknown, with the
// import that takes the object over if the create took effect. Terraform does
// not tell a provider the resource's address, so the command says ADDRESS.
func (r *genericResource) unknown(err error, plan values, path string) error {
	ids := r.t.identity()
	parts := make([]string, len(ids)-1)
	for i, n := range ids[:len(ids)-1] {
		_ = plan[n].As(&parts[i])
	}
	last := "ID"
	if r.t.named() {
		_ = plan["name"].As(&last)
	}
	return fmt.Errorf("%w\n\nThe create may have taken effect. If it did, the object is under %s; import it with: terraform import ADDRESS %s",
		err, path, strings.Join(append(parts, last), "/"))
}

func (r *genericResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	prior := valuesOf(req.State.Raw)
	ctx, cancel := context.WithTimeout(ctx, readTimeout)
	defer cancel()
	item, err := r.c.fill(r.t.item, prior)
	var body map[string]any
	if err == nil {
		body, err = r.c.do(ctx, request{method: http.MethodGet, path: item})
	}
	if isNotFound(err) {
		resp.State.RemoveResource(ctx)
		return
	}
	var state values
	if err == nil {
		state, err = r.t.state(body, prior)
	}
	if err != nil {
		r.fail(&resp.Diagnostics, "read", err)
		return
	}
	r.write(ctx, &resp.State, resp.Identity, state)
}

// Update sends, in order, each verb that owns a changed attribute, and
// settles after each. A changed attribute that no verb owns, such as a
// write-only input after an import, is adopted into state with no request. If
// a verb fails, Update writes the prior state, with the planned values of the
// attributes owned by the verbs that succeeded, before reporting the error, so
// that those changes are not lost; the next refresh reads the rest.
func (r *genericResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	plan, prior := valuesOf(req.Plan.Raw), valuesOf(req.State.Raw)
	ctx, cancel := context.WithTimeout(ctx, deadline(plan, "update"))
	defer cancel()
	item, err := r.c.fill(r.t.item, prior)
	if err != nil {
		r.fail(&resp.Diagnostics, "update", err)
		return
	}
	applied := maps.Clone(prior)
	var body map[string]any
	for i, v := range r.t.verbs {
		owned := r.t.owned(i)
		changed := func(n string) bool { return plan[n].IsFullyKnown() && !plan[n].Equal(prior[n]) }
		if !slices.ContainsFunc(owned, changed) {
			continue
		}
		_, err = r.c.do(ctx, request{method: v.method, path: item + v.path, body: r.t.body(v.body, plan, prior)})
		if err == nil {
			body, err = r.settle(ctx, item)
		}
		if err != nil {
			r.write(ctx, &resp.State, resp.Identity, applied)
			r.fail(&resp.Diagnostics, "update", err)
			return
		}
		for _, n := range owned {
			applied[n] = plan[n]
		}
	}
	if body == nil {
		body, err = r.settle(ctx, item)
	}
	var state values
	if err == nil {
		state, err = r.t.state(body, plan)
	}
	if err != nil {
		r.fail(&resp.Diagnostics, "update", err)
		return
	}
	r.write(ctx, &resp.State, resp.Identity, state)
	resp.Diagnostics.Append(resp.Private.SetKey(ctx, importedKey, nil)...)
}

// Delete sends the DELETE, treating a 404 as success, and then waits until
// the object is gone.
func (r *genericResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	prior := valuesOf(req.State.Raw)
	ctx, cancel := context.WithTimeout(ctx, deadline(prior, "delete"))
	defer cancel()
	item, err := r.c.fill(r.t.item, prior)
	if err == nil {
		_, err = r.c.do(ctx, request{method: http.MethodDelete, path: item})
	}
	if err == nil || isNotFound(err) {
		err = r.gone(ctx, item)
	}
	if err != nil {
		r.fail(&resp.Diagnostics, "delete", err)
	}
}

// ImportState splits the import ID into the item path's attributes, or takes
// them from an identity, and leaves the rest to the read that follows, which
// resolves a name to the id. It writes the import marker that
// replaceUnlessImported reads.
func (r *genericResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	names := r.t.identity()
	parts := strings.Split(req.ID, "/")
	if req.ID == "" && req.Identity != nil {
		parts = make([]string, len(names))
		for i, n := range names {
			resp.Diagnostics.Append(req.Identity.GetAttribute(ctx, path.Root(n), &parts[i])...)
		}
	}
	if len(parts) != len(names) || slices.Contains(parts, "") {
		resp.Diagnostics.AddError("Error importing "+r.t.typeName(),
			fmt.Sprintf("Expected an import ID of the form <%s>, got %q.", strings.Join(names, ">/<"), req.ID))
		return
	}
	for i, n := range names {
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root(n), parts[i])...)
		resp.Diagnostics.Append(resp.Identity.SetAttribute(ctx, path.Root(n), parts[i])...)
	}
	resp.Diagnostics.Append(resp.Private.SetKey(ctx, importedKey, []byte("true"))...)
}

func (r *genericResource) write(ctx context.Context, state *tfsdk.State, identity *tfsdk.ResourceIdentity, vals values) {
	state.Raw = tftypes.NewValue(state.Schema.Type().TerraformType(ctx), known(vals))
	ids := values{}
	for _, n := range r.t.identity() {
		ids[n] = vals[n]
	}
	identity.Raw = tftypes.NewValue(identity.Schema.Type().TerraformType(ctx), known(ids))
}

// fail reports err from op with a summary such as "Error creating
// ubicloud_vm". If the deadline passed and the timeouts block covers op, it
// suggests raising that timeout.
func (r *genericResource) fail(diags *diag.Diagnostics, op string, err error) {
	if errors.Is(err, context.DeadlineExceeded) && defaultTimeouts[op] != 0 {
		err = fmt.Errorf("%w\n\nTo wait longer, raise timeouts.%s.", err, op)
	}
	report(diags, &r.t.objectDesc, "Error "+strings.TrimSuffix(op, "e")+"ing "+r.t.typeName(), err)
}

// report adds err to diags under summary, and each of the API's details to
// the attribute it names.
func report(diags *diag.Diagnostics, o *objectDesc, summary string, err error) {
	detail, fields := err.Error(), []string{}
	var e *apiError
	if errors.As(err, &e) {
		for _, k := range slices.Sorted(maps.Keys(e.details)) {
			if o.find(k) != nil {
				fields = append(fields, k)
			} else {
				detail += fmt.Sprintf("\n%s: %v", k, e.details[k])
			}
		}
	}
	diags.AddError(summary, detail)
	for _, k := range fields {
		diags.AddAttributeError(path.Root(k), summary, fmt.Sprint(e.details[k]))
	}
}

// deadline returns the timeouts block's duration for op, or its default.
func deadline(vals values, op string) time.Duration {
	var block values
	var s string
	if vals["timeouts"].As(&block) == nil && block[op].As(&s) == nil {
		if d, err := time.ParseDuration(s); err == nil {
			return d
		}
	}
	return defaultTimeouts[op]
}
