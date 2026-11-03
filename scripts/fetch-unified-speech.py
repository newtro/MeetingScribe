#!/usr/bin/env python3
"""Build-only fetch of the selected immutable model artifacts. Never imported by the app."""
import hashlib
import json
import pathlib
import sys
import time
import urllib.request

REPO = "FluidInference/parakeet-unified-en-0.6b-coreml"
REV = "d32e972dd4315f1dc3f6be28fb2aab0ab3e80358"
BUNDLES = (
    "parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc/",
    "parakeet_unified_decoder.mlmodelc/",
    "parakeet_unified_joint_decision_single_step.mlmodelc/",
)
ROOT_FILES = {"vocab.json", "metadata.json", "README.md"}


def digest(path, git_blob=False):
    h = hashlib.sha1() if git_blob else hashlib.sha256()
    if git_blob:
        h.update(f"blob {path.stat().st_size}\0".encode())
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def main():
    target = pathlib.Path(sys.argv[1])
    target.mkdir(parents=True, exist_ok=True)
    manifest_path = target / "artifact-manifest.json"
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text())
        if manifest.get("revision") == REV:
            items = manifest["files"]
        else:
            items = None
    else:
        items = None
    if items is None:
        url = f"https://huggingface.co/api/models/{REPO}/tree/{REV}?recursive=true&limit=1000"
        with urllib.request.urlopen(url, timeout=60) as response:
            tree = json.load(response)
        items = []
        for item in tree:
            name = item["path"]
            if item["type"] != "file" or not (name.startswith(BUNDLES) or name in ROOT_FILES):
                continue
            if pathlib.PurePosixPath(name).is_absolute() or ".." in pathlib.PurePosixPath(name).parts:
                raise ValueError("Unsafe model path")
            items.append({"path": name, "size": item["size"], "digest": item.get("lfs", {}).get("oid", item["oid"]),
                          "gitBlob": "lfs" not in item})
        if not all(any(i["path"].startswith(b) for i in items) for b in BUNDLES) or not any(i["path"] == "vocab.json" for i in items):
            raise RuntimeError("Pinned repository is missing required speech artifacts")
    for item in items:
        dest = target / item["path"]
        valid = lambda p: p.is_file() and p.stat().st_size == item["size"] and digest(p, item["gitBlob"]) == item["digest"]
        if valid(dest):
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        partial = dest.with_name(dest.name + ".partial")
        print(f"fetching Unified {item['path']} ({item['size'] / 1e6:.1f} MB)", flush=True)
        for attempt in range(3):
            try:
                with urllib.request.urlopen(f"https://huggingface.co/{REPO}/resolve/{REV}/{item['path']}", timeout=120) as source, partial.open("wb") as sink:
                    while block := source.read(1024 * 1024):
                        sink.write(block)
                if not valid(partial):
                    raise RuntimeError(f"Model digest mismatch: {item['path']}")
                partial.replace(dest)
                break
            except Exception:
                if attempt == 2:
                    raise
                time.sleep(1 + attempt)
    manifest_path.write_text(json.dumps({"repository": REPO, "revision": REV, "sdk": "0.18.2", "tier": "640ms-int8", "files": items}, indent=2) + "\n")
    (target / (".rev-" + REV)).write_text(REV + "\n")
    print("Unified speech assets verified (local-only at runtime)")


if __name__ == "__main__":
    main()
