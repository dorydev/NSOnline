// Package seal encrypts the embedded configuration with AES-256-GCM. This is
// OBFUSCATION, not security: the key ships in the same binary, split into
// XOR-masked shares. Treat every embedded value as extractable.
package seal

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
)

const KeySize = 32

var aad = []byte("nsonline/secrets/v1")

// Seal returns nonce || ciphertext.
func Seal(values map[string]string, key []byte) ([]byte, error) {
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	plain, err := json.Marshal(values)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return gcm.Seal(nonce, nonce, plain, aad), nil
}

func Open(sealed, key []byte) (map[string]string, error) {
	if len(sealed) == 0 {
		return map[string]string{}, nil
	}
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	if len(sealed) < gcm.NonceSize()+gcm.Overhead() {
		return nil, errors.New("seal: ciphertext too short")
	}
	ns := gcm.NonceSize()
	plain, err := gcm.Open(nil, sealed[:ns], sealed[ns:], aad)
	if err != nil {
		return nil, fmt.Errorf("seal: %w", err)
	}
	out := map[string]string{}
	if err := json.Unmarshal(plain, &out); err != nil {
		return nil, fmt.Errorf("seal: decode: %w", err)
	}
	return out, nil
}

func newGCM(key []byte) (cipher.AEAD, error) {
	if len(key) != KeySize {
		return nil, fmt.Errorf("seal: key must be %d bytes, got %d", KeySize, len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func NewKey() ([]byte, error) {
	k := make([]byte, KeySize)
	_, err := rand.Read(k)
	return k, err
}

// Split masks key into n shares whose XOR is the key, so it never appears in one piece.
func Split(key []byte, n int) ([][]byte, error) {
	if n < 2 {
		return nil, errors.New("seal: need at least 2 shares")
	}
	shares := make([][]byte, n)
	last := append([]byte(nil), key...)
	for i := 0; i < n-1; i++ {
		s := make([]byte, len(key))
		if _, err := rand.Read(s); err != nil {
			return nil, err
		}
		for j := range last {
			last[j] ^= s[j]
		}
		shares[i] = s
	}
	shares[n-1] = last
	return shares, nil
}

func Join(shares [][]byte) []byte {
	if len(shares) == 0 {
		return nil
	}
	key := make([]byte, len(shares[0]))
	for _, s := range shares {
		if len(s) != len(key) {
			return nil
		}
		for j := range s {
			key[j] ^= s[j]
		}
	}
	return key
}
