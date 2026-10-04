package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"strings"

	"github.com/gotd/td/session"
)

func decodeKey(value string) ([]byte, error) {
	key, err := hex.DecodeString(strings.TrimSpace(value))
	if err != nil || len(key) != 32 {
		return nil, errors.New("TELEGRAM_SESSION_KEY must be 64 hex characters")
	}
	return key, nil
}

// encryptedStorage stores the MTProto session as AES-GCM ciphertext.
// The key stays in the instance credentials; this file is not readable without it.
type encryptedStorage struct {
	path string
	key  []byte
}

func (s *encryptedStorage) LoadSession(context.Context) ([]byte, error) {
	raw, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, session.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return decrypt(s.key, raw)
}

func (s *encryptedStorage) StoreSession(_ context.Context, data []byte) error {
	raw, err := encrypt(s.key, data)
	if err != nil {
		return err
	}
	return os.WriteFile(s.path, raw, 0o600)
}

func encrypt(key, plain []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return gcm.Seal(nonce, nonce, plain, nil), nil
}

func decrypt(key, raw []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if len(raw) < gcm.NonceSize() {
		return nil, errors.New("session ciphertext is too short")
	}
	nonce, body := raw[:gcm.NonceSize()], raw[gcm.NonceSize():]
	return gcm.Open(nil, nonce, body, nil)
}
