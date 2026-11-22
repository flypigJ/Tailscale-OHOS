package main

import (
	"bytes"
	"errors"
	"io"
	"testing"
	"time"

	"github.com/tailscale/wireguard-go/tun"
	"golang.org/x/sys/unix"
)

func TestHarmonyTunCloseInterruptsIdleReader(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fds[0])
	defer unix.Close(fds[1])
	d, err := newHarmonyTunDevice(fds[0], 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	// A deadline requires a runtime-pollable descriptor. Without it Close
	// cannot evict an idle read and a destroyed TUN can remain referenced.
	if err := d.file.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatalf("TUN descriptor cannot be interrupted: %v", err)
	}
	done := make(chan error, 1)
	go func() {
		_, e := d.Read(make([]byte, 1280+2*tun.ReadPacketSpacing), make([]tun.ReadPacket, 1))
		done <- e
	}()
	select {
	case e := <-done:
		t.Fatalf("idle read returned before close: %v", e)
	case <-time.After(20 * time.Millisecond):
	}
	closed := make(chan error, 1)
	go func() { closed <- d.Close() }()
	select {
	case e := <-closed:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(300 * time.Millisecond):
		t.Fatal("Close blocked on idle TUN")
	}
	select {
	case e := <-done:
		if e == nil {
			t.Fatal("closed read succeeded")
		}
	case <-time.After(300 * time.Millisecond):
		t.Fatal("idle reader survived Close")
	}
	if _, e := unix.FcntlInt(uintptr(fds[0]), unix.F_GETFD, 0); e != nil {
		t.Fatal("platform fd ownership changed")
	}
}

