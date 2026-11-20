package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"nsonline/internal/discord"
	api "nsonline/internal/http"
	"nsonline/internal/lockfile"
	"nsonline/internal/logfile"
	"nsonline/internal/presence"
	"nsonline/internal/providers/nswitch/client"
	"nsonline/internal/providers/nswitch/znca"
	"nsonline/internal/sidecar"
	"nsonline/internal/version"
	"nsonline/shared/i18n"
)

// TokenEnv carries the API bearer token from the desktop app, never on argv.
const (
	TokenEnv    = "NSONLINE_API_TOKEN"
	readyPrefix = "NSONLINE_READY "
	logMax      = 1 << 20
	logKeep     = 3
)

// appDeps are the side effects of `nsonline app`, replaced in tests.
type appDeps struct {
	getenv     func(string) string
	unsetenv   func(string)
	sink       presence.DiscordSink
	clearStale func(ids []string)
	probe      func(id string) error
	signals    <-chan os.Signal
	stderr     io.Writer
	znca       func() znca.Config
	apps       func() presence.DiscordApps
	config     func() presence.Config
	tweak      func(*sidecar.Config)
}

func defaultAppDeps() appDeps {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	return appDeps{
		getenv:     os.Getenv,
		unsetenv:   func(k string) { os.Unsetenv(k) },
		sink:       &presence.DiscordLink{},
		clearStale: clearStaleActivities,
		signals:    sig,
		stderr:     os.Stderr,
		znca:       zncaConfigFromEnv,
		apps:       discordApps,
		config:     func() presence.Config { return baseConfig(true) },
	}
}

func runApp(args []string) {
	os.Exit(appMain(args, os.Stdin, os.Stdout, defaultAppDeps()))
}

func readyLine(addr string, pid int) string {
	b, _ := json.Marshal(struct {
		Addr    string `json:"addr"`
		Version string `json:"version"`
		PID     int    `json:"pid"`
	}{addr, version.Version, pid})
	return readyPrefix + string(b) + "\n"
}

func watchStdin(r io.Reader, onEOF func()) {
	go func() {
		_, _ = io.Copy(io.Discard, r)
		onEOF()
	}()
}

// appMain never prompts: consent and login come through the API.
func appMain(args []string, stdin io.Reader, stdout io.Writer, d appDeps) int {
	fs := flag.NewFlagSet("app", flag.ContinueOnError)
	fs.SetOutput(d.stderr)
	dataDir := fs.String("data-dir", "", i18n.T("cli.flag.dataDir"))
	verbose := fs.Bool("v", false, i18n.T("cli.flag.appVerbose"))
	stdinWatch := fs.Bool("stdin-watchdog", true, i18n.T("cli.flag.stdinWatchdog"))
	lang := fs.String("lang", "", i18n.T("cli.flag.lang"))
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *lang != "" {
		i18n.SetLocale(*lang)
	}
	if *dataDir == "" {
		fmt.Fprintln(d.stderr, "nsonline app: "+i18n.T("cli.app.dataDirRequired"))
		return 2
	}
	token := d.getenv(TokenEnv)
	d.unsetenv(TokenEnv) // not inherited by the browser we may start
	if len(token) < 32 {
		fmt.Fprintln(d.stderr, "nsonline app: "+i18n.T("cli.app.tokenTooShort", i18n.Args{"env": TokenEnv}))
		return 2
	}
	if err := os.MkdirAll(*dataDir, 0o700); err != nil {
		fmt.Fprintf(d.stderr, "nsonline app: %v\n", err)
		return 1
	}
	unlock, err := lockfile.Write(*dataDir, os.Getpid())
	if err != nil {
		fmt.Fprintf(d.stderr, "nsonline app: %v\n", err)
	}
	defer unlock()

	znca := d.znca()
	redact := logfile.Chain(client.Redact, logfile.Literals(token, znca.ClientSecret, znca.SharedSecret))
	logs, err := logfile.Open(filepath.Join(*dataDir, "logs", "backend.log"), logMax, logKeep, redact)
	if err != nil {
		fmt.Fprintf(d.stderr, "nsonline app: %s: %v\n", i18n.T("cli.app.logFile"), err)
		return 1
	}
	errOut := logfile.NewAsync(redactWriter{d.stderr, redact}, 256)
	prevOut, prevFlags := log.Writer(), log.Flags()
	log.SetOutput(io.MultiWriter(logs, errOut))
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	defer func() {
		log.SetOutput(prevOut)
		log.SetFlags(prevFlags)
		errOut.Close()
		logs.Close()
	}()
	log.Printf("nsonline %s starting (app mode, pid %d)", version.Version, os.Getpid())

	stop := make(chan struct{})
	var stopOnce sync.Once
	shutdown := func(why string) {
		stopOnce.Do(func() {
			log.Printf("shutting down: %s", why)
			close(stop)
		})
	}

	cfg := sidecar.Config{
		DataDir:        *dataDir,
		Znca:           znca,
		Apps:           d.apps(),
		Sink:           d.sink,
		ConfigBase:     d.config(),
		Verbose:        *verbose,
		ClearStale:     d.clearStale,
		DiscordProbe:   d.probe,
		OnShutdown:     func() { go shutdown("POST /api/shutdown") },
		CommandTimeout: 25 * time.Second,
	}
	if d.tweak != nil {
		d.tweak(&cfg)
	}
	sup, err := sidecar.New(cfg)
	if err != nil {
		log.Printf("startup: %v", err)
		return 1
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Printf("listen: %v", err)
		return 1
	}
	addr := ln.Addr().String()
	_, port, _ := net.SplitHostPort(addr)
	srv := api.NewServer(addr, api.NewHandler(sup, api.Options{Port: port, Token: token}))
	srv.WriteTimeout = cfg.CommandTimeout + 10*time.Second
	srv.ErrorLog = log.Default()
	serveDone := make(chan struct{})
	go func() {
		defer close(serveDone)
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("api: %v", err)
			shutdown("API server failed")
		}
	}()

	supDone := make(chan struct{})
	go func() {
		defer close(supDone)
		_ = sup.Run(stop)
	}()

	if _, err := io.WriteString(stdout, readyLine(addr, os.Getpid())); err != nil {
		shutdown("stdout closed")
	}
	log.Printf("API on http://%s", addr)

	if *stdinWatch {
		watchStdin(stdin, func() { shutdown("stdin closed (parent gone)") })
	}
	if d.signals != nil {
		go func() {
			select {
			case s := <-d.signals:
				shutdown(s.String())
			case <-stop:
			}
		}()
	}

	<-stop
	select {
	case <-supDone:
	case <-time.After(15 * time.Second):
		log.Printf("shutdown: presence loop did not stop in time")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	<-serveDone
	log.Printf("bye")
	return 0
}

type redactWriter struct {
	w      io.Writer
	redact func([]byte) []byte
}

func (r redactWriter) Write(p []byte) (int, error) {
	if _, err := r.w.Write(r.redact(p)); err != nil {
		return 0, err
	}
	return len(p), nil
}

func clearStaleActivities(ids []string) {
	for _, id := range ids {
		c, err := discord.Connect(id)
		if err != nil {
			continue
		}
		if err := c.SetActivity(nil); err != nil {
			log.Printf("discord: clearing a stale activity: %v", err)
		}
		c.Close()
	}
}
