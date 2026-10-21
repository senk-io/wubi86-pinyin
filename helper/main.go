// wubi86d 是 wubi86-pinyin 输入法的常驻进程：读取输入法写出的上文，
// 结合本机输入历史和资料文件夹做检索（RAG），调用本地 Ollama 模型生成联想词，
// 再写回给输入法。所有数据都留在本机。
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

const usage = `用法：wubi86d [-rime-dir 目录] <命令>

命令：
  run                常驻运行（默认）
  try <上文>         用当前配置生成一次联想并打印，用于检查模型是否可用
  folders            列出可切换的资料文件夹，当前使用的标 *
  use <名称|->       切换资料文件夹；- 表示只用输入历史
  index              立即索引全部资料文件夹（抽取术语）
  terms [名称]       查看某个资料文件夹的术语表（默认当前文件夹）
  forget-history     清空本机输入历史索引
`

func main() {
	rimeDir := flag.String("rime-dir", defaultRimeDir(), "Rime 用户目录")
	flag.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	flag.Parse()

	dir := filepath.Join(*rimeDir, "wubi86d")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		log.Fatal(err)
	}
	cfg, err := loadConfig(dir)
	if err != nil {
		log.Fatal(err)
	}
	d, err := newDaemon(dir, cfg)
	if err != nil {
		log.Fatal(err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	args := flag.Args()
	cmd := "run"
	if len(args) > 0 {
		cmd = args[0]
	}
	switch cmd {
	case "run":
		log.Printf("wubi86d 已启动，目录 %s，模型 %s / %s", dir, cfg.ChatModel, cfg.EmbedModel)
		err = d.Run(ctx)
	case "try":
		err = cmdTry(ctx, d, strings.Join(args[1:], ""))
	case "folders":
		current := d.profile()
		for _, f := range cfg.Folders {
			mark := " "
			if f.Name == current {
				mark = "*"
			}
			fmt.Printf("%s %s\t%s\t%d 段\n", mark, f.Name, f.Path, d.folders[f.Name].Len())
		}
	case "use":
		err = cmdUse(d, args[1:])
	case "index":
		d.reindex(ctx)
	case "terms":
		err = cmdTerms(d, args[1:])
	case "forget-history":
		err = d.history.Replace(nil)
		if err == nil {
			fmt.Println("已清空输入历史索引。")
		}
	default:
		flag.Usage()
		os.Exit(2)
	}
	if err != nil {
		log.Fatal(err)
	}
}

func cmdTry(ctx context.Context, d *Daemon, recent string) error {
	if recent == "" {
		return fmt.Errorf("请给出上文，例如：wubi86d try 今天天气")
	}
	if err := d.predict(ctx, newSeq(), recent); err != nil {
		return err
	}
	data, err := os.ReadFile(d.path("suggest.txt"))
	if err != nil {
		return err
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	fmt.Printf("资料文件夹：%s\n联想：%s\n", orNone(lines[1]), strings.Join(lines[2:], " / "))
	return nil
}

func cmdUse(d *Daemon, args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("用法：wubi86d use <名称|->")
	}
	name := args[0]
	if name == "-" {
		name = ""
	} else if _, ok := d.cfg.folder(name); !ok {
		return fmt.Errorf("没有名为「%s」的资料文件夹，请先在 %s 中添加", name, d.path("config.json"))
	}
	if err := writeAtomic(d.path("profile.txt"), []byte(name+"\n")); err != nil {
		return err
	}
	fmt.Printf("当前资料文件夹：%s\n", orNone(name))
	return nil
}

func cmdTerms(d *Daemon, args []string) error {
	name := d.profile()
	if len(args) > 0 {
		name = args[0]
	}
	if name == "" {
		return fmt.Errorf("当前没有选择资料文件夹，请指定名称：wubi86d terms <名称>")
	}
	data, err := os.ReadFile(d.termListPath(name))
	if err != nil {
		return fmt.Errorf("「%s」还没有术语表，先运行 wubi86d index", name)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	fmt.Printf("「%s」共 %d 个术语：\n", name, len(lines)-1)
	for _, line := range lines[1:] {
		fmt.Println(strings.Replace(line, "\t", "  ×", 1))
	}
	return nil
}

func orNone(s string) string {
	if s == "" {
		return "（无，只用输入历史）"
	}
	return s
}

func defaultRimeDir() string {
	home, _ := os.UserHomeDir()
	switch runtime.GOOS {
	case "darwin":
		return filepath.Join(home, "Library", "Rime")
	case "windows":
		return filepath.Join(os.Getenv("APPDATA"), "Rime")
	default:
		return filepath.Join(home, ".local", "share", "fcitx5", "rime")
	}
}
