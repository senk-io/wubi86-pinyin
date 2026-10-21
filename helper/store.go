package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"math"
	"os"
	"sort"
)

// Entry 是索引中的一段文字及其向量。File/MTime 只对文件夹资料有意义，
// 用于判断文件改动后需要重新索引。
type Entry struct {
	File  string    `json:"file,omitempty"`
	MTime int64     `json:"mtime,omitempty"`
	Text  string    `json:"text"`
	Vec   []float32 `json:"vec"`
}

// Store 是一个以 JSONL 持久化的小型向量库，检索用暴力余弦相似度。
// 个人数据量（几千到几万段）下足够快，也免去额外依赖。
type Store struct {
	path    string
	entries []Entry
}

func openStore(path string) (*Store, error) {
	s := &Store{path: path}
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	for sc.Scan() {
		var e Entry
		if json.Unmarshal(sc.Bytes(), &e) == nil && len(e.Vec) > 0 {
			s.entries = append(s.entries, e)
		}
	}
	return s, sc.Err()
}

// Append 追加条目并写入文件末尾。
func (s *Store) Append(es ...Entry) error {
	f, err := os.OpenFile(s.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	for _, e := range es {
		normalize(e.Vec)
		line, err := json.Marshal(e)
		if err != nil {
			return err
		}
		w.Write(line)
		w.WriteByte('\n')
		s.entries = append(s.entries, e)
	}
	return w.Flush()
}

// Replace 用新条目整体替换并重写文件。
func (s *Store) Replace(es []Entry) error {
	for _, e := range es {
		normalize(e.Vec)
	}
	tmp := s.path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(f)
	for _, e := range es {
		line, err := json.Marshal(e)
		if err != nil {
			f.Close()
			return err
		}
		w.Write(line)
		w.WriteByte('\n')
	}
	if err := w.Flush(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	s.entries = es
	return os.Rename(tmp, s.path)
}

func (s *Store) Len() int { return len(s.entries) }

type hit struct {
	Text  string
	Score float32
}

// Search 返回与 query 最相近的 k 条（query 需已归一化）。
func (s *Store) Search(query []float32, k int) []hit {
	hits := make([]hit, 0, len(s.entries))
	for _, e := range s.entries {
		if len(e.Vec) != len(query) {
			continue
		}
		hits = append(hits, hit{e.Text, dot(e.Vec, query)})
	}
	sort.Slice(hits, func(i, j int) bool { return hits[i].Score > hits[j].Score })
	if len(hits) > k {
		hits = hits[:k]
	}
	return hits
}

func dot(a, b []float32) float32 {
	var sum float32
	for i := range a {
		sum += a[i] * b[i]
	}
	return sum
}

func normalize(v []float32) {
	var sum float64
	for _, x := range v {
		sum += float64(x) * float64(x)
	}
	if sum == 0 {
		return
	}
	n := float32(1 / math.Sqrt(sum))
	for i := range v {
		v[i] *= n
	}
}
