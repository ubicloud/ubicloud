package provider

import (
	"context"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/identityschema"
	rschema "github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/tfsdk"
	"github.com/hashicorp/terraform-plugin-go/tftypes"
)

// gadget is a named type with a lifecycle, a write-only input that replaces,
// a rename and a verb that runs after create.
func gadget() *typeDesc {
	t := newType("gadget", "/{project_id}/location/{location}/gadget/{id}", "A gadget")
	t.create("POST", "/{project_id}/location/{location}/gadget/{name}", "secret", "size")
	t.datasource("id", "name")
	t.pending("state", "creating", "deleting")
	t.failed("state", "broken")
	t.attr("id", str, computed|stable, "ID of the gadget")
	t.attr("location", str, required|replace, "Location")
	t.attr("name", str, required, "Name")
	t.attr("note", str, optional|computed|stable, "Note, which only the PATCH sets")
	t.attr("secret", str, optional|sensitive|replace|writeOnly, "Secret")
	t.attr("size", i64, optional|computed|stable, "Size", defaultInt(2))
	t.attr("state", str, computed, "State")
	t.verb("POST", "/rename", "name")
	t.verb("PATCH", "", "note", "size")
	return t
}

// part is a nameless child type without a lifecycle.
func part() *typeDesc {
	t := newType("part", "/{project_id}/location/{location}/gadget/{gadget_id}/part/{id}", "A part")
	t.create("POST", "/{project_id}/location/{location}/gadget/{gadget_id}/part", "label")
	t.attr("gadget_id", str, required|replace, "ID of the gadget")
	t.attr("id", str, computed|stable, "ID of the part")
	t.attr("label", str, required|replace, "Label")
	t.attr("location", str, required|replace, "Location")
	return t
}

const (
	gadgetPath  = "/p1/location/l1/gadget/g1"
	creating    = `{"id":"g1","location":"l1","name":"web","note":"","size":2,"state":"creating"}`
	running     = `{"id":"g1","location":"l1","name":"web","note":"","size":2,"state":"running"}`
	runningNote = `{"id":"g1","location":"l1","name":"web","note":"hi","size":2,"state":"running"}`
)

type harness struct {
	api    *fakeAPI
	r      *genericResource
	schema rschema.Schema
	ids    identityschema.Schema
}

func newHarness(t *testing.T, ty *typeDesc, replies map[string][]reply) *harness {
	api := newFakeAPI(t, replies)
	return &harness{api, &genericResource{ty, api.client()}, resourceSchema(context.Background(), ty), identitySchema(ty)}
}

// object builds the type's object from vals, with every other attribute null.
func (h *harness) object(vals values) tftypes.Value {
	typ := h.schema.Type().TerraformType(context.Background()).(tftypes.Object)
	full := values{}
	for n, at := range typ.AttributeTypes {
		full[n] = tftypes.NewValue(at, nil)
		if v, ok := vals[n]; ok {
			full[n] = v
		}
	}
	return tftypes.NewValue(typ, full)
}

func (h *harness) null() tfsdk.State {
	return tfsdk.State{Schema: h.schema, Raw: tftypes.NewValue(h.schema.Type().TerraformType(context.Background()), nil)}
}

func (h *harness) state(vals values) tfsdk.State {
	return tfsdk.State{Schema: h.schema, Raw: h.object(vals)}
}

func (h *harness) identity() *tfsdk.ResourceIdentity {
	return &tfsdk.ResourceIdentity{Schema: h.ids, Raw: tftypes.NewValue(h.ids.Type().TerraformType(context.Background()), nil)}
}

// text shows a value as the tests compare it.
func text(v tftypes.Value) string {
	var s string
	var f big.Float
	switch {
	case !v.IsKnown():
		return "?"
	case v.IsNull():
		return "-"
	case v.As(&s) == nil:
		return s
	case v.As(&f) == nil:
		return f.String()
	}
	return v.String()
}

func show(raw tftypes.Value, names ...string) string {
	vals := valuesOf(raw)
	var out []string
	for _, n := range names {
		out = append(out, n+"="+text(vals[n]))
	}
	return strings.Join(out, " ")
}

