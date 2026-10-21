package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// 与输入法（Lua）之间的文件约定，都在 <rime>/wubi86d/ 下：
//
//	context.txt  Lua 写：第 1 行序号，第 2 行刚上屏的文字，第 3 行最近的上文
//	suggest.txt  本进程写：第 1 行对应的序号，第 2 行当前资料文件夹名，之后每行一个联想词
//	profile.txt  当前使用的资料文件夹名（空表示只用输入历史）；Lua 快捷键或 `wubi86d use` 写
//	folders.txt  本进程写：可切换的文件夹名，每行一个，供 Lua 快捷键轮换
//	terms/<名称>.txt  本进程写：该文件夹的项目术语表，第 1 行版本号，之后「术语<TAB>次数」
//	index/       向量索引与术语索引
//
// 不监听任何端口；唯一的网络访问是本机的 Ollama。
const (
	pollInterval   = 40 * time.Millisecond
	reindexEvery   = 5 * time.Minute
	contextRunes   = 48
	queryRunes     = 32
	historyFlushAt = 60 // 输入历史攒到这么多字也会入库
	minScore       = 0.3
	predictTimeout = 8 * time.Second
)

type Daemon struct {
	dir string
	cfg Config
	llm *Ollama

	mu      sync.Mutex
	history *Store
	folders map[string]*Store
	terms   map[string]*TermIndex

	lastSeq  string
	lastStat time.Time
	buffer   string // 尚未入库的输入历史
	cancel   context.CancelFunc
}

func newDaemon(dir string, cfg Config) (*Daemon, error) {
	for _, sub := range []string{"index", "terms"} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o700); err != nil {
			return nil, err
		}
	}
	d := &Daemon{dir: dir, cfg: cfg, llm: newOllama(cfg), folders: map[string]*Store{}, terms: map[string]*TermIndex{}}
	var err error
	if d.history, err = openStore(d.indexPath("history")); err != nil {
		return nil, err
	}
	for _, f := range cfg.Folders {
		if d.folders[f.Name], err = openStore(d.indexPath("folder-" + f.Name)); err != nil {
			return nil, err
		}
		if d.terms[f.Name], err = openTermIndex(d.indexPath("terms-" + f.Name)); err != nil {
			return nil, err
		}
	}
	var names []string
	for _, f := range cfg.Folders {
		names = append(names, f.Name)
	}
	return d, writeAtomic(d.path("folders.txt"), []byte(strings.Join(names, "\n")+"\n"))
}

func (d *Daemon) path(name string) string { return filepath.Join(d.dir, name) }

func (d *Daemon) indexPath(name string) string {
	return filepath.Join(d.dir, "index", safeName(name)+".jsonl")
}

// safeName 把文件夹名变成可用作文件名的形式（中文保留，路径分隔符等替换掉）。
func safeName(s string) string {
	return strings.Map(func(r rune) rune {
		if strings.ContainsRune(`/\:*?"<>|`, r) || r < 32 || r == 127 { // 与 Lua 的 %c 一致
			return '_'
		}
		return r
	}, s)
}

func (d *Daemon) profile() string {
	data, _ := os.ReadFile(d.path("profile.txt"))
	name := strings.TrimSpace(string(data))
	if _, ok := d.cfg.folder(name); !ok {
		return ""
	}
	return name
}

// Run 主循环：轮询 context.txt，有新上屏就检索并生成联想；定期增量索引资料文件夹。
func (d *Daemon) Run(ctx context.Context) error {
	if d.cfg.IndexDuty > 0 {
		log.Printf("后台抽取限速：占用比例 %.2f（config.json 的 index_duty）", d.cfg.IndexDuty)
	} else {
		hw := currentHW()
		log.Printf("后台抽取限速：自动，当前占用比例 %.2f（%s/%s，内存 %dGB，电池供电 %v）",
			d.cfg.indexDuty(), runtime.GOOS, runtime.GOARCH, hw.memBytes>>30, hw.onBattery)
	}
	go d.reindexLoop(ctx)
	tick := time.NewTicker(pollInterval)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			d.flushHistory(context.Background())
			return nil
		case <-tick.C:
			d.poll(ctx)
		}
	}
}

func (d *Daemon) poll(ctx context.Context) {
	if !d.cfg.Continuation {
		return
	}
	info, err := os.Stat(d.path("context.txt"))
	if err != nil || info.ModTime().Equal(d.lastStat) {
		return
	}
	d.lastStat = info.ModTime()
	seq, commit, recent, err := readContext(d.path("context.txt"))
	if err != nil || seq == d.lastSeq {
		return
	}
	d.lastSeq = seq
	if d.cancel != nil {
		d.cancel() // 新的上屏到来，旧的联想已经没用了
	}
	pctx, cancel := context.WithTimeout(ctx, predictTimeout)
	d.cancel = cancel
	go func() {
		defer cancel()
		if err := d.predict(pctx, seq, recent); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("联想失败：%v", err)
		}
		d.addHistory(ctx, commit)
	}()
}

func readContext(path string) (seq, commit, recent string, err error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	lines := strings.SplitN(string(data), "\n", 4)
	if len(lines) < 3 {
		return "", "", "", fmt.Errorf("context.txt 格式不完整")
	}
	return strings.TrimSpace(lines[0]), lines[1], lines[2], nil
}

