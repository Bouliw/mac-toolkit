#!/usr/bin/python3
# Disables SwiftUI #Preview blocks (their macro only ships with Xcode) in every .swift file of the
# given folders, by wrapping them in "#if false … #endif".
# Usage: no_previews.py <folder> [folder…]
import pathlib
import re
import sys

PREVIEW = re.compile(r'^[ \t]*#Preview\b', re.M)


def disable(text):
    out, i, n, count = [], 0, len(text), 0
    while True:
        m = PREVIEW.search(text, i)
        if not m:
            out.append(text[i:])
            break
        out.append(text[i:m.start()])
        k = text.index('{', m.end())
        depth, in_string = 0, False
        while k < n:
            c = text[k]
            if c == '"' and text[k - 1] != '\\':
                in_string = not in_string
            elif not in_string:
                if c == '{':
                    depth += 1
                elif c == '}':
                    depth -= 1
                    if depth == 0:
                        break
            k += 1
        out.append('#if false\n' + text[m.start():k + 1] + '\n#endif')
        i = k + 1
        count += 1
    return ''.join(out), count


total = 0
for root in sys.argv[1:]:
    for path in pathlib.Path(root).rglob('*.swift'):
        if '/.build/' in str(path):
            continue
        text = path.read_text()
        if '#Preview' in text:
            new, count = disable(text)
            if count:
                path.write_text(new)
                total += count
print('previews disabled:', total)
