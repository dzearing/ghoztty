#!/usr/bin/env python3
"""Move line ranges of a win32 owner file into a method-call plane (T1775).

The mechanical half of the T299/T1013 split method, so each plane child of
T1775 moves code the same way instead of by hand:

  python scripts/split-plane.py <owner.zig> <plane.zig> <alias> START-END [START-END ...]

- the ranges (1-based, inclusive) are cut out of the owner and written, in
  order, to the plane after a header that re-imports the owner's import block
  and `const Owner = @import("Owner.zig");`;
- every top-level `fn`/`const` moved becomes `pub`;
- every owner top-level name the moved code uses is aliased in the plane
  (`const X = Owner.X;`) and marked `pub` in the owner; owner `var`s are not
  aliased (a comptime alias of a runtime var does not compile) but qualified
  as `Owner.x` at each use instead;
- the owner gets `pub const f = <alias>.f;` for every moved name, inserted
  under a `// Split modules (T1775)` banner (created on first use).

It does not judge anything: compile, then prove the split with
`split-plane-proof.py` (signature set + code-line multiset).
"""
import re
import sys
from pathlib import Path

DECL = re.compile(r'^(pub )?(fn|const|var|threadlocal var) ([A-Za-z_][A-Za-z0-9_]*)')
IDENT = re.compile(r'(?<![A-Za-z0-9_.@])([A-Za-z_][A-Za-z0-9_]*)\b')
BANNER = '// Split modules (T1775)'


def strip_strings_comments(line: str) -> str:
    line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
    line = re.sub(r"'(?:\\.|[^'\\])*'", "''", line)
    i = line.find('//')
    return line if i < 0 else line[:i]


def main() -> int:
    owner_path, plane_path, alias = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    ranges = []
    for r in sys.argv[4:]:
        a, b = r.split('-')
        ranges.append((int(a), int(b)))
    owner_name = owner_path.stem
    lines = owner_path.read_text(encoding='utf-8').split('\n')
    moved_idx = set()
    for a, b in ranges:
        moved_idx.update(range(a - 1, b))

    moved = [lines[i] for i in sorted(moved_idx)]
    kept = [(i, l) for i, l in enumerate(lines) if i not in moved_idx]

    # Top-level declarations (column 0) on each side.
    def decls(src):
        out = {}
        for i, l in src:
            m = DECL.match(l)
            if m:
                out[m.group(3)] = (i, m.group(2), bool(m.group(1)), l)
        return out

    moved_decls = decls([(i, lines[i]) for i in sorted(moved_idx)])
    owner_decls = decls(kept)
    imports = [l for _, l in kept if DECL.match(l) and '@import(' in l and l.rstrip().endswith(';')]
    import_names = {DECL.match(l).group(3) for l in imports}

    used = set()
    for l in moved:
        for m in IDENT.finditer(strip_strings_comments(l)):
            used.add(m.group(1))
    need = sorted(n for n in used if n in owner_decls and n not in moved_decls
                  and n not in import_names and n != owner_name)
    owner_vars = {n for n in need if 'var' in owner_decls[n][1]}
    need_alias = [n for n in need if n not in owner_vars]

    # Plane body: pub-ify moved top-level decls, qualify owner vars.
    body = []
    for l in moved:
        m = DECL.match(l)
        if m and not m.group(1):
            l = 'pub ' + l
        if owner_vars:
            code = l
            for v in owner_vars:
                code = re.sub(r'(?<![A-Za-z0-9_.])' + v + r'\b', f'{owner_name}.{v}', code)
            l = code
        body.append(l)

    header = [
        f'const {owner_name} = @import("{owner_path.name}");',
        '',
    ] + [l for l in imports if f'"{plane_path.name}"' not in l]
    if need_alias:
        header += [''] + [f'const {n} = {owner_name}.{n};' for n in need_alias]
    plane_text = '\n'.join(header + [''] + body).rstrip() + '\n'

    # Owner: pub-ify what the plane needs, drop the moved lines, add aliases.
    out = []
    # Owner methods the moved code calls as `self.f(...)`: method syntax
    # across files needs the decl to be `pub`, but no alias.
    methods = set()
    for l in moved:
        for m in re.finditer(r'\bself\.([A-Za-z_][A-Za-z0-9_]*)\(', strip_strings_comments(l)):
            n = m.group(1)
            if n in owner_decls and owner_decls[n][1] == 'fn' and n not in moved_decls:
                methods.add(n)
    pubify = set(need) | methods
    for i, l in kept:
        m = DECL.match(l)
        if m and m.group(3) in pubify and not m.group(1):
            l = 'pub ' + l
        out.append(l)
    alias_lines = [f'pub const {n} = {alias}.{n};' for n in moved_decls]
    import_line = f'const {alias} = @import("{plane_path.name}");'
    END = '// (end of split modules)'
    if END in out:
        e = out.index(END)
        out[e:e] = [import_line] + alias_lines + ['']
    else:
        # after the `const log = ...` line that ends the import block
        li = next(i for i, l in enumerate(out) if re.match(r'(pub )?const log = ', l))
        block = [
            '',
            '// -------------------------------------------------------------------------',
            BANNER,
            '// -------------------------------------------------------------------------',
            '//',
            '// This file is the pane: its state, construction, and window procedure.',
            '// The planes below used to live inline here; each is imported back as',
            '// method-call aliases so every `self.f(x)` call site reads as it always',
            '// did. The aliases are the planes\' public surface: a function the pane',
            '// calls is a function a plane promised, listed here in one place.',
            '',
            import_line,
        ] + alias_lines + ['', END]
        out[li + 1:li + 1] = block

    owner_path.write_text('\n'.join(out), encoding='utf-8', newline='\n')
    plane_path.write_text(plane_text, encoding='utf-8', newline='\n')
    print(f'moved {len(moved)} lines, {len(moved_decls)} decls -> {plane_path}')
    print(f'owner names made pub: {", ".join(sorted(pubify)) or "(none)"}')
    print(f'owner vars qualified: {", ".join(sorted(owner_vars)) or "(none)"}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
