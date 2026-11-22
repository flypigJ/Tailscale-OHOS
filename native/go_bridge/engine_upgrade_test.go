package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func privateUpgradeTestDirectory(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	return root
}

func writeUpgradeTestState(t *testing.T, root, state string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, "tailscaled.state"), []byte(state), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestEngineUpgradeBackupAndRollback(t *testing.T) {
	root := privateUpgradeTestDirectory(t)
	writeUpgradeTestState(t, root, "old-state")
	userFile := filepath.Join(root, "received-user-file")
	if err := os.WriteFile(userFile, []byte("keep-user-data"), 0600); err != nil {
		t.Fatal(err)
	}
	lease, err := prepareEngineStateUpgrade(root)
	if err != nil {
		t.Fatal(err)
	}
	writeUpgradeTestState(t, root, "new-engine-state")
	if err := restoreEngineStateUpgrade(root); err == nil {
		t.Fatal("rollback accepted an active engine lease")
	}
	if err := lease.Close(); err != nil {
		t.Fatal(err)
	}
	resumed, err := prepareEngineStateUpgrade(root)
	if err != nil {
		t.Fatal(err)
	}
	_, data, err := loadEngineStateBackup(root)
	if err != nil || string(data) != "old-state" {
		t.Fatal("new-engine restart overwrote the old state backup")
	}
	_ = resumed.Close()
	if err := restoreEngineStateUpgrade(root); err != nil {
		t.Fatal(err)
	}
	state, err := os.ReadFile(filepath.Join(root, "tailscaled.state"))
	if err != nil || string(state) != "old-state" {
		t.Fatal("rollback did not restore the exact original state")
	}
	userData, err := os.ReadFile(userFile)
	if err != nil || string(userData) != "keep-user-data" {
		t.Fatal("rollback touched a user file")
	}
	writeUpgradeTestState(t, root, "old-engine-new-account")
	nextLease, err := prepareEngineStateUpgrade(root)
	if err != nil {
		t.Fatal(err)
	}
	defer nextLease.Close()
	_, data, err = loadEngineStateBackup(root)
	if err != nil || string(data) != "old-engine-new-account" {
		t.Fatal("a separate upgrade reused a stale identity backup")
	}
}

func TestEngineUpgradeRejectsConcurrentIdentity(t *testing.T) {
	root := privateUpgradeTestDirectory(t)
	lease, err := prepareEngineStateUpgrade(root)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	if duplicate, err := prepareEngineStateUpgrade(root); err == nil {
		_ = duplicate.Close()
		t.Fatal("a second engine acquired the same profile")
	}
}

func TestEngineUpgradeRejectsCorruptBackup(t *testing.T) {
	root := privateUpgradeTestDirectory(t)
	writeUpgradeTestState(t, root, "old-state")
	lease, err := prepareEngineStateUpgrade(root)
	if err != nil {
		t.Fatal(err)
	}
	_ = lease.Close()
	backup, _, err := loadEngineStateBackup(root)
	if err != nil {
		t.Fatal(err)
	}
	writeUpgradeTestState(t, filepath.Join(root, backup.BackupName), "corrupt-backup")
	if lease, err := prepareEngineStateUpgrade(root); err == nil {
		_ = lease.Close()
		t.Fatal("accepted a modified backup")
	}
	if err := restoreEngineStateUpgrade(root); err == nil {
		t.Fatal("restored a modified backup")
	}
	state, _ := os.ReadFile(filepath.Join(root, "tailscaled.state"))
	if string(state) != "old-state" {
		t.Fatal("a failed rollback modified state")
	}
}

func TestEngineUpgradeRejectsSymlinkState(t *testing.T) {
	root := privateUpgradeTestDirectory(t)
	outside := filepath.Join(t.TempDir(), "outside-state")
	if err := os.WriteFile(outside, []byte("outside-data"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "tailscaled.state")); err != nil {
		t.Fatal(err)
	}
	if lease, err := prepareEngineStateUpgrade(root); err == nil {
		_ = lease.Close()
		t.Fatal("copied state outside the private directory")
	}
}

func TestEngineUpgradeFreshStateRollback(t *testing.T) {
	root := privateUpgradeTestDirectory(t)
	lease, err := prepareEngineStateUpgrade(root)
	if err != nil {
		t.Fatal(err)
	}
	_ = lease.Close()
	writeUpgradeTestState(t, root, "new-state")
	if err := restoreEngineStateUpgrade(root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "tailscaled.state")); !os.IsNotExist(err) {
		t.Fatal("fresh-state rollback did not restore the prior absence")
	}
}

