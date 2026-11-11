// The Go twin of bench/web_cores.iyi: the same three endpoints, the same
// stored hash and the same answers, byte for byte, which bench/web_cores.py
// checks over the wire before it times either server. What a Go port of
// the issue's app would write: net/http, encoding/json and
// golang.org/x/crypto/bcrypt.
//
//	go build -o web-go ./bench/web_cores
//	./web-go PORTFILE [tls]
//
// GOMAXPROCS is Go's default, every core the machine has.
package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"math"
	"net"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"

	"golang.org/x/crypto/bcrypt"
)

const stored = "$2b$10$kUj/jTAf4epbl60uJp1DrO1.9/rLc0aH1R6bGrunr.zUgxVg9tb5S"
const user = "ada@example.com"

// bench/std_http_parallel.iyi's test PKI: an Ed25519 leaf for localhost.
const leafPEM = "-----BEGIN CERTIFICATE-----\n" +
	"MIIBQzCB9qADAgECAgEDMAUGAytlcDAZMRcwFQYDVQQDDA5peWkgYmVuY2ggcm9v\n" +
	"dDAgFw0yNTAxMDEwMDAwMDBaGA85OTk5MTIzMTIzNTk1OVowFDESMBAGA1UEAwwJ\n" +
	"bG9jYWxob3N0MCowBQYDK2VwAyEAOeskudtTVi76JObK6QHqJy6M7PaEu/aLlC5H\n" +
	"B5OLks+jZjBkMBQGA1UdEQQNMAuCCWxvY2FsaG9zdDAMBgNVHRMBAf8EAjAAMB0G\n" +
	"A1UdDgQWBBQN8ZJay/U7zf07disj78hKukvGAjAfBgNVHSMEGDAWgBSNjkTWVhBs\n" +
	"a874Ao2cPFX4w4saajAFBgMrZXADQQAcAgj9qe58GnzceRkYfxyfNHxmqWOgDJkn\n" +
	"b3rO1pz+8OCRioO1P+BhFa1FR/FMHSH9bOFEKfXfy3Nwr+y+GkMM\n" +
	"-----END CERTIFICATE-----\n"
const keyPEM = "-----BEGIN PRIVATE KEY-----\n" +
	"MC4CAQAwBQYDK2VwBCIEIOYKs3OzEJYJ/j+ZQYLoAU929MQeanF9kupAR9HpeHJ8\n" +
	"-----END PRIVATE KEY-----\n"

type login struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type loginAnswer struct {
	OK   bool   `json:"ok"`
	User string `json:"user"`
}

type versionAnswer struct {
	Platform string `json:"platform"`
	Latest   string `json:"latest"`
	Minimum  string `json:"minimum"`
	Update   bool   `json:"update"`
	Forced   bool   `json:"forced"`
}

type item struct {
	ID    int64   `json:"id"`
	Price float64 `json:"price"`
	Qty   int64   `json:"qty"`
}

type order struct {
	Items []item `json:"items"`
}

type orderAnswer struct {
	Lines      int     `json:"lines"`
	Count      int64   `json:"count"`
	TotalCents int64   `json:"total_cents"`
	Largest    []int64 `json:"largest"`
}

// versionNumber is bench/web_cores.iyi's version_number.
func versionNumber(text string) int64 {
	parts := strings.Split(text, ".")
	var number int64
	for i := range 3 {
		part := 0
		if i < len(parts) {
			if n, err := strconv.Atoi(parts[i]); err == nil {
				part = n
			}
		}
		number = number*1000 + int64(part)
	}
	return number
}

func answer(w http.ResponseWriter, status int, value any) {
	body, err := json.Marshal(value)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	w.Write(body)
}

func handleLogin(w http.ResponseWriter, r *http.Request) {
	var asked login
	if err := json.NewDecoder(r.Body).Decode(&asked); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	ok := asked.Email == user && bcrypt.CompareHashAndPassword([]byte(stored), []byte(asked.Password)) == nil
	status := 200
	name := ""
	if ok {
		name = asked.Email
	} else {
		status = 401
	}
	answer(w, status, loginAnswer{OK: ok, User: name})
}

func handleCheckVersion(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	platform := query.Get("platform")
	latest := "2.4.0"
	if platform == "ios" {
		latest = "2.4.1"
	}
	minimum := "2.0.0"
	version := query.Get("version")
	if version == "" {
		version = "0"
	}
	have := versionNumber(version)
	answer(w, 200, versionAnswer{
		Platform: platform,
		Latest:   latest,
		Minimum:  minimum,
		Update:   have < versionNumber(latest),
		Forced:   have < versionNumber(minimum),
	})
}

func handleOrder(w http.ResponseWriter, r *http.Request) {
	var asked order
	if err := json.NewDecoder(r.Body).Decode(&asked); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	total := 0.0
	var count int64
	for _, it := range asked.Items {
		total += it.Price * float64(it.Qty)
		count += it.Qty
	}
	largest := append([]item(nil), asked.Items...)
	sort.SliceStable(largest, func(a, b int) bool {
		return largest[a].Price*float64(largest[a].Qty) > largest[b].Price*float64(largest[b].Qty)
	})
	ids := []int64{}
	for i := range min(3, len(largest)) {
		ids = append(ids, largest[i].ID)
	}
	answer(w, 200, orderAnswer{
		Lines:      len(asked.Items),
		Count:      count,
		TotalCents: int64(math.Round(total * 100)),
		Largest:    ids,
	})
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: web-go PORTFILE [tls]")
		os.Exit(2)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/login", handleLogin)
	mux.HandleFunc("/check_version", handleCheckVersion)
	mux.HandleFunc("/order", handleOrder)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := os.WriteFile(os.Args[1], []byte(fmt.Sprintf("%d\n", port)), 0o644); err != nil {
		panic(err)
	}
	server := &http.Server{Handler: mux}
	if len(os.Args) > 2 && os.Args[2] == "tls" {
		pair, err := tls.X509KeyPair([]byte(leafPEM), []byte(keyPEM))
		if err != nil {
			panic(err)
		}
		// HTTP/1.1 alone, as the iyi server is offered: wrk speaks nothing else.
		server.TLSConfig = &tls.Config{Certificates: []tls.Certificate{pair}, NextProtos: []string{"http/1.1"}}
		panic(server.Serve(tls.NewListener(listener, server.TLSConfig)))
	}
	panic(server.Serve(listener))
}
