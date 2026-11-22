package main

import (
	"context"
	"encoding/json"
	"net/netip"
	"strings"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

type dnsAnswerEvidence struct {
	Received        bool `json:"received"`
	RCode           int  `json:"rcode"`
	Answers         int  `json:"answers"`
	ExpectedMatches int  `json:"expectedMatches"`
}

func dnsAnswerSummary(packet []byte, expected []netip.Addr) dnsAnswerEvidence {
	result := dnsAnswerEvidence{RCode: -1}
	var message dnsmessage.Message
	if message.Unpack(packet) != nil {
		return result
	}
	result.Received, result.RCode, result.Answers = true, int(message.Header.RCode), len(message.Answers)
	for _, answer := range message.Answers {
		var address netip.Addr
		switch body := answer.Body.(type) {
		case *dnsmessage.AResource:
			address = netip.AddrFrom4(body.A)
		case *dnsmessage.AAAAResource:
			address = netip.AddrFrom16(body.AAAA)
		}
		for _, want := range expected {
			if address.IsValid() && address.Unmap() == want.Unmap() {
				result.ExpectedMatches++
				break
			}
		}
	}
	return result
}

// Used only by the Debug Extension's explicit, bounded diagnostic request.
// The target must be an existing peer. No arbitrary domains or error text are returned.
func (b *backendController) diagnosePeerDNS(peerKey string) string {
	if !validPeerKey(peerKey) {
		return `{"state":"invalid_target"}`
	}
	b.mu.Lock()
	client, server, generation := b.client, b.server, b.generation
	b.mu.Unlock()
	if client == nil {
		return `{"state":"unavailable"}`
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil || status == nil || status.Self == nil {
		return `{"state":"unavailable"}`
	}
	var name string
	var addresses []netip.Addr
	for _, peer := range status.Peer {
		if peer != nil && peerStableKey(peer.ID) == peerKey {
			name = strings.TrimSuffix(peer.DNSName, ".")
			addresses = peer.TailscaleIPs
			break
		}
	}
	if name == "" || len(addresses) == 0 {
		return `{"state":"invalid_target"}`
	}
	_, suffix, _ := strings.Cut(name, ".")
	_, ownSuffix, _ := strings.Cut(strings.TrimSuffix(status.Self.DNSName, "."), ".")
	config, _ := client.DNSConfig(ctx)
	queries := map[string]dnsAnswerEvidence{}
	short, _, _ := strings.Cut(name, ".")
	for _, query := range []struct{ label, name, kind string }{{"shortA", short, "A"}, {"shortAAAA", short, "AAAA"}, {"fullA", name, "A"}, {"fullAAAA", name, "AAAA"}} {
		queryContext, queryCancel := context.WithTimeout(ctx, 2*time.Second)
		packet, _, _ := client.QueryDNS(queryContext, query.name+".", query.kind)
		queryCancel()
		queries[query.label] = dnsAnswerSummary(packet, addresses)
	}
	b.mu.Lock()
	current := b.client == client && b.server == server && b.generation == generation
	b.mu.Unlock()
	if !current {
		return `{"state":"stale"}`
	}
	result := struct {
		State      string                       `json:"state"`
		MagicDNS   bool                         `json:"magicDns"`
		SameSuffix bool                         `json:"sameSuffix"`
		Queries    map[string]dnsAnswerEvidence `json:"queries"`
	}{"complete", config != nil && config.Proxied, suffix != "" && strings.EqualFold(suffix, ownSuffix), queries}
	encoded, _ := json.Marshal(result)
	return string(encoded)
}
