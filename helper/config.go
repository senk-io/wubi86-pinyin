package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// Folder 是一个可切换的 RAG 资料文件夹。
type Folder struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

// Config 对应 <rime>/wubi86d/config.json。
type Config struct {
	OllamaURL    string   `json:"ollama_url"`
	ChatModel    string   `json:"chat_model"`
	EmbedModel   string   `json:"embed_model"`
	Terms        bool     `json:"terms"`        // 从资料文件夹抽取项目术语，供输入法按编码补全
	Continuation bool     `json:"continuation"` // 根据上文猜下一个词（默认关闭）
	History      bool     `json:"history"`      // 续写模式下，是否把上屏文字记入本机历史用于检索
	Folders      []Folder `json:"folders"`      // 可切换的资料文件夹
	TopK         int      `json:"top_k"`        // 检索条数
	MaxPhrases   int      `json:"max_phrases"`  // 每次给出的联想数
	AllowRemote  bool     `json:"allow_remote"` // 默认只允许本机模型地址
	IndexDuty    float64  `json:"index_duty"`   // 后台抽取术语时占用模型的时间比例：0 为按机器自动决定（见 hw.go），0.5 即干一秒歇一秒，1 为不限速
}

func defaultConfig() Config {
	return Config{
		OllamaURL:  "http://127.0.0.1:11434",
		ChatModel:  "qwen2.5:7b",
		EmbedModel: "bge-m3",
		Terms:      true,
		History:    true,
		TopK:       4,
		MaxPhrases: 5,
	}
}

// loadConfig 读取配置；文件不存在时写出默认配置，方便用户编辑。
func loadConfig(dir string) (Config, error) {
	cfg := defaultConfig()
	path := filepath.Join(dir, "config.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return cfg, writeJSON(path, cfg)
	}
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("%s: %w", path, err)
	}
	for i := range cfg.Folders {
		cfg.Folders[i].Path = expandHome(cfg.Folders[i].Path)
	}
	return cfg, cfg.validate()
}

func (c Config) validate() error {
	u, err := url.Parse(c.OllamaURL)
	if err != nil || u.Host == "" {
		return fmt.Errorf("ollama_url 无效：%q", c.OllamaURL)
	}
	if !c.AllowRemote && !isLoopback(u.Hostname()) {
		return fmt.Errorf("ollama_url 指向非本机地址 %q；输入内容不应离开本机，确需如此请设置 allow_remote", u.Hostname())
	}
	seen := map[string]bool{}
	for _, f := range c.Folders {
		if f.Name == "" || strings.ContainsAny(f.Name, "\r\n") {
			return fmt.Errorf("文件夹名称不能为空或包含换行：%q", f.Name)
		}
		if seen[f.Name] {
			return fmt.Errorf("文件夹名称重复：%q", f.Name)
		}
		seen[f.Name] = true
	}
	return nil
}

func (c Config) folder(name string) (Folder, bool) {
	for _, f := range c.Folders {
		if f.Name == name {
			return f, true
		}
	}
	return Folder{}, false
}

func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, p[1:])
		}
	}
	return p
}

// writeJSON 原子写入：先写临时文件再改名，读方不会读到半截内容。
func writeJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(path, append(data, '\n'))
}

func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