func checkDiags(t *testing.T, diags diag.Diagnostics, want string) {
	t.Helper()
	var got []string
	for _, d := range diags {
		got = append(got, d.Summary()+": "+d.Detail())
	}
	if all := strings.Join(got, "\n"); want == "" && all != "" || !strings.Contains(all, want) {
		t.Errorf("diagnostics:\n%s\nwant %q", all, want)
	}
}

var unknownStr = tftypes.NewValue(tftypes.String, tftypes.UnknownValue)

func (h *harness) create(plan values) *resource.CreateResponse {
	resp := &resource.CreateResponse{State: h.null(), Identity: h.identity()}
	h.r.Create(context.Background(), resource.CreateRequest{Plan: tfsdk.Plan{Schema: h.schema, Raw: h.object(plan)}}, resp)
	return resp
}

func gadgetPlan(note tftypes.Value) values {
	return values{"location": tfStr("l1"), "name": tfStr("web"), "secret": tfStr("s3"), "size": tftypes.NewValue(tftypes.Number, 2),
		"id": unknownStr, "note": note, "state": unknownStr}
}

func TestCreate(t *testing.T) {
	h := newHarness(t, gadget(), map[string][]reply{
		"POST /p1/location/l1/gadget/web": {{200, `{"id":"g1"}`, ""}},
		"GET " + gadgetPath:               {{200, creating, ""}, {200, running, ""}, {200, runningNote, ""}},
		"PATCH " + gadgetPath:             {{200, runningNote, ""}},
	})
	resp := h.create(gadgetPlan(tfStr("hi")))
	checkDiags(t, resp.Diagnostics, "")
	want := `POST /p1/location/l1/gadget/web {"secret":"s3","size":2}
GET /p1/location/l1/gadget/g1
GET /p1/location/l1/gadget/g1
PATCH /p1/location/l1/gadget/g1 {"note":"hi","size":2}
GET /p1/location/l1/gadget/g1`
	if got := h.api.requests(); got != want {
		t.Errorf("requests:\n%s\nwant:\n%s", got, want)
	}
	if got := show(resp.State.Raw, "id", "note", "secret", "size", "state"); got != "id=g1 note=hi secret=s3 size=2 state=running" {
		t.Errorf("state %s", got)
	}
	if got := show(resp.Identity.Raw, "location", "id"); got != "location=l1 id=g1" {
		t.Errorf("identity %s", got)
	}
}

func TestCreateFailsAfterPartialState(t *testing.T) {
	for get, want := range map[reply]string{
		{200, strings.Replace(creating, "creating", "broken", 1), ""}: `/p1/location/l1/gadget/g1 failed: its state is "broken"`,
		{404, notFound, ""}: "/p1/location/l1/gadget/g1 disappeared",
		{500, "", ""}:       "GET /p1/location/l1/gadget/g1: 500 Internal Server Error",
	} {
		h := newHarness(t, gadget(), map[string][]reply{"POST /p1/location/l1/gadget/web": {{200, `{"id":"g1"}`, ""}}, "GET " + gadgetPath: {get}})
		resp := h.create(gadgetPlan(unknownStr))
		checkDiags(t, resp.Diagnostics, "Error creating ubicloud_gadget: "+want)
		if got := show(resp.State.Raw, "id", "name", "note", "state"); got != "id=g1 name=web note=- state=-" {
			t.Errorf("partial state %s", got)
		}
	}
}

func TestCreateTimesOut(t *testing.T) {
	h := newHarness(t, gadget(), map[string][]reply{
		"POST /p1/location/l1/gadget/web": {{200, `{"id":"g1"}`, ""}},
		"GET " + gadgetPath:               {{200, creating, ""}},
	})
	resp := h.create(h.timeouts(gadgetPlan(unknownStr), "30ms"))
	checkDiags(t, resp.Diagnostics, `timed out waiting on /p1/location/l1/gadget/g1; its state was last "creating"`)
	checkDiags(t, resp.Diagnostics, "To wait longer, raise timeouts.create.")
}

