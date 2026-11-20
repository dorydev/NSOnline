package env

import (
	"bufio"
	"io"
	"log"
	"os"
	"strings"
)

// Load never overrides an existing variable. A missing file is not an error.
func Load(path string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	values, order, err := parse(f)
	for _, k := range order {
		if _, exists := os.LookupEnv(k); !exists {
			os.Setenv(k, values[k])
		}
	}
	if err != nil {
		log.Printf("%s: %v (keys after this point are not loaded)", path, err)
	}
}

// Parse skips blanks, # comments and lines without "=", removes one pair of
// quotes, and keeps the first value of a key. On a read error it returns what it read.
func Parse(r io.Reader) (map[string]string, error) {
	values, _, err := parse(r)
	return values, err
}

func parse(r io.Reader) (map[string]string, []string, error) {
	values := map[string]string{}
	var order []string
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1<<20) // long values (certificates…) up to 1 MiB
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		if k == "" {
			continue
		}
		if _, dup := values[k]; dup {
			continue
		}
		values[k] = unquote(strings.TrimSpace(v))
		order = append(order, k)
	}
	return values, order, sc.Err()
}

func unquote(v string) string {
	if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
		return v[1 : len(v)-1]
	}
	return v
}

func Get(key string) string { return strings.TrimSpace(os.Getenv(key)) }

func Or(key, def string) string {
	if v := Get(key); v != "" {
		return v
	}
	return def
}
