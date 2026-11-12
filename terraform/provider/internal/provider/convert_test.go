package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/hashicorp/terraform-plugin-go/tftypes"
)

func decodeJSON(t *testing.T, s string) any {
	t.Helper()
	dec := json.NewDecoder(strings.NewReader(s))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

func TestConvertBothWays(t *testing.T) {
	in := `{"cidr":"10.0.0.0/8","copies":9007199254740993,"created_at":"2026-11-02T10:00:00Z","enabled":true,` +
		`"nics":[{"id":"n1","ips":[{"address":"10.0.0.1"}],"mac":"m","port":22}],"options":{"auth":{"credentials":"t"},"data":{"a":{"b":"c"}}},"tags":["x","y"],"window":null,"future":1}`
	o := &everything().objectDesc
	v, err := decode(o, decodeJSON(t, in), "body")
	if err != nil {
		t.Fatal(err)
	}
	out, _ := json.Marshal(encode(o, v))
	want := `{"cidr":"10.0.0.0/8","copies":9007199254740993,"created_at":"2026-11-02T10:00:00Z","enabled":true,` +
		`"nics":[{"id":"n1","ips":[{"address":"10.0.0.1"}],"mac":"m"}],"options":{"auth":{"credentials":"t"},"data":{"a":{"b":"c"}}},"tags":["x","y"],"window":null}`
	if !bytes.Equal(out, []byte(want)) {
		t.Errorf("round trip\n got %s\nwant %s", out, want)
	}
}

func TestDecodeRefusesMismatches(t *testing.T) {
	nic := object()
	nic.attr("port", i64, computed, "Port")
	vm := object()
	vm.attr("firewall_ids", listOf(str), computed, "Firewalls", idsOf("firewalls"))
	tests := []struct {
		ty   attrType
		in   string
		want string
	}{
		{str, `5`, "x: expected a string, got 5"},
		{i64, `2.5`, "x: expected an integer, got 2.5"},
		{i64, `1e30`, "x: expected an integer, got 1e30"},
		{boolean, `"yes"`, `x: expected a boolean, got "yes"`},
		{listOf(str), `{"a":1}`, `x: expected an array, got {"a":1}`},
		{mapOf(str), `{"k":1}`, `x["k"]: expected a string, got 1`},
		{listOf(nic), `[{"port":"22"}]`, `x[0].port: expected an integer, got "22"`},
		{single(nic), `[]`, `x: expected an object, got []`},
		{single(vm), `{"firewalls":[5]}`, `x.firewall_ids[0]: expected a string, got 5`},
		{single(vm), `{"firewalls":[{"name":"a"}]}`, `x.firewall_ids[0]: expected a string, got {"name":"a"}`},
		{single(vm), `{"firewalls":[{"id":null}]}`, `x.firewall_ids[0]: expected a string, got {"id":null}`},
	}
	for _, tt := range tests {
		if _, err := decode(tt.ty, decodeJSON(t, tt.in), "x"); err == nil || err.Error() != tt.want {
			t.Errorf("decode(%s) = %v, want %q", tt.in, err, tt.want)
		}
	}
}

// An attribute declared with idsOf holds the ids of the objects in the
// property it names, in a type or in a nested object, as a list or a set.
// A null or missing property gives null, and an empty array no ids.
func TestStateReadsIDs(t *testing.T) {
	ty := newType("x", "/x/{id}", "X")
	ty.attr("firewall_ids", listOf(str), computed, "Firewalls", idsOf("firewalls"))
	ty.attr("subnet_id", str, computed, "Subnet", idsOf("subnet"))
	ty.attr("vm_ids", setOf(str), computed, "VMs", idsOf("vms"))
	ty.attr("nic_ids", listOf(str), computed, "NICs", idsOf("nics"))
	ty.attr("lb_id", str, computed, "Load balancer", idsOf("lb"))
	ty.attr("disk_ids", listOf(str), computed, "Disks", idsOf("disks"))
	pool := object()
	pool.attr("vm_ids", listOf(str), computed, "VMs", idsOf("vms"))
	ty.attr("pool", single(pool), computed, "Pool")
	body := decodeJSON(t, `{"firewalls":[{"id":"f1","name":"a"},{"id":"f2"}],"subnet":{"id":"s1"},"vms":[{"id":"v2"},{"id":"v1"}],"nics":[],"lb":null,"pool":{"vms":[{"id":"v1"}]}}`).(map[string]any)
	state, err := ty.state(body, values{})
	if err != nil {
		t.Fatal(err)
	}
	got, _ := json.Marshal(encode(&ty.objectDesc, tftypes.NewValue(ty.valueType().TerraformType(context.Background()), state)))
	if want := `{"firewall_ids":["f1","f2"],"nic_ids":[],"pool":{"vm_ids":["v1"]},"subnet_id":"s1","vm_ids":["v2","v1"]}`; string(got) != want {
		t.Errorf("state = %s, want %s", got, want)
	}
	if !state["lb_id"].IsNull() || !state["disk_ids"].IsNull() {
		t.Errorf("lb_id = %v, disk_ids = %v, want both null", state["lb_id"], state["disk_ids"])
	}
}

// Right after a create, body falls back to the state read from the API, whose
// write-only inputs are the planned ones and so may still be unknown.
func TestBody(t *testing.T) {
	ty := newType("x", "/x/{id}", "X")
	names := []string{"planned", "unset", "unknown", "unrecorded", "null", "cleared"}
	for _, n := range names {
		ty.attr(n, str, optional, n)
	}
	ty.find("cleared").flags |= nullable
	null := tftypes.NewValue(tftypes.String, nil)
	plan := values{"planned": tfStr("p"), "unset": unknownStr, "unknown": unknownStr, "unrecorded": unknownStr, "null": null, "cleared": null}
	got, _ := json.Marshal(ty.body(names, plan, values{"unset": tfStr("prior"), "unrecorded": unknownStr}))
	if want := `{"cleared":null,"planned":"p","unset":"prior"}`; string(got) != want {
		t.Errorf("body = %s, want %s", got, want)
	}
}
