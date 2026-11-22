package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

const validGameStreamInfo = `<root status_code="200"><hostname>Test PC</hostname><appversion>7.1.431.-1</appversion><uniqueid>test-host</uniqueid><PairStatus>0</PairStatus></root>`

func TestGameStreamDiscovery(t *testing.T) {
	for _, tc := range []struct {
		name, body, state string
		status            int
	}{
		{"unpaired", validGameStreamInfo, "available", 200},
		{"paired", strings.ReplaceAll(validGameStreamInfo, ">0<", ">1<"), "available", 200},
		{"wrong-root", strings.ReplaceAll(validGameStreamInfo, "root", "html"), "unavailable", 200},
		{"server-error", strings.ReplaceAll(validGameStreamInfo, `status_code="200"`, `status_code="401"`), "unavailable", 200},
		{"missing-id", strings.ReplaceAll(validGameStreamInfo, "<uniqueid>test-host</uniqueid>", ""), "unavailable", 200},
		{"generic-http", "<html><appversion>1</appversion></html>", "unavailable", 200},
		{"malformed", "<root>", "unavailable", 200},
		{"oversized", validGameStreamInfo + strings.Repeat(" ", 65536), "unavailable", 200},
		{"http-error", validGameStreamInfo, "unavailable", 503},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/serverinfo" || r.Method != "GET" {
					t.Errorf("unexpected request: %s %s", r.Method, r.URL)
				}
				w.WriteHeader(tc.status)
				fmt.Fprint(w, tc.body)
			}))
			defer server.Close()
			dial := func(ctx context.Context, network, address string) (net.Conn, error) {
				if address != "100.64.0.1:47989" {
					t.Errorf("wrong discovery address: %s", address)
				}
				return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
			}
			result := probeGameStream(context.Background(), "100.64.0.1", dial)
			if result.State != tc.state {
				t.Fatalf("got %+v, want %s", result, tc.state)
			}
			if tc.state == "available" && (result.ServerName != "Test PC" || result.ServerVersion != "7.1.431.-1") {
				t.Fatalf("metadata: %+v", result)
			}
		})
	}
}

func TestGameStreamDoesNotFollowRedirect(t *testing.T) {
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		http.Redirect(w, r, "/other", http.StatusFound)
	}))
	defer server.Close()
	dial := func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
	}
	result := probeGameStream(context.Background(), "100.64.0.1", dial)
	if calls != 1 || result.State != "unavailable" {
		t.Fatalf("calls=%d result=%+v", calls, result)
	}
}

func TestGameStreamDeadlineIncludesBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	dial := func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	result := probeGameStream(ctx, "100.64.0.1", dial)
	if result.State != "timeout" {
		t.Fatalf("got %+v", result)
	}
}

func TestGameStreamLiveHost(t *testing.T) {
	host := os.Getenv("MESHARC_TEST_SUNSHINE_HOST")
	if host == "" {
		t.Skip("set MESHARC_TEST_SUNSHINE_HOST for opt-in local host verification")
	}
	result := probeGameStream(context.Background(), host, (&net.Dialer{}).DialContext)
	if result.State != "available" {
		t.Fatalf("live discovery failed: %+v", result)
	}
	t.Logf("live discovery: state=%s version=%s latencyMs=%d", result.State, result.ServerVersion, result.LatencyMS)
}
