package main

import (
	"encoding/json"
	"errors"
	"net/netip"
	"slices"
	"strings"
	"sync"

	"tailscale.com/net/dns"
	"tailscale.com/net/tsaddr"
	"tailscale.com/types/dnstype"
	"tailscale.com/util/dnsname"
)

type dnsStartupInput struct {
	sequence        int64
	enabled         bool
	resolvers       []string
	tailnetEnabled  bool
	customResolvers []string
	searchDomains   []string
}

type dnsRuntimeCommand struct {
	PeerKey         string   `json:"peerKey"`
	Operation       string   `json:"operation"`
	Sequence        int64    `json:"sequence"`
	Enabled         bool     `json:"enabled"`
	Session         string   `json:"session"`
	Resolvers       []string `json:"resolvers"`
	CustomResolvers []string `json:"customResolvers,omitempty"`
	SearchDomains   []string `json:"searchDomains,omitempty"`
}

func (b *backendController) dnsRuntimeCommand(text string) string {
	if len(text) > 16384 {
		return "FAILED | DNS runtime | input capacity"
	}
	var command dnsRuntimeCommand
	if json.Unmarshal([]byte(text), &command) != nil {
		return "FAILED | DNS runtime | invalid input"
	}
	if command.Operation == "snapshot" {
		return b.dnsSystemConfig()
	}
	if command.Operation == "diagnose" {
		return b.diagnosePeerDNS(command.PeerKey)
	}
	if command.Operation == "stage" {
		if command.Sequence <= 0 {
			return "FAILED | DNS runtime | invalid sequence"
		}
		if len(command.CustomResolvers) > 2 || len(command.SearchDomains) > 8 {
			return "FAILED | DNS runtime | custom capacity"
		}
		if len(command.CustomResolvers) > 0 {
			if _, err := validatedCustomDNS(command.CustomResolvers); err != nil {
				return "FAILED | DNS runtime | invalid custom resolver"
			}
		}
		if _, err := validatedCustomSearchDomains(command.SearchDomains); err != nil {
			return "FAILED | DNS runtime | invalid custom domain"
		}
		if len(command.SearchDomains) > 0 && len(command.CustomResolvers) == 0 {
			return "FAILED | DNS runtime | custom resolver required"
		}
		if command.Enabled && len(command.CustomResolvers) == 0 {
			if _, err := validatedDNSBase(command.Resolvers); err != nil {
				return "FAILED | DNS runtime | physical DNS unavailable"
			}
		}
		b.mu.Lock()
		defer b.mu.Unlock()
		if b.server != nil || b.starting || command.Sequence <= b.dnsInput.sequence {
			return "FAILED | DNS runtime | stale startup"
		}
		b.dnsInput = dnsStartupInput{sequence: command.Sequence,
			enabled: command.Enabled || len(command.CustomResolvers) > 0, tailnetEnabled: command.Enabled,
			resolvers: slices.Clone(command.Resolvers), customResolvers: slices.Clone(command.CustomResolvers),
			searchDomains: slices.Clone(command.SearchDomains)}
		return "OK | DNS runtime staged"
	}
	if command.Operation != "update" {
		return "FAILED | DNS runtime | invalid operation"
	}
	b.dnsUpdateMu.Lock()
	defer b.dnsUpdateMu.Unlock()
	b.mu.Lock()
	server, adapter, generation := b.server, b.dnsRuntime, b.generation
	session := b.dnsObservation.session
	if command.Session == "" || command.Session != session || server == nil || adapter == nil || b.starting {
		b.mu.Unlock()
		return "FAILED | DNS runtime | stale session"
	}
	b.mu.Unlock()
	if err := adapter.replaceBase(command.Resolvers); err != nil {
		return "FAILED | DNS runtime | physical DNS unavailable"
	}
	if err := server.RecompileDNSConfig(); err != nil {
		adapter.invalidateOutput()
		return "FAILED | DNS runtime | compile unavailable"
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.server != server || b.dnsRuntime != adapter || b.generation != generation {
		return "FAILED | DNS runtime | stale session"
	}
	b.dnsInput.resolvers = slices.Clone(command.Resolvers)
	return "OK | DNS runtime updated"
}

func (b *backendController) dnsSystemConfig() string {
	b.dnsUpdateMu.Lock()
	defer b.dnsUpdateMu.Unlock()
	b.mu.Lock()
	defer b.mu.Unlock()
	snapshot := dnsSystemSnapshot{SchemaVersion: 1, Session: b.dnsObservation.session,
		State: "disabled", DNSAddresses: []string{}, SearchDomains: []string{}}
	if b.dnsInput.enabled {
		snapshot.State = "unavailable"
		if b.dnsRuntime != nil && b.client != nil && !b.starting {
			snapshot = b.dnsRuntime.snapshot(snapshot.Session)
		}
	}
	text, _ := json.Marshal(snapshot)
	return string(text)
}

// The engine compiles DNS policy; this adapter only supplies the physical
// network's base and observes the resulting OS projection. ArkTS owns applying
// that projection through VpnConnection. It does not configure the host OS here.
type harmonyDNSConfigurator struct {
	mu                  sync.Mutex
	base                []netip.Addr
	config              dns.OSConfig
	revision            uint64
	ready               bool
	closed              bool
	customResolvers     []string
	customSearchDomains []dnsname.FQDN
}

func (d *harmonyDNSConfigurator) invalidateOutput() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.ready = false
	d.config = dns.OSConfig{}
}

