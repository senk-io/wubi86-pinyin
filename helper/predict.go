package main

import (
	"fmt"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

const maxPhraseRune = 8

func systemPrompt(n int) string {
	return fmt.Sprintf("你是中文输入法的联想引擎。根据「上文」推测用户接下来最可能输入的词语。"+
		"只输出 %d 行，每行一个 1 到 %d 个字的词语或短语，不要编号、不要标点、不要解释。"+
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

var listMarker = regexp.MustCompile(`^\s*(\d+\s*[.、:：)）]|[-*•·])\s*`)

// parsePhrases 从模型输出中取出可用的联想词：去掉编号和标点，
// 只保留含汉字、长度合适、且与上文结尾不重复的词，去重后最多 n 个。
func parsePhrases(out, context string, n int) []string {
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
		if strings.HasSuffix(context, line) {
			continue
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