// timeouts gives plan a timeouts block that sets the create timeout.
func (h *harness) timeouts(plan values, create string) values {
	tt := h.schema.Type().TerraformType(context.Background()).(tftypes.Object).AttributeTypes["timeouts"].(tftypes.Object)
	null := tftypes.NewValue(tftypes.String, nil)
	plan["timeouts"] = tftypes.NewValue(tt, values{"create": tfStr(create), "update": null, "delete": null})
	return plan
}

func TestCreateUnknownOutcome(t *testing.T) {
	const post, byName = "POST /p1/location/l1/gadget/web", "GET /p1/location/l1/gadget/web"
	lost := reply{503, "", ""}
	taken := reply{400, `{"error":{"code":400,"type":"InvalidRequest","message":"project_id and location_id and name is already taken",` +
		`"details":{"name":"project_id and location_id and name is already taken"}}}`, ""}
	refused := reply{400, `{"error":{"code":400,"type":"InvalidRequest","message":"no"}}`, ""}
	forbidden := reply{403, `{"error":{"code":403,"type":"Forbidden","message":"no"}}`, ""}
	tests := []struct {
		name    string
		replies map[string][]reply
		creates int
		want    string // "" for success, else a substring of the diagnostics
	}{
		{"the object found by name is adopted", map[string][]reply{post: {lost}, byName: {{200, running, ""}}}, 1, ""},
		{"an empty answer is lost, and on a 404 the create is sent again", map[string][]reply{post: {{200, "", ""}, {200, `{"id":"g1"}`, ""}}}, 2, ""},
		{"a taken name is looked up again", map[string][]reply{post: {lost, taken}, byName: {{404, notFound, ""}, {200, running, ""}}}, 2, ""},
		{"another refusal of the repeated create is reported", map[string][]reply{post: {lost, refused}}, 2,
			"Error creating ubicloud_gadget: POST /p1/location/l1/gadget/web: 400 InvalidRequest: no"},
		{"a failed lookup is reported", map[string][]reply{post: {lost}, byName: {forbidden}}, 1,
			"GET /p1/location/l1/gadget/web: 403 Forbidden: no\n\nThe create may have taken effect. " +
				"If it did, the object is under /p1/location/l1/gadget/web; import it with: terraform import ADDRESS l1/web"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tt.replies["GET "+gadgetPath] = []reply{{200, running, ""}}
			h := newHarness(t, gadget(), tt.replies)
			resp := h.create(gadgetPlan(unknownStr))
			checkDiags(t, resp.Diagnostics, tt.want)
			if n := strings.Count(h.api.requests(), "POST"); n != tt.creates {
				t.Errorf("%d creates, want %d:\n%s", n, tt.creates, h.api.requests())
			}
			if got := show(resp.State.Raw, "id"); tt.want == "" && got != "id=g1" {
				t.Errorf("state %s", got)
			}
		})
	}
}

// The deadline leaves the outcome unknown, whether it falls while the
// repeated create is lost or while it is refused.
func TestCreateUnknownOutcomeUntilDeadline(t *testing.T) {
	busy := reply{409, `{"error":{"code":409,"type":"Busy","message":"busy"}}`, "0"}
	for name, again := range map[string]reply{"lost": {503, "", ""}, "refused": busy} {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t, gadget(), map[string][]reply{"POST /p1/location/l1/gadget/web": {{503, "", ""}, again}})
			h.r.c.poll = time.Hour
			resp := h.create(h.timeouts(gadgetPlan(unknownStr), "50ms"))
			checkDiags(t, resp.Diagnostics, "the object is under /p1/location/l1/gadget/web; import it with: terraform import ADDRESS l1/web")
			checkDiags(t, resp.Diagnostics, "To wait longer, raise timeouts.create.")
			want := `POST /p1/location/l1/gadget/web {"secret":"s3","size":2}
GET /p1/location/l1/gadget/web
POST /p1/location/l1/gadget/web {"secret":"s3","size":2}`
			if got := h.api.requests(); got != want {
				t.Errorf("requests:\n%s\nwant:\n%s", got, want)
			}
		})
	}
}

