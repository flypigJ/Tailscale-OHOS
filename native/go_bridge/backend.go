package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"math"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/hostinfo"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/net/netns"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/util/dnsname"
)

type backendController struct {
	mu           sync.Mutex
	server       *tsnet.Server
	client       *local.Client
	starting     bool
	startErr     string
	phase        string
	externalTun  bool
	tunDevice    *harmonyTunDevice
	stateDir     string
	subnetRoutes int
	generation   uint64
	cancelStart  context.CancelFunc
}

var harmonyBackend backendController
var hostinfoModelOnce sync.Once

const harmonyOSVersion = "Linux HongMeng Kernel Build 1.12.0"

type exitNodeChoice struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Online   bool   `json:"online"`
	Selected bool   `json:"selected"`
}

type peerSummary struct {
	Key             string   `json:"key"`
	Name            string   `json:"name"`
	OS              string   `json:"os"`
	DeviceModel     string   `json:"deviceModel"`
	DeviceType      string   `json:"deviceType"`
	Addresses       []string `json:"addresses"`
	Online          bool     `json:"online"`
	ExitNode        bool     `json:"exitNode"`
	KeyExpired      bool     `json:"keyExpired"`
	KeyExpiryUnixMS int64    `json:"keyExpiryUnixMs"`
}

type peerConnectivityResult struct {
	State        string `json:"state"`
	Reason       string `json:"reason"`
	Sent         int    `json:"sent"`
	Received     int    `json:"received"`
	LossPercent  int    `json:"lossPercent"`
	MinLatencyMS int    `json:"minLatencyMs"`
	AvgLatencyMS int    `json:"avgLatencyMs"`
	MaxLatencyMS int    `json:"maxLatencyMs"`
}

type accountSummary struct {
	DisplayName     string   `json:"displayName"`
	LoginName       string   `json:"loginName"`
	ProfilePicURL   string   `json:"profilePicURL"`
	TailnetName     string   `json:"tailnetName"`
	DeviceName      string   `json:"deviceName"`
	Addresses       []string `json:"addresses"`
	NeedsApproval   bool     `json:"needsApproval"`
	KeyExpired      bool     `json:"keyExpired"`
	KeyExpiryUnixMS int64    `json:"keyExpiryUnixMs"`
}

func keyExpiryUnixMS(expiry *time.Time) int64 {
	if expiry == nil || expiry.IsZero() {
		return 0
	}
	return expiry.UnixMilli()
}

func displayAddresses(addresses []netip.Addr) []string {
	result := make([]string, 0, len(addresses))
	for _, address := range addresses {
		if address.IsValid() {
			result = append(result, address.String())
		}
	}
	return result
}

type networkPreferences struct {
	RouteAll               bool `json:"routeAll"`
	CorpDNS                bool `json:"corpDNS"`
	ExitNodeAllowLANAccess bool `json:"exitNodeAllowLANAccess"`
}

type backendSnapshot struct {
	Status          string             `json:"status"`
	ExitNodes       []exitNodeChoice   `json:"exitNodes"`
	Peers           []peerSummary      `json:"peers"`
	NetworkSettings networkPreferences `json:"networkSettings"`
	Account         accountSummary     `json:"account"`
}

func (b *backendController) start(stateDir, deviceModel string) string {
	return b.startWithDevice(stateDir, deviceModel, nil)
}

func (b *backendController) stop() string {
	b.mu.Lock()
	server := b.server
	cancelStart := b.cancelStart
	b.generation++
	b.server = nil
	b.client = nil
	b.starting = false
	b.startErr = ""
	b.phase = "stopped"
	b.externalTun = false
	b.tunDevice = nil
	b.subnetRoutes = 0
	b.cancelStart = nil
	b.mu.Unlock()
	if cancelStart != nil {
		cancelStart()
	}
	if server != nil {
		if err := server.Close(); err != nil {
			return "FAILED | backend stop"
		}
	}
	return "OK | backend stopped"
}

