#!/bin/sh
# build_peers.sh -- build the C/Rust/Go/OCaml/Java peers of the application
# workloads (SPEC.md) into bin/<w>.<lang>.  Run from anywhere.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
BIN="$HERE/bin"
WORKLOADS="csv wordfreq format records treemap sim"
mkdir -p "$BIN" "$BIN/ocaml-build" "$BIN/java-classes"

# OCaml: flambda is not available in this switch, so -O3 would be a no-op.
OCAMLFLAGS=""
if ocamlopt -config | grep -q '^flambda: true'; then OCAMLFLAGS="-O3"; fi

for w in $WORKLOADS; do
  W=$(printf '%s' "$w" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
  echo "== $w"
  cc -O2 -o "$BIN/$w.c" "c/$w.c"
  rustc -C opt-level=3 -o "$BIN/$w.rust" "rust/$w.rs"
  GO111MODULE=off go build -o "$BIN/$w.go" "go/$w.go"
  cp "ocaml/$w.ml" "$BIN/ocaml-build/$w.ml"
  (cd "$BIN/ocaml-build" && ocamlfind ocamlopt $OCAMLFLAGS -package unix -o "$BIN/$w.ocaml" "$w.ml")
  javac -d "$BIN/java-classes" "java/$W.java"
  cat > "$BIN/$w.java" <<WRAP
#!/bin/sh
exec java -cp "$BIN/java-classes" $W "\$@"
WRAP
  chmod +x "$BIN/$w.java"
done
echo "built into $BIN"
