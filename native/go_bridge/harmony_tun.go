package main

import (
	"errors"
	"net/netip"
	"os"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/tailscale/wireguard-go/tun"
	"golang.org/x/sys/unix"
)

// harmonyTunDevice adapts the raw IP packet descriptor returned by
// vpnExtension.VpnConnection.create to wireguard-go's tun.Device interface.
// HarmonyOS owns interface creation and routing, so Linux TUN ioctls and
// netlink monitoring are intentionally not used here.
type harmonyTunDevice struct {
	file               *os.File
	mtu                int
	events             chan tun.Event
	closeOnce          sync.Once
	readCount          atomic.Uint64
	writeCount         atomic.Uint64
	dnsQueryCount      atomic.Uint64
	dnsResponseCount   atomic.Uint64
	dnsAnswerCount     atomic.Uint64
	magicMu            sync.Mutex
	magicName          string
	magicPeerV4        [4]byte
	magicPeerValid     bool
	magicTransactions  map[uint16]struct{}
	magicQueryCount    atomic.Uint64
	magicResponseCount atomic.Uint64
	magicAnswerCount   atomic.Uint64
	magicPeerOutCount  atomic.Uint64
	magicPeerInCount   atomic.Uint64
}

func newHarmonyTunDevice(fd, mtu int) (*harmonyTunDevice, error) {
	if fd < 0 {
		return nil, errors.New("invalid TUN descriptor")
	}
	duplicate, err := unix.Dup(fd)
	if err != nil {
		return nil, err
	}
	if err := unix.SetNonblock(duplicate, true); err != nil {
		_ = unix.Close(duplicate)
		return nil, err
	}
	device := &harmonyTunDevice{
		file:   os.NewFile(uintptr(duplicate), "harmony-vpn-tun"),
		mtu:    mtu,
		events: make(chan tun.Event, 2),
	}
	device.events <- tun.EventUp
	return device, nil
}

func (d *harmonyTunDevice) File() *os.File { return d.file }

func (d *harmonyTunDevice) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	if len(bufs) == 0 || len(sizes) == 0 || offset < 0 || offset >= len(bufs[0]) {
		return 0, errors.New("invalid TUN read buffer")
	}
	n, err := d.file.Read(bufs[0][offset:])
	if n > 0 {
		sizes[0] = n
		d.readCount.Add(1)
		d.observeDNSPacket(bufs[0][offset:offset+n], true)
		return 1, nil
	}
	return 0, err
}

func (d *harmonyTunDevice) Write(bufs [][]byte, offset int) (int, error) {
	written := 0
	for _, buf := range bufs {
		if offset < 0 || offset > len(buf) {
			return written, errors.New("invalid TUN write buffer")
		}
		n, err := d.file.Write(buf[offset:])
		if err != nil {
			return written, err
		}
		if n > 0 {
			d.writeCount.Add(1)
			d.observeDNSPacket(buf[offset:offset+n], false)
		}
		written++
	}
	return written, nil
}

func (d *harmonyTunDevice) MTU() (int, error) { return d.mtu, nil }

func (d *harmonyTunDevice) Name() (string, error) { return "tailscale0", nil }

func (d *harmonyTunDevice) Events() <-chan tun.Event { return d.events }

func (d *harmonyTunDevice) Close() error {
	var err error
	d.closeOnce.Do(func() {
		d.events <- tun.EventDown
		close(d.events)
		err = d.file.Close()
	})
	return err
}

func (d *harmonyTunDevice) BatchSize() int { return 1 }

func (d *harmonyTunDevice) packetCounts() (read uint64, written uint64) {
	return d.readCount.Load(), d.writeCount.Load()
}

func (d *harmonyTunDevice) dnsCounts() (queries uint64, responses uint64, answers uint64) {
	return d.dnsQueryCount.Load(), d.dnsResponseCount.Load(), d.dnsAnswerCount.Load()
}