// logout invalidates this node's current Tailscale login. The UI keeps this
// behind a destructive-action confirmation and only calls it while the system
// VPN is stopped, so the active LocalClient belongs to this process.
func (b *backendController) logout() string {
	b.mu.Lock()
	client := b.client
	stateDir := b.stateDir
	starting := b.starting
	b.mu.Unlock()
	if client == nil || starting {
		return "FAILED | logout | backend not ready"
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := client.Logout(ctx); err != nil {
		return "FAILED | logout | request failed"
	}
	// An exit-node choice is account-specific and must not leak into a later
	// login, even if the new tailnet happens to contain the same stable node ID.
	if stateDir != "" {
		if err := os.Remove(filepath.Join(stateDir, exitNodeChoiceFile)); err != nil && !os.IsNotExist(err) {
			return "OK | logged out | local preference cleanup pending"
		}
	}
	return "OK | logged out"
}

func (b *backendController) startWithDevice(stateDir, deviceModel string, device *harmonyTunDevice) string {
	b.mu.Lock()
	if b.server != nil || b.starting {
		b.mu.Unlock()
		return b.status()
	}
	// The OpenHarmony Go port intentionally matches Linux build tags, but an
	// application process cannot use tailscaled's Linux socket marks/network
	// namespace bypass. Use the ordinary system dialer for control traffic.
	netns.SetEnabled(false)
	hostinfo.SetOSVersion(harmonyOSVersion)
	trimmedModel := strings.TrimSpace(deviceModel)
	hostinfoModelOnce.Do(func() {
		hostinfo.RegisterHostinfoNewHook(func(info *tailcfg.Hostinfo) {
			info.OS = "harmonyos"
			if trimmedModel != "" && trimmedModel != "default" {
				info.DeviceModel = trimmedModel
			}
		})
	})

	b.generation++
	generation := b.generation
	startContext, cancelStart := context.WithCancel(context.Background())
	server := &tsnet.Server{
		Dir:       stateDir,
		Hostname:  harmonyHostname(trimmedModel),
		Ephemeral: false,
		UserLogf:  b.userLogf,
		Logf:      b.backendLogf,
	}
	// Assigning a nil *harmonyTunDevice directly to the tun.Device interface
	// creates a non-nil interface containing a nil pointer. wireguard-go then
	// starts its reader and calls Read on that nil receiver. Leave the interface
	// itself nil until a real HarmonyOS VPN descriptor has been adapted.
	if device != nil {
		server.Tun = device
	}
	b.server = server
	b.starting = true
	b.startErr = ""
	b.phase = "netns-disabled"
	b.externalTun = device != nil
	b.tunDevice = device
	b.stateDir = stateDir
	b.cancelStart = cancelStart
	b.mu.Unlock()

	go b.startAsync(server, stateDir, generation, startContext)
	if device != nil {
		return "OK | VPN backend starting | persistent private state"
	}
	return "OK | backend starting | persistent private state"
}

func (b *backendController) restartWithTun(stateDir, deviceModel string, fd int) string {
	device, err := newHarmonyTunDevice(fd, 1280)
	if err != nil {
		return "FAILED | VPN backend | TUN descriptor adaptation"
	}

	b.mu.Lock()
	oldServer := b.server
	cancelStart := b.cancelStart
	b.generation++
	b.server = nil
	b.client = nil
	b.starting = false
	b.startErr = ""
	b.phase = "vpn-restart"
	b.externalTun = false
	b.tunDevice = nil
	b.cancelStart = nil
	b.mu.Unlock()
	if cancelStart != nil {
		cancelStart()
	}
	if oldServer != nil {
		if err := oldServer.Close(); err != nil {
			_ = device.Close()
			return "FAILED | VPN backend | previous backend close"
		}
	}
	return b.startWithDevice(stateDir, deviceModel, device)
}

func harmonyHostname(deviceModel string) string {
	hostname := dnsname.SanitizeHostname(strings.TrimSpace(deviceModel))
	if hostname == "" || hostname == "default" {
		return "harmonyos-next"
	}
	return hostname
}

// vpnConfig returns the assigned node addresses and currently selected routes
// for in-process transfer to VpnExtensionAbility. Callers must not display or
// log this value.
func (b *backendController) vpnConfig() string {
	b.mu.Lock()
	client := b.client
	starting := b.starting
	b.mu.Unlock()
	if client == nil || starting {
		return "FAILED | VPN config | backend not ready"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil || status.BackendState != "Running" {
		return "FAILED | VPN config | backend not running"
	}
	prefs, err := client.GetPrefs(ctx)
	if err != nil || prefs == nil {
		return "FAILED | VPN config | preferences unavailable"
	}
	var v4, v6 netip.Addr
	for _, addr := range status.TailscaleIPs {
		if addr.Is4() {
			v4 = addr
		} else if addr.Is6() {
			v6 = addr
		}
	}
	if !v4.IsValid() {
		return "FAILED | VPN config | IPv4 address unavailable"
	}
	v6Text := ""
	if v6.IsValid() {
		v6Text = v6.String()
	}

	// PrimaryRoutes contains control-plane-approved routes for the peers that
	// currently own them. Exit routes are included only for the peer that this
	// client has explicitly selected as its exit node.
	routeSet := make(map[string]struct{})
	for _, peer := range status.Peer {
		if prefs.RouteAll && peer.PrimaryRoutes != nil {
			for _, prefix := range peer.PrimaryRoutes.All() {
				if prefix.IsValid() {
					routeSet[prefix.Masked().String()] = struct{}{}
				}
			}
		}
		if peer.ExitNode && peer.AllowedIPs != nil {
			for _, prefix := range peer.AllowedIPs.All() {
				if prefix.IsValid() && prefix.Bits() == 0 {
					routeSet[prefix.Masked().String()] = struct{}{}
				}
			}
		}
	}
	routes := make([]string, 0, len(routeSet))
	subnetRoutes := 0
	for route := range routeSet {
		routes = append(routes, route)
		if prefix, err := netip.ParsePrefix(route); err == nil && prefix.Bits() > 0 {
			subnetRoutes++
		}
	}
	sort.Strings(routes)
	b.mu.Lock()
	b.subnetRoutes = subnetRoutes
	b.mu.Unlock()
	return fmt.Sprintf("%s|%s|%s|%t", v4.String(), v6Text,
		strings.Join(routes, ","), prefs.CorpDNS)
}

// exitNodes returns the exit-node choices intended for direct rendering in the
// app UI. This contains tailnet identities, so callers must never log it.
func (b *backendController) exitNodes() string {
	b.mu.Lock()
	client := b.client
	stateDir := b.stateDir
	b.mu.Unlock()
	if client == nil {
		return "[]"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil || status.BackendState != "Running" {
		return "[]"
	}
	persistedID, _ := readExitNodeChoice(stateDir)
	choices := make([]exitNodeChoice, 0)
	for _, peer := range status.Peer {
		if !peer.ExitNodeOption {
			continue
		}
		name := strings.TrimSuffix(peer.DNSName, ".")
		if name == "" {
			name = peer.HostName
		}
		if name == "" {
			name = "Unnamed exit node"
		}
		if persistedID == "" && peer.ExitNode {
			if writeExitNodeChoice(stateDir, string(peer.ID)) == nil {
				persistedID = string(peer.ID)
			}
		}
		choices = append(choices, exitNodeChoice{
			ID:       string(peer.ID),
			Name:     name,
			Online:   peer.Online,
			Selected: peer.ExitNode || (persistedID != "" && string(peer.ID) == persistedID),
		})
	}
	sort.Slice(choices, func(i, j int) bool {
		return choices[i].Name < choices[j].Name
	})
	encoded, err := json.Marshal(choices)
	if err != nil {
		return "[]"
	}
	return string(encoded)
}

// peers returns display-only peer metadata and the Tailscale addresses the user
// explicitly sees in the device list. Keys, user identities, and control-plane
// details remain excluded.
func (b *backendController) peers() string {
	b.mu.Lock()
	client := b.client
	b.mu.Unlock()
	if client == nil {
		return "[]"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil || status.BackendState != "Running" {
		return "[]"
	}
	peers := make([]peerSummary, 0, len(status.Peer))
	for _, peer := range status.Peer {
		name := strings.TrimSuffix(peer.DNSName, ".")
		if name == "" {
			name = peer.HostName
		}
		if name == "" {
			name = "Unnamed device"
		}
		peers = append(peers, peerSummary{
			Key:             peerStableKey(peer.ID),
			Name:            name,
			OS:              peer.OS,
			DeviceModel:     peer.DeviceModel,
			DeviceType:      classifyPeerDevice(peer.OS, peer.DeviceModel),
			Addresses:       displayAddresses(peer.TailscaleIPs),
			Online:          peer.Online,
			ExitNode:        peer.ExitNodeOption,
			KeyExpired:      peer.Expired,
			KeyExpiryUnixMS: keyExpiryUnixMS(peer.KeyExpiry),
		})
	}
	sort.Slice(peers, func(i, j int) bool {
		if peers[i].Online != peers[j].Online {
			return peers[i].Online
		}
		return peers[i].Name < peers[j].Name
	})
	encoded, err := json.Marshal(peers)
	if err != nil {
		return "[]"
	}
	return string(encoded)
}

func peerStableKey(id tailcfg.StableNodeID) string {
	digest := sha256.Sum256([]byte(id))
	return fmt.Sprintf("peer-%x", digest[:8])
}

func classifyPeerDevice(osName, deviceModel string) string {
	osValue := strings.ToLower(strings.TrimSpace(osName))
	model := strings.ToLower(strings.TrimSpace(deviceModel))

	if containsAny(model, "mate x", "pocket", "magic v", "galaxy z fold", "galaxy z flip", "pixel fold", "foldable") {
		return "foldable"
	}
	if containsAny(model, "ipad", "tablet", "matepad", "mediapad", "galaxy tab", "surface go", "surface pro", "pad ") ||
		strings.HasSuffix(model, " pad") {
		return "tablet"
	}
	if containsAny(model, "matebook", "macbook", "thinkpad", "notebook", "laptop", "chromebook") {
		return "laptop"
	}
	if containsAny(model, "desktop", "imac", "mac mini", "mac studio", "workstation") {
		return "desktop"
	}

	if containsAny(osValue, "ios", "android", "harmony", "ohos") {
		return "phone"
	}
	if containsAny(osValue, "windows", "macos", "linux", "freebsd", "openbsd", "chromeos") {
		return "computer"
	}
	return "computer"
}

func containsAny(value string, candidates ...string) bool {
	for _, candidate := range candidates {
		if strings.Contains(value, candidate) {
			return true
		}
	}
	return false
}

// account returns the current user's display profile, human-readable device and
// tailnet names, and this node's Tailscale addresses. Stable IDs, node keys, and
// control-plane metadata are deliberately not exposed to the UI.
func (b *backendController) account() string {
	b.mu.Lock()
	client := b.client
	b.mu.Unlock()
	if client == nil {
		return "{}"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil || status.BackendState != "Running" || status.Self == nil {
		return "{}"
	}

	account := buildAccountSummary(status)
	encoded, err := json.Marshal(account)
	if err != nil {
		return "{}"
	}
	return string(encoded)
}

func (b *backendController) snapshot() string {
	b.mu.Lock()
	client := b.client
	starting := b.starting
	startErr := b.startErr
	phase := b.phase
	serverPresent := b.server != nil
	stateDir := b.stateDir
	b.mu.Unlock()

	settings, err := readNetworkPreferences(stateDir)
	if err != nil {
		settings = defaultNetworkPreferences()
	}
	snapshot := backendSnapshot{
		ExitNodes:       []exitNodeChoice{},
		Peers:           []peerSummary{},
		NetworkSettings: settings,
		Account:         accountSummary{Addresses: []string{}},
	}
	switch {
	case startErr != "":
		snapshot.Status = fmt.Sprintf("FAILED | backend start | %s", startErr)
	case starting:
		snapshot.Status = fmt.Sprintf("OK | backend starting | phase=%s", phase)
	case client == nil && serverPresent:
		snapshot.Status = "OK | backend initialized | LocalClient pending"
	case client == nil:
		snapshot.Status = "STOPPED | backend not started"
	}
	if snapshot.Status != "" {
		return marshalBackendSnapshot(snapshot)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	status, statusErr := client.Status(ctx)
	if statusErr != nil {
		snapshot.Status = fmt.Sprintf("FAILED | backend status | %v", statusErr)
		return marshalBackendSnapshot(snapshot)
	}
	prefs, prefsErr := client.GetPrefs(ctx)
	snapshot.Status = b.formatRunningStatus(status, prefs, prefsErr)
	snapshot.Account = buildAccountSummary(status)
	if status.BackendState != "Running" {
		return marshalBackendSnapshot(snapshot)
	}

	snapshot.ExitNodes = buildExitNodeChoices(status, stateDir)
	snapshot.Peers = buildPeerSummaries(status)
	if prefsErr == nil && prefs != nil {
		snapshot.NetworkSettings = networkPreferences{
			RouteAll:               prefs.RouteAll,
			CorpDNS:                prefs.CorpDNS,
			ExitNodeAllowLANAccess: prefs.ExitNodeAllowLANAccess,
		}
	}
	return marshalBackendSnapshot(snapshot)
}

func marshalBackendSnapshot(snapshot backendSnapshot) string {
	encoded, err := json.Marshal(snapshot)
	if err != nil {
		return `{"status":"FAILED | backend snapshot | encoding"}`
	}
	return string(encoded)
}

func buildExitNodeChoices(status *ipnstate.Status, stateDir string) []exitNodeChoice {
	persistedID, _ := readExitNodeChoice(stateDir)
	choices := make([]exitNodeChoice, 0)
	for _, peer := range status.Peer {
		if !peer.ExitNodeOption {
			continue
		}
		name := strings.TrimSuffix(peer.DNSName, ".")
		if name == "" {
			name = peer.HostName
		}
		if name == "" {
			name = "Unnamed exit node"
		}
		if persistedID == "" && peer.ExitNode {
			if writeExitNodeChoice(stateDir, string(peer.ID)) == nil {
				persistedID = string(peer.ID)
			}
		}
		choices = append(choices, exitNodeChoice{
			ID:       string(peer.ID),
			Name:     name,
			Online:   peer.Online,
			Selected: peer.ExitNode || (persistedID != "" && string(peer.ID) == persistedID),
		})
	}
	sort.Slice(choices, func(i, j int) bool { return choices[i].Name < choices[j].Name })
	return choices
}

func buildPeerSummaries(status *ipnstate.Status) []peerSummary {
	peers := make([]peerSummary, 0, len(status.Peer))
	for _, peer := range status.Peer {
		name := strings.TrimSuffix(peer.DNSName, ".")
		if name == "" {
			name = peer.HostName
		}
		if name == "" {
			name = "Unnamed device"
		}
		peers = append(peers, peerSummary{
			Key:             peerStableKey(peer.ID),
			Name:            name,
			OS:              peer.OS,
			DeviceModel:     peer.DeviceModel,
			DeviceType:      classifyPeerDevice(peer.OS, peer.DeviceModel),
			Addresses:       displayAddresses(peer.TailscaleIPs),
			Online:          peer.Online,
			ExitNode:        peer.ExitNodeOption,
			KeyExpired:      peer.Expired,
			KeyExpiryUnixMS: keyExpiryUnixMS(peer.KeyExpiry),
		})
	}
	sort.Slice(peers, func(i, j int) bool {
		if peers[i].Online != peers[j].Online {
			return peers[i].Online
		}
		return peers[i].Name < peers[j].Name
	})
	return peers
}

func buildAccountSummary(status *ipnstate.Status) accountSummary {
	account := accountSummary{Addresses: []string{}}
	account.NeedsApproval = status.BackendState == "NeedsMachineAuth"
	if status.Self == nil {
		return account
	}
	account.KeyExpired = status.Self.Expired
	account.KeyExpiryUnixMS = keyExpiryUnixMS(status.Self.KeyExpiry)
	if profile, ok := status.User[status.Self.UserID]; ok {
		account.DisplayName = strings.TrimSpace(profile.DisplayName)
		account.LoginName = strings.TrimSpace(profile.LoginName)
		account.ProfilePicURL = strings.TrimSpace(profile.ProfilePicURL)
	}
	account.DeviceName = strings.TrimSuffix(status.Self.DNSName, ".")
	if account.DeviceName == "" {
		account.DeviceName = strings.TrimSpace(status.Self.HostName)
	}
	account.Addresses = displayAddresses(status.TailscaleIPs)
	if status.CurrentTailnet != nil {
		account.TailnetName = strings.TrimSpace(status.CurrentTailnet.Name)
	}
	if account.DisplayName == "" {
		account.DisplayName = account.LoginName
	}
	return account
}

// setExitNode validates the requested stable ID against the current netmap,
// then stores the choice in the same persistent preferences used by Tailscale.
// An empty ID disables exit-node use.
func (b *backendController) setExitNode(id string) string {
	b.mu.Lock()
	client := b.client
	stateDir := b.stateDir
	b.mu.Unlock()
	if client == nil {
		return "FAILED | exit node | backend not ready"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil || status.BackendState != "Running" {
		return "FAILED | exit node | status unavailable"
	}
	selectedID := tailcfg.StableNodeID(id)
	if id != "" {
		validChoice := false
		for _, peer := range status.Peer {
			if peer.ID == selectedID && peer.ExitNodeOption {
				validChoice = true
				break
			}
		}
		if !validChoice {
			return "FAILED | exit node | invalid selection"
		}
	}
	_, err = client.EditPrefs(ctx, &ipn.MaskedPrefs{
		Prefs: ipn.Prefs{
			ExitNodeID: selectedID,
		},
		ExitNodeIDSet: true,
	})
	if err != nil {
		return "FAILED | exit node | preference update"
	}
	if err := writeExitNodeChoice(stateDir, id); err != nil {
		return "FAILED | exit node | persistence update"
	}
	if id == "" {
		return "OK | exit node disabled"
	}
	return "OK | exit node selected"
}

// networkSettings returns only non-sensitive, user-editable network
// preferences. Tailnet policy, peer identities, and addresses are excluded.
func (b *backendController) networkSettings() string {
	b.mu.Lock()
	client := b.client
	stateDir := b.stateDir
	b.mu.Unlock()

	settings, err := readNetworkPreferences(stateDir)
	if err != nil {
		settings = defaultNetworkPreferences()
	}
	if client != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		prefs, prefsErr := client.GetPrefs(ctx)
		cancel()
		if prefsErr == nil && prefs != nil {
			settings.RouteAll = prefs.RouteAll
			settings.CorpDNS = prefs.CorpDNS
			settings.ExitNodeAllowLANAccess = prefs.ExitNodeAllowLANAccess
		}
	}
	encoded, err := json.Marshal(settings)
	if err != nil {
		return "{}"
	}
	return string(encoded)
}

// setNetworkSetting validates a fixed preference key, applies it to the live
// LocalBackend, and persists the app-level choice for the VPN Extension
// process. The UI only exposes this while the system VPN is disconnected.
func (b *backendController) setNetworkSetting(key string, enabled bool) string {
	b.mu.Lock()
	client := b.client
	stateDir := b.stateDir
	starting := b.starting
	b.mu.Unlock()
	if client == nil || starting {
		return "FAILED | network setting | backend not ready"
	}

	settings, err := readNetworkPreferences(stateDir)
	if err != nil {
		return "FAILED | network setting | persistence read"
	}
	masked := &ipn.MaskedPrefs{}
	switch key {
	case "routeAll":
		settings.RouteAll = enabled
		masked.Prefs.RouteAll = enabled
		masked.RouteAllSet = true
	case "corpDNS":
		settings.CorpDNS = enabled
		masked.Prefs.CorpDNS = enabled
		masked.CorpDNSSet = true
	case "exitNodeAllowLANAccess":
		settings.ExitNodeAllowLANAccess = enabled
		masked.Prefs.ExitNodeAllowLANAccess = enabled
		masked.ExitNodeAllowLANAccessSet = true
	default:
		return "FAILED | network setting | unsupported key"
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	_, err = client.EditPrefs(ctx, masked)
	cancel()
	if err != nil {
		return "FAILED | network setting | preference update"
	}
	if err := writeNetworkPreferences(stateDir, settings); err != nil {
		return "FAILED | network setting | persistence update"
	}
	return "OK | network setting updated"
}

const exitNodeChoiceFile = "exit-node-choice"
const networkPreferencesFile = "network-preferences.json"

func defaultNetworkPreferences() networkPreferences {
	return networkPreferences{
		RouteAll:               true,
		CorpDNS:                true,
		ExitNodeAllowLANAccess: false,
	}
}

func readNetworkPreferences(stateDir string) (networkPreferences, error) {
	settings := defaultNetworkPreferences()
	if stateDir == "" {
		return settings, fmt.Errorf("missing state directory")
	}
	value, err := os.ReadFile(filepath.Join(stateDir, networkPreferencesFile))
	if os.IsNotExist(err) {
		return settings, nil
	}
	if err != nil {
		return settings, err
	}
	if err := json.Unmarshal(value, &settings); err != nil {
		return defaultNetworkPreferences(), err
	}
	return settings, nil
}

func writeNetworkPreferences(stateDir string, settings networkPreferences) error {
	if stateDir == "" {
		return fmt.Errorf("missing state directory")
	}
	value, err := json.Marshal(settings)
	if err != nil {
		return err
	}
	path := filepath.Join(stateDir, networkPreferencesFile)
	temporaryPath := path + ".tmp"
	if err := os.WriteFile(temporaryPath, value, 0600); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		_ = os.Remove(temporaryPath)
		return err
	}
	return nil
}

func readExitNodeChoice(stateDir string) (string, error) {
	if stateDir == "" {
		return "", os.ErrNotExist
	}
	value, err := os.ReadFile(filepath.Join(stateDir, exitNodeChoiceFile))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(value)), nil
}

func writeExitNodeChoice(stateDir, id string) error {
	if stateDir == "" {
		return fmt.Errorf("missing state directory")
	}
	path := filepath.Join(stateDir, exitNodeChoiceFile)
	temporaryPath := path + ".tmp"
	if err := os.WriteFile(temporaryPath, []byte(id), 0600); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		_ = os.Remove(temporaryPath)
		return err
	}
	return nil
}

// restoreExitNodeChoice reapplies the app-level selection after tsnet startup.
// tsnet intentionally supplies a fresh preference set on every Server.Start,
// which otherwise clears exit-node choice when the UI hands off to the VPN
// Extension or when a development update restarts the processes.
func restoreExitNodeChoice(ctx context.Context, client *local.Client, stateDir string) {
	id, err := readExitNodeChoice(stateDir)
	if err != nil || id == "" {
		return
	}
	selectedID := tailcfg.StableNodeID(id)
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		requestContext, cancel := context.WithTimeout(ctx, 2*time.Second)
		status, statusErr := client.Status(requestContext)
		cancel()
		if statusErr == nil && status.BackendState == "Running" {
			validChoice := false
			for _, peer := range status.Peer {
				if peer.ID == selectedID && peer.ExitNodeOption {
					validChoice = true
					break
				}
			}
			if !validChoice {
				if !waitForBackendRetry(ctx) {
					return
				}
				continue
			}
			requestContext, cancel = context.WithTimeout(ctx, 3*time.Second)
			_, _ = client.EditPrefs(requestContext, &ipn.MaskedPrefs{
				Prefs: ipn.Prefs{
					ExitNodeID: selectedID,
				},
				ExitNodeIDSet: true,
			})
			cancel()
			return
		}
		if !waitForBackendRetry(ctx) {
			return
		}
	}
}

// restoreNetworkPreferences matches the mobile defaults on a first run, then
// preserves explicit user choices across the UI-process to VPN-Extension
// handoff. tsnet supplies fresh platform defaults on each Server.Start, and
// OpenHarmony does not inherit the Android/iOS RouteAll default.
func restoreNetworkPreferences(ctx context.Context, client *local.Client, stateDir string) {
	settings, err := readNetworkPreferences(stateDir)
	if err != nil {
		settings = defaultNetworkPreferences()
	}
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		requestContext, cancel := context.WithTimeout(ctx, 2*time.Second)
		status, statusErr := client.Status(requestContext)
		cancel()
		if statusErr == nil && status.BackendState == "Running" {
			requestContext, cancel = context.WithTimeout(ctx, 2*time.Second)
			_, prefsErr := client.EditPrefs(requestContext, &ipn.MaskedPrefs{
				Prefs: ipn.Prefs{
					RouteAll:               settings.RouteAll,
					CorpDNS:                settings.CorpDNS,
					ExitNodeAllowLANAccess: settings.ExitNodeAllowLANAccess,
				},
				RouteAllSet:               true,
				CorpDNSSet:                true,
				ExitNodeAllowLANAccessSet: true,
			})
			cancel()
			if prefsErr == nil {
				_ = writeNetworkPreferences(stateDir, settings)
				return
			}
		}
		if !waitForBackendRetry(ctx) {
			return
		}
	}
}

func waitForBackendRetry(ctx context.Context) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(250 * time.Millisecond):
		return true
	}
}

