#!/usr/bin/env python3
"""render-digest.py - render the weekly "shipped this week" markdown body.

stdin: TSV rows  pkg<TAB>tag<TAB>published_at<TAB>html_url<TAB>kind(first|update)
argv:  [1] week label (e.g. 2026-W35)  [2] since timestamp (ISO)
"""
import sys
import datetime

rows = [l.split("\t") for l in sys.stdin.read().splitlines() if l.strip()]
week, since = sys.argv[1], sys.argv[2]

new = [r for r in rows if len(r) >= 5 and r[4] == "first"]
upd = [r for r in rows if len(r) >= 5 and r[4] != "first"]


def when(iso):
    return datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).strftime("%a %H:%M UTC")


out = [f"# Shipped this week ({week})\n",
       f"{len(rows)} versions across {len(set(r[0] for r in rows))} tools, "
       f"published since {since}.\n"]
if new:
    out.append("\n## 🎉 New in the catalog\n\n| Tool | Version | When |\n|---|---|---|\n")
    for r in sorted(new, key=lambda x: x[0]):
        out.append(f"| [{r[0]}]({r[3].rsplit('/', 1)[0]}) | `{r[1]}` | {when(r[2])} |\n")
if upd:
    out.append("\n## ⬆️ Updated\n\n| Tool | Version | When |\n|---|---|---|\n")
    for r in sorted(upd, key=lambda x: (x[0], x[1])):
        out.append(f"| {r[0]} | [`{r[1]}`]({r[3]}) | {when(r[2])} |\n")
out.append("\n---\n\nSubscribe to automatic updates: "
           "`https://github.com/latest-debs/apt-repo/issues.atom` "
           "(filter label: weekly-digest)\n")
out.append("\nInstall: `sudo extrepo enable latest-debs` — docs at https://latest-debs.github.io/\n")
sys.stdout.write("".join(out))