func TestCreateUnknownOutcomeWithoutName(t *testing.T) {
	h := newHarness(t, part(), map[string][]reply{"POST /p1/location/l1/gadget/g1/part": {{503, "", ""}}})
	resp := h.create(values{"location": tfStr("l1"), "gadget_id": tfStr("g1"), "label": tfStr("x"), "id": unknownStr})
	checkDiags(t, resp.Diagnostics, "POST /p1/location/l1/gadget/g1/part: 503 Service Unavailable\n\nThe create may have taken effect. "+
		"If it did, the object is under /p1/location/l1/gadget/g1/part; import it with: terraform import ADDRESS l1/g1/ID")
	if got := h.api.requests(); got != `POST /p1/location/l1/gadget/g1/part {"label":"x"}` {
		t.Errorf("requests:\n%s", got)
	}
}

func TestCreateReportsDetails(t *testing.T) {
	h := newHarness(t, gadget(), map[string][]reply{"POST /p1/location/l1/gadget/web": {{400,
		`{"error":{"code":400,"type":"InvalidRequest","message":"Validation failed for following fields: name, body","details":{"name":"is taken","body":"is odd"}}}`, ""}}})
	resp := h.create(gadgetPlan(unknownStr))
	checkDiags(t, resp.Diagnostics, "POST /p1/location/l1/gadget/web: 400 InvalidRequest: Validation failed for following fields: name, body\nbody: is odd")
	if len(resp.Diagnostics) != 2 || resp.Diagnostics[1].Detail() != "is taken" {
		t.Errorf("diagnostics %v", resp.Diagnostics)
	}
}

func TestRead(t *testing.T) {
	h := newHarness(t, gadget(), map[string][]reply{
		"GET /p1/location/l1/gadget/web":   {{200, running, ""}},
		"GET /p1/location/l1/gadget/odd":   {{200, `{"id":5}`, ""}},
		"GET /p1/location/l1/gadget/empty": {{200, "", ""}},
	})
	prior := h.state(values{"location": tfStr("l1"), "id": tfStr("web"), "secret": tfStr("s3")})
	resp := &resource.ReadResponse{State: prior, Identity: h.identity()}
	h.r.Read(context.Background(), resource.ReadRequest{State: prior}, resp)
	checkDiags(t, resp.Diagnostics, "")
	if got := show(resp.State.Raw, "id", "name", "secret", "state"); got != "id=g1 name=web secret=s3 state=running" {
		t.Errorf("state %s", got)
	}

	odd := h.state(values{"location": tfStr("l1"), "id": tfStr("odd")})
	resp = &resource.ReadResponse{State: odd, Identity: h.identity()}
	h.r.Read(context.Background(), resource.ReadRequest{State: odd}, resp)
	checkDiags(t, resp.Diagnostics, "Error reading ubicloud_gadget: id: expected a string, got 5")

	empty := h.state(values{"location": tfStr("l1"), "id": tfStr("empty")})
	resp = &resource.ReadResponse{State: empty, Identity: h.identity()}
	h.r.Read(context.Background(), resource.ReadRequest{State: empty}, resp)
	checkDiags(t, resp.Diagnostics, "Error reading ubicloud_gadget: the response is empty")

	gone := h.state(values{"location": tfStr("l1"), "id": tfStr("g9")})
	resp = &resource.ReadResponse{State: gone, Identity: h.identity()}
	h.r.Read(context.Background(), resource.ReadRequest{State: gone}, resp)
	if !resp.State.Raw.IsNull() {
		t.Errorf("a 404 kept state %v", resp.State.Raw)
	}
}

