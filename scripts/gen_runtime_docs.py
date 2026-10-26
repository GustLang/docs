#!/usr/bin/env python3
"""Generate lang/runtime.mdx from runtime/*.c comments and definitions.

Run directly with Python 3, or through gen_docs.sh. GUST_ROOT defaults to the
sibling gust tree; GUST_DOCS_ROOT overrides the output directory. Set
GUST_SOURCE_BASE to a repository URL ending in / to include source links.

This is a source inventory, not a C preprocessor or an ABI specification:
all conditional branches are included, static helpers and declarations are
excluded, and header-only / Gust-authored functions are outside its scope.
Enclosing preprocessor conditions are reported without evaluating macros.
Edit the C comments, not the generated MDX. No third-party packages required.
"""

import argparse
import json
import os
from pathlib import Path
import re
import textwrap


# Consume strings, comments and entire preprocessor directives as units so
# braces in them cannot change the top-level definition scanner's depth.
TOKEN = re.compile(
    r"(?P<directive>^[ \t]*\#(?:[^\n\\]|\\[^\n]|\\\n)*)(?:\n|$)"
    r"|(?P<comment>/\*[\s\S]*?\*/|//[^\n]*)"
    r'|(?P<string>"(?:\\[\s\S]|[^"\\])*"|\'(?:\\[\s\S]|[^\'\\])*\')'
    r"|(?P<word>[A-Za-z_]\w*)|(?P<symbol>[^\s])",
    re.MULTILINE,
)


def comment_text(raw):
    if raw.startswith("//"):
        return raw[2:].strip()
    lines = [re.sub(r"^\s*\* ?", "", line) for line in raw[2:-2].splitlines()]
    return textwrap.dedent("\n".join(lines)).strip()


def negate_condition(expression):
    if re.fullmatch(r"!?defined\(\w+\)", expression):
        return expression[1:] if expression.startswith("!") else "!" + expression
    return f"!({expression})"


def update_conditions(stack, directive):
    """Track branch predicates, including the branches an elif/else excludes."""
    directive = re.sub(r"\\\r?\n", " ", directive)
    directive = re.sub(r"/\*[\s\S]*?\*/|//[^\n]*", " ", directive)
    match = re.match(r"\s*#\s*(\w+)\b(.*)", directive, flags=re.S)
    if not match:
        return
    command, expression = match.groups()
    expression = " ".join(expression.split())
    if command in ("if", "ifdef", "ifndef"):
        if command == "ifdef":
            expression = f"defined({expression})"
        elif command == "ifndef":
            expression = f"!defined({expression})"
        stack.append({"previous": [expression], "active": expression})
    elif command in ("elif", "else") and stack:
        frame = stack[-1]
        terms = [negate_condition(branch) for branch in frame["previous"]]
        if command == "elif":
            terms.append(f"({expression})")
            frame["previous"].append(expression)
        frame["active"] = " && ".join(terms)
    elif command == "endif" and stack:
        stack.pop()


def compilation_condition(stack):
    terms = [frame["active"] for frame in stack]
    if len(terms) == 1:
        return terms[0]
    return " && ".join(f"({term})" for term in terms)


def parse_source(source, filename):
    """Return the file overview and non-static top-level function definitions.

    Keep offsets for optional source links. Only comments directly before a
    definition describe it; comments in a body never leak to the next function.
    """
    overview = ""
    functions = []
    pending = []
    parts = []
    depth = 0
    conditions = []
    for token in TOKEN.finditer(source):
        kind, value = token.lastgroup, token.group()
        if kind == "directive":
            update_conditions(conditions, value)
            continue
        if kind == "comment":
            if depth == 0:
                doc = comment_text(value)
                if not overview and doc.startswith(filename):
                    overview = doc
                    pending = []
                elif not parts:
                    pending.append(doc)
            continue
        if value == "{":
            if depth == 0:
                words = [part.group() for part in parts]
                # Find an outermost call-shaped declarator, skipping compiler
                # attributes. Parentheses inside function-pointer parameters
                # are deliberately not candidates.
                parens = 0
                name = None
                for i, word in enumerate(words):
                    if word == "(":
                        if parens == 0 and i and re.fullmatch(r"[A-Za-z_]\w*", words[i - 1]):
                            if words[i - 1] not in ("__attribute__", "__declspec"):
                                name = words[i - 1]
                        parens += 1
                    elif word == ")":
                        parens -= 1
                if name and "static" not in words and "typedef" not in words and "=" not in words:
                    start = parts[0].start()
                    signature = source[start:token.start()]
                    signature = re.sub(r"/\*[\s\S]*?\*/|//[^\n]*", " ", signature)
                    signature = re.sub(r"^[ \t]*#(?:[^\n\\]|\\[^\n]|\\\n)*", "", signature, flags=re.M)
                    functions.append((name, " ".join(signature.split()) + ";",
                                      "\n\n".join(pending), source.count("\n", 0, start) + 1,
                                      compilation_condition(conditions)))
                parts, pending = [], []
            depth += 1
        elif value == "}":
            depth -= 1
            if depth == 0:
                parts, pending = [], []
        elif depth == 0:
            if value == ";":
                parts, pending = [], []
            else:
                parts.append(token)
    return overview, functions


