package main

import (
	"net/netip"
	"testing"

	"golang.org/x/net/dns/dnsmessage"
)

func TestDNSDiagnosticAnswerEvidence(t *testing.T) {
	name := dnsmessage.MustNewName("controlled.test.")
	message := dnsmessage.Message{Header: dnsmessage.Header{Response: true}, Answers: []dnsmessage.Resource{
		{Header: dnsmessage.ResourceHeader{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}, Body: &dnsmessage.AResource{A: [4]byte{100, 64, 0, 9}}},
	}}
	packet, err := message.Pack()
	if err != nil {
		t.Fatal(err)
	}
	result := dnsAnswerSummary(packet, []netip.Addr{netip.MustParseAddr("100.64.0.9")})
	if !result.Received || result.RCode != 0 || result.Answers != 1 || result.ExpectedMatches != 1 {
		t.Fatal("positive DNS evidence not validated")
	}
	message.Header.RCode, message.Answers = dnsmessage.RCodeNameError, nil
	packet, _ = message.Pack()
	result = dnsAnswerSummary(packet, nil)
	if !result.Received || result.RCode != 3 || result.ExpectedMatches != 0 {
		t.Fatal("negative answer misclassified")
	}
	if dnsAnswerSummary([]byte("invalid"), nil).Received {
		t.Fatal("malformed DNS accepted")
	}
}

func TestDNSDiagnosticRejectsUnknownTargetsBeforeQuery(t *testing.T) {
	b := &backendController{}
	for _, target := range []string{"", "private.test", "peer-invalid", "https://private.test"} {
		if b.diagnosePeerDNS(target) != `{"state":"invalid_target"}` {
			t.Fatal("arbitrary DNS target accepted")
		}
	}
}