func TestUpdate(t *testing.T) {
	h := newHarness(t, gadget(), map[string][]reply{
		"POST " + gadgetPath + "/rename": {{200, running, ""}},
		"PATCH " + gadgetPath:            {{200, running, ""}},
		"GET " + gadgetPath: {{200, `{"id":"g1","name":"web2","size":2,"state":"running"}`, ""},
			{200, `{"id":"g1","name":"web2","note":"hi","size":2,"state":"running"}`, ""}},
	})
	prior := values{"location": tfStr("l1"), "id": tfStr("g1"), "name": tfStr("web"), "note": tfStr(""), "size": tftypes.NewValue(tftypes.Number, 2), "state": tfStr("running")}
	plan := map[string]tftypes.Value{}
	for k, v := range prior {
		plan[k] = v
	}
	plan["name"], plan["note"], plan["secret"], plan["state"] = tfStr("web2"), tfStr("hi"), tfStr("adopted"), unknownStr
	resp := h.update(prior, plan, true)
	checkDiags(t, resp.Diagnostics, "")
	want := `POST /p1/location/l1/gadget/g1/rename {"name":"web2"}
GET /p1/location/l1/gadget/g1
PATCH /p1/location/l1/gadget/g1 {"note":"hi","size":2}
GET /p1/location/l1/gadget/g1`
	if got := h.api.requests(); got != want {
		t.Errorf("requests:\n%s\nwant:\n%s", got, want)
	}
	if got := show(resp.State.Raw, "name", "note", "secret", "state"); got != "name=web2 note=hi secret=adopted state=running" {
		t.Errorf("state %s", got)
	}
	if v, _ := resp.Private.GetKey(context.Background(), importedKey); v != nil {
		t.Errorf("the import marker survived the update")
	}
}

func TestUpdateAdopts(t *testing.T) {
	h := newHarness(t, gadget(), map[string][]reply{"GET " + gadgetPath: {{200, running, ""}}})
	prior := values{"location": tfStr("l1"), "id": tfStr("g1"), "name": tfStr("web")}
	plan := values{"location": tfStr("l1"), "id": tfStr("g1"), "name": tfStr("web"), "secret": tfStr("s3")}
	resp := h.update(prior, plan, true)
	checkDiags(t, resp.Diagnostics, "")
	if got := h.api.requests(); got != "GET "+gadgetPath {
		t.Errorf("requests:\n%s", got)
	}
	if got := show(resp.State.Raw, "secret", "state"); got != "secret=s3 state=running" {
		t.Errorf("state %s", got)
	}

	h = newHarness(t, gadget(), nil)
	checkDiags(t, h.update(prior, plan, true).Diagnostics, "Error updating ubicloud_gadget: /p1/location/l1/gadget/g1 disappeared")
}

func TestUpdateKeepsWhatTookEffect(t *testing.T) {
	h := newHarness(t, gadget(), map[string][]reply{
		"POST " + gadgetPath + "/rename": {{200, running, ""}},
		"PATCH " + gadgetPath:            {{400, `{"error":{"code":400,"type":"InvalidRequest","message":"no"}}`, ""}},
		"GET " + gadgetPath:              {{200, `{"id":"g1","name":"web2","note":"","size":2,"state":"running"}`, ""}},
	})
	prior := values{"location": tfStr("l1"), "id": tfStr("g1"), "name": tfStr("web"), "note": tfStr("")}
	plan := values{"location": tfStr("l1"), "id": tfStr("g1"), "name": tfStr("web2"), "note": tfStr("hi")}
	resp := h.update(prior, plan, false)
	checkDiags(t, resp.Diagnostics, "PATCH /p1/location/l1/gadget/g1: 400 InvalidRequest: no")
	if got := show(resp.State.Raw, "name", "note"); got != "name=web2 note=" {
		t.Errorf("state %s", got)
	}
}

func (h *harness) update(prior, plan values, imported bool) *resource.UpdateResponse {
	imp := h.importState("l1/g1")
	if !imported {
		newPrivate(&imp.Private)
	}
	resp := &resource.UpdateResponse{State: h.state(plan), Identity: h.identity(), Private: imp.Private}
	h.r.Update(context.Background(), resource.UpdateRequest{State: h.state(prior), Plan: tfsdk.Plan{Schema: h.schema, Raw: h.object(plan)}, Private: imp.Private}, resp)
	return resp
}

