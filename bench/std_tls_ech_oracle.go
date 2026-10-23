// Go's crypto/tls as the other end of std/tls's Encrypted Client Hello
// (RFC 9849), for bench/std_tls_exercise.sh: Go's ECH client
// (Config.EncryptedClientHelloConfigList, Go 1.23 and later) and server
// (Config.EncryptedClientHelloKeys, Go 1.24 and later), from its standard
// library alone.
//
//	go run bench/std_tls_ech_oracle.go server DIR COUNT
//	go run bench/std_tls_ech_oracle.go client PORT DIR
//
// server: a TLS 1.3 server on 127.0.0.1 for inner.test and public.test,
// certificates from a root of its own (DIR/root.pem), and an ECH key whose
// ECHConfig it writes itself, as RFC 9849 section 4 lays one out - X25519,
// HKDF-SHA256 with AES-128-GCM and with ChaCha20-Poly1305, public_name
// public.test: DIR/ech_configs is its ECHConfigList, DIR/stale_configs one
// of a key it does not hold, DIR/port its port, written last. It takes
// secp256r1 alone, so a client whose first shares are X25519's is asked
// again (HelloRetryRequest). COUNT connections, a line each: "held ech=
// name= group= alpn= hellos= read=" - hellos the ClientHellos it read - the
// bytes read echoed back as "echo:...", or "refused: " and why.
//
// client: to 127.0.0.1:PORT for inner.test, the server's root
// DIR/root.pem, Go's groups as they come - its shares X25519MLKEM768's and
// X25519's, secp256r1 listed without one, so a server that takes secp256r1
// alone asks again (Go 1.24 on sends shares in the groups it prefers, the
// order of CurvePreferences aside); under DIR/ech_configs, then
// DIR/stale_configs, then the retry configurations that refusal carried.
// A line each, hellos the ClientHellos it wrote.
package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: server DIR COUNT | client PORT DIR")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "server":
		count, err := strconv.Atoi(os.Args[3])
		must(err)
		server(os.Args[2], count)
	case "client":
		client(os.Args[2], os.Args[3])
	default:
		fmt.Fprintln(os.Stderr, "usage: server DIR COUNT | client PORT DIR")
		os.Exit(2)
	}
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func be16(b []byte, v int) []byte { return append(b, byte(v>>8), byte(v)) }

// echConfig is RFC 9849 section 4's ECHConfig, written here byte by byte:
// version 0xfe0d, its length, then config_id, the X25519 KEM (0x0020) and
// its public key, two suites, maximum_name_length 0, the public_name and no
// extensions.
func echConfig(id byte, publicName string) (*ecdh.PrivateKey, []byte) {
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	must(err)
	pub := key.PublicKey().Bytes()
	c := []byte{id}
	c = be16(c, 0x0020)
	c = be16(c, len(pub))
	c = append(c, pub...)
	c = be16(c, 8)
	c = be16(be16(c, 0x0001), 0x0001)
	c = be16(be16(c, 0x0001), 0x0003)
	c = append(c, 0, byte(len(publicName)))
	c = append(c, publicName...)
	c = be16(c, 0)
	return key, append(be16(be16(nil, 0xfe0d), len(c)), c...)
}

func list(configs ...[]byte) []byte {
	var body []byte
	for _, c := range configs {
		body = append(body, c...)
	}
	return append(be16(nil, len(body)), body...)
}

// counter counts the ClientHellos that pass through a connection, in the
// records written (a client's) or read (a server's): each a handshake
// record whose first byte is ClientHello's type. Before the keys change a
// ClientHello is a record of its own here, so a record is a message.
type counter struct {
	net.Conn
	mu      sync.Mutex
	writes  bool
	pending []byte
	hellos  int
}

func (c *counter) note(b []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.pending = append(c.pending, b...)
	for len(c.pending) >= 5 {
		size := int(c.pending[3])<<8 | int(c.pending[4])
		if len(c.pending) < 5+size {
			return
		}
		if c.pending[0] == 22 && size > 0 && c.pending[5] == 1 {
			c.hellos++
		}
		c.pending = c.pending[5+size:]
	}
}

func (c *counter) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	if !c.writes && n > 0 {
		c.note(b[:n])
	}
	return n, err
}

func (c *counter) Write(b []byte) (int, error) {
	if c.writes {
		c.note(b)
	}
	return c.Conn.Write(b)
}

func (c *counter) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.hellos
}

func certificate(name string, root *x509.Certificate, rootKey *ecdsa.PrivateKey, serial int64) tls.Certificate {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	must(err)
	template := &x509.Certificate{
		SerialNumber: big.NewInt(serial),
		Subject:      pkix.Name{CommonName: name},
		DNSNames:     []string{name},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, root, &key.PublicKey, rootKey)
	must(err)
	return tls.Certificate{Certificate: [][]byte{der, root.Raw}, PrivateKey: key}
}

