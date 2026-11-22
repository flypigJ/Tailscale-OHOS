package main

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"tailscale.com/client/local"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/types/dnstype"
)

func dnsTestController() *backendController {
	b := &backendController{client: &local.Client{}, server: &tsnet.Server{}, generation: 1}
	b.resetDNSLocked()
	return b
}

func decodeDNS(t *testing.T, text string) dnsConfigSnapshot {
	t.Helper()
	var snapshot dnsConfigSnapshot
	if err := json.Unmarshal([]byte(text), &snapshot); err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func TestDNSConfigRevisionsAndSplitPolicy(t *testing.T) {
	b := dnsTestController()
	policy := &tailcfg.DNSConfig{Proxied: true, Domains: []string{"private.test"},
		Resolvers:    []*dnstype.Resolver{{Addr: "https://dns.test/dns-query", UseWithExitNode: true}},
		Routes:       map[string][]*dnstype.Resolver{"private.test.": {}},
		ExtraRecords: []tailcfg.DNSRecord{{Name: "app.private.test", Value: "100.64.0.9"}}}
	read := func(context.Context, *local.Client) (*tailcfg.DNSConfig, error) { return policy, nil }
	first := decodeDNS(t, b.dnsConfigWithReader(read))
	second := decodeDNS(t, b.dnsConfigWithReader(read))
	if first.State != "ready" || first.Session == "" || first.Revision != 1 || second.Revision != 1 {
		t.Fatal("stable policy must not create a new revision")
	}
	var observed tailcfg.DNSConfig
	if err := json.Unmarshal(first.Config, &observed); err != nil {
		t.Fatal(err)
	}
	if observed.Routes["private.test."] == nil || len(observed.Routes) != 1 ||
		!observed.Resolvers[0].UseWithExitNode || len(observed.ExtraRecords) != 1 {
		t.Fatal("split DNS and kernel-only policy fields were lost")
	}
	policy.Domains = []string{"changed.test"}
	changed := decodeDNS(t, b.dnsConfigWithReader(read))
	if changed.Revision != 2 || changed.Session != first.Session {
		t.Fatal("missing DNS change revision")
	}
}

func TestDNSConfigUnavailableClearsAndRecoveryRevises(t *testing.T) {
	b := dnsTestController()
	read := func(context.Context, *local.Client) (*tailcfg.DNSConfig, error) {
		return &tailcfg.DNSConfig{Proxied: true}, nil
	}
	decodeDNS(t, b.dnsConfigWithReader(read))
	failed := decodeDNS(t, b.dnsConfigWithReader(func(context.Context, *local.Client) (*tailcfg.DNSConfig, error) {
		return nil, errors.New("private resolver error must not be serialized")
	}))
	if failed.State != "unavailable" || string(failed.Config) != "null" || failed.Revision != 2 {
		t.Fatal("query failure retained a prior DNS policy")
	}
	if decodeDNS(t, b.dnsConfigWithReader(read)).Revision != 3 {
		t.Fatal("recovery not observed")
	}
}

func TestDNSConfigOldGenerationCannotCommit(t *testing.T) {
	b := dnsTestController()
	previous := b.dnsObservation.session
	snapshot := decodeDNS(t, b.dnsConfigWithReader(func(context.Context, *local.Client) (*tailcfg.DNSConfig, error) {
		b.mu.Lock()
		b.generation++
		b.resetDNSLocked()
		b.mu.Unlock()
		return &tailcfg.DNSConfig{Domains: []string{"old.test"}}, nil
	}))
	if snapshot.State != "stale" || snapshot.Session != "" || string(snapshot.Config) != "null" ||
		b.dnsObservation.revision != 0 || b.dnsObservation.session == previous {
		t.Fatal("old generation crossed the identity boundary")
	}
}

func TestDNSConfigOlderRequestCannotOverwriteNewer(t *testing.T) {
	b := dnsTestController()
	started, release := make(chan struct{}), make(chan struct{})
	old := make(chan string, 1)
	go func() {
		old <- b.dnsConfigWithReader(func(context.Context, *local.Client) (*tailcfg.DNSConfig, error) {
			close(started)
			<-release
			return &tailcfg.DNSConfig{Domains: []string{"old.test"}}, nil
		})
	}()
	<-started
	fresh := decodeDNS(t, b.dnsConfigWithReader(func(context.Context, *local.Client) (*tailcfg.DNSConfig, error) {
		return &tailcfg.DNSConfig{Domains: []string{"new.test"}}, nil
	}))
	close(release)
	if decodeDNS(t, <-old).State != "stale" || fresh.Revision != 1 || b.dnsObservation.revision != 1 {
		t.Fatal("out-of-order request overwrote a newer policy")
	}
}

func TestDNSConfigStopAndNotReadyDoNotQuery(t *testing.T) {
	b := dnsTestController()
	b.stop()
	called := false
	snapshot := decodeDNS(t, b.dnsConfigWithReader(func(context.Context, *local.Client) (*tailcfg.DNSConfig, error) {
		called = true
		return &tailcfg.DNSConfig{}, nil
	}))
	if called || snapshot.State != "unavailable" || b.dnsObservation.session != "" {
		t.Fatal("stopped backend exposed a DNS policy")
	}
}

func TestDNSConfigNilAndOversizedPolicyFailClosed(t *testing.T) {
	b := dnsTestController()
	for _, policy := range []*tailcfg.DNSConfig{nil, {Domains: []string{string(make([]byte, 256*1024))}}} {
		snapshot := decodeDNS(t, b.dnsConfigWithReader(func(context.Context, *local.Client) (*tailcfg.DNSConfig, error) {
			return policy, nil
		}))
		if snapshot.State != "unavailable" || string(snapshot.Config) != "null" {
			t.Fatal("invalid policy must not be truncated or published as ready")
		}
	}
}
