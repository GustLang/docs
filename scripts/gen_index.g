"""Build the stdlib index page (`stdlib/index.mdx`) from per-package
descriptions.

The companion to `gen_docs.sh`. That script compiles each stdlib package in
isolation (packages define colliding private helpers, so they can't share one
program) and drops each package's one-line description into a directory of
plain-text files named `<pkg>` (dotted for subpackages, e.g.
`cryptography.random`). This program reads that directory and renders the
themed package listing — it imports no documented package itself, so it is
collision-free.

Environment:
  GUST_DOCS_ROOT   output root (the index lands at <root>/stdlib/index.mdx)
  GUST_DESC_DIR    directory of `<pkg>` description files written by the shell
"""


use autodoc
use Buffer, new_buffer from buffer
use fs
use env from os


def find_desc(names: list[string], descs: list[string], pkg: string) -> string
    """The recorded description for `pkg`, or "" if it wasn't generated."""
    for i in range(names.length)
        if names[i] == pkg
            return descs[i]
        end
    end
    return ""
end


def render_group(
    buf: Buffer,
    names: list[string],
    descs: list[string],
    title: string,
    pkgs: list[string],
) -> none
    """Append one themed index table — `## title` then a Package/Description row
    per member of `pkgs` that was actually generated. Skips empty groups.
    """
    present: list[string] = []
    for i in range(pkgs.length)
        if pkgs[i] in names
            present.append(pkgs[i])
        end
    end
    if present.length == 0
        return
    end
    buf.append("## ")
    buf.append(title)
    buf.append("\n\n| Package | Description |\n|---------|-------------|\n")
    for i in range(present.length)
        p := present[i]
        buf.append("| [`")
        buf.append(p)
        buf.append("`](/stdlib/")
        buf.append(p.replace(".", "/"))
        buf.append(") | ")
        buf.append(find_desc(names, descs, p))
        buf.append(" |\n")
    end
    buf.append("\n")
end


def build_namespace_page(
    names: list[string],
    descs: list[string],
    slug: string,
    blurb: string,
    subpkgs: list[string],
) -> string
    """A landing page for a pure-namespace package (one that groups subpackages
    but exports no symbols of its own, e.g. `cryptography` / `cli`). Serves as
    the `root` a nested navigation group opens to: frontmatter, the `blurb`, and
    a table linking each subpackage that was actually generated.
    """
    buf := new_buffer()
    buf.append(autodoc.frontmatter(slug, blurb))
    buf.append(blurb)
    buf.append("\n\n")
    render_group(buf, names, descs, "Packages", subpkgs)
    return buf.to_string().trim() + "\n"
end


def build_index(names: list[string], descs: list[string]) -> string
    """The `stdlib/index.mdx` landing page: frontmatter, an importing example,
    and the package tables grouped by theme. Only generated packages appear.
    """
    buf := new_buffer()
    buf.append(
        autodoc.frontmatter(
            "Standard library",
            "Gust's batteries-included standard library — importable packages plus the built-in type methods",
        ),
    )
    buf.append(
        "Each package is a `.g` declaration file paired with a C implementation that links into your binary automatically. Import with `use <pkg>`; members are accessed as `pkg.name`. The [Builtins](/builtins/prelude) section covers the prelude and the methods on the built-in types.\n\n",
    )
    buf.append(
        "## Importing\n\n```gust\nuse math\nuse time\n\ndef main() -> none\n    print(math.sqrt(2.0))\n    print((time.now() as integer))\nend\n```\n\n",
    )
    render_group(buf, names, descs, "Core", ["math", "convert", "time", "uuid"])
    render_group(
        buf,
        names,
        descs,
        "System",
        ["os", "fs", "exitcode", "signal", "profile", "mmap", "ioctl", "dl"],
    )
    render_group(
        buf,
        names,
        descs,
        "Text & data",
        ["regex", "highlight", "url", "buffer", "hashmap", "ansi", "mime"],
    )
    render_group(
        buf,
        names,
        descs,
        "Serialization",
        ["json", "toml", "yaml", "xml", "csv", "compression"],
    )
    render_group(
        buf,
        names,
        descs,
        "Cryptography",
        [
            "cryptography.sha",
            "cryptography.hmac",
            "cryptography.kdf",
            "cryptography.random",
            "cryptography.aes",
            "cryptography.bcrypt",
            "cryptography.ed25519",
            "cryptography.x25519",
            "cryptography.ssl",
        ],
    )
    render_group(buf, names, descs, "Networking", ["socket", "websockets", "http"])
    render_group(
        buf,
        names,
        descs,
        "Database",
        ["database", "database.sqlite", "database.postgres"],
    )
    render_group(
        buf,
        names,
        descs,
        "Interaction & media",
        ["cli.app", "cli.ui", "images", "barcode"],
    )
    render_group(
        buf,
        names,
        descs,
        "Embedded",
        [
            "i2c",
            "spi",
            "cec",
            "pin",
            "framebuffer",
            "drm",
            "wifi",
            "bluetooth",
            "usb",
            "usb.device",
            "drivers.sht41",
        ],
    )
    render_group(
        buf,
        names,
        descs,
        "Metaprogramming",
        ["ast", "derive", "imports", "inspect", "autodoc"],
    )
    render_group(buf, names, descs, "Debugging", ["trace"])
    render_group(buf, names, descs, "Testing", ["testing"])
    return buf.to_string().trim() + "\n"
end


def main() -> none
    """Read the description directory and write the themed index page."""
    docs_root := env("GUST_DOCS_ROOT")
    if docs_root == ""
        docs_root = "docs"
    end
    desc_dir := env("GUST_DESC_DIR")
    if desc_dir == ""
        print(
            "error: set GUST_DESC_DIR to the directory of per-package description files",
        )
        return
    end
    names: list[string] = []
    descs: list[string] = []
    for name in fs.list_dir(desc_dir)
        names.append(name)
        descs.append(fs.read_file(desc_dir + "/" + name).trim())
    end
    fs.write_file(docs_root + "/stdlib/index.mdx", build_index(names, descs))

    # Landing pages for the pure-namespace parents (cryptography, cli). These
    # export no symbols, so `gen_docs.sh` produces no page for them; each is the
    # `root` its nested sidebar group opens to.
    fs.write_file(
        docs_root + "/stdlib/cryptography.mdx",
        build_namespace_page(
            names,
            descs,
            "cryptography",
            "Cryptographic primitives grouped into focused subpackages — hashing, message authentication, key derivation, random generation, symmetric and public-key encryption, and TLS.",
            [
                "cryptography.sha",
                "cryptography.hmac",
                "cryptography.kdf",
                "cryptography.random",
                "cryptography.aes",
                "cryptography.bcrypt",
                "cryptography.ed25519",
                "cryptography.x25519",
                "cryptography.ssl",
            ],
        ),
    )
    fs.write_file(
        docs_root + "/stdlib/cli.mdx",
        build_namespace_page(
            names,
            descs,
            "cli",
            "Command-line application tooling, split into argument parsing and command dispatch (`cli.app`) and interactive prompts and terminal rendering (`cli.ui`).",
            ["cli.app", "cli.ui"],
        ),
    )
    print(f"generated stdlib/index.mdx ({names.length} packages)")
end
