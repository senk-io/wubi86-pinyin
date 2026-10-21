package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// 项目术语：从资料文件夹里抽出项目名、系统名、内部叫法、专业术语，
// 生成术语表供输入法按编码前缀匹配。抽取在后台进行，打字时只查表。

const (
	termWindowRunes = 800 // 每次交给模型的文本长度
	minTermRunes    = 2
	maxTermRunes    = 20
)

const termSystemPrompt = "你是术语抽取工具。从用户给出的文本中找出这个项目或领域特有的叫法：" +
	"项目名、产品名、系统名、模块名、内部代号、专业术语、固定说法。" +
	"不要常见的日常词语，不要人名以外的普通名词，不要整句。" +
	"输出一个 JSON 字符串数组，每个元素必须与原文写法完全一致。没有就输出空数组。"

// fileTerms 记录一个文件抽出的术语及其在该文件中的出现次数，用于增量更新。
type fileTerms struct {
	File  string         `json:"file"`
	MTime int64          `json:"mtime"`
	Terms map[string]int `json:"terms"`
}

// extractTerms 分窗口调用模型抽取术语，只保留原文中确实出现过的词，防止模型编造。
func extractTerms(ctx context.Context, o *Ollama, text string) (map[string]int, error) {
	counts := map[string]int{}
	for _, window := range windows(text, termWindowRunes) {
		out, err := o.Generate(ctx, termSystemPrompt, window, 256, stringList)
		if err != nil {
			return nil, err
		}
		for _, t := range parseTerms(out, window) {
			counts[t] = 0
		}
	}
	for t := range counts {
		counts[t] = strings.Count(text, t)
	}
	return counts, nil
}

func windows(text string, size int) []string {
	var out []string
	for _, para := range chunkText(text) {
		if n := len(out); n > 0 && utf8.RuneCountInString(out[n-1])+utf8.RuneCountInString(para) < size {
			out[n-1] += "\n" + para
		} else {
			out = append(out, para)
		}
	}
	return out
}

// parseTerms 清理模型输出：去编号、去两端标点，长度合适、含字母或汉字，且在原文中出现。
func parseTerms(out, source string) []string {
	var terms []string
	seen := map[string]bool{}
	for _, line := range strings.Split(unwrapList(out), "\n") {
		line = listMarker.ReplaceAllString(line, "")
		line = strings.TrimFunc(line, func(r rune) bool {
			return unicode.IsSpace(r) || unicode.IsPunct(r) && r != '-' && r != '_' || unicode.IsSymbol(r)
		})
		n := utf8.RuneCountInString(line)
		if n < minTermRunes || n > maxTermRunes || seen[line] || !hasWordRune(line) {
			continue
		}
		if !strings.Contains(source, line) {
			continue
		}
		seen[line] = true
		terms = append(terms, line)
	}
	return terms
}

func hasWordRune(s string) bool {
	for _, r := range s {
		if unicode.Is(unicode.Han, r) || unicode.IsLetter(r) {
			return true
		}
	}
	return false
}

// TermIndex 是一个文件夹的术语索引，按文件保存，文件改动时只重抽该文件。
type TermIndex struct {
	path  string
	files map[string]fileTerms
}

func openTermIndex(path string) (*TermIndex, error) {
	idx := &TermIndex{path: path, files: map[string]fileTerms{}}
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return idx, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	for sc.Scan() {
		var ft fileTerms
		if json.Unmarshal(sc.Bytes(), &ft) == nil && ft.File != "" {
			idx.files[ft.File] = ft
		}
	}
	return idx, sc.Err()
}

func (idx *TermIndex) save() error {
	var b strings.Builder
	keys := make([]string, 0, len(idx.files))
	for k := range idx.files {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		line, err := json.Marshal(idx.files[k])
		if err != nil {
			return err
		}
		b.Write(line)
		b.WriteByte('\n')
	}
	return writeAtomic(idx.path, []byte(b.String()))
}

// Totals 汇总全文件夹的术语出现次数。
func (idx *TermIndex) Totals() map[string]int {
	totals := map[string]int{}
	for _, ft := range idx.files {
		for t, n := range ft.Terms {
			totals[t] += n
		}
	}
	return totals
}

// update 增量更新：新增或改动的文件重新抽取，删除的文件移除。progress 每处理完一个文件调用一次。
func (idx *TermIndex) update(ctx context.Context, o *Ollama, root string, progress func(file string)) (changed int, err error) {
	present := map[string]bool{}
	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if path != root && strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if !textExts[strings.ToLower(filepath.Ext(d.Name()))] {
			return nil
		}
		info, err := d.Info()
		if err != nil || info.Size() > maxFileSize {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		present[rel] = true
		mtime := info.ModTime().Unix()
		if prev, ok := idx.files[rel]; ok && prev.MTime == mtime {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil || !utf8.Valid(data) {
			return nil
		}
		terms, err := extractTerms(ctx, o, string(data))
		if err != nil {
			return err
		}
		idx.files[rel] = fileTerms{File: rel, MTime: mtime, Terms: terms}
		changed++
		if progress != nil {
			progress(rel)
		}
		// 每个文件处理完就落盘，大文件夹中途中断也不会丢掉已完成的部分
		return idx.save()
	})
	if err != nil {
		return changed, err
	}
	for f := range idx.files {
		if !present[f] {
			delete(idx.files, f)
			changed++
		}
	}
	if changed > 0 {
		err = idx.save()
	}
	return changed, err
}

// writeTermList 写出供输入法读取的术语表：第 1 行版本号，之后每行「术语<TAB>次数」，按次数降序。
func writeTermList(path string, totals map[string]int) error {
	type kv struct {
		term  string
		count int
	}
	list := make([]kv, 0, len(totals))
	for t, n := range totals {
		if n > 0 {
			list = append(list, kv{t, n})
		}
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].count != list[j].count {
			return list[i].count > list[j].count
		}
		return list[i].term < list[j].term
	})
	var b strings.Builder
	fmt.Fprintf(&b, "v%d\n", time.Now().UnixNano())
	for _, e := range list {
		fmt.Fprintf(&b, "%s\t%d\n", e.term, e.count)
	}
	return writeAtomic(path, []byte(b.String()))
}
