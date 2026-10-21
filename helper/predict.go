package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

const maxPhraseRune = 8

func systemPrompt(n int) string {
	return fmt.Sprintf("你是中文输入法的联想引擎。根据「上文」推测用户接下来最可能输入的词语。"+
		"输出一个 JSON 字符串数组，包含 %d 个不同的、1 到 %d 个字的词语或短语。"+
		"如果「资料」里有相关用词，优先使用这些用词。", n, maxPhraseRune)
}

func userPrompt(context string, refs []hit) string {
	var b strings.Builder
	if len(refs) > 0 {
		b.WriteString("资料：\n")
		for _, r := range refs {
			b.WriteString("- ")
			b.WriteString(r.Text)
			b.WriteString("\n")
		}
		b.WriteString("\n")
	}
	b.WriteString("上文：")
	b.WriteString(context)
	b.WriteString("\n接下来：")
	return b.String()
}

// stringList 约束模型输出字符串数组。只要求"每行一个"时 qwen2.5 往往只给一个词就停了。
var stringList = map[string]any{"type": "array", "items": map[string]any{"type": "string"}}

var listMarker = regexp.MustCompile(`^\s*(\d+\s*[.、:：)）]|[-*•·])\s*`)

// parsePhrases 从模型输出（JSON 字符串数组，或每行一个词）中取出可用的联想词：去掉编号和标点，
// 只保留含汉字、长度合适、且不在上文中出现过的词，去重后最多 n 个。
func parsePhrases(out, context string, n int) []string {
	out = unwrapList(out)
	var phrases []string
	seen := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		line = listMarker.ReplaceAllString(line, "")
		line = strings.TrimFunc(line, func(r rune) bool {
			return unicode.IsSpace(r) || unicode.IsPunct(r) || unicode.IsSymbol(r)
		})
		count := utf8.RuneCountInString(line)
		if count == 0 || count > maxPhraseRune || seen[line] || !hasHan(line) {
			continue
		}
		if strings.Contains(context, line) {
			continue // 上文里已经打过的词不再联想
		}
		seen[line] = true
		phrases = append(phrases, line)
		if len(phrases) == n {
			break
		}
	}
	return phrases
}

func hasHan(s string) bool {
	for _, r := range s {
		if unicode.Is(unicode.Han, r) {
			return true
		}
	}
	return false
}

// sentenceEnd 判断一段上屏文字是否结束了一句话，用于把输入历史切成句子入库。
func sentenceEnd(s string) bool {
	r, _ := utf8.DecodeLastRuneInString(strings.TrimSpace(s))
	return strings.ContainsRune("。！？!?；;…\n", r)
}

// tailRunes 取字符串最后 n 个字。
func tailRunes(s string, n int) string {
	rs := []rune(s)
	if len(rs) <= n {
		return s
	}
	return string(rs[len(rs)-n:])
}

// unwrapList 把 JSON 字符串数组展开成每行一个；不是数组就原样返回。
func unwrapList(out string) string {
	var list []string
	if json.Unmarshal([]byte(strings.TrimSpace(out)), &list) == nil {
		return strings.Join(list, "\n")
	}
	return out
}