func (d *harmonyTunDevice) armMagicDNS(name string, peer netip.Addr) bool {
	if !peer.Is4() {
		return false
	}
	d.magicMu.Lock()
	d.magicName = strings.TrimSuffix(strings.ToLower(name), ".")
	d.magicPeerV4 = peer.As4()
	d.magicPeerValid = d.magicName != ""
	d.magicTransactions = make(map[uint16]struct{})
	armed := d.magicPeerValid
	d.magicMu.Unlock()
	return armed
}

func (d *harmonyTunDevice) magicDNSCounts() (armed bool, queries uint64, responses uint64, answers uint64, peerOut uint64, peerIn uint64) {
	d.magicMu.Lock()
	armed = d.magicPeerValid
	d.magicMu.Unlock()
	return armed,
		d.magicQueryCount.Load(),
		d.magicResponseCount.Load(),
		d.magicAnswerCount.Load(),
		d.magicPeerOutCount.Load(),
		d.magicPeerInCount.Load()
}

// observeDNSPacket records only coarse DNS counters. It deliberately does not
// retain query names, addresses, transaction IDs, or packet payloads.
func (d *harmonyTunDevice) observeDNSPacket(packet []byte, fromSystem bool) {
	if len(packet) < 20 || packet[0]>>4 != 4 {
		return
	}
	d.observeMagicDNSPeerPacket(packet, fromSystem)
	headerLength := int(packet[0]&0x0f) * 4
	if headerLength < 20 || len(packet) < headerLength+8+12 || packet[9] != 17 {
		return
	}
	udp := packet[headerLength:]
	sourcePort := uint16(udp[0])<<8 | uint16(udp[1])
	destinationPort := uint16(udp[2])<<8 | uint16(udp[3])
	dns := udp[8:]
	isResponse := dns[2]&0x80 != 0
	if fromSystem && destinationPort == 53 && !isResponse {
		d.dnsQueryCount.Add(1)
		name, ok := dnsQuestionName(dns)
		if ok {
			d.magicMu.Lock()
			if d.magicPeerValid && strings.EqualFold(name, d.magicName) {
				transactionID := uint16(dns[0])<<8 | uint16(dns[1])
				d.magicTransactions[transactionID] = struct{}{}
				d.magicQueryCount.Add(1)
			}
			d.magicMu.Unlock()
		}
		return
	}
	if !fromSystem && sourcePort == 53 && isResponse {
		d.dnsResponseCount.Add(1)
		answerCount := uint16(dns[6])<<8 | uint16(dns[7])
		if answerCount > 0 {
			d.dnsAnswerCount.Add(1)
		}
		transactionID := uint16(dns[0])<<8 | uint16(dns[1])
		d.magicMu.Lock()
		if _, ok := d.magicTransactions[transactionID]; ok {
			delete(d.magicTransactions, transactionID)
			d.magicResponseCount.Add(1)
			if answerCount > 0 {
				d.magicAnswerCount.Add(1)
			}
		}
		d.magicMu.Unlock()
	}
}

func (d *harmonyTunDevice) observeMagicDNSPeerPacket(packet []byte, fromSystem bool) {
	d.magicMu.Lock()
	valid := d.magicPeerValid
	peer := d.magicPeerV4
	d.magicMu.Unlock()
	if !valid || len(packet) < 20 {
		return
	}
	if fromSystem && packet[16] == peer[0] && packet[17] == peer[1] && packet[18] == peer[2] && packet[19] == peer[3] {
		d.magicPeerOutCount.Add(1)
	} else if !fromSystem && packet[12] == peer[0] && packet[13] == peer[1] && packet[14] == peer[2] && packet[15] == peer[3] {
		d.magicPeerInCount.Add(1)
	}
}

func dnsQuestionName(dns []byte) (string, bool) {
	if len(dns) < 13 {
		return "", false
	}
	labels := make([]string, 0, 4)
	for offset := 12; offset < len(dns); {
		length := int(dns[offset])
		offset++
		if length == 0 {
			return strings.Join(labels, "."), len(labels) > 0
		}
		if length&0xc0 != 0 || length > 63 || offset+length > len(dns) {
			return "", false
		}
		labels = append(labels, string(dns[offset:offset+length]))
		offset += length
	}
	return "", false
}

var _ tun.Device = (*harmonyTunDevice)(nil)
