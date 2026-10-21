package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Ollama 是本地 Ollama 服务的最小客户端，只用到生成和向量两个接口。
type Ollama struct {
	base       string
	chatModel  string
	embedModel string
	http       *http.Client
}

func newOllama(cfg Config) *Ollama {
	return &Ollama{
		base:       strings.TrimRight(cfg.OllamaURL, "/"),
		chatModel:  cfg.ChatModel,
		embedModel: cfg.EmbedModel,
		http:       &http.Client{Timeout: 30 * time.Second},
	}
}

func (o *Ollama) post(ctx context.Context, path string, req, resp any) error {
	body, err := json.Marshal(req)
	if err != nil {
		return err
	}
	r, err := http.NewRequestWithContext(ctx, http.MethodPost, o.base+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	r.Header.Set("Content-Type", "application/json")
	res, err := o.http.Do(r)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(res.Body, 512))
		return fmt.Errorf("ollama %s: %s: %s", path, res.Status, bytes.TrimSpace(msg))
	}
	return json.NewDecoder(res.Body).Decode(resp)
}

const numCtx = 4096

// Generate 生成一段文本。keepAlive 是用完后模型在内存里保留多久（如 "30m"）：
// 续写要随打随用，保留得久以免冷启动；后台抽术语用短的，抽完很快释放内存。
// format 非空时按该 JSON Schema 约束输出（Ollama 的结构化输出）。
func (o *Ollama) Generate(ctx context.Context, system, prompt string, maxTokens int, format any, keepAlive string) (string, error) {
	req := map[string]any{
		"model":      o.chatModel,
		"system":     system,
		"prompt":     prompt,
		"stream":     false,
		"keep_alive": keepAlive,
		"options": map[string]any{
			"num_predict": maxTokens,
			"temperature": 0.3,
			// 提示词最多一千多 token；默认按模型的 32k 上下文分配缓存会多占 1GB 以上内存。
			// 所有调用用同一个值，避免上下文长度不同导致模型重新加载。
			"num_ctx": numCtx,
		},
	}
	if format != nil {
		req["format"] = format
	}
	var resp struct {
		Response string `json:"response"`
	}
	if err := o.post(ctx, "/api/generate", req, &resp); err != nil {
		return "", err
	}
	return resp.Response, nil
}

// Embed 批量求向量。
func (o *Ollama) Embed(ctx context.Context, texts []string) ([][]float32, error) {
	req := map[string]any{"model": o.embedModel, "input": texts, "keep_alive": "30m"}
	var resp struct {
		Embeddings [][]float32 `json:"embeddings"`
	}
	if err := o.post(ctx, "/api/embed", req, &resp); err != nil {
		return nil, err
	}
	if len(resp.Embeddings) != len(texts) {
		return nil, fmt.Errorf("ollama /api/embed: 期望 %d 个向量，得到 %d 个", len(texts), len(resp.Embeddings))
	}
	return resp.Embeddings, nil
}
