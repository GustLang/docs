#!/usr/bin/env bash
#
# Generate the full Gust API reference: the importable stdlib package pages,
# the themed index, and the built-in type / prelude pages. This is the single
# entrypoint — running it regenerates everything under docs/stdlib and
# docs/builtins.
#
# Stdlib package pages use the compiler's own introspection instead of
# re-parsing source. For each package it compiles a tiny program that calls
# `inspect.entries(pkg)` and renders the result with `autodoc.package_page`
# (see stdlib/autodoc/mdx.g). A pass over the emitted descriptions then builds
# the themed index.
#
# Each package is compiled on its own: stdlib packages define colliding private
# helpers (e.g. several define `_hex_val` / `app`), so they cannot all be
# `use`d in one program. The per-package isolation sidesteps that.
#
# The built-in type pages (string / list / dict / …) and the prelude page are
# produced by the gen_api_docs.py pass at the end: they are bodyless doc-stubs
# outside any compiled program, so compile-time `inspect` can't see them.
# `wifi` is skipped: it is embedded-only and won't build for the host.
#
# Usage:
#   GUST_ROOT=/path/to/gust docs/scripts/gen_docs.sh
#   GUST_ROOT=... GUST_DOCS_ROOT=/path/to/docs docs/scripts/gen_docs.sh
#
# Set GUST_SOURCE_BASE to a repository URL prefix (e.g.
# https://github.com/GustLang/gust/blob/main/) to add a "View source" link to
# every declaration; leave it unset to omit source links.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCS="${GUST_DOCS_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [[ -z "${GUST_ROOT:-}" ]]; then
    echo "error: set GUST_ROOT to the gust tree (the dir holding stdlib/ and runtime/)" >&2
    exit 1
fi
GUST="${GUST:-$(command -v gust || true)}"
if [[ -z "$GUST" || ! -x "$GUST" ]]; then
    echo "error: 'gust' not found on PATH (set GUST=/path/to/gust)" >&2
    exit 1
fi

# Every importable, host-buildable stdlib package. Dotted names are
# subpackages: a parent like `cryptography` or `cli` is a pure namespace (no
# symbols of its own), so only its subpackages are documented (`cli.app` for
# argument parsing / dispatch, `cli.ui` for prompts + rendering); `database`
# has both a core package and driver subpackages. Excluded on purpose: `orm`
# (its `@model` derive is still WIP and does not compile standalone), `twmerge`,
# `wifi`, `pico`, and `requests` (embedded-only — they don't build for the
# host; hosted HTTP is `http.client`).
PKGS="ansi ast autodoc barcode bluetooth buffer compression convert csv database derive exitcode \
hashmap highlight http i2c images imports inspect json math mime os pin profile regex \
signal socket sync fs testing time toml unsafe url uuid websockets yaml \
cli.app cli.ui \
cryptography.aes cryptography.bcrypt cryptography.ed25519 cryptography.hmac \
cryptography.kdf cryptography.random cryptography.sha cryptography.ssl \
cryptography.x25519 database.postgres database.sqlite \
http.client http.server http.server.middleware"

mkdir -p "$DOCS/stdlib"
descdir="$(mktemp -d)"
gendir="$(mktemp -d)"
trap 'rm -rf "$descdir" "$gendir"' EXIT

echo "generating stdlib package pages -> $DOCS/stdlib/"
for pkg in $PKGS; do
    # A dotted package (cryptography.random) is `use`d by its full path and
    # aliased to its underscore form (`cryptography_random`), which inspect is
    # then called on. The alias avoids the case where the last segment collides
    # with a symbol inside the package (e.g. `cli.app` binds `app`, which is
    # also the parser constructor, so a bare `inspect.entries(app)` would resolve
    # the function). The page lands at a nested slug mirroring the import path;
    # the description file stays flat (dotted name, no slash) so gen_index.g can
    # list it from a single flat directory.
    slug="${pkg//.//}"
    if [[ "$pkg" == *.* ]]; then
        ref="${pkg//./_}"
        useline="use $pkg as $ref"
    else
        ref="$pkg"
        useline="use $pkg"
    fi
    out="$DOCS/stdlib/$slug.mdx"
    mkdir -p "$(dirname "$out")"
    cat > "$gendir/gen.g" <<EOF
use autodoc
use inspect
use fs
use env from os
$useline

def main() -> none
    doc := inspect.doc($ref)
    source_base := env("GUST_SOURCE_BASE")
    source_root := env("GUST_ROOT")
    fs.write_file("$out", autodoc.package_page("$pkg", doc, inspect.entries($ref), source_base, source_root))
    fs.write_file("$descdir/$pkg", autodoc.first_sentence(autodoc.strip_copyright(doc), "The $pkg package"))
end
EOF
    GUST_ROOT="$GUST_ROOT" GUST_SOURCE_BASE="${GUST_SOURCE_BASE:-}" "$GUST" run "$gendir/gen.g" >/dev/null
    echo "  stdlib/$slug"
done

GUST_ROOT="$GUST_ROOT" GUST_DOCS_ROOT="$DOCS" GUST_DESC_DIR="$descdir" \
    "$GUST" run "$SCRIPT_DIR/gen_index.g" >/dev/null
echo "  stdlib/index"

# Prune pages for packages that no longer exist in stdlib (e.g. a deleted
# package), so stale .mdx don't linger in the nav. The index is kept; a page
# whose stdlib/<slug>/ dir still exists is kept too (wifi is embedded-only —
# kept, just not regenerated on the host). A nested slug maps directly to its
# package dir (stdlib/cryptography/random -> $GUST_ROOT/stdlib/cryptography/random).
while IFS= read -r f; do
    slug="${f#"$DOCS"/stdlib/}"
    slug="${slug%.mdx}"
    [ "$slug" = "index" ] && continue
    if [ ! -d "$GUST_ROOT/stdlib/$slug" ]; then
        rm -f "$f"
        echo "  pruned stale stdlib/$slug (no such package)"
    fi
done < <(find "$DOCS/stdlib" -name '*.mdx')
# Drop any now-empty subpackage dirs left behind by pruning.
find "$DOCS/stdlib" -mindepth 1 -type d -empty -delete

# Built-in type pages + prelude: bodyless doc-stubs that compile-time `inspect`
# can't reach, so they come from the Python generator. It writes to
# <docs>/builtins relative to its own location; GUST_DOCS_ROOT does not retarget
# it (the stdlib pages above honor GUST_DOCS_ROOT, the builtins do not).
echo "generating built-in type + prelude pages -> $DOCS/builtins/"
GUST_ROOT="$GUST_ROOT" python3 "$SCRIPT_DIR/gen_api_docs.py"

# Rule reference: generated straight from the compiler's rule registry and
# formatter pass list via `gustc rules-doc`, so it never drifts from the code.
# A landing page with the summary tables plus one detail page per code class.
echo "generating rule reference -> $DOCS/rules/"
mkdir -p "$DOCS/rules"
GUST_ROOT="$GUST_ROOT" "$GUST" rules-doc           > "$DOCS/rules.mdx"
GUST_ROOT="$GUST_ROOT" "$GUST" rules-doc formatter  > "$DOCS/rules/formatter.mdx"
GUST_ROOT="$GUST_ROOT" "$GUST" rules-doc errors     > "$DOCS/rules/errors.mdx"
GUST_ROOT="$GUST_ROOT" "$GUST" rules-doc warnings   > "$DOCS/rules/warnings.mdx"
echo "  rules (+ formatter / errors / warnings)"

echo "done."