// peerProbe performs an identity-redacted TSMP data-plane check against the
// first online IPv4 peer. It never returns a peer name, key, or address.
func (b *backendController) peerProbe() string {
	b.mu.Lock()
	client := b.client
	b.mu.Unlock()
	if client == nil {
		return "FAILED | peer TSMP probe | backend not ready"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil {
		return "FAILED | peer TSMP probe | status unavailable"
	}
	foundOnline := false
	for _, peer := range status.Peer {
		if !peer.Online {
			continue
		}
		foundOnline = true
		for _, addr := range peer.TailscaleIPs {
			if !addr.Is4() {
				continue
			}
			result, err := client.Ping(ctx, addr, tailcfg.PingTSMP)
			if err == nil && result != nil && result.Err == "" {
				return "OK | peer TSMP data plane reachable"
			}
			return "FAILED | peer TSMP probe | no response"
		}
	}
	if !foundOnline {
		return "SKIPPED | peer TSMP probe | no online peer"
	}
	return "SKIPPED | peer TSMP probe | no IPv4 peer"
}

// peerConnectivity performs three TSMP probes against a UI-selected peer. The
// UI passes only the stable hashed peer key and the result contains aggregate
// reachability metrics, never the peer address, name, endpoint, or key.
func (b *backendController) peerConnectivity(peerKey string) string {
	result := peerConnectivityResult{State: "failed", Reason: "backend_unavailable"}
	b.mu.Lock()
	client := b.client
	b.mu.Unlock()
	if client == nil {
		return marshalPeerConnectivity(result)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	status, err := client.Status(ctx)
	cancel()
	if err != nil {
		result.Reason = "status_unavailable"
		return marshalPeerConnectivity(result)
	}
	var target netip.Addr
	peerFound := false
	peerOnline := false
	for _, peer := range status.Peer {
		if peerStableKey(peer.ID) != peerKey {
			continue
		}
		peerFound = true
		peerOnline = peer.Online
		for _, addr := range peer.TailscaleIPs {
			if addr.Is4() {
				target = addr
				break
			}
			if !target.IsValid() {
				target = addr
			}
		}
		break
	}
	if !peerFound {
		result.Reason = "peer_not_found"
		return marshalPeerConnectivity(result)
	}
	if !peerOnline {
		result.State = "skipped"
		result.Reason = "peer_offline"
		return marshalPeerConnectivity(result)
	}
	if !target.IsValid() {
		result.State = "skipped"
		result.Reason = "no_address"
		return marshalPeerConnectivity(result)
	}

	const attempts = 3
	latencies := make([]int, 0, attempts)
	result.Sent = attempts
	for attempt := 0; attempt < attempts; attempt++ {
		pingCtx, pingCancel := context.WithTimeout(context.Background(), 3*time.Second)
		pingResult, pingErr := client.Ping(pingCtx, target, tailcfg.PingTSMP)
		pingCancel()
		if pingErr == nil && pingResult != nil && pingResult.Err == "" {
			latencyMS := int(math.Round(pingResult.LatencySeconds * 1000))
			latencies = append(latencies, max(0, latencyMS))
		}
		if attempt+1 < attempts {
			time.Sleep(200 * time.Millisecond)
		}
	}
	result.Received = len(latencies)
	result.LossPercent = (attempts - result.Received) * 100 / attempts
	if result.Received == 0 {
		result.Reason = "no_response"
		return marshalPeerConnectivity(result)
	}
	result.State = "reachable"
	result.Reason = ""
	if result.Received < attempts {
		result.State = "degraded"
	}
	result.MinLatencyMS = latencies[0]
	result.MaxLatencyMS = latencies[0]
	totalLatencyMS := 0
	for _, latencyMS := range latencies {
		result.MinLatencyMS = min(result.MinLatencyMS, latencyMS)
		result.MaxLatencyMS = max(result.MaxLatencyMS, latencyMS)
		totalLatencyMS += latencyMS
	}
	result.AvgLatencyMS = totalLatencyMS / result.Received
	return marshalPeerConnectivity(result)
}

func marshalPeerConnectivity(result peerConnectivityResult) string {
	encoded, err := json.Marshal(result)
	if err != nil {
		return `{"state":"failed","reason":"encoding_failed","sent":0,"received":0,"lossPercent":0,"minLatencyMs":0,"avgLatencyMs":0,"maxLatencyMs":0}`
	}
	return string(encoded)
}

// magicDNSProbeURL returns an in-memory-only browser target for one online
// peer. Callers must never display, log, or persist the returned URL.
func (b *backendController) magicDNSProbeURL() string {
	b.mu.Lock()
	client := b.client
	b.mu.Unlock()
	if client == nil {
		return "FAILED | MagicDNS probe | backend not ready"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil {
		return "FAILED | MagicDNS probe | status unavailable"
	}
	prefs, prefsErr := client.GetPrefs(ctx)
	if prefsErr != nil || prefs == nil || !prefs.CorpDNS {
		return "SKIPPED | MagicDNS probe | Tailscale DNS disabled"
	}
	if status.CurrentTailnet == nil {
		return "FAILED | MagicDNS probe | tailnet state not ready"
	}
	if !status.CurrentTailnet.MagicDNSEnabled {
		return "SKIPPED | MagicDNS probe | disabled by tailnet policy"
	}
	host, _, ok := selectMagicDNSPeer(status)
	if ok {
		return (&url.URL{Scheme: "http", Host: host, Path: "/"}).String()
	}
	return "SKIPPED | MagicDNS probe | no online named peer"
}

func (b *backendController) armMagicDNSProbe() string {
	b.mu.Lock()
	client := b.client
	device := b.tunDevice
	b.mu.Unlock()
	if client == nil || device == nil {
		return "FAILED | MagicDNS probe | VPN backend not ready"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil {
		return "FAILED | MagicDNS probe | status unavailable"
	}
	prefs, prefsErr := client.GetPrefs(ctx)
	if prefsErr != nil || prefs == nil || !prefs.CorpDNS {
		return "SKIPPED | MagicDNS probe | Tailscale DNS disabled"
	}
	if status.CurrentTailnet == nil {
		return "FAILED | MagicDNS probe | tailnet state not ready"
	}
	if !status.CurrentTailnet.MagicDNSEnabled {
		return "SKIPPED | MagicDNS probe | disabled by tailnet policy"
	}
	host, peerIP, ok := selectMagicDNSPeer(status)
	if !ok {
		return "SKIPPED | MagicDNS probe | no online named peer"
	}
	if !device.armMagicDNS(host, peerIP) {
		return "FAILED | MagicDNS probe | target unavailable"
	}
	return "OK | MagicDNS probe armed"
}

func selectMagicDNSPeer(status *ipnstate.Status) (host string, ipv4 netip.Addr, ok bool) {
	type candidate struct {
		host string
		ip   netip.Addr
	}
	candidates := make([]candidate, 0)
	for _, peer := range status.Peer {
		host := strings.TrimSuffix(peer.DNSName, ".")
		if !peer.Online || host == "" || strings.ContainsAny(host, "/?#@:") {
			continue
		}
		for _, address := range peer.TailscaleIPs {
			if address.Is4() {
				candidates = append(candidates, candidate{host: host, ip: address})
				break
			}
		}
	}
	if len(candidates) == 0 {
		return "", netip.Addr{}, false
	}
	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].host < candidates[j].host
	})
	return candidates[0].host, candidates[0].ip, true
}

// userLogf records only coarse progress markers. In particular, it never
// stores the formatted log arguments because those can contain an auth URL.
func (b *backendController) userLogf(format string, _ ...any) {
	switch {
	case strings.Contains(format, "To start this tsnet server"):
		b.setPhase("login-url-ready")
	case strings.Contains(format, "StartLoginInteractive"):
		b.setPhase("login-requested")
	case strings.Contains(format, "AuthLoop"):
		b.setPhase("auth-loop-finished")
	}
}

// backendLogf deliberately classifies errors without retaining their text or
// arguments, which may include network identifiers or credentials.
func (b *backendController) backendLogf(format string, args ...any) {
	lowerFormat := strings.ToLower(format)
	phase := ""
	switch {
	case strings.Contains(lowerFormat, "direct.trylogin"):
		phase = "direct-try-login"
	case strings.Contains(lowerFormat, "logininteractive"):
		phase = "interactive-key-regen"
	case strings.Contains(lowerFormat, "dologin("):
		phase = "do-login"
	case strings.Contains(lowerFormat, "control server key"):
		phase = "control-key-loaded"
	case strings.Contains(lowerFormat, "registerreq"):
		phase = "register-request-built"
	case strings.Contains(lowerFormat, "trylogin"):
		phase = "try-login-returned"
	case strings.Contains(lowerFormat, "awaiting unpause"):
		phase = "auth-awaiting-unpause"
	}
	if phase != "" {
		b.setPhase(phase)
	}
	if !strings.Contains(lowerFormat, "controlhttp") &&
		!strings.Contains(lowerFormat, "noise dial") {
		return
	}

	// Inspect error arguments only to assign a fixed category. Never retain or
	// display the arguments themselves because they may contain addresses.
	detail := strings.ToLower(fmt.Sprint(args...))
	switch {
	case strings.Contains(detail, "operation not permitted"),
		strings.Contains(detail, "permission denied"):
		b.setPhase("network-permission-denied")
	case strings.Contains(detail, "network is unreachable"),
		strings.Contains(detail, "no route to host"):
		b.setPhase("network-unreachable")
	case strings.Contains(detail, "no such host"),
		strings.Contains(detail, "name resolution"),
		strings.Contains(detail, "lookup "):
		b.setPhase("dns-error")
	case strings.Contains(detail, "certificate"),
		strings.Contains(detail, "x509"),
		strings.Contains(detail, "tls"):
		b.setPhase("tls-error")
	case strings.Contains(detail, "deadline exceeded"),
		strings.Contains(detail, "timed out"),
		strings.Contains(detail, "timeout"):
		b.setPhase("network-timeout")
	case strings.Contains(detail, "connection refused"),
		strings.Contains(detail, "connection reset"):
		b.setPhase("connection-error")
	case strings.Contains(detail, "not supported"):
		b.setPhase("socket-unsupported")
	case strings.Contains(lowerFormat, "failed"):
		b.setPhase("control-error-observed")
	}
}

func (b *backendController) setPhase(phase string) {
	b.mu.Lock()
	b.phase = phase
	b.mu.Unlock()
}

func (b *backendController) startAsync(
	server *tsnet.Server, stateDir string, generation uint64, startContext context.Context,
) {
	defer func() {
		if recovered := recover(); recovered != nil {
			b.setStartErrorFor(server, generation, fmt.Errorf("panic: %v\n%s", recovered, debug.Stack()))
		}
	}()

	if err := server.Start(); err != nil {
		b.setStartErrorFor(server, generation, err)
		return
	}
	client, err := server.LocalClient()
	if err != nil {
		b.setStartErrorFor(server, generation, err)
		return
	}

	b.mu.Lock()
	if b.server != server || b.generation != generation || startContext.Err() != nil {
		b.mu.Unlock()
		return
	}
	b.client = client
	b.mu.Unlock()

	restoreNetworkPreferences(startContext, client, stateDir)
	restoreExitNodeChoice(startContext, client, stateDir)

	b.mu.Lock()
	if b.server != server || b.generation != generation || startContext.Err() != nil {
		b.mu.Unlock()
		return
	}
	b.starting = false
	b.cancelStart = nil
	if b.phase == "netns-disabled" {
		b.phase = "local-client-ready"
	}
	b.mu.Unlock()
}

func (b *backendController) setStartErrorFor(server *tsnet.Server, generation uint64, err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.server != server || b.generation != generation {
		return
	}
	b.starting = false
	b.startErr = err.Error()
	b.cancelStart = nil
}

func (b *backendController) status() string {
	b.mu.Lock()
	client := b.client
	starting := b.starting
	startErr := b.startErr
	phase := b.phase
	serverPresent := b.server != nil
	b.mu.Unlock()

	switch {
	case startErr != "":
		return fmt.Sprintf("FAILED | backend start | %s", startErr)
	case starting:
		return fmt.Sprintf("OK | backend starting | phase=%s", phase)
	case client == nil && serverPresent:
		return "OK | backend initialized | LocalClient pending"
	case client == nil:
		return "STOPPED | backend not started"
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	status, err := client.StatusWithoutPeers(ctx)
	if err != nil {
		return fmt.Sprintf("FAILED | backend status | %v", err)
	}
	prefs, prefsErr := client.GetPrefs(ctx)
	return b.formatRunningStatus(status, prefs, prefsErr)
}

func (b *backendController) formatRunningStatus(
	status *ipnstate.Status, prefs *ipn.Prefs, prefsErr error,
) string {
	b.mu.Lock()
	externalTun := b.externalTun
	tunDevice := b.tunDevice
	subnetRoutes := b.subnetRoutes
	phase := b.phase
	b.mu.Unlock()
	exitNodeSelected := prefsErr == nil && prefs != nil &&
		(!prefs.ExitNodeID.IsZero() || prefs.ExitNodeIP.IsValid())
	subnetRoutesEnabled := prefsErr == nil && prefs != nil && prefs.RouteAll
	corpDNSEnabled := prefsErr == nil && prefs != nil && prefs.CorpDNS
	exitNodeLANEnabled := prefsErr == nil && prefs != nil && prefs.ExitNodeAllowLANAccess
	magicDNSState := "unknown"
	if status.CurrentTailnet != nil {
		if status.CurrentTailnet.MagicDNSEnabled {
			magicDNSState = "enabled"
		} else {
			magicDNSState = "disabled"
		}
	}
	var tunRead, tunWritten, txBytes, rxBytes, trafficSession uint64
	var dnsQueries, dnsResponses, dnsAnswers uint64
	var magicArmed bool
	var magicQueries, magicResponses, magicAnswers, magicPeerOut, magicPeerIn uint64
	if tunDevice != nil {
		tunRead, tunWritten = tunDevice.packetCounts()
		txBytes, rxBytes, trafficSession = tunDevice.trafficCounts()
		dnsQueries, dnsResponses, dnsAnswers = tunDevice.dnsCounts()
		magicArmed, magicQueries, magicResponses, magicAnswers, magicPeerOut, magicPeerIn = tunDevice.magicDNSCounts()
	}
	return fmt.Sprintf(
		"OK | state=%s | loginURLReady=%t | tailscaleIPs=%d | tun=%t | exitNode=%t | routeAll=%t | corpDNS=%t | exitNodeLAN=%t | subnetRoutes=%d | tunRead=%d | tunWrite=%d | trafficSession=%d | txBytes=%d | rxBytes=%d | dnsQ=%d | dnsR=%d | dnsA=%d | magicDNSState=%s | magicArmed=%t | magicQ=%d | magicR=%d | magicA=%d | magicOut=%d | magicIn=%d | netUp=unknown | phase=%s",
		status.BackendState,
		status.AuthURL != "",
		len(status.TailscaleIPs),
		status.TUN || externalTun,
		exitNodeSelected,
		subnetRoutesEnabled,
		corpDNSEnabled,
		exitNodeLANEnabled,
		subnetRoutes,
		tunRead,
		tunWritten,
		trafficSession,
		txBytes,
		rxBytes,
		dnsQueries,
		dnsResponses,
		dnsAnswers,
		magicDNSState,
		magicArmed,
		magicQueries,
		magicResponses,
		magicAnswers,
		magicPeerOut,
		magicPeerIn,
		phase,
	)
}

func (b *backendController) authURL() string {
	b.mu.Lock()
	client := b.client
	b.mu.Unlock()
	if client == nil {
		return "FAILED | login URL | backend not ready"
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	status, err := client.StatusWithoutPeers(ctx)
	if err != nil {
		return "FAILED | login URL | status unavailable"
	}
	if status.AuthURL == "" {
		// Logout clears the previous authorization URL. Explicitly start a new
		// interactive flow; the control plane publishes the new URL
		// asynchronously, so the ArkUI side polls this bounded PENDING state.
		if err := client.StartLoginInteractive(ctx); err != nil {
			return "FAILED | login URL | interactive login request"
		}
		return "PENDING | login URL | requested"
	}
	parsed, err := url.Parse(status.AuthURL)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() != "login.tailscale.com" {
		return "FAILED | login URL | rejected unexpected origin"
	}
	return status.AuthURL
}
