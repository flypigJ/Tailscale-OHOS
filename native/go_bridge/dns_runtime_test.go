package main

import (
	"encoding/json"
	"net/netip"
	"testing"

	"tailscale.com/client/local"
	"tailscale.com/net/dns"
	"tailscale.com/util/dnsname"
)

func TestDNSRuntimeBaseAndProjectionIsolation(t *testing.T) {
	d := &harmonyDNSConfigurator{}
	if _, err := d.GetBaseConfig(); err != dns.ErrGetBaseConfigNoResolvers {
		t.Fatal("empty base allowed takeover")
	}
	if err := d.replaceBase([]string{"192.0.2.53", "192.0.2.53"}); err != nil {
		t.Fatal(err)
	}
	base, err := d.GetBaseConfig()
	if err != nil || len(base.Nameservers) != 1 {
		t.Fatal("base not available")
	}
	if len(base.Resolvers) != 1 || !base.Resolvers[0].UsesPhysicalNetwork() || base.Resolvers[0].Addr != "192.0.2.53" {
		t.Fatal("local physical DNS provenance missing")
	}
	base.Resolvers[0].Addr = "192.0.2.88"
	base.Nameservers[0] = netip.MustParseAddr("192.0.2.99")
	again, _ := d.GetBaseConfig()
	if again.Nameservers[0].String() != "192.0.2.53" {
		t.Fatal("caller mutated base")
	}
	if again.Resolvers[0].Addr != "192.0.2.53" || !again.Resolvers[0].UsesPhysicalNetwork() {
		t.Fatal("caller mutated local resolver provenance")
	}
	domain, _ := dnsname.ToFQDN("private.test")
	config := dns.OSConfig{Nameservers: []netip.Addr{netip.MustParseAddr("100.100.100.100")}, SearchDomains: []dnsname.FQDN{domain}}
	if err := d.SetDNS(config); err != nil {
		t.Fatal(err)
	}
	first := d.snapshot("session")
	config.Nameservers[0] = netip.MustParseAddr("192.0.2.99")
	if first.State != "ready" || first.SearchDomains[0] != "private.test" || d.snapshot("session").DNSAddresses[0] != "100.100.100.100" {
		t.Fatal("compiled OS output was lost or externally mutated")
	}
	if err := d.replaceBase([]string{"192.0.2.54"}); err != nil {
		t.Fatal(err)
	}
	if d.snapshot("session").State == "ready" {
		t.Fatal("new base inherited old ready")
	}
	d.Close()
	if d.SetDNS(config) == nil || d.snapshot("session").State == "ready" {
		t.Fatal("closed owner accepted output")
	}
}

func TestDNSRuntimeRejectsForwardingLoopsAndInvalidBase(t *testing.T) {
	for _, base := range [][]string{nil, {"100.100.100.100"}, {"fd7a:115c:a1e0::53"}, {"127.0.0.1"}, {"::1"},
		{"0.0.0.0"}, {"224.0.0.1"}, {"https://private.test"}, {"192.0.2.53", "bad"}} {
		if _, err := validatedDNSBase(base); err == nil {
			t.Fatalf("invalid base accepted: count=%d", len(base))
		}
	}
}

func TestDNSRuntimeStagesMonotonicImmutableStartupInput(t *testing.T) {
	b := &backendController{}
	stage := func(sequence int64, enabled bool) string {
		text, _ := json.Marshal(dnsRuntimeCommand{Operation: "stage", Sequence: sequence, Enabled: enabled, Resolvers: []string{"192.0.2.53"}})
		return b.dnsRuntimeCommand(string(text))
	}
	if stage(2, true) != "OK | DNS runtime staged" || stage(1, false) == "OK | DNS runtime staged" || !b.dnsInput.enabled {
		t.Fatal("old startup replaced a new input")
	}
	b.client = &local.Client{}
	b.dnsRuntime = &harmonyDNSConfigurator{}
	b.stop()
	if b.dnsInput.enabled || b.dnsRuntime != nil || b.dnsInput.sequence != 2 {
		t.Fatal("stop retained DNS intent or lost replay fence")
	}
	if stage(3, false) != "OK | DNS runtime staged" || b.dnsInput.enabled {
		t.Fatal("DNS-off could inherit prior enable")
	}
}

func TestDNSRuntimeStaleUpdateCannotChangeAnotherSession(t *testing.T) {
	b := dnsTestController()
	b.dnsRuntime = &harmonyDNSConfigurator{}
	b.dnsRuntime.replaceBase([]string{"192.0.2.53"})
	response := b.dnsRuntimeCommand(`{"operation":"update","session":"old","resolvers":["192.0.2.54"]}`)
	base, _ := b.dnsRuntime.GetBaseConfig()
	if response != "FAILED | DNS runtime | stale session" || base.Nameservers[0].String() != "192.0.2.53" {
		t.Fatal("old session changed the current DNS base")
	}
}
