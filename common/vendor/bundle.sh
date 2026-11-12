#!/bin/sh
# Makes postgres.js beside it: the Postgres client (postgres.js 3.4.7, Unlicense) as one file, so each
# broker (identity's and billing's, each a link at broker/vendor/postgres.js), which runs from files in
# a ConfigMap and imports nothing from the network at start, can reach its database. Run it to change the version; the bytes committed are the ones the broker runs.
# (The bundler's comments name the machine's cache path; they are dropped so the file is the same anywhere.)
set -eu
cd "$(dirname "$0")"
deno bundle --platform=deno npm:postgres@3.4.7 -o postgres.js
sed -i.bak "/^\/\/ \.\.\/.*registry\.npmjs\.org/d" postgres.js && rm postgres.js.bak
# Another's code, kept as the bundler wrote it: not held to this repository's lint.
{ printf '// deno-lint-ignore-file\n'; cat postgres.js; } > postgres.js.new && mv postgres.js.new postgres.js
