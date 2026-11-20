package diagnostics

import (
	"time"

	"nsonline/shared/i18n"
)

type Check struct {
	Name      string `json:"name"`
	OK        bool   `json:"ok"`
	LatencyMs int64  `json:"latencyMs"`
	Detail    string `json:"detail"`
}

type Report struct {
	Checks []Check   `json:"checks"`
	At     time.Time `json:"at"`
}

// Probes are run in order. A nil probe is skipped with its reason.
type Probes struct {
	Version string
	Uptime  time.Duration

	Account     func() error
	ZncaSkipped string
	Znca        func() error
	Coral       func() (friends int, err error)
	DiscordApp  bool
	Discord     func() error
}

func shorten(s string) string {
	if len(s) <= 300 {
		return s
	}
	n := 300
	for n > 0 && s[n]&0xc0 == 0x80 {
		n--
	}
	return s[:n] + "…"
}

func timed(name, okDetail string, f func() error) Check {
	start := time.Now()
	err := f()
	c := Check{Name: name, OK: err == nil, LatencyMs: time.Since(start).Milliseconds(), Detail: okDetail}
	if err != nil {
		c.Detail = shorten(err.Error())
	}
	return c
}

func Run(p Probes, now time.Time) Report {
	checks := []Check{{Name: "backend", OK: true, Detail: i18n.T("diag.backend", i18n.Args{"version": p.Version, "uptime": p.Uptime.Round(time.Second)})}}

	nintendoOK := false
	if p.Account == nil {
		checks = append(checks, Check{Name: "nintendo", Detail: i18n.T("diag.nintendo.notLoggedIn")})
	} else {
		c := timed("nintendo", i18n.T("diag.nintendo.ok"), p.Account)
		nintendoOK = c.OK
		checks = append(checks, c)
	}

	zncaOK := false
	if p.Znca == nil {
		checks = append(checks, Check{Name: "znca", Detail: p.ZncaSkipped})
	} else {
		c := timed("znca", i18n.T("diag.znca.ok"), p.Znca)
		zncaOK = c.OK
		checks = append(checks, c)
	}

	if nintendoOK && zncaOK && p.Coral != nil {
		count := 0
		c := timed("coral", "", func() error {
			var err error
			count, err = p.Coral()
			return err
		})
		if c.OK {
			c.Detail = i18n.T("diag.coral.ok", i18n.Args{"count": count})
		}
		checks = append(checks, c)
	} else {
		checks = append(checks, Check{Name: "coral", Detail: i18n.T("diag.coral.skipped")})
	}

	if !p.DiscordApp || p.Discord == nil {
		checks = append(checks, Check{Name: "discord", Detail: i18n.T("api.error.noDiscordApp")})
	} else {
		checks = append(checks, timed("discord", i18n.T("diag.discord.ok"), p.Discord))
	}

	return Report{Checks: checks, At: now}
}
