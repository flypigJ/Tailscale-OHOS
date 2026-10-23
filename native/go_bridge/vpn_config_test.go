package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/tailcfg"
	"tailscale.com/types/netmap"
)

type vpnConfigRoundTripper struct {
	response []byte
	status   int
	closed   atomic.Int32
	delay    time.Duration
}

func (rt *vpnConfigRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	if rt.delay > 0 {
		select {
		case <-time.After(rt.delay):
		case <-req.Context().Done():
			return nil, req.Context().Err()
		}
	}
	return &http.Response{
		StatusCode: rt.status,
		Status:     http.StatusText(rt.status),
		Body:       &vpnConfigBody{Reader: strings.NewReader(string(rt.response)), closed: &rt.closed},
		Header:     make(http.Header),
		Request:    req,
	}, nil
}

type vpnConfigBody struct {
	*strings.Reader
	closed *atomic.Int32
}

func (b *vpnConfigBody) Close() error {
	b.closed.Add(1)
	return nil
}

func TestWaitForCurrentNetMapRejectsCachedMap(t *testing.T) {
	rt := newVPNConfigRoundTripper(t, true, true)
	_, err := waitForCurrentNetMap(context.Background(), &local.Client{Transport: rt, OmitAuth: true})
	if !errors.Is(err, errVPNNetMapNotReady) {
		t.Fatalf("waitForCurrentNetMap(cached) error = %v, want %v", err, errVPNNetMapNotReady)
	}
	if got := rt.closed.Load(); got != 1 {
		t.Fatalf("watch response closes = %d, want 1", got)
	}
}

func TestWaitForCurrentNetMapAcceptsFreshEmptyTailnet(t *testing.T) {
	rt := newVPNConfigRoundTripper(t, false, true)
	got, err := waitForCurrentNetMap(context.Background(), &local.Client{Transport: rt, OmitAuth: true})
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || got.Cached || !got.SelfNode.Valid() {
		t.Fatalf("fresh map = %#v, want valid non-cached map", got)
	}
	if got := rt.closed.Load(); got != 1 {
		t.Fatalf("watch response closes = %d, want 1", got)
	}
}

func TestWaitForCurrentNetMapRejectsAbsentMapAndSelf(t *testing.T) {
	for _, test := range []struct {
		name    string
		payload []byte
	}{
		{name: "absent", payload: []byte(`{"NetMap":null}`)},
		{name: "absent self", payload: []byte(`{"NetMap":{"SelfNode":null}}`)},
	} {
		t.Run(test.name, func(t *testing.T) {
			rt := &vpnConfigRoundTripper{response: append(test.payload, '\n'), status: http.StatusOK}
			_, err := waitForCurrentNetMap(context.Background(), &local.Client{Transport: rt, OmitAuth: true})
			if !errors.Is(err, errVPNNetMapNotReady) {
				t.Fatalf("error = %v, want %v", err, errVPNNetMapNotReady)
			}
			if got := rt.closed.Load(); got != 1 {
				t.Fatalf("watch response closes = %d, want 1", got)
			}
		})
	}
}

func TestWaitForCurrentNetMapPropagatesTransportAndDeadlineErrors(t *testing.T) {
	rt := &vpnConfigRoundTripper{response: nil, status: http.StatusOK, delay: time.Second}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	_, err := waitForCurrentNetMap(ctx, &local.Client{Transport: rt, OmitAuth: true})
	if err == nil {
		t.Fatal("deadline error = nil")
	}
	if got := rt.closed.Load(); got != 0 {
		t.Fatalf("watch response closes = %d, want 0 when transport never returned", got)
	}
}
func newVPNConfigRoundTripper(t *testing.T, cached, validSelf bool) *vpnConfigRoundTripper {
	t.Helper()
	var self tailcfg.NodeView
	if validSelf {
		self = (&tailcfg.Node{ID: 1}).View()
	}
	payload, err := json.Marshal(&ipn.Notify{NetMap: &netmap.NetworkMap{Cached: cached, SelfNode: self}})
	if err != nil {
		t.Fatal(err)
	}
	return &vpnConfigRoundTripper{response: append(payload, '\n'), status: http.StatusOK}
}

var _ io.ReadCloser = (*vpnConfigBody)(nil)
