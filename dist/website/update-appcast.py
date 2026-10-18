#!/usr/bin/env python3
"""Write (or replace) one release's entry in the Sparkle appcast (T1089).

This was inline in `.github/workflows/release.yml` until T1089 moved it here,
beside its Windows twin `update-windows-links.py`, so the gh-pages publish
that calls it (`publish-appcast.sh`) can be run against a local repo by
test\\win32\\website-windows-download.ps1 section H instead of only by a real
release.

Usage:
    update-appcast.py <appcast.xml> <X.Y.Z> <download-url> <ed-signature>
                      <length> <pub-date> [client-notes.json]

Idempotent: a re-run (or a dispatch re-release) REPLACES this version's
entry, never appends a second one. A rebuilt DMG has a new signature and
length, so the newest write is the correct one.

Exit codes: 0 written. 1 the appcast could not be read or has no <channel>.
2 called wrong.
"""

import os
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.net/xml-namespaces/sparkle"


def main(argv):
    if len(argv) not in (7, 8):
        print(
            "usage: update-appcast.py <appcast.xml> <X.Y.Z> <download-url> "
            "<ed-signature> <length> <pub-date> [client-notes.json]",
            file=sys.stderr,
        )
        return 2

    path, version, url, sig, length, pub_date = argv[1:7]
    client_notes_path = argv[7] if len(argv) == 8 else ""

    ET.register_namespace("sparkle", SPARKLE)
    ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")

    try:
        tree = ET.parse(path)
    except (OSError, ET.ParseError) as e:
        print(f"::error::cannot read appcast {path}: {e}", file=sys.stderr)
        return 1
    channel = tree.find("channel")
    if channel is None:
        print(f"::error::appcast {path} has no <channel>", file=sys.stderr)
        return 1

    for existing in channel.findall("item"):
        v = existing.find("{%s}version" % SPARKLE)
        if v is not None and (v.text or "").strip() == version:
            channel.remove(existing)

    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Version {version}"
    ET.SubElement(item, "{%s}version" % SPARKLE).text = version
    ET.SubElement(item, "{%s}shortVersionString" % SPARKLE).text = version
    ET.SubElement(item, "pubDate").text = pub_date

    if client_notes_path and os.path.isfile(client_notes_path):
        with open(client_notes_path, "r", encoding="utf-8") as f:
            ET.SubElement(item, "description").text = f.read()

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", url)
    enclosure.set("type", "application/octet-stream")
    enclosure.set("{%s}edSignature" % SPARKLE, sig)
    enclosure.set("length", length)

    ET.indent(tree, space="    ")
    tree.write(path, xml_declaration=True, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
