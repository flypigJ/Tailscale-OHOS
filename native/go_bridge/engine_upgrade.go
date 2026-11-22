package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"golang.org/x/sys/unix"
)

const engineUpgradeMarker = ".mesharc-engine-upgrade-1.104.5.json"
const engineStateSizeLimit = 64 << 20

type engineStateBackup struct {
	SchemaVersion int    `json:"schemaVersion"`
	FromVersion   string `json:"fromVersion"`
	ToVersion     string `json:"toVersion"`
	BackupName    string `json:"backupName"`
	HasState      bool   `json:"hasState"`
	StateSHA256   string `json:"stateSha256"`
}

type engineStateLease struct {
	file *os.File
	once sync.Once
}

func (lease *engineStateLease) Close() error {
	var closeErr error
	lease.once.Do(func() {
		closeErr = lease.file.Close()
	})
	return closeErr
}

func acquireEngineStateLease(profileRoot string) (*engineStateLease, error) {
	if !filepath.IsAbs(profileRoot) {
		return nil, errors.New("engine state directory must be absolute")
	}
	if err := os.MkdirAll(profileRoot, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(profileRoot)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("engine state directory is not a private directory")
	}
	descriptor, err := unix.Open(filepath.Join(profileRoot, ".mesharc-engine.lock"),
		unix.O_CREAT|unix.O_RDWR|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(descriptor), "engine-state-lease")
	if err := unix.Flock(descriptor, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = file.Close()
		return nil, errors.New("engine state already in use")
	}
	return &engineStateLease{file: file}, nil
}

func readEngineStateFile(path string) ([]byte, error) {
	descriptor, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(descriptor), "engine-state-read")
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > engineStateSizeLimit {
		return nil, errors.New("invalid engine state file")
	}
	data, err := io.ReadAll(io.LimitReader(file, engineStateSizeLimit+1))
	if err != nil {
		return nil, err
	}
	if len(data) > engineStateSizeLimit {
		return nil, errors.New("engine state file exceeded size limit")
	}
	return data, nil
}

func syncEngineStateDirectory(path string) error {
	descriptor, err := unix.Open(path, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(descriptor), "engine-state-directory")
	defer file.Close()
	return file.Sync()
}

func engineStateDigest(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

func writeEngineStateFile(path string, data []byte) error {
	return writeEngineStateFileWithSync(path, data, syncEngineStateDirectory)
}

func writeEngineStateFileWithSync(path string, data []byte, syncDirectory func(string) error) error {
	if len(data) > engineStateSizeLimit {
		return errors.New("engine state write exceeded size limit")
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".engine-state-write-")
	if err != nil {
		return err
	}
	name := file.Name()
	defer os.Remove(name)
	if err := file.Chmod(0600); err != nil {
		_ = file.Close()
		return err
	}
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, path); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(path))
}

func loadEngineStateBackup(profileRoot string) (engineStateBackup, []byte, error) {
	var backup engineStateBackup
	encoded, err := readEngineStateFile(filepath.Join(profileRoot, engineUpgradeMarker))
	if err != nil {
		return backup, nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&backup); err != nil {
		return backup, nil, errors.New("invalid engine backup metadata")
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return backup, nil, errors.New("invalid engine backup metadata suffix")
	}
	if backup.SchemaVersion != 1 || backup.FromVersion != "1.86.5" || backup.ToVersion != "1.104.5" ||
		filepath.Base(backup.BackupName) != backup.BackupName || !strings.HasPrefix(backup.BackupName, ".mesharc-engine-backup-") {
		return backup, nil, errors.New("engine backup does not match the fixed upgrade")
	}
	backupRoot := filepath.Join(profileRoot, backup.BackupName)
	info, err := os.Lstat(backupRoot)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return backup, nil, errors.New("invalid engine backup directory")
	}
	if !backup.HasState {
		if backup.StateSHA256 != "" {
			return backup, nil, errors.New("unexpected engine backup digest")
		}
		return backup, nil, nil
	}
	data, err := readEngineStateFile(filepath.Join(backupRoot, "tailscaled.state"))
	if err != nil || engineStateDigest(data) != backup.StateSHA256 {
		return backup, nil, errors.New("engine backup digest mismatch")
	}
	return backup, data, nil
}

func prepareEngineStateUpgrade(profileRoot string) (*engineStateLease, error) {
	return prepareEngineStateUpgradeWithSync(profileRoot, syncEngineStateDirectory)
}

func prepareEngineStateUpgradeWithSync(profileRoot string, syncDirectory func(string) error) (*engineStateLease, error) {
	lease, err := acquireEngineStateLease(profileRoot)
	if err != nil {
		return nil, err
	}
	valid := false
	defer func() {
		if !valid {
			_ = lease.Close()
		}
	}()
	if backup, _, err := loadEngineStateBackup(profileRoot); err == nil {
		if err := syncDirectory(filepath.Join(profileRoot, backup.BackupName)); err != nil {
			return nil, err
		}
		if err := syncDirectory(profileRoot); err != nil {
			return nil, err
		}
		valid = true
		return lease, nil
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	state, err := readEngineStateFile(filepath.Join(profileRoot, "tailscaled.state"))
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	hasState := err == nil
	backupRoot, err := os.MkdirTemp(profileRoot, ".mesharc-engine-backup-")
	if err != nil {
		return nil, err
	}
	backup := engineStateBackup{SchemaVersion: 1, FromVersion: "1.86.5", ToVersion: "1.104.5", BackupName: filepath.Base(backupRoot), HasState: hasState}
	if hasState {
		backup.StateSHA256 = engineStateDigest(state)
		if err := writeEngineStateFileWithSync(filepath.Join(backupRoot, "tailscaled.state"), state, syncDirectory); err != nil {
			return nil, err
		}
	}
	if err := syncDirectory(backupRoot); err != nil {
		return nil, err
	}
	if err := syncDirectory(profileRoot); err != nil {
		return nil, err
	}
	encoded, err := json.Marshal(backup)
	if err != nil {
		return nil, err
	}
	if err := writeEngineStateFileWithSync(filepath.Join(profileRoot, engineUpgradeMarker), encoded, syncDirectory); err != nil {
		return nil, err
	}
	valid = true
	return lease, nil
}

func restoreEngineStateUpgrade(profileRoot string) error {
	return restoreEngineStateUpgradeWithSync(profileRoot, syncEngineStateDirectory)
}

func restoreEngineStateUpgradeWithSync(profileRoot string, syncDirectory func(string) error) error {
	lease, err := acquireEngineStateLease(profileRoot)
	if err != nil {
		return err
	}
	defer lease.Close()
	backup, data, err := loadEngineStateBackup(profileRoot)
	if err != nil {
		return err
	}
	statePath := filepath.Join(profileRoot, "tailscaled.state")
	if _, err := readEngineStateFile(statePath); err != nil && !os.IsNotExist(err) {
		return err
	}
	if backup.HasState {
		if err := writeEngineStateFileWithSync(statePath, data, syncDirectory); err != nil {
			return err
		}
	} else if err := os.Remove(statePath); err != nil && !os.IsNotExist(err) {
		return err
	}
	if err := syncDirectory(profileRoot); err != nil {
		return err
	}
	markerPath := filepath.Join(profileRoot, engineUpgradeMarker)
	if err := os.Remove(markerPath); err != nil {
		return err
	}
	if err := syncDirectory(profileRoot); err != nil {
		encoded, encodeErr := json.Marshal(backup)
		if encodeErr != nil {
			return errors.Join(err, encodeErr)
		}
		return errors.Join(err, writeEngineStateFile(markerPath, encoded))
	}
	return nil
}
