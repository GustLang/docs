#!/usr/bin/env bash
#
# Generate the full Gust API reference: the importable stdlib package pages,
# the themed index, and the built-in type / prelude pages. This is the single
# entrypoint — running it regenerates everything under docs/stdlib and
# docs/builtins, plus the C runtime reference under docs/lang.
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
#
# Every package is compiled with `--doc-cfg`, which keeps the declarations
# conditional compilation excludes for the host instead of pruning them, each
# tagged with the targets it exists on. That is what puts the embedded-only
# packages (machine.*, wifi) and the device-only files inside otherwise portable
# ones (lvgl's ST7789 panel) on the docs site, each under an "Only available on
# …" callout, from one host build.
#
# Usage:
#   GUST_ROOT=/path/to/gust docs/scripts/gen_docs.sh
#   GUST_ROOT=... GUST_DOCS_ROOT=/path/to/docs docs/scripts/gen_docs.sh
#   GUST_ROOT=... docs/scripts/gen_docs.sh json toml      # named packages only
#   python3 docs/scripts/gen_runtime_docs.py            # C runtime only
#
# Naming one or more packages regenerates just those stdlib pages and stops:
# the themed index, the stale-page prune, the built-in / prelude pages, the
# C runtime, and the rule reference are all left untouched. Use it when a
# docstring changed in one package and a full run is not worth the wait.
#
# Run with no arguments to regenerate everything except the packages listed in
# SLOW_PKGS, which take long enough to compile that paying for them on every
# unrelated run is not worth it. Their existing pages are left in place (the
# prune keeps any page whose package still exists), so the site stays complete;
# name one explicitly to refresh it:
#
#   GUST_ROOT=... docs/scripts/gen_docs.sh lvgl
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
# has both a core package and driver subpackages. Embedded-only packages are
# documented too — `--doc-cfg` builds them for the host without their gates, and
# every page they produce carries the targets it is really available on.
# Excluded on purpose: `orm` (its `@model` derive is still WIP and does not
# compile standalone) and `twmerge`.
ALL_PKGS="ansi ast autodoc barcode bluetooth bluetooth.classic buffer cec compression convert csv database derive dl drivers.sht41 drm exitcode ffi \
fibers framebuffer hashmap highlight http i2c images imports inspect ioctl json lvgl math mime mmap os pin posix profile regex \
sdcard serial signal socket spi subprocess sync fs testing time trace toml unsafe url usb usb.device uuid websockets wifi yaml \
cli.app cli.ui gust.formatter \
machine.adc machine.clocks machine.dma machine.flash machine.interp \
machine.multicore machine.otp machine.pio machine.power machine.pwm machine.touch \
cryptography.aes cryptography.bcrypt cryptography.ed25519 cryptography.hmac \
cryptography.kdf cryptography.random cryptography.sha cryptography.ssl \
cryptography.x25519 database.postgres database.sqlite \
http.client http.server http.server.middleware"

# Packages a full run skips because they dominate its wall-clock time. They are
# still regenerated when named explicitly, and their pages survive the prune
# below, so skipping one never removes it from the site — it only leaves it at
# whatever the last run that named it produced. Regenerate one after editing
# its docstrings.
SLOW_PKGS="lvgl"

# Named packages restrict the run to their pages. Unknown names fail here
# rather than silently generating nothing.
if [[ $# -gt 0 ]]; then
    for pkg in "$@"; do
        case " $ALL_PKGS " in
            *" $pkg "*) ;;
            *)
                echo "error: unknown package '$pkg'" >&2
                echo "known packages:" >&2
                printf '  %s\n' $ALL_PKGS >&2
                exit 1
                ;;
        esac
    done
    PKGS="$*"
    SELECTED=1
else
    PKGS=""
    for pkg in $ALL_PKGS; do
        case " $SLOW_PKGS " in
            *" $pkg "*) ;;
            *) PKGS="$PKGS $pkg" ;;
        esac
    done
    SELECTED=0
    echo "skipping (name one to regenerate):$(printf ' %s' $SLOW_PKGS)"
fi

mkdir -p "$DOCS/stdlib"
descdir="$(mktemp -d)"
gendir="$(mktemp -d)"
trap 'rm -rf "$descdir" "$gendir"' EXIT

echo "generating stdlib package pages -> $DOCS/stdlib/"
for pkg in $PKGS; do
    # Every package is `use`d under a `pkg_`-prefixed alias, which inspect is
    # then called on. The alias avoids two collisions: with a symbol inside the
    # package (e.g. `cli.app` binds `app`, which is also the parser constructor,
    # so a bare `inspect.entries(app)` would resolve the function), and with the
    # fixed imports this program already makes (`use autodoc` for the package
    # named `autodoc` would be a duplicate import). The page lands at a nested
    # slug mirroring the import path; the description file stays flat (dotted
    # name, no slash) so gen_index.g can list it from a single flat directory.
    slug="${pkg//.//}"
    ref="pkg_${pkg//./_}"
    useline="use $pkg as $ref"
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
    GUST_ROOT="$GUST_ROOT" GUST_SOURCE_BASE="${GUST_SOURCE_BASE:-}" "$GUST" run --doc-cfg "$gendir/gen.g" >/dev/null
    echo "  stdlib/$slug"
done

# The index is rebuilt from the descriptions collected above, so a selective run
# has only the named packages to offer it and would drop every other entry.
# Everything past this point is whole-tree work a single package cannot affect.
if [[ $SELECTED -eq 1 ]]; then
    echo "done (index, builtins, runtime, and rule reference left untouched)."
    exit 0
fi

GUST_ROOT="$GUST_ROOT" GUST_DOCS_ROOT="$DOCS" GUST_DESC_DIR="$descdir" \
    "$GUST" run "$SCRIPT_DIR/gen_index.g" >/dev/null
echo "  stdlib/index"

# Prune pages for packages that no longer exist in stdlib (e.g. a deleted
# package), so stale .mdx don't linger in the nav. The index is kept, as is any
# page whose stdlib/<slug>/ dir still exists. A nested slug maps directly to its
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

# C runtime: file comments and exported definitions, without invoking a C
# compiler. You can also run this script directly to refresh only this page.
echo "generating C runtime reference -> $DOCS/lang/runtime.mdx"
GUST_ROOT="$GUST_ROOT" GUST_DOCS_ROOT="$DOCS" python3 "$SCRIPT_DIR/gen_runtime_docs.py"

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