func TestEngineUpgradeSyncFailuresRemainRetryable(t *testing.T) {
	for failureIndex := 1; failureIndex <= 4; failureIndex++ {
		t.Run(fmt.Sprint(failureIndex), func(t *testing.T) {
			root := privateUpgradeTestDirectory(t)
			writeUpgradeTestState(t, root, "original-state")
			calls := 0
			lease, err := prepareEngineStateUpgradeWithSync(root, func(path string) error {
				calls++
				if calls == failureIndex {
					return errors.New("injected directory sync failure")
				}
				return syncEngineStateDirectory(path)
			})
			if err == nil || lease != nil {
				t.Fatal("engine was allowed to start without a durable backup")
			}
			resumed, err := prepareEngineStateUpgrade(root)
			if err != nil {
				t.Fatal(err)
			}
			_ = resumed.Close()
			_, state, err := loadEngineStateBackup(root)
			if err != nil || string(state) != "original-state" {
				t.Fatal("retry did not preserve the original state")
			}
		})
	}
}

func TestEngineUpgradeExistingMarkerMustResync(t *testing.T) {
	root := privateUpgradeTestDirectory(t)
	writeUpgradeTestState(t, root, "original-state")
	lease, err := prepareEngineStateUpgrade(root)
	if err != nil {
		t.Fatal(err)
	}
	_ = lease.Close()
	writeUpgradeTestState(t, root, "new-engine-state")
	for failureIndex := 1; failureIndex <= 2; failureIndex++ {
		calls := 0
		lease, err := prepareEngineStateUpgradeWithSync(root, func(path string) error {
			calls++
			if calls == failureIndex {
				return errors.New("injected restart sync failure")
			}
			return syncEngineStateDirectory(path)
		})
		if err == nil || lease != nil {
			t.Fatal("restart accepted an unsynchronized existing backup")
		}
	}
	if err := restoreEngineStateUpgrade(root); err != nil {
		t.Fatal(err)
	}
	state, _ := readEngineStateFile(filepath.Join(root, "tailscaled.state"))
	if string(state) != "original-state" {
		t.Fatal("restart failure replaced the upgrade snapshot")
	}
}

func TestEngineUpgradeRollbackSyncFailuresRemainRetryable(t *testing.T) {
	for _, hasState := range []bool{false, true} {
		lastBoundary := 2
		if hasState {
			lastBoundary = 3
		}
		for failureIndex := 1; failureIndex <= lastBoundary; failureIndex++ {
			t.Run(fmt.Sprintf("state-%t-boundary-%d", hasState, failureIndex), func(t *testing.T) {
				root := privateUpgradeTestDirectory(t)
				if hasState {
					writeUpgradeTestState(t, root, "original-state")
				}
				lease, err := prepareEngineStateUpgrade(root)
				if err != nil {
					t.Fatal(err)
				}
				_ = lease.Close()
				writeUpgradeTestState(t, root, "new-engine-state")
				calls := 0
				err = restoreEngineStateUpgradeWithSync(root, func(path string) error {
					calls++
					if calls == failureIndex {
						return errors.New("injected rollback sync failure")
					}
					return syncEngineStateDirectory(path)
				})
				if err == nil {
					t.Fatal("rollback reported success after a sync failure")
				}
				if _, _, err := loadEngineStateBackup(root); err != nil {
					t.Fatal("failed rollback lost its retry metadata")
				}
				if err := restoreEngineStateUpgrade(root); err != nil {
					t.Fatal(err)
				}
				state, err := readEngineStateFile(filepath.Join(root, "tailscaled.state"))
				if hasState && (err != nil || string(state) != "original-state") {
					t.Fatal("retry did not restore the original state")
				}
				if !hasState && !os.IsNotExist(err) {
					t.Fatal("retry did not restore the original absence")
				}
			})
		}
	}
}

func TestEngineUpgradeRejectsUnsafeFiles(t *testing.T) {
	for _, kind := range []string{"directory", "fifo", "oversized"} {
		t.Run(kind, func(t *testing.T) {
			root := privateUpgradeTestDirectory(t)
			path := filepath.Join(root, "tailscaled.state")
			switch kind {
			case "directory":
				if err := os.Mkdir(path, 0700); err != nil {
					t.Fatal(err)
				}
			case "fifo":
				if err := unix.Mkfifo(path, 0600); err != nil {
					t.Fatal(err)
				}
			case "oversized":
				file, err := os.Create(path)
				if err != nil {
					t.Fatal(err)
				}
				err = file.Truncate(engineStateSizeLimit + 1)
				_ = file.Close()
				if err != nil {
					t.Fatal(err)
				}
			}
			if lease, err := prepareEngineStateUpgrade(root); err == nil {
				_ = lease.Close()
				t.Fatal("accepted an unsafe state file")
			}
		})
	}
}

func TestEngineUpgradeRejectsNonprivateDirectory(t *testing.T) {
	root := privateUpgradeTestDirectory(t)
	if err := os.Chmod(root, 0755); err != nil {
		t.Fatal(err)
	}
	if lease, err := prepareEngineStateUpgrade(root); err == nil {
		_ = lease.Close()
		t.Fatal("accepted a nonprivate profile directory")
	}
}
