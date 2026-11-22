package main

import (
	"encoding/json"
	"slices"
	"strings"
	"tailscale.com/net/dns"
	"tailscale.com/types/dnstype"
	"tailscale.com/util/dnsname"
	"testing"
)

func TestCustomDNSPreservesPrivateRoutesAndSearchPriority(t *testing.T) {
	private := dnsname.FQDN("private.test.")
	tailnet := dnsname.FQDN("tailnet.test.")
	d := &harmonyDNSConfigurator{customResolvers: []string{"192.0.2.53"},
		customSearchDomains: []dnsname.FQDN{tailnet, "custom.test."}}
	original := dns.Config{AcceptDNS: true, UsingExitNode: true,
		DefaultResolvers: []*dnstype.Resolver{{Addr: "192.0.2.54", UseWithExitNode: true}},
		Routes:           map[dnsname.FQDN][]*dnstype.Resolver{private: {{Addr: "100.64.0.53"}}, tailnet: nil},
		SearchDomains:    []dnsname.FQDN{tailnet}}
	result, err := d.TransformDNSConfig(*original.Clone())
	if err != nil {
		t.Fatal(err)
	}
	if result.DefaultResolvers[0].Addr != "192.0.2.53" || result.DefaultResolvers[0].UsesPhysicalNetwork() ||
		result.Routes[private][0].Addr != "100.64.0.53" || result.Routes[tailnet] != nil || !result.UsingExitNode ||
		!slices.Equal(result.SearchDomains, []dnsname.FQDN{tailnet, "custom.test."}) {
		t.Fatal("custom policy lost split/exit/search semantics")
	}
	if len(original.Routes) != 2 || len(original.SearchDomains) != 1 || original.DefaultResolvers[0].Addr != "192.0.2.54" {
		t.Fatal("custom policy mutated original")
	}
	d.Close()
	if _, err = d.TransformDNSConfig(original); err == nil {
		t.Fatal("closed adapter accepted policy")
	}
}

func TestCustomDNSStageAndStopKeepTailnetOptInIndependent(t *testing.T) {
	b := &backendController{}
	for index, tailnet := range []bool{false, true} {
		text, _ := json.Marshal(dnsRuntimeCommand{Operation: "stage", Sequence: int64(index + 1), Enabled: tailnet,
			CustomResolvers: []string{"2001:4860:4860::8888"}, SearchDomains: []string{"corp.test"}})
		if !strings.HasPrefix(b.dnsRuntimeCommand(string(text)), "OK") || !b.dnsInput.enabled || b.dnsInput.tailnetEnabled != tailnet {
			t.Fatal("custom DNS changed Tailnet opt-in or required physical DNS")
		}
	}
	b.stop()
	if b.dnsInput.enabled || b.dnsInput.tailnetEnabled || len(b.dnsInput.customResolvers) > 0 || len(b.dnsInput.searchDomains) > 0 {
		t.Fatal("stop retained custom input")
	}
}

func TestCustomDNSRejectsMalformedOrUnusableInputs(t *testing.T) {
	for _, ip := range []string{"192.0.2.1::", "::ffff:127.0.0.1", "::ffff:100.100.100.100", "169.254.1.53", "fe80::53", "255.255.255.255"} {
		b := &backendController{}
		text, _ := json.Marshal(dnsRuntimeCommand{Operation: "stage", Sequence: 1, CustomResolvers: []string{ip}})
		if strings.HasPrefix(b.dnsRuntimeCommand(string(text)), "OK") {
			t.Fatal("invalid custom DNS accepted")
		}
	}
	for _, name := range []string{"bad_domain.test", "a..test", "-a.test", strings.Repeat("a", 64) + ".test"} {
		if _, err := validatedCustomSearchDomains([]string{name}); err == nil {
			t.Fatal("invalid search domain accepted")
		}
	}
}