func TestDelete(t *testing.T) {
	h := newHarness(t, gadget(), map[string][]reply{
		"DELETE " + gadgetPath: {{204, "", ""}},
		"GET " + gadgetPath:    {{200, strings.Replace(running, "running", "deleting", 1), ""}, {404, notFound, ""}},
	})
	resp := &resource.DeleteResponse{}
	h.r.Delete(context.Background(), resource.DeleteRequest{State: h.state(values{"location": tfStr("l1"), "id": tfStr("g1")})}, resp)
	checkDiags(t, resp.Diagnostics, "")
	if got := h.api.requests(); strings.Count(got, "GET") != 2 {
		t.Errorf("requests:\n%s", got)
	}

	h = newHarness(t, gadget(), nil)
	resp = &resource.DeleteResponse{}
	h.r.Delete(context.Background(), resource.DeleteRequest{State: h.state(values{"location": tfStr("l1"), "id": tfStr("g1")})}, resp)
	checkDiags(t, resp.Diagnostics, "")
}

func TestMissingKey(t *testing.T) {
	h := newHarness(t, gadget(), nil)
	ctx := context.Background()
	keyless := values{"id": tfStr("g1"), "name": tfStr("web")}
	want := "{location} in /{project_id}/location/{location}/gadget/"
	checkDiags(t, h.create(keyless).Diagnostics, "Error creating ubicloud_gadget: "+want+"{name} has no value")
	read := &resource.ReadResponse{State: h.state(keyless), Identity: h.identity()}
	h.r.Read(ctx, resource.ReadRequest{State: h.state(keyless)}, read)
	checkDiags(t, read.Diagnostics, "Error reading ubicloud_gadget: "+want+"{id} has no value")
	checkDiags(t, h.update(keyless, keyless, false).Diagnostics, "Error updating ubicloud_gadget: "+want+"{id} has no value")
	var del resource.DeleteResponse
	h.r.Delete(ctx, resource.DeleteRequest{State: h.state(keyless)}, &del)
	checkDiags(t, del.Diagnostics, "Error deleting ubicloud_gadget: "+want+"{id} has no value")
	if n := h.api.attempts(); n != 0 {
		t.Errorf("%d requests sent", n)
	}
}

// newPrivate gives a response the private state the framework would; its
// type is internal to the framework.
func newPrivate[T any](p **T) { *p = new(T) }

func (h *harness) importState(id string) *resource.ImportStateResponse {
	resp := &resource.ImportStateResponse{State: h.null(), Identity: h.identity()}
	newPrivate(&resp.Private)
	h.r.ImportState(context.Background(), resource.ImportStateRequest{ID: id}, resp)
	return resp
}

func TestImportState(t *testing.T) {
	h := newHarness(t, part(), nil)
	resp := h.importState("l1/g1/p1")
	checkDiags(t, resp.Diagnostics, "")
	if got := show(resp.State.Raw, "location", "gadget_id", "id", "label"); got != "location=l1 gadget_id=g1 id=p1 label=-" {
		t.Errorf("state %s", got)
	}
	if got := show(resp.Identity.Raw, "location", "gadget_id", "id"); got != "location=l1 gadget_id=g1 id=p1" {
		t.Errorf("identity %s", got)
	}
	if v, _ := resp.Private.GetKey(context.Background(), importedKey); v == nil {
		t.Errorf("no import marker")
	}
	checkDiags(t, h.importState("l1/p1").Diagnostics, `Expected an import ID of the form <location>/<gadget_id>/<id>, got "l1/p1".`)

	identity := h.identity()
	identity.Raw = tftypes.NewValue(identity.Raw.Type(), values{"location": tfStr("l2"), "gadget_id": tfStr("g2"), "id": tfStr("p2")})
	resp = &resource.ImportStateResponse{State: h.null(), Identity: h.identity()}
	newPrivate(&resp.Private)
	h.r.ImportState(context.Background(), resource.ImportStateRequest{Identity: identity}, resp)
	if got := show(resp.State.Raw, "location", "gadget_id", "id"); got != "location=l2 gadget_id=g2 id=p2" {
		t.Errorf("state %s", got)
	}
}