func server(dir string, count int) {
	rootKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	must(err)
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Go ECH oracle root"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &rootKey.PublicKey, rootKey)
	must(err)
	root, err := x509.ParseCertificate(der)
	must(err)
	must(os.WriteFile(filepath.Join(dir, "root.pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644))
	key, config := echConfig(0x42, "public.test")
	_, stale := echConfig(0x42, "public.test")
	must(os.WriteFile(filepath.Join(dir, "ech_configs"), list(config), 0o644))
	must(os.WriteFile(filepath.Join(dir, "stale_configs"), list(stale), 0o644))
	cfg := &tls.Config{
		Certificates:     []tls.Certificate{certificate("inner.test", root, rootKey, 2), certificate("public.test", root, rootKey, 3)},
		MinVersion:       tls.VersionTLS13,
		CurvePreferences: []tls.CurveID{tls.CurveP256},
		NextProtos:       []string{"h2", "http/1.1"},
		EncryptedClientHelloKeys: []tls.EncryptedClientHelloKey{
			{Config: config, PrivateKey: key.Bytes(), SendAsRetry: true},
		},
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	must(err)
	port := listener.Addr().(*net.TCPAddr).Port
	must(os.WriteFile(filepath.Join(dir, "port"), []byte(strconv.Itoa(port)), 0o644))
	for range count {
		raw, err := listener.Accept()
		must(err)
		counted := &counter{Conn: raw}
		conn := tls.Server(counted, cfg)
		must(conn.SetDeadline(time.Now().Add(10 * time.Second)))
		if err := conn.Handshake(); err != nil {
			fmt.Printf("refused: %v\n", err)
			conn.Close()
			continue
		}
		state := conn.ConnectionState()
		buf := make([]byte, 256)
		n, err := conn.Read(buf)
		read := string(buf[:n])
		if err != nil && err != io.EOF {
			read = err.Error()
		}
		conn.Write([]byte("echo:" + string(buf[:n])))
		fmt.Printf("held ech=%v name=%s group=%v alpn=%s hellos=%d read=%s\n", state.ECHAccepted, state.ServerName, state.CurveID, state.NegotiatedProtocol, counted.count(), read)
		conn.Close()
	}
}

// connect is one connection under *configs*, "hello" written and the
// answer read: its line, and the retry configurations a refusal carried.
func connect(port string, roots *x509.CertPool, configs []byte) (string, []byte) {
	raw, err := net.Dial("tcp", "127.0.0.1:"+port)
	if err != nil {
		return "no connection: " + err.Error(), nil
	}
	counted := &counter{Conn: raw, writes: true}
	conn := tls.Client(counted, &tls.Config{
		ServerName:                     "inner.test",
		RootCAs:                        roots,
		MinVersion:                     tls.VersionTLS13,
		NextProtos:                     []string{"h2"},
		EncryptedClientHelloConfigList: configs,
	})
	defer conn.Close()
	must(conn.SetDeadline(time.Now().Add(10 * time.Second)))
	if err := conn.Handshake(); err != nil {
		var rejection *tls.ECHRejectionError
		if errors.As(err, &rejection) {
			return fmt.Sprintf("refused: ECH rejected, hellos=%d", counted.count()), rejection.RetryConfigList
		}
		return "refused: " + err.Error(), nil
	}
	state := conn.ConnectionState()
	conn.Write([]byte("hello"))
	got, err := io.ReadAll(conn)
	if err != nil {
		got = append(got, []byte(" ["+err.Error()+"]")...)
	}
	return fmt.Sprintf("ech=%v group=%v alpn=%s hellos=%d got=%s", state.ECHAccepted, state.CurveID, state.NegotiatedProtocol, counted.count(), got), nil
}

func client(port, dir string) {
	pemBytes, err := os.ReadFile(filepath.Join(dir, "root.pem"))
	must(err)
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pemBytes) {
		must(errors.New("no certificate in " + filepath.Join(dir, "root.pem")))
	}
	current, err := os.ReadFile(filepath.Join(dir, "ech_configs"))
	must(err)
	stale, err := os.ReadFile(filepath.Join(dir, "stale_configs"))
	must(err)
	said, _ := connect(port, roots, current)
	fmt.Println("current: " + said)
	said, retry := connect(port, roots, stale)
	whose := "none"
	if retry != nil {
		whose = "another list"
		if bytes.Equal(retry, current) {
			whose = "the server's own"
		}
	}
	fmt.Printf("stale: %s; retry_configs %s\n", said, whose)
	if retry != nil {
		said, _ = connect(port, roots, retry)
		fmt.Println("retried: " + said)
	}
}
