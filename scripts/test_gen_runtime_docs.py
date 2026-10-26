"""Run with: python3 -m unittest discover -s docs/scripts -p 'test_*.py'."""

from pathlib import Path
import tempfile
import unittest

from gen_runtime_docs import parse_source, prose, render


class RuntimeDocsTests(unittest.TestCase):
    def test_definitions_ignore_bodies_macros_and_declarations(self):
        source = '''/* Copyright Example */
/* example.c — Overview. */
#define BODY(x) { \\
    x; }
extern void declared(void);
static void hidden(void) { }
/* Callback with a function-pointer argument. */
__attribute__((noinline))
void exported(void (*callback)(int),
              const char* text) {
    const char* braces = "} {";
    /* A body comment must not describe the next function. */
    if (callback) { callback(1); }
}
void next(void) { }
struct Example { int field; };
int values[] = {1, 2};
'''
        overview, functions = parse_source(source, "example.c")
        self.assertEqual(overview, "example.c — Overview.")
        self.assertEqual([f[0] for f in functions], ["exported", "next"])
        self.assertIn("void (*callback)(int)", functions[0][1])
        self.assertEqual(functions[0][2], "Callback with a function-pointer argument.")
        self.assertEqual(functions[1][2], "")
        self.assertTrue(source.splitlines()[functions[0][3] - 1].startswith("__attribute__"))

    def test_license_is_not_function_documentation(self):
        _, functions = parse_source('''/* Copyright Example */
/* example.c — Overview. */
#include "runtime.h"
void first(void) { }
''', "example.c")
        self.assertEqual(functions[0][2], "")

    def test_variants_and_source_links(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            (runtime / "example.c").write_text('''/* example.c — Overview. */
#ifdef TARGET
/* Target-specific variant. */
void example(void) { }
#else
/* Fallback variant. */
void example(void) { }
#endif
''')
            page = render(runtime, "https://example.com/repo/blob/main/")
            self.assertEqual(page.count("### example\n"), 1)
            self.assertEqual(page.count("```c\nvoid example(void);\n```"), 1)
            self.assertIn("Target-specific variant.", page)
            self.assertIn("Fallback variant.", page)
            self.assertNotIn("**Compiled when:**", page)
            self.assertNotIn("**Variant condition:**", page)
            self.assertIn("/runtime/example.c#L4)", page)
            self.assertIn("/runtime/example.c#L7)", page)
            self.assertEqual(page, render(runtime, "https://example.com/repo/blob/main/"))

    def test_single_signature_has_no_condition_labels(self):
        sources = [
            '''#ifndef __SANITIZE_ADDRESS__
/* Begin a new arena window. */
void example(void) { }
#else
void example(void) { }
#endif
''',
            '''#ifdef TARGET
/* Only one definition. */
void example(void) { }
#endif
''',
        ]
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            for source in sources:
                with self.subTest(source=source):
                    (runtime / "example.c").write_text(source)
                    for source_base in ("", "https://example.com/repo/"):
                        page = render(runtime, source_base)
                        self.assertEqual(page.count("```c\nvoid example(void);\n```"), 1)
                        self.assertNotIn("**Compiled when:**", page)
                        self.assertNotIn("**Variant condition:**", page)

    def test_duplicate_signatures_keep_unique_comments_and_distinct_signatures(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            (runtime / "example.c").write_text('''/* example.c — Overview. */
#ifdef TARGET
/* Begin a new arena window. */
void example(void) { }
#elif FALLBACK
void example(void) { }
#elif OTHER
/* Begin a new arena window. */
void example(void) { }
#else
/* Accept a target-specific argument. */
void example(int target) { }
#endif
''')
            page = render(runtime)
            self.assertEqual(page.count("```c\nvoid example(void);\n```"), 1)
            self.assertEqual(page.count("Begin a new arena window."), 1)
            self.assertEqual(page.count("```c\nvoid example(int target);\n```"), 1)
            self.assertIn("Accept a target-specific argument.", page)
            self.assertIn("**Compiled when:** `!defined(TARGET) && !(FALLBACK) && !(OTHER)`.", page)

    def test_nested_conditions_elif_exclusions_and_multiline_directives(self):
        _, functions = parse_source('''/* example.c — Overview. */
#ifndef DISABLED
#if defined(__linux__) && \\
    defined(FEATURE)
void first(void) {
#ifdef BODY_ONLY
    return;
#endif
}
#elif defined(_WIN32) /* Windows branch */
void second(int flag) { }
#else
void third(void) { }
#endif
#endif
void unconditional(void) { }
''', "example.c")
        conditions = {name: condition for name, _, _, _, condition in functions}
        self.assertEqual(conditions["first"],
                         "(!defined(DISABLED)) && (defined(__linux__) && defined(FEATURE))")
        self.assertEqual(conditions["second"],
                         "(!defined(DISABLED)) && (!(defined(__linux__) && defined(FEATURE)) && (defined(_WIN32)))")
        self.assertEqual(conditions["third"],
                         "(!defined(DISABLED)) && (!(defined(__linux__) && defined(FEATURE)) && !defined(_WIN32))")
        self.assertEqual(conditions["unconditional"], "")
        self.assertNotIn("BODY_ONLY", conditions["first"])

    def test_mdx_escaping_preserves_code(self):
        self.assertEqual(prose("Use {ptr} < 2 & `GClosure*`"),
                         "Use &#123;ptr&#125; &lt; 2 &amp; `GClosure*`")
        self.assertEqual(prose("```c\nif (x < 2) { }\n```"),
                         "```c\nif (x < 2) { }\n```")

    def test_missing_runtime_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "no C sources"):
                render(Path(directory))


if __name__ == "__main__":
    unittest.main()
