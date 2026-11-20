module nsonline

go 1.22

require nsonline/shared v0.0.0

// The shared translation catalogs live outside this module (go:embed cannot
// reach ../shared), in their own module; the replace keeps
// `cd backend && go build ./...` working without go.work.
replace nsonline/shared => ../shared