func validatedDNSBase(values []string) ([]netip.Addr, error) {
	if len(values) == 0 || len(values) > 64 {
		return nil, errors.New("physical DNS capacity")
	}
	addresses := make([]netip.Addr, 0, len(values))
	for _, value := range values {
		address, err := netip.ParseAddr(value)
		if err != nil || address.IsUnspecified() || address.IsMulticast() || address.IsLoopback() {
			return nil, errors.New("invalid physical DNS address")
		}
		address = address.Unmap()
		if address == tsaddr.TailscaleServiceIP() || address == tsaddr.TailscaleServiceIPv6() {
			return nil, errors.New("DNS forwarding loop")
		}
		if !slices.Contains(addresses, address) {
			addresses = append(addresses, address)
		}
	}
	return addresses, nil
}

func (d *harmonyDNSConfigurator) SetDNS(config dns.OSConfig) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return errors.New("DNS configurator closed")
	}
	if !d.config.Equal(config) || !d.ready {
		d.revision++
	}
	d.config = dns.OSConfig{Nameservers: slices.Clone(config.Nameservers),
		SearchDomains: slices.Clone(config.SearchDomains), MatchDomains: slices.Clone(config.MatchDomains)}
	d.ready = len(config.Nameservers) > 0 && len(config.Nameservers) <= 64 && len(config.MatchDomains) == 0
	return nil
}

func (d *harmonyDNSConfigurator) SupportsSplitDNS() bool { return false }

func (d *harmonyDNSConfigurator) GetBaseConfig() (dns.OSConfig, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return dns.OSConfig{}, errors.New("DNS configurator closed")
	}
	if len(d.base) == 0 {
		return dns.OSConfig{}, dns.ErrGetBaseConfigNoResolvers
	}
	base := dns.OSConfig{Nameservers: slices.Clone(d.base)}
	for _, ip := range d.base {
		base.Resolvers = append(base.Resolvers, dnstype.PhysicalNetworkResolver(&dnstype.Resolver{Addr: ip.String()}))
	}
	return base, nil
}

func (d *harmonyDNSConfigurator) Close() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.closed, d.ready = true, false
	d.config = dns.OSConfig{}
	d.base = nil
	d.customResolvers = nil
	d.customSearchDomains = nil
	d.revision++
	return nil
}

func (d *harmonyDNSConfigurator) replaceBase(values []string) error {
	base, err := validatedDNSBase(values)
	if err != nil {
		return err
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return errors.New("DNS configurator closed")
	}
	d.base = base
	d.ready = false
	d.config = dns.OSConfig{}
	return nil
}

