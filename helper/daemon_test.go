package main

import (
	"context"
	"encoding/json"
	"hash/fnv"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeOllama 模拟 Ollama：向量按字哈希成词袋，生成接口返回固定的几行并记录收到的提示词。
type fakeOllama struct {
	mu         sync.Mutex
	lastPrompt string
	reply      string
	calls      int
}

func (f *fakeOllama) handler(t *testing.T) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/embed", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Input []string }
		json.NewDecoder(r.Body).Decode(&req)
		var out [][]float32
		for _, s := range req.Input {
			v := make([]float32, 64)
			for _, ch := range s {
				h := fnv.New32a()
				h.Write([]byte(string(ch)))
				v[h.Sum32()%64]++
			}
			out = append(out, v)
		}
		json.NewEncoder(w).Encode(map[string]any{"embeddings": out})
	})
	mux.HandleFunc("/api/generate", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Prompt string }
		json.NewDecoder(r.Body).Decode(&req)
		f.mu.Lock()
		f.lastPrompt = req.Prompt
		f.calls++
		reply := f.reply
		f.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]any{"response": reply})
	})
	return mux
}

func newTestDaemon(t *testing.T, folders []Folder) (*Daemon, *fakeOllama) {
	t.Helper()
	fake := &fakeOllama{reply: "1. 晴朗\n- 很好。\n不错\n今天天气\n这是一个特别特别长的短语不要\nhello\n不错"}
	srv := httptest.NewServer(fake.handler(t))
	t.Cleanup(srv.Close)
	cfg := defaultConfig()
	cfg.OllamaURL = srv.URL
	cfg.Folders = folders
	cfg.Continuation = true
	cfg.IndexDuty = 1 // 测试不限速
	d, err := newDaemon(t.TempDir(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	return d, fake
}

func TestParsePhrases(t *testing.T) {
	got := parsePhrases("1. 晴朗\n- 很好。\n不错\n今天天气\n这是一个特别特别长的短语不要\nhello\n不错", "我说今天天气", 5)
	want := []string{"晴朗", "很好", "不错"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("parsePhrases = %v, want %v", got, want)
	}
}

func TestChunkText(t *testing.T) {
	chunks := chunkText("第一段。\n\n" + strings.Repeat("长", 450))
	if len(chunks) != 4 || chunks[0] != "第一段。" {
		t.Fatalf("chunks = %d %q", len(chunks), chunks[0])
	}
	for _, c := range chunks {
		if n := len([]rune(c)); n > maxChunkRune {
			t.Fatalf("chunk too long: %d", n)
		}
	}
}

func TestConfigRejectsRemoteModel(t *testing.T) {
	cfg := defaultConfig()
	cfg.OllamaURL = "http://example.com:11434"
	if cfg.validate() == nil {
		t.Fatal("remote ollama_url should be rejected by default")
	}
	cfg.AllowRemote = true
	if err := cfg.validate(); err != nil {
		t.Fatal(err)
	}
}

func TestPredictUsesActiveFolder(t *testing.T) {
	notes := t.TempDir()
	os.WriteFile(filepath.Join(notes, "a.md"), []byte("量子纠缠是量子力学的现象。\n\n今天天气晴朗适合出门。"), 0o600)
	os.WriteFile(filepath.Join(notes, "skip.bin"), []byte("今天天气"), 0o600)
	d, fake := newTestDaemon(t, []Folder{{Name: "笔记", Path: notes}, {Name: "工作", Path: t.TempDir()}})
	ctx := context.Background()

	d.reindex(ctx)
	if n := d.folders["笔记"].Len(); n != 2 {
		t.Fatalf("indexed %d chunks, want 2", n)
	}
	names, _ := os.ReadFile(d.path("folders.txt"))
	if string(names) != "笔记\n工作\n" {
		t.Fatalf("folders.txt = %q", names)
	}

	// 未选择文件夹：不带资料
	if err := d.predict(ctx, "1", "今天天气"); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(fake.lastPrompt, "资料") {
		t.Fatalf("no folder selected, prompt should not have refs: %q", fake.lastPrompt)
	}

	// 切到「笔记」：检索到相关段落
	if err := cmdUse(d, []string{"笔记"}); err != nil {
		t.Fatal(err)
	}
	if err := d.predict(ctx, "2", "今天天气"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(fake.lastPrompt, "今天天气晴朗适合出门") {
		t.Fatalf("prompt missing retrieved chunk: %q", fake.lastPrompt)
	}
	got, _ := os.ReadFile(d.path("suggest.txt"))
	if string(got) != "2\n笔记\n晴朗\n很好\n不错\n" {
		t.Fatalf("suggest.txt = %q", got)
	}

	if err := cmdUse(d, []string{"不存在"}); err == nil {
		t.Fatal("unknown folder should be rejected")
	}
}

func TestReindexIsIncremental(t *testing.T) {
	notes := t.TempDir()
	file := filepath.Join(notes, "a.md")
	os.WriteFile(file, []byte("第一版内容"), 0o600)
	d, _ := newTestDaemon(t, []Folder{{Name: "笔记", Path: notes}})
	ctx := context.Background()
	work := d.folders["笔记"]
	if n, _ := indexFolder(ctx, d.llm, work, notes); n != 1 {
		t.Fatalf("first index changed %d files", n)
	}
	if n, _ := indexFolder(ctx, d.llm, work, notes); n != 0 {
		t.Fatalf("unchanged folder re-indexed %d files", n)
	}
	os.Remove(file)
	indexFolder(ctx, d.llm, work, notes)
	if work.Len() != 0 {
		t.Fatalf("deleted file still indexed: %d", work.Len())
	}
	reopened, _ := openStore(work.path)
	if reopened.Len() != 0 {
		t.Fatal("index file not rewritten after deletion")
	}
}

func TestHistoryFlushesOnSentenceEnd(t *testing.T) {
	d, _ := newTestDaemon(t, nil)
	ctx := context.Background()
	d.addHistory(ctx, "今天天气")
	if d.history.Len() != 0 {
		t.Fatal("history flushed before sentence end")
	}
	d.addHistory(ctx, "很好。")
	if d.history.Len() != 1 || d.history.entries[0].Text != "今天天气很好。" {
		t.Fatalf("history = %+v", d.history.entries)
	}
	reopened, _ := openStore(d.history.path)
	if reopened.Len() != 1 {
		t.Fatal("history not persisted")
	}

	d.cfg.History = false
	d.addHistory(ctx, "不该记录。")
	if d.history.Len() != 1 {
		t.Fatal("history recorded while disabled")
	}
}

func TestRunLoopAnswersContext(t *testing.T) {
	d, _ := newTestDaemon(t, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go d.Run(ctx)

	writeAtomic(d.path("context.txt"), []byte("42\n天气\n今天天气\n"))
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if data, err := os.ReadFile(d.path("suggest.txt")); err == nil && strings.HasPrefix(string(data), "42\n") {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("no suggestion written for context seq 42")
}

func TestParseTermsKeepsOnlyVerbatim(t *testing.T) {
	src := "星辰数据平台的灰度发布定在周四晚上，由运维组执行 SenkNet-API 回滚预案。"
	out := `["星辰数据平台", "灰度发布", "灰度上线", "SenkNet-API", "周", "回滚预案。", "星辰数据平台"]`
	got := parseTerms(out, src)
	want := "星辰数据平台,灰度发布,SenkNet-API,回滚预案"
	if strings.Join(got, ",") != want {
		t.Fatalf("parseTerms = %v, want %s", got, want)
	}
}

func TestTermIndexIncremental(t *testing.T) {
	notes := t.TempDir()
	a := filepath.Join(notes, "a.md")
	os.WriteFile(a, []byte("星辰数据平台上线。星辰数据平台很稳。"), 0o600)
	os.WriteFile(filepath.Join(notes, "b.txt"), []byte("灰度发布流程"), 0o600)
	// 依赖目录不抽取
	os.MkdirAll(filepath.Join(notes, "node_modules", "pkg"), 0o700)
	os.WriteFile(filepath.Join(notes, "node_modules", "pkg", "README.md"), []byte("星辰数据平台"), 0o600)
	// 内容相同的副本只调用一次模型
	os.MkdirAll(filepath.Join(notes, "copy"), 0o700)
	os.WriteFile(filepath.Join(notes, "copy", "b.txt"), []byte("灰度发布流程"), 0o600)
	d, fake := newTestDaemon(t, []Folder{{Name: "星辰", Path: notes}})
	fake.reply = `["星辰数据平台", "灰度发布", "不存在的词"]`
	ctx := context.Background()

	d.reindex(ctx)
	data, err := os.ReadFile(d.termListPath("星辰"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if !strings.HasPrefix(lines[0], "v") || strings.Join(lines[1:], "|") != "星辰数据平台\t2|灰度发布\t2" {
		t.Fatalf("term list = %q", data)
	}
	if fake.calls != 2 {
		t.Fatalf("model called %d times, want 2 (duplicate content reused)", fake.calls)
	}

	// 删除文件后术语随之移除；未改动的文件不重抽
	os.Remove(a)
	fake.reply = `[]`
	d.reindex(ctx)
	data, _ = os.ReadFile(d.termListPath("星辰"))
	if got := strings.Join(strings.Split(strings.TrimSpace(string(data)), "\n")[1:], "|"); got != "灰度发布\t2" {
		t.Fatalf("after delete term list = %q", got)
	}

	reopened, _ := openTermIndex(d.terms["星辰"].path)
	if len(reopened.files) != 2 {
		t.Fatalf("term index not persisted: %d files", len(reopened.files))
	}
}

func TestContinuationOffSkipsContext(t *testing.T) {
	d, _ := newTestDaemon(t, nil)
	d.cfg.Continuation = false
	writeAtomic(d.path("context.txt"), []byte("7\n天气\n今天天气\n"))
	d.poll(context.Background())
	time.Sleep(100 * time.Millisecond)
	if _, err := os.Stat(d.path("suggest.txt")); err == nil {
		t.Fatal("continuation disabled but suggestion written")
	}
}

func TestAutoDuty(t *testing.T) {
	cases := []struct {
		goos, goarch string
		hw           hwInfo
		want         float64
	}{
		{"darwin", "arm64", hwInfo{memBytes: 36 << 30}, 0.25},
		{"darwin", "arm64", hwInfo{memBytes: 36 << 30, onBattery: true}, 0.125},
		{"darwin", "arm64", hwInfo{memBytes: 8 << 30}, 0.125},
		{"darwin", "amd64", hwInfo{memBytes: 16 << 30}, 0.125},
		{"windows", "amd64", hwInfo{memBytes: 8 << 30, onBattery: true}, 0.03125},
		{"linux", "amd64", hwInfo{}, 0.125},
	}
	for _, c := range cases {
		if got := autoDuty(c.goos, c.goarch, c.hw); got != c.want {
			t.Errorf("autoDuty(%s/%s, %+v) = %v, want %v", c.goos, c.goarch, c.hw, got, c.want)
		}
	}
	if d := (Config{IndexDuty: 0.8}).indexDuty(); d != 0.8 {
		t.Errorf("configured duty ignored: %v", d)
	}
}

func TestPacerWaitsWhileTyping(t *testing.T) {
	d, _ := newTestDaemon(t, nil)
	if d.typing() {
		t.Fatal("typing without active.txt")
	}
	writeAtomic(d.path("active.txt"), []byte("1\n"))
	if !d.typing() {
		t.Fatal("recent active.txt not seen as typing")
	}
	old := time.Now().Add(-idleAfter - time.Second)
	os.Chtimes(d.path("active.txt"), old, old)
	if d.typing() {
		t.Fatal("stale active.txt seen as typing")
	}

	// 正在打字时 before 一直等待，直到 ctx 取消
	p := &pacer{busy: func() bool { return true }}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if err := p.before(ctx); err == nil {
		t.Fatal("before returned while busy")
	}
	// 占用比例 0.5：休息时长等于调用时长
	start := time.Now()
	(&pacer{duty: func() float64 { return 0.5 }}).after(context.Background(), 30*time.Millisecond)
	if el := time.Since(start); el < 30*time.Millisecond {
		t.Fatalf("rested %v, want >= 30ms", el)
	}
}
