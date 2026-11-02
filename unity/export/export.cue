// One app's Unity host files, by tag: `cue export ./unity/export -t package=<pkg> [-t previous=<the
// app's unity/unity.json>] [-t screens=a,b -t shared=<uss>,… -t hatches=a,b -t scenarios=<cue>,…
// -t suites=all|<a,b> -t server=<suite>=<why>;<suite>=<why> -t cases=true|false (older: all or none) -t cluster=true|false
// -t stage=<path>,…] -e files --out json`, each path from
// the app's root to {seed, text}. An argument not given keeps what `previous` declared.
package export

import (
	"encoding/json"
	"strings"

	"github.com/bsoneca/pronto-plugins/unity"
)

_package:   string         @tag(package)
_previous:  *"{}" | string @tag(previous)
_screens:   *"" | string   @tag(screens)
_shared:    *"-" | string  @tag(shared)
_hatches:   *"-" | string  @tag(hatches)
_scenarios: *"-" | string  @tag(scenarios)
_cases:     *"" | string   @tag(cases)
_suites:    *"" | string   @tag(suites)
_server:    *"-" | string  @tag(server)
_cluster:   *"" | string   @tag(cluster)
_stage:     *"-" | string  @tag(stage)

_prev: json.Unmarshal(_previous)
_list: {
	in: string
	out: [for x in strings.Split(strings.Replace(in, " ", ",", -1), ",") if x != "" {x}]
}

_host: unity.#Host & {
	package: _package
	surface: {
		// Screens given: each with the shared sheets given (or none); else the app's as declared.
		if _screens != "" {
			screens: {for s in (_list & {in: _screens}).out {(s): {
				if _shared != "-" {shared: (_list & {in: _shared}).out}
				if _shared == "-" && _prev.screens[s] != _|_ {shared: _prev.screens[s].shared}
				if _prev.screens[s] != _|_ {uss: _prev.screens[s].uss}
			}}}
		}
		if _screens == "" && _prev.screens != _|_ {screens: {for s, v in _prev.screens {(s): {uss: v.uss, shared: [
			if _shared != "-" for p in (_list & {in: _shared}).out {p},
			if _shared == "-" for p in v.shared {p},
		]}}}}
		if _hatches != "-" {hatches: (_list & {in: _hatches}).out}
		if _hatches == "-" && _prev.hatches != _|_ {hatches: _prev.hatches}
		if _scenarios != "-" {scenarios: (_list & {in: _scenarios}).out}
		if _scenarios == "-" && _prev.scenarios != _|_ {scenarios: _prev.scenarios}
		if _stage != "-" {stage: (_list & {in: _stage}).out}
		if _stage == "-" && _prev.stage != _|_ {stage: _prev.stage}
		// The suites run here: given (all, or a list), else the older cases flag given or kept (true = all, false = none), else
		// what the app declared.
		if _suites != "" {suites: host: [if _suites == "all" {"all"}, (_list & {in: _suites}).out][0]}
		if _suites == "" && _cases != "" {suites: host: [if _cases == "true" {"all"}, []][0]}
		if _suites == "" && _cases == "" && _prev.suites != _|_ {suites: host: _prev.suites.host}
		if _suites == "" && _cases == "" && _prev.suites == _|_ && _prev.cases != _|_ {suites: host: [if _prev.cases {"all"}, []][0]}
		if _server != "-" {suites: server: {for kv in strings.Split(_server, ";") if kv != "" {(strings.SplitN(kv, "=", 2)[0]): strings.SplitN(kv, "=", 2)[1]}}}
		if _server == "-" && _prev.suites != _|_ {suites: server: _prev.suites.server}
		if _cluster != "" {cluster: _cluster == "true"}
		if _cluster == "" && _prev.cluster != _|_ {cluster: _prev.cluster}
	}
}
files: _host.files