func TestHarmonyTunSlabReadPreservesSpacingAndDescriptor(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fds[0])
	defer unix.Close(fds[1])
	d, err := newHarmonyTunDevice(fds[0], 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	payload := []byte{0x60, 1, 2, 3, 4, 5, 6, 7}
	if _, err := unix.Write(fds[1], payload); err != nil {
		t.Fatal(err)
	}
	slab := bytes.Repeat([]byte{0xa5}, len(payload)+2*tun.ReadPacketSpacing)
	packets := make([]tun.ReadPacket, d.BatchSize())
	n, err := d.Read(slab, packets)
	if err != nil || n != 1 {
		t.Fatalf("Read = %d, %v", n, err)
	}
	p := packets[0]
	if p.Offset != tun.ReadPacketSpacing || p.Size != len(payload) || !bytes.Equal(slab[p.Offset:p.Offset+p.Size], payload) {
		t.Fatal("slab packet boundary or payload changed")
	}
	if !bytes.Equal(slab[:p.Offset], bytes.Repeat([]byte{0xa5}, tun.ReadPacketSpacing)) ||
		!bytes.Equal(slab[p.Offset+p.Size:], bytes.Repeat([]byte{0xa5}, tun.ReadPacketSpacing)) {
		t.Fatal("WireGuard headroom or tailroom was overwritten")
	}
	if d.readCount.Load() != 1 || d.readByteCount.Load() != uint64(len(payload)) {
		t.Fatal("TUN counters changed semantics")
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := unix.FcntlInt(uintptr(fds[0]), unix.F_GETFD, 0); err != nil {
		t.Fatal("closed the platform-owned descriptor")
	}
}

func TestHarmonyTunSlabReadRejectsInvalidBuffers(t *testing.T) {
	d := &harmonyTunDevice{}
	for _, size := range []int{0, 1, 2*tun.ReadPacketSpacing - 1, 2 * tun.ReadPacketSpacing} {
		if n, err := d.Read(make([]byte, size), make([]tun.ReadPacket, 1)); n != 0 || err == nil {
			t.Fatalf("accepted slab size %d", size)
		}
	}
	if n, err := d.Read(make([]byte, 512), nil); n != 0 || err == nil {
		t.Fatal("accepted missing packet metadata")
	}
}

type scriptedTunWrite struct {
	steps  []scriptedTunWriteStep
	output []byte
	calls  int
}

type scriptedTunWriteStep struct {
	count int
	err   error
}

type scriptedTunRead struct {
	steps []scriptedTunReadStep
}

type scriptedTunReadStep struct {
	data []byte
	err  error
}

func (r *scriptedTunRead) Read(packet []byte) (int, error) {
	if len(r.steps) == 0 {
		return 0, io.EOF
	}
	step := r.steps[0]
	r.steps = r.steps[1:]
	return copy(packet, step.data), step.err
}

func (w *scriptedTunWrite) Write(packet []byte) (int, error) {
	w.calls++
	if len(w.steps) == 0 {
		return 0, io.ErrNoProgress
	}
	step := w.steps[0]
	w.steps = w.steps[1:]
	if step.count > len(packet) {
		step.count = len(packet)
	}
	w.output = append(w.output, packet[:step.count]...)
	return step.count, step.err
}

func TestReadTunPacketRetriesTransientErrors(t *testing.T) {
	reader := &scriptedTunRead{
		steps: []scriptedTunReadStep{
			{err: unix.EAGAIN},
			{err: unix.EINTR},
			{data: []byte("packet")},
		},
	}

	packet := make([]byte, 16)
	read, err := readTunPacket(reader, packet)
	if err != nil {
		t.Fatalf("readTunPacket returned error: %v", err)
	}
	if got := string(packet[:read]); got != "packet" {
		t.Fatalf("readTunPacket returned %q, want packet", got)
	}
}

func TestWriteTunPacketCompletesShortAndTransientWrites(t *testing.T) {
	// 1. Transient EAGAIN/EINTR before any bytes are consumed retries the full packet cleanly.
	transientWriter := &scriptedTunWrite{
		steps: []scriptedTunWriteStep{
			{count: 0, err: unix.EAGAIN},
			{count: 0, err: unix.EINTR},
			{count: 5},
		},
	}
	packet := []byte("hello")
	written, err := writeTunPacket(transientWriter, packet)
	if err != nil {
		t.Fatalf("writeTunPacket transient retry returned error: %v", err)
	}
	if written != len(packet) || transientWriter.calls != 3 || string(transientWriter.output) != "hello" {
		t.Fatalf("writeTunPacket transient retry = (%d, calls=%d, out=%q), want (5, 3, \"hello\")",
			written, transientWriter.calls, transientWriter.output)
	}

	// 2. Partial write (0 < count < len) fails immediately with io.ErrShortWrite without
	// injecting a second headerless tail fragment, and increments writeErrorCount.
	shortWriter := &scriptedTunWrite{
		steps: []scriptedTunWriteStep{
			{count: 2},
			{count: 3},
		},
	}
	var device harmonyTunDevice
	packetsWritten, shortErr := device.writePackets(shortWriter, [][]byte{packet}, 0)
	if !errors.Is(shortErr, io.ErrShortWrite) || packetsWritten != 0 {
		t.Fatalf("device.writePackets short write = (%d, %v), want (0, io.ErrShortWrite)", packetsWritten, shortErr)
	}
	if shortWriter.calls != 1 || string(shortWriter.output) != "he" {
		t.Fatalf("short write issued tail fragment call: calls=%d, output=%q", shortWriter.calls, shortWriter.output)
	}
	if _, writeErrors := device.errorCounts(); writeErrors != 1 {
		t.Fatalf("writeErrorCount = %d, want 1", writeErrors)
	}
}

func TestHarmonyTunDuplicateSetsCloseOnExec(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fds[0])
	defer unix.Close(fds[1])

	device, err := newHarmonyTunDevice(fds[0], 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer device.Close()

	rawConn, err := device.file.SyscallConn()
	if err != nil {
		t.Fatalf("SyscallConn failed: %v", err)
	}
	var flags int
	var fcntlErr error
	if err := rawConn.Control(func(fd uintptr) {
		flags, fcntlErr = unix.FcntlInt(fd, unix.F_GETFD, 0)
	}); err != nil {
		t.Fatalf("Control failed: %v", err)
	}
	if fcntlErr != nil {
		t.Fatalf("F_GETFD failed: %v", fcntlErr)
	}
	if flags&unix.FD_CLOEXEC == 0 {
		t.Fatalf("duplicated TUN descriptor missing FD_CLOEXEC: flags=%#x", flags)
	}
}

func TestWriteTunPacketRejectsNoProgress(t *testing.T) {
	writer := &scriptedTunWrite{
		steps: []scriptedTunWriteStep{{count: 0}},
	}
	if _, err := writeTunPacket(writer, []byte("packet")); !errors.Is(err, io.ErrNoProgress) {
		t.Fatalf("writeTunPacket error = %v, want io.ErrNoProgress", err)
	}
}