def prose(text):
    """Render plain C comments safely in MDX, retaining code and indentation."""
    lines = []
    fenced = False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fenced = not fenced
            lines.append(line)
        elif fenced:
            lines.append(line)
        else:
            spans = re.split(r"(`+[^`]*`+)", line)
            for i in range(0, len(spans), 2):
                spans[i] = (spans[i].replace("&", "&amp;").replace("<", "&lt;")
                            .replace("{", "&#123;").replace("}", "&#125;"))
            lines.append("".join(spans))
    return "\n".join(lines)


def render(runtime, source_base=""):
    paths = sorted(runtime.glob("*.c"))
    if not paths:
        raise ValueError(f"no C sources found in {runtime}")
    out = ["---", "title: C runtime reference",
           "description: " + json.dumps("Source comments and exported function definitions from Gust's C runtime."),
           "---", "", "{/* Generated by scripts/gen_runtime_docs.py. Edit runtime/*.c instead. */}", "",
           "Use this reference when you write C that calls into Gust's runtime. "
           "Start with [C interop](/lang/ffi-c) for type mappings and ownership rules.", "",
           "This page lists file descriptions and non-static function definitions from "
           "`runtime/*.c`. It includes every conditional compilation branch, so a listed "
           "function may be unavailable on your target. Each distinct signature appears "
           "once, with comments from its platform variants. When a function has multiple "
           "distinct signatures, compilation conditions show "
           "the enclosing `#if`, `#ifdef`, and `#ifndef` branches, including exclusions "
           "for `#elif` and `#else`. Macro values are not evaluated; conditions inside "
           "function bodies do not change the listed signature. Check `g_runtime.h` for declarations and availability; "
           "header-only helpers and functions implemented in Gust are outside this inventory.", ""]
    for path in paths:
        overview, functions = parse_source(path.read_text(encoding="utf-8"), path.name)
        out += [f"## {path.name}", ""]
        if source_base:
            out += [f"[View source]({source_base.rstrip('/')}/runtime/{path.name})", ""]
        if overview:
            out += [prose(overview), ""]
        grouped = {}
        for name, signature, doc, line, condition in functions:
            variants = grouped.setdefault(name, {}).setdefault(signature, [])
            variants.append((doc, line, condition))
        for name, signatures in grouped.items():
            out += [f"### {name}", ""]
            for signature, variants in signatures.items():
                if len(signatures) > 1:
                    conditions = list(dict.fromkeys(condition for _, _, condition in variants))
                    label = " or ".join(f"`{condition}`" if condition else "unconditionally" for condition in conditions)
                    out += [f"**Compiled when:** {label}.", ""]
                out += ["```c", signature, "```", ""]
                by_doc = {}
                for doc, line, condition in variants:
                    by_doc.setdefault(doc, []).append((line, condition))
                for doc, definitions in by_doc.items():
                    if len(signatures) > 1 and len(by_doc) > 1 and (doc or source_base):
                        conditions = list(dict.fromkeys(condition for _, condition in definitions))
                        label = " or ".join(f"`{condition}`" if condition else "unconditionally" for condition in conditions)
                        out += [f"**Variant condition:** {label}.", ""]
                    for line, _ in definitions:
                        if source_base:
                            out += [f"[View definition]({source_base.rstrip('/')}/runtime/{path.name}#L{line})", ""]
                    if doc:
                        out += [prose(doc), ""]
        if not functions:
            out += ["This file has no non-static function definitions.", ""]
    return "\n".join(out).rstrip() + "\n"


def main():
    docs = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gust-root", type=Path,
                        default=Path(os.environ.get("GUST_ROOT", docs.parent / "gust")))
    parser.add_argument("--docs-root", type=Path,
                        default=Path(os.environ.get("GUST_DOCS_ROOT", docs)))
    args = parser.parse_args()
    try:
        content = render(args.gust_root / "runtime", os.environ.get("GUST_SOURCE_BASE", ""))
    except (OSError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")
    output = args.docs_root / "lang" / "runtime.mdx"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content, encoding="utf-8")
    print(f"generated {output}")


if __name__ == "__main__":
    main()
