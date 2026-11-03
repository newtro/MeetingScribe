#!/usr/bin/env python3
"""Validate a monotonically increasing Sparkle release and atomically update its feed."""
import argparse
import base64
import email.utils
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


def fail(message):
    raise SystemExit(message)


def positive(value):
    if not re.fullmatch(r"[1-9][0-9]*", value):
        fail("Build numbers and archive lengths must be positive integers.")
    return int(value)


def read_feed(path):
    if path.exists():
        try:
            tree = ET.parse(path)
        except ET.ParseError as error:
            fail(f"Invalid existing appcast; it was not changed: {error}")
        root = tree.getroot()
        channel = root.find("channel")
        if root.tag != "rss" or channel is None:
            fail("Expected an RSS appcast with one channel.")
    else:
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        for key, value in [("title", "MeetingScribe"), ("link", "https://github.com/newtro/MeetingScribe"),
                           ("description", "MeetingScribe updates"), ("language", "en")]:
            ET.SubElement(channel, key).text = value
        tree = ET.ElementTree(root)
    return tree, channel


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("appcast", type=Path)
    parser.add_argument("--check-build")
    for name in ("version", "build", "min-os", "url", "signature", "notes"):
        parser.add_argument("--" + name)
    args = parser.parse_args()
    tree, channel = read_feed(args.appcast)
    items = channel.findall("item")
    builds = [positive(item.findtext(f"{{{SPARKLE}}}version", "")) for item in items]
    newest = max(builds, default=0)
    build = positive(args.check_build or args.build or "")
    if build <= newest:
        fail(f"Build {build} must exceed every published build (current maximum {newest}).")
    if args.check_build:
        return
    required = ("version", "build", "min_os", "url", "signature", "notes")
    if missing := [name for name in required if not getattr(args, name)]:
        parser.error("Missing " + ", ".join("--" + name.replace("_", "-") for name in missing))
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
        fail("Version must use major.minor.patch.")
    if any(item.findtext(f"{{{SPARKLE}}}shortVersionString") == args.version for item in items):
        fail(f"Version {args.version} already exists; releases are immutable.")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", args.min_os):
        fail("Invalid minimum macOS version.")
    for url in (args.url, args.notes):
        parsed = urlsplit(url)
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
            fail("Release and notes URLs must use HTTPS without embedded credentials.")
    signature = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', args.signature)
    length = re.search(r'length="([0-9]+)"', args.signature)
    try:
        valid_signature = signature is not None and len(base64.b64decode(signature[1], validate=True)) == 64
    except ValueError:
        valid_signature = False
    if not valid_signature or length is None:
        fail("Expected a 64-byte Sparkle Ed25519 signature and archive length.")
    positive(length[1])
    item = ET.Element("item")
    for name, value in [("title", "Version " + args.version), ("pubDate", email.utils.formatdate(usegmt=True)),
                        (f"{{{SPARKLE}}}version", str(build)), (f"{{{SPARKLE}}}shortVersionString", args.version),
                        (f"{{{SPARKLE}}}minimumSystemVersion", args.min_os),
                        (f"{{{SPARKLE}}}releaseNotesLink", args.notes)]:
        ET.SubElement(item, name).text = value
    ET.SubElement(item, "enclosure", {"url": args.url, "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": signature[1], "length": length[1]})
    channel.insert(list(channel).index(items[0]) if items else len(channel), item)
    ET.indent(tree, space="  ")
    args.appcast.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile("wb", dir=args.appcast.parent, delete=False) as output:
            temporary = output.name
            tree.write(output, encoding="utf-8", xml_declaration=True)
            output.write(b"\n"); output.flush(); os.fsync(output.fileno())
        os.replace(temporary, args.appcast)
        directory = os.open(args.appcast.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Added MeetingScribe {args.version} ({build}) to {args.appcast}")


if __name__ == "__main__":
    main()
