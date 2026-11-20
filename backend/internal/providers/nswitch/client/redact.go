package client

import (
	"bytes"
	"fmt"
	"regexp"
	"unicode/utf8"
)

var redactors = []*regexp.Regexp{
	regexp.MustCompile(`(\\?"(?:session_token|access_token|refresh_token|id_token|accessToken|idToken|naIdToken|token|client_secret|client_assertion|f)\\?"\s*:\s*\\?")(?:[^"\\]|\\[^"])*`),
	regexp.MustCompile(`(\\?"(?:email|birthday|gender|screenName|friendCode)\\?"\s*:\s*\\?")(?:[^"\\]|\\[^"])*`),
	regexp.MustCompile(`("(?:data|encrypted_token_request)"\s*:\s*")([^"]{16})[^"]*`),
	regexp.MustCompile(`((?:session_token_code|session_token_code_verifier|session_token|client_secret|client_assertion|refresh_token)=)[^&\s]*`),
	regexp.MustCompile(`(Authorization: (?:Bearer|Basic) )\S*`),
	regexp.MustCompile(`((?i:x-gamewebtoken): )\S*`),
}

// Redact masks tokens, secrets and personal data so logs can be pasted safely.
func Redact(b []byte) []byte {
	b = bytes.Clone(b)
	for _, re := range redactors {
		repl := []byte("${1}${2}…")
		if re.NumSubexp() == 1 {
			repl = []byte("${1}…")
		}
		b = re.ReplaceAll(b, repl)
	}
	return b
}

func Truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}

	cut := n
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + fmt.Sprintf("… (%d bytes)", len(s))
}
