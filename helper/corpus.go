package main

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

const (
	maxFileSize  = 2 << 20 // 跳过超过 2MB 的文件
	maxChunkRune = 200     // 每段最多字数
	embedBatch   = 32
)

var textExts = map[string]bool{".md": true, ".markdown": true, ".txt": true}

// 依赖、构建产物等目录里是第三方或生成的内容，不是项目自己的叫法
var skipDirs = map[string]bool{
	"node_modules": true, "vendor": true, "dist": true, "build": true, "out": true,
	"target": true, "__pycache__": true, "venv": true, "Pods": true, "DerivedData": true,
}

// skipDir 判断遍历资料文件夹时是否跳过这个子目录：隐藏目录和依赖、构建产物目录。
func skipDir(path, root, name string) bool {
	return path != root && (strings.HasPrefix(name, ".") || skipDirs[name])
}

// indexFolder 增量索引一个资料文件夹：只为新增或改动过的文件求向量，
// 已删除的文件从索引中移除。
func indexFolder(ctx context.Context, o *Ollama, store *Store, root string) (changed int, err error) {
	old := map[string][]Entry{}
	for _, e := range store.entries {
		old[e.File] = append(old[e.File], e)
	}

	var keep []Entry
	var pending []Entry
	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // 读不了的子目录跳过
		}
		name := d.Name()
		if d.IsDir() {
			if skipDir(path, root, name) {
				return filepath.SkipDir
			}
			return nil
		}
		if !textExts[strings.ToLower(filepath.Ext(name))] {
			return nil
		}
		info, err := d.Info()
		if err != nil || info.Size() > maxFileSize {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		mtime := info.ModTime().Unix()
		if prev := old[rel]; len(prev) > 0 && prev[0].MTime == mtime {
			keep = append(keep, prev...)
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil || !utf8.Valid(data) {
			return nil
		}
		changed++
		for _, chunk := range chunkText(string(data)) {
			pending = append(pending, Entry{File: rel, MTime: mtime, Text: chunk})
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	removed := len(old) > 0 && countFiles(keep) != len(old)
	if changed == 0 && !removed {
		return 0, nil
	}
	for i := 0; i < len(pending); i += embedBatch {
		end := min(i+embedBatch, len(pending))
		texts := make([]string, end-i)
		for j := range texts {
			texts[j] = pending[i+j].Text
		}
		vecs, err := o.Embed(ctx, texts)
		if err != nil {
			return 0, err
		}
		for j, v := range vecs {
			pending[i+j].Vec = v
		}
	}
	return changed, store.Replace(append(keep, pending...))
}

func countFiles(es []Entry) int {
	seen := map[string]bool{}
	for _, e := range es {
		seen[e.File] = true
	}
	return len(seen)
}

// chunkText 按段落切分，过长的段落再按句末标点切成不超过 maxChunkRune 的片段。
func chunkText(text string) []string {
	var chunks []string
	for _, para := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n\n") {
		para = strings.Join(strings.Fields(para), " ")
		if para == "" {
			continue
		}
		var cur []rune
		for _, r := range para {
			cur = append(cur, r)
			if len(cur) >= maxChunkRune || (len(cur) > maxChunkRune/2 && strings.ContainsRune("。！？!?；;", r)) {
				chunks = append(chunks, string(cur))
				cur = cur[:0]
			}
		}
		if len(cur) > 0 {
			chunks = append(chunks, string(cur))
		}
	}
	return chunks
}
