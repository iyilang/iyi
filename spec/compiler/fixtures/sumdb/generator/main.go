// Generate ../golden.json with golang.org/x/mod's signed-note and tlog
// implementation. The fixed key is only for this public test fixture.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	"golang.org/x/mod/sumdb/note"
	"golang.org/x/mod/sumdb/tlog"
)

type memory []tlog.Hash

func (m memory) ReadHashes(indexes []int64) ([]tlog.Hash, error) {
	out := make([]tlog.Hash, len(indexes))
	for i, index := range indexes {
		if index < 0 || index >= int64(len(m)) {
			return nil, fmt.Errorf("missing hash %d", index)
		}
		out[i] = m[index]
	}
	return out, nil
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
func record(i int) string {
	one := sha256.Sum256([]byte(fmt.Sprintf("tree-%d", i)))
	two := sha256.Sum256([]byte(fmt.Sprintf("manifest-%d", i)))
	p := fmt.Sprintf("example.test/pack%04d", i)
	return fmt.Sprintf("%s v1.2.3 h2:%s\n%s v1.2.3/iyi.mod h2:%s\n", p, hex.EncodeToString(one[:]), p, hex.EncodeToString(two[:]))
}
func main() {
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = byte(i)
	}
	skey, vkey, err := note.GenerateKey(bytes.NewReader(seed), "sum.iyi.dev")
	must(err)
	signer, err := note.NewSigner(skey)
	must(err)
	var hashes memory
	sizes := []int64{1, 2, 3, 5, 17, 255, 256, 257, 300, 513, 256003}
	roots := map[int64]tlog.Hash{}
	checkpoints := map[int64]string{}
	records := map[int64]string{}
	recordProofs := map[int64]map[int64]tlog.RecordProof{}
	treeProofs := map[int64]map[int64]tlog.TreeProof{}
	tileSets := map[int64]map[string][]byte{}
	for i := range 256003 {
		more, err := tlog.StoredHashes(int64(i), []byte(record(i)), hashes)
		must(err)
		hashes = append(hashes, more...)
		n := int64(i + 1)
		selected := false
		for _, s := range sizes {
			if s == n {
				selected = true
				break
			}
		}
		if !selected {
			continue
		}
		root, err := tlog.TreeHash(n, hashes)
		must(err)
		roots[n] = root
		text := fmt.Sprintf("sum.iyi.dev\n%d\n%s\n", n, root.String())
		signed, err := note.Sign(&note.Note{Text: text}, signer)
		must(err)
		checkpoints[n] = string(signed)
		rp := map[int64]tlog.RecordProof{}
		for _, at := range []int64{0, n / 2, n - 1} {
			records[at] = record(int(at))
			p, err := tlog.ProveRecord(n, at, hashes)
			must(err)
			must(tlog.CheckRecord(p, n, root, at, tlog.RecordHash([]byte(record(int(at))))))
			rp[at] = p
		}
		recordProofs[n] = rp
		tp := map[int64]tlog.TreeProof{}
		for _, old := range sizes {
			if old > n {
				break
			}
			p, err := tlog.ProveTree(n, old, hashes)
			must(err)
			must(tlog.CheckTree(p, n, root, old, roots[old]))
			tp[old] = p
		}
		treeProofs[n] = tp
		tiles := map[string][]byte{}
		for _, tile := range tlog.NewTiles(8, 0, n) {
			if n == 256003 && tile.L == 0 && tile.N != 1000 {
				continue
			}
			data, err := tlog.ReadTileData(tile, hashes)
			must(err)
			tiles[tile.Path()] = data
		}
		tileSets[n] = tiles
	}
	const target = 260
	records[target] = record(target)
	framed, err := tlog.FormatRecord(target, []byte(record(target)))
	must(err)
	forkRoot := tlog.RecordHash([]byte("fork"))
	forkText := fmt.Sprintf("sum.iyi.dev\n513\n%s\n", forkRoot.String())
	fork, err := note.Sign(&note.Note{Text: forkText}, signer)
	must(err)
	foreignText := fmt.Sprintf("other.example\n513\n%s\n", roots[513].String())
	foreign, err := note.Sign(&note.Note{Text: foreignText}, signer)
	must(err)
	oldFramed, err := tlog.FormatRecord(256, []byte(record(256)))
	must(err)
	oldForkText := fmt.Sprintf("sum.iyi.dev\n257\n%s\n", forkRoot.String())
	oldFork, err := note.Sign(&note.Note{Text: oldForkText}, signer)
	must(err)
	output := map[string]any{
		"go_module": "golang.org/x/mod v0.29.0", "verifier": vkey,
		"records": records,
		"roots":   roots, "checkpoints": checkpoints, "record_proofs": recordProofs,
		"tree_proofs": treeProofs, "tiles": tileSets,
		"lookup":         string(framed) + checkpoints[513],
		"fork":           string(fork),
		"foreign_origin": string(foreign),
		"old_lookup":     string(oldFramed) + checkpoints[257],
		"old_fork":       string(oldFork),
	}
	data, err := json.MarshalIndent(output, "", "  ")
	must(err)
	data = append(data, '\n')
	must(os.WriteFile("../golden.json", data, 0644))
}