type dnsSystemSnapshot struct {
	SchemaVersion int      `json:"schemaVersion"`
	Session       string   `json:"session"`
	Revision      uint64   `json:"revision"`
	State         string   `json:"state"`
	DNSAddresses  []string `json:"dnsAddresses"`
	SearchDomains []string `json:"searchDomains"`
}

func (d *harmonyDNSConfigurator) snapshot(session string) dnsSystemSnapshot {
	d.mu.Lock()
	defer d.mu.Unlock()
	snapshot := dnsSystemSnapshot{SchemaVersion: 1, Session: session, Revision: d.revision,
		State: "unavailable", DNSAddresses: []string{}, SearchDomains: []string{}}
	if d.closed || !d.ready {
		return snapshot
	}
	snapshot.State = "ready"
	for _, address := range d.config.Nameservers {
		snapshot.DNSAddresses = append(snapshot.DNSAddresses, address.String())
	}
	for _, domain := range d.config.SearchDomains {
		snapshot.SearchDomains = append(snapshot.SearchDomains, domain.WithoutTrailingDot())
	}
	return snapshot
}

// Compile-time contract: all platform policy is handled by the upstream manager.
var _ dns.OSConfigurator = (*harmonyDNSConfigurator)(nil)

func validatedCustomSearchDomains(values []string) ([]dnsname.FQDN, error) {
	if len(values) > 8 {
		return nil, errors.New("custom search capacity")
	}
	var result []dnsname.FQDN
	for _, value := range values {
		value = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(value)), ".")
		if len(value) == 0 || len(value) > 253 {
			return nil, errors.New("invalid custom search")
		}
		for _, label := range strings.Split(value, ".") {
			if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
				return nil, errors.New("invalid custom label")
			}
			for _, ch := range label {
				if !(ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' || ch == '-') {
					return nil, errors.New("invalid custom label")
				}
			}
		}
		domain, err := dnsname.ToFQDN(value)
		if err != nil {
			return nil, errors.New("invalid custom search")
		}
		if !slices.Contains(result, domain) {
			result = append(result, domain)
		}
	}
	return result, nil
}

func validatedCustomDNS(values []string) ([]netip.Addr, error) {
	addresses, err := validatedDNSBase(values)
	if err != nil {
		return nil, err
	}
	for _, address := range addresses {
		if address.IsUnspecified() || address.IsMulticast() || address.IsLoopback() || address.IsLinkLocalUnicast() ||
			address == netip.MustParseAddr("255.255.255.255") {
			return nil, errors.New("unusable custom DNS address")
		}
	}
	return addresses, nil
}

// Called on a clone by the DNS manager, before resolver and OS compilation.
// Only the default upstream and extra search list change. More-specific routes,
// including authoritative nil routes, remain intact and have no public fallback.
func (d *harmonyDNSConfigurator) TransformDNSConfig(cfg dns.Config) (dns.Config, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return dns.Config{}, errors.New("DNS configurator closed")
	}
	if len(d.customResolvers) == 0 {
		return cfg, nil
	}
	cfg.DefaultResolvers = nil
	for _, address := range d.customResolvers {
		cfg.DefaultResolvers = append(cfg.DefaultResolvers, &dnstype.Resolver{Addr: address})
	}
	// Keep the platform on Quad100 even in custom-only mode. Upstream IPv6
	// reachability belongs to the dialer, not the platform TUN address families.
	if cfg.Routes == nil {
		cfg.Routes = make(map[dnsname.FQDN][]*dnstype.Resolver)
	}
	cfg.Routes["."] = slices.Clone(cfg.DefaultResolvers)
	for _, domain := range d.customSearchDomains {
		if len(cfg.SearchDomains) >= 256 {
			break
		}
		if !slices.Contains(cfg.SearchDomains, domain) {
			cfg.SearchDomains = append(cfg.SearchDomains, domain)
		}
	}
	return cfg, nil
}