func (d *Daemon) predict(ctx context.Context, seq, recent string) error {
	recent = tailRunes(strings.TrimSpace(recent), contextRunes)
	if recent == "" {
		return nil
	}
	profile := d.profile()
	refs, err := d.retrieve(ctx, tailRunes(recent, queryRunes), profile)
	if err != nil {
		log.Printf("检索失败，仅用上文联想：%v", err)
	}
	out, err := d.llm.Generate(ctx, systemPrompt(d.cfg.MaxPhrases), userPrompt(recent, refs), 96, stringList)
	if err != nil {
		return err
	}
	phrases := parsePhrases(out, recent, d.cfg.MaxPhrases)
	body := seq + "\n" + profile + "\n" + strings.Join(phrases, "\n") + "\n"
	return writeAtomic(d.path("suggest.txt"), []byte(body))
}

func (d *Daemon) retrieve(ctx context.Context, query, profile string) ([]hit, error) {
	d.mu.Lock()
	empty := d.history.Len() == 0 && (profile == "" || d.folders[profile].Len() == 0)
	d.mu.Unlock()
	if empty {
		return nil, nil
	}
	vecs, err := d.llm.Embed(ctx, []string{query})
	if err != nil {
		return nil, err
	}
	q := vecs[0]
	normalize(q)
	d.mu.Lock()
	defer d.mu.Unlock()
	hits := d.history.Search(q, d.cfg.TopK)
	if profile != "" {
		hits = append(hits, d.folders[profile].Search(q, d.cfg.TopK)...)
	}
	var refs []hit
	for _, h := range hits {
		if h.Score >= minScore {
			refs = append(refs, h)
		}
	}
	return refs, nil
}

// addHistory 把上屏文字攒成句子，句子结束或攒够长度时求向量入库。
func (d *Daemon) addHistory(ctx context.Context, commit string) {
	if !d.cfg.History || commit == "" {
		return
	}
	d.mu.Lock()
	d.buffer += commit
	ready := sentenceEnd(d.buffer) || utf8.RuneCountInString(d.buffer) >= historyFlushAt
	d.mu.Unlock()
	if ready {
		d.flushHistory(ctx)
	}
}

func (d *Daemon) flushHistory(ctx context.Context) {
	d.mu.Lock()
	text := strings.TrimSpace(d.buffer)
	d.buffer = ""
	d.mu.Unlock()
	if utf8.RuneCountInString(text) < 4 || !hasHan(text) {
		return
	}
	vecs, err := d.llm.Embed(ctx, []string{text})
	if err != nil {
		log.Printf("输入历史入库失败：%v", err)
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if err := d.history.Append(Entry{Text: text, Vec: vecs[0]}); err != nil {
		log.Printf("输入历史写入失败：%v", err)
	}
}

func (d *Daemon) reindexLoop(ctx context.Context) {
	for {
		d.reindex(ctx)
		select {
		case <-ctx.Done():
			return
		case <-time.After(reindexEvery):
		}
	}
}

func (d *Daemon) reindex(ctx context.Context) {
	for _, f := range d.cfg.Folders {
		if _, err := os.Stat(f.Path); err != nil {
			log.Printf("资料文件夹「%s」不可用：%v", f.Name, err)
			continue
		}
		if d.cfg.Terms {
			d.reindexTerms(ctx, f)
		}
		if d.cfg.Continuation {
			d.reindexVectors(ctx, f)
		}
	}
}

func (d *Daemon) termListPath(name string) string {
	return filepath.Join(d.dir, "terms", safeName(name)+".txt")
}

func (d *Daemon) reindexTerms(ctx context.Context, f Folder) {
	idx := d.terms[f.Name]
	n, err := idx.update(ctx, d.llm, f.Path, d.cfg.indexDuty, func(file string, done, total int, reused bool) {
		note := ""
		if reused {
			note = "（与已抽取的文件内容相同，直接复用）"
		}
		log.Printf("「%s」术语抽取 %d/%d：%s%s", f.Name, done, total, file, note)
		// 边抽边更新术语表，大文件夹不用等全部完成就能用上；文件很多时每 20 个写一次
		if done == total || done%20 == 0 || total < 20 {
			writeTermList(d.termListPath(f.Name), idx.Totals())
		}
	})
	if err != nil {
		log.Printf("「%s」术语抽取失败：%v", f.Name, err)
	}
	if _, statErr := os.Stat(d.termListPath(f.Name)); n > 0 || os.IsNotExist(statErr) {
		if err := writeTermList(d.termListPath(f.Name), idx.Totals()); err != nil {
			log.Printf("写术语表失败：%v", err)
		} else if n > 0 {
			log.Printf("「%s」术语表已更新：%d 个文件有变化，共 %d 个术语", f.Name, n, len(idx.Totals()))
		}
	}
}

func (d *Daemon) reindexVectors(ctx context.Context, f Folder) {
	// 索引时先复制一份，求向量期间不阻塞联想
	d.mu.Lock()
	work := &Store{path: d.folders[f.Name].path, entries: d.folders[f.Name].entries}
	d.mu.Unlock()
	n, err := indexFolder(ctx, d.llm, work, f.Path)
	if err != nil {
		log.Printf("索引「%s」失败：%v", f.Name, err)
		return
	}
	if n > 0 {
		d.mu.Lock()
		d.folders[f.Name] = work
		d.mu.Unlock()
		log.Printf("已索引「%s」：%d 个文件有更新，共 %d 段", f.Name, n, work.Len())
	}
}

// newSeq 仅供命令行工具在测试时使用；正常的序号由 Lua 生成。
func newSeq() string { return strconv.FormatInt(time.Now().UnixNano(), 10) }
