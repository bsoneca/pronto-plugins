package prontoproject

import (
	"github.com/bonisoft3/pronto/distribution"
	terminal "github.com/bonisoft3/pronto/terminals:omnishell"
	"github.com/bonisoft3/pronto/clusters:mecha"
	"github.com/bonisoft3/pronto/builders:bayt"
)

pronto: distribution.#Project & terminal.#Project & mecha.#Project & bayt.#Toolchain