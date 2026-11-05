"""Strict release tags; prerelease identity is kept outside Apple's numeric version."""
import argparse
import json
import re


def parse_tag(tag):
    match = re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?", tag)
    if not match or len(tag) > 100:
        raise ValueError("Expected vX.Y.Z or vX.Y.Z-prerelease (no build metadata)")
    suffix = match[4]
    if suffix and any(part.isdigit() and len(part) > 1 and part[0] == "0" for part in suffix.split(".")):
        raise ValueError("Numeric prerelease identifiers must not have leading zeros")
    return {"tag": tag, "version": ".".join(match.group(1, 2, 3)), "prerelease": bool(suffix)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("tag")
    args = parser.parse_args()
    try:
        print(json.dumps(parse_tag(args.tag)))
    except ValueError as error:
        parser.error(str(error))
