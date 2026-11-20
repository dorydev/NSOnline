package providers

type Platform struct {
	ID    int
	Name  string
	Asset string
}

type Login struct {
	URL            string
	RedirectPrefix string
	State          any
}

type Provider interface {
	Kind() string
	Platforms() []Platform
	DiscordApp(platform int) string
	WebServices() []WebService
	Open(path string) (Session, error)
}

type Session interface {
	LoggedIn() bool
	StartLogin() (*Login, error)
	FinishLogin(login *Login, redirect string) error
	Friends() ([]Friend, error)
	Presence(target string) (Presence, string, error)
	OpenWebService(id string) (*WebServiceOpen, error)
}
