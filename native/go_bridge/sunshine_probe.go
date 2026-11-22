package main

import (
	"context"
	"encoding/xml"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

type sunshineProbeResult struct {
	State         string `json:"state"`
	CheckedAt     int64  `json:"checkedAt"`
	LatencyMS     int    `json:"latencyMs,omitempty"`
	ServerName    string `json:"serverName,omitempty"`
	ServerVersion string `json:"serverVersion,omitempty"`
	ErrorMessage  string `json:"errorMessage,omitempty"`
}

type gameStreamServerInfo struct {
	XMLName    xml.Name `xml:"root"`
	StatusCode string   `xml:"status_code,attr"`
	AppVersion string   `xml:"appversion"`
	UniqueID   string   `xml:"uniqueid"`
	HostName   string   `xml:"hostname"`
}

// Discovery uses GameStream's unpaired HTTP endpoint. The HTTPS endpoint
// requires a paired client certificate on Sunshine; TLS alert text and the
// certificate common name are neither portable nor proof of a working server.
// Production callers supply tsnet.Server.Dial so this HTTP request stays inside
// the encrypted tailnet even when the VPN extension excludes its own bundle.
func probeGameStream(ctx context.Context, host string,
	dial func(context.Context, string, string) (net.Conn, error)) sunshineProbeResult {
	startedAt := time.Now()
	result := sunshineProbeResult{State: "unavailable", CheckedAt: startedAt.UnixMilli()}
	ctx, cancel := context.WithTimeout(ctx, 2200*time.Millisecond)
	defer cancel()
	transport := &http.Transport{DialContext: dial, DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"http://"+net.JoinHostPort(host, "47989")+"/serverinfo", nil)
	if err != nil {
		result.State, result.ErrorMessage = "error", "request_invalid"
		return result
	}
	response, err := client.Do(request)
	if err != nil {
		result.ErrorMessage = "serverinfo_unreachable"
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			result.State, result.ErrorMessage = "timeout", "timeout"
		}
		return result
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		result.ErrorMessage = "serverinfo_http_status"
		return result
	}
	const maxBody = 64 * 1024
	body, err := io.ReadAll(io.LimitReader(response.Body, maxBody+1))
	var info gameStreamServerInfo
	if err != nil || len(body) > maxBody || xml.Unmarshal(body, &info) != nil ||
		info.StatusCode != "200" || strings.TrimSpace(info.AppVersion) == "" ||
		strings.TrimSpace(info.UniqueID) == "" || strings.TrimSpace(info.HostName) == "" {
		result.ErrorMessage = "serverinfo_invalid"
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			result.State, result.ErrorMessage = "timeout", "timeout"
		}
		return result
	}
	result.State = "available"
	result.LatencyMS = int(time.Since(startedAt).Milliseconds())
	result.ServerName = strings.TrimSpace(info.HostName)
	result.ServerVersion = strings.TrimSpace(info.AppVersion)
	return result
}
