package provider

import (
	"context"
	"testing"

	rschema "github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
)

// everything has an attribute of every kind, with every check and default.
func everything() *typeDesc {
	t := newType("everything", "/{project_id}/location/{location}/everything/{id}", "Everything")
	t.create("POST", "/{project_id}/location/{location}/everything/{name}", "cidr", "ports", "size", "options")
	t.datasource("id", "name")
	ip := object()
	ip.attr("address", str, computed, "Address")
	nic := object()
	nic.attr("id", str, computed, "ID")
	nic.attr("ips", listOf(ip), computed, "IPs")
	nic.attr("mac", str, computed|sensitive, "MAC")
	auth := object()
	auth.attr("credentials", str, required, "Credentials")
	opts := object()
	opts.attr("auth", single(auth), optional, "Authorization")
	opts.attr("headers", mapOf(str), optional, "Headers")
	opts.attr("data", mapOf(mapOf(str)), optional, "Structured data")
	t.attr("cidr", stringOf("cidr"), required, "CIDR")
	t.attr("copies", i64, optional, "Copies", atMost(9))
	t.attr("created_at", timestamp, computed|stable, "Created")
	t.attr("enabled", boolean, optional|computed|stable|replace, "Enabled", defaultBool(false))
	t.attr("id", str, computed|stable, "ID")
	t.attr("labels", mapOf(str), optional|computed|stable, "Labels")
	t.attr("location", str, required|replace, "Location")
	t.attr("name", str, required, "Name", atLeast(1), atMost(63), matches(`^[a-z]`))
	t.attr("nics", listOf(nic), computed, "NICs")
	t.attr("options", single(opts), optional|sensitive|replace|writeOnly, "Options")
	t.attr("ports", stringOf("port-range"), optional|computed|stable, "Ports", defaultString("0..65535"))
	t.attr("primary", single(nic), computed, "Primary NIC")
	t.attr("protocol", str, optional, "Protocol", oneOf("tcp", "udp"))
	t.attr("public", boolean, computed, "Public")
	t.attr("rules", setOf(nic), computed, "Rules")
	t.attr("size", i64, optional|computed|stable, "Size", atLeast(1), atMost(10), defaultInt(2))
	t.attr("tags", setOf(str), optional|computed|stable|replace, "Tags")
	t.attr("members", listOf(str), computed, "Members")
	t.attr("window", i64, optional|nullable, "Window", atLeast(0))
	t.attr("zones", i64, optional, "Zones", oneOf(1, 3))
	return t
}

func TestResourceAttributes(t *testing.T) {
	attrs := resourceSchema(context.Background(), everything()).Attributes
	options := attrs["options"].(rschema.SingleNestedAttribute)
	if !options.Sensitive || len(options.PlanModifiers) != 1 || options.PlanModifiers[0] != planmodifier.Object(replaceUnlessImported) {
		t.Errorf("options %+v", options)
	}
	if auth := options.Attributes["auth"].(rschema.SingleNestedAttribute); !auth.Attributes["credentials"].IsRequired() {
		t.Errorf("auth %+v", auth)
	}
	tags := attrs["tags"].(rschema.SetAttribute)
	if len(tags.PlanModifiers) != 2 || tags.PlanModifiers[0] != planmodifier.Set(keepState) || tags.PlanModifiers[1] != planmodifier.Set(requireReplace) {
		t.Errorf("tags %+v", tags)
	}
	nics := attrs["nics"].(rschema.ListNestedAttribute)
	if ips := nics.NestedObject.Attributes["ips"].(rschema.ListNestedAttribute); !ips.Computed || !ips.NestedObject.Attributes["address"].IsComputed() {
		t.Errorf("ips %+v", ips)
	}
	name := attrs["name"].(rschema.StringAttribute)
	if len(name.Validators) != 3 || len(attrs["size"].(rschema.Int64Attribute).Validators) != 2 || attrs["enabled"].(rschema.BoolAttribute).Default == nil {
		t.Errorf("checks or defaults are missing")
	}
}
