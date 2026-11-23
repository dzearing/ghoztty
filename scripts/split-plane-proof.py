#!/usr/bin/env python3
"""Prove a T1775 plane move is a pure refactor (step 5 of the T299 method).

  python scripts/split-plane-proof.py <before.zig> <after-owner.zig> <plane.zig> [<plane.zig> ...]

Compares the BEFORE snapshot of the owner against the owner and its planes
AFTER the move:

1. the top-level `fn` signature set (name + parameter list, `pub` ignored)
   must be identical;
2. the multiset of non-comment, non-blank code lines must differ only by the
   mechanical shapes: a `pub` marker, a static qualified with its owning file
   (`Owner.x`), or a line the split itself adds (a plane import, a
   `const f = plane.f;` / `const X = Owner.X;` alias, an import block the
   plane re-declares, the `const testing = std.testing;` a plane's tests need).

Exit 0 and `PROOF OK` when every difference is one of those; exit 1 and the
residual lines otherwise. A residual is not necessarily a bug, but it is a
line somebody must read.
"""
import re
import sys
from collections import Counter
from pathlib import Path

FN = re.compile(r'^(?:pub )?fn ([A-Za-z_][A-Za-z0-9_]*)\(')


def code_lines(path: Path):
    out = []
    for l in path.read_text(encoding='utf-8').split('\n'):
        s = l.strip()
        if not s or s.startswith('//'):
            continue
        out.append(s)
    return out


def signatures(path: Path):
    lines = path.read_text(encoding='utf-8').split('\n')
    sigs = Counter()
    for i, l in enumerate(lines):
        m = FN.match(l)
        if not m:
            continue
        # gather the parameter list up to the line holding the body brace
        sig = l
        j = i
        while '{' not in sig and j + 1 < len(lines):
            j += 1
            sig += ' ' + lines[j].strip()
        sig = re.sub(r'^pub ', '', sig)
        sig = re.sub(r'\s+', ' ', sig.split('{')[0]).strip()
        sigs[sig] += 1
    return sigs


def normalize(s: str, owner: str) -> str:
    s = re.sub(r'^pub ', '', s)
    if '@import(' in s:
        return s  # the owner's file name is a string here, not a qualifier
    s = re.sub(r'(?<![A-Za-z0-9_])' + owner + r'\.(?=[a-z_A-Z])', '', s)
    return s


def main() -> int:
    before, after, planes = Path(sys.argv[1]), Path(sys.argv[2]), [Path(p) for p in sys.argv[3:]]
    owner = after.stem
    plane_stems = [p.stem for p in planes]

    sb = signatures(before)
    sa = signatures(after)
    for p in planes:
        sa += signatures(p)
    ok = True
    if sb != sa:
        ok = False
        print('SIGNATURES DIFFER')
        for s in sorted((sb - sa).elements()):
            print('  only before:', s)
        for s in sorted((sa - sb).elements()):
            print('  only after: ', s)
    else:
        print(f'signatures identical ({sum(sb.values())} top-level fns)')

    cb = Counter(normalize(s, owner) for s in code_lines(before))
    ca = Counter()
    for p in [after] + planes:
        ca.update(normalize(s, owner) for s in code_lines(p))

    imports_before = {s for s in cb if '@import(' in s and s.endswith(';')}

    def added_by_split(s: str) -> bool:
        if s in imports_before:
            return True  # a plane re-declaring the owner's import block
        if re.fullmatch(r'const [A-Za-z_]\w* = @import\("(' + '|'.join(map(re.escape, [f'{x}.zig' for x in plane_stems + [owner]])) + r')"\);', s):
            return True
        if re.fullmatch(r'const ([A-Za-z_]\w*) = [A-Za-z_]\w*\.\1;', s):
            return True  # an alias, either direction (Owner. already stripped)
        if s == 'const testing = std.testing;':
            return True
        return False

    extra_after = ca - cb
    extra_before = cb - ca
    residual_after = Counter({s: n for s, n in extra_after.items() if not added_by_split(s)})
    # an alias line normalizes to `const X = X;` once `Owner.` is stripped
    residual_after = Counter({s: n for s, n in residual_after.items()
                              if not re.fullmatch(r'const ([A-Za-z_]\w*) = \1;', s)})
    if residual_after or extra_before:
        ok = False
        print('CODE LINES DIFFER beyond the mechanical shapes')
        for s, n in sorted(extra_before.items()):
            print(f'  only before x{n}: {s}')
        for s, n in sorted(residual_after.items()):
            print(f'  only after  x{n}: {s}')
    else:
        print(f'code lines: {sum(cb.values())} before, every difference mechanical '
              f'({sum(extra_after.values())} split-added lines)')

    print('PROOF OK' if ok else 'PROOF FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
