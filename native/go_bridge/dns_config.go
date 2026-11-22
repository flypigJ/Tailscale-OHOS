package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/tailcfg"
)

// Private, observation-only transport. Never log or persist Config: it contains
// private DNS names and resolver endpoints. The kernel retains DNS policy ownership.
type dnsConfigSnapshot struct {
	SchemaVersion int             `json:"schemaVersion"`
	Session       string          `json:"session"`
	Revision      uint64          `json:"revision"`
	State         string          `json:"state"`
	Config        json.RawMessage `json:"config"`
}

type dnsConfigObservation struct {
	session   string
	revision  uint64
	requested uint64
	committed uint64
	content   string
}

// Called with b.mu held, only when a new backend identity is created.
func (b *backendController) resetDNSLocked() {
	b.dnsObservation = dnsConfigObservation{session: rand.Text()}
}

func readTailnetDNSConfig(ctx context.Context, client *local.Client) (*tailcfg.DNSConfig, error) {
	status, err := client.StatusWithoutPeers(ctx)
	if err != nil || status == nil || status.BackendState != "Running" {
		return nil, errors.New("DNS backend not running")
	}
	return client.DNSConfig(ctx)
}

func (b *backendController) dnsConfig() string {
	return b.dnsConfigWithReader(readTailnetDNSConfig)
}

func (b *backendController) dnsConfigWithReader(
	read func(context.Context, *local.Client) (*tailcfg.DNSConfig, error),
) string {
	b.mu.Lock()
	client, server, generation := b.client, b.server, b.generation
	session := b.dnsObservation.session
	if client == nil || b.starting || session == "" {
		b.mu.Unlock()
		return marshalDNSSnapshot(dnsConfigSnapshot{SchemaVersion: 1, State: "unavailable"})
	}
	b.dnsObservation.requested++
	request := b.dnsObservation.requested
	b.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	config, err := read(ctx, client)
	state := "ready"
	var content []byte
	if err == nil && config != nil {
		content, err = json.Marshal(config)
	}
	if err != nil || config == nil || len(content) > 256*1024 {
		state, content = "unavailable", nil
	}

	b.mu.Lock()
	defer b.mu.Unlock()
	if b.client != client || b.server != server || b.generation != generation ||
		b.dnsObservation.session != session || request < b.dnsObservation.committed {
		return marshalDNSSnapshot(dnsConfigSnapshot{SchemaVersion: 1, State: "stale"})
	}
	b.dnsObservation.committed = request
	fingerprint := state + ":" + string(content)
	if fingerprint != b.dnsObservation.content {
		b.dnsObservation.content = fingerprint
		b.dnsObservation.revision++
	}
	return marshalDNSSnapshot(dnsConfigSnapshot{SchemaVersion: 1, Session: session,
		Revision: b.dnsObservation.revision, State: state, Config: content})
}

func marshalDNSSnapshot(snapshot dnsConfigSnapshot) string {
	encoded, _ := json.Marshal(snapshot)
	return string(encoded)
}
