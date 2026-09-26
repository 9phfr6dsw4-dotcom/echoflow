#!/usr/bin/env python3
"""Fetch a pinned tiny compiled Whisper model into a new GitHub runner temp folder.

Only Hugging Face's pinned repository tree metadata supplies the expected digest:
LFS entries use their SHA-256 object ID; ordinary Git blobs use their blob SHA-1.
Every downloaded byte is verified before Swift is allowed to use the folder.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import quote
from urllib.request import Request, urlopen

MODEL_REPO = "argmaxinc/whisperkit-coreml"
MODEL_REV = "0f63a7800b00dd0226abd051b906c246e1907482"
MODEL_PREFIX = "openai_whisper-tiny"
MODEL_PARTS = frozenset(("AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"))
TOKEN_REPO = "openai/whisper-tiny"
TOKENIZER_COMMIT = "169d4a4341b33bc18d8881c4b69c2e104e1cc0af"  # gitleaks:allow - public pinned upstream Git commit, not a credential
TOKEN_FILES = frozenset((
    "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
    "added_tokens.json", "vocab.json", "merges.txt", "normalizer.json",
))
MAX_FILE_BYTES = 80_000_000
MAX_TOTAL_BYTES = 110_000_000
HEX = re.compile(r"[0-9a-f]+\Z")
COMPONENT = re.compile(r"[A-Za-z0-9_.-]+\Z")


class IntegrityError(ValueError):
    pass


def safe_parts(path):
    if not isinstance(path, str) or not path or "\\" in path:
        raise IntegrityError("Invalid repository path")
    parts = path.split("/")
    if any(p in ("", ".", "..") or not COMPONENT.fullmatch(p) for p in parts):
        raise IntegrityError("Unsafe repository path")
    return parts


def expected_digest(item):
    size = item.get("size")
    if type(size) is not int or not 0 <= size <= MAX_FILE_BYTES:
        raise IntegrityError("Missing or invalid repository file size")
    lfs = item.get("lfs")
    if lfs is not None:
        if not isinstance(lfs, dict) or lfs.get("size") != size:
            raise IntegrityError("Inconsistent LFS size")
        oid = lfs.get("oid")
        if not isinstance(oid, str) or len(oid) != 64 or not HEX.fullmatch(oid):
            raise IntegrityError("Missing or invalid LFS SHA-256")
        return "sha256", oid
    oid = item.get("oid")
    if not isinstance(oid, str) or len(oid) != 40 or not HEX.fullmatch(oid):
        raise IntegrityError("Missing or invalid Git blob SHA-1")
    return "sha1", oid


def tree(repo, revision, prefix=""):
    path = f"/{quote(prefix, safe='/')}" if prefix else ""
    url = f"https://huggingface.co/api/models/{repo}/tree/{revision}{path}?recursive=true&expand=true"
    with urlopen(Request(url, headers={"User-Agent": "EchoFlow-CI-Whisper-benchmark"}), timeout=45) as response:
        # The small pinned trees must arrive complete; never silently benchmark a partial list.
        if response.headers.get("Link"):
            raise IntegrityError("Paginated repository tree is not supported")
        data = response.read(2_000_001)
        if len(data) > 2_000_000:
            raise IntegrityError("Repository tree too large")
    entries = json.loads(data)
    if not isinstance(entries, list):
        raise IntegrityError("Invalid repository tree")
    return entries


def select_entries(entries, prefix, allowed):
    selected = {}
    for item in entries:
        if not isinstance(item, dict):
            raise IntegrityError("Invalid repository entry")
        path = item.get("path")
        parts = safe_parts(path)  # Reject traversal even in otherwise ignored metadata.
        kind = item.get("type")
        if kind not in ("file", "directory"):
            raise IntegrityError("Unexpected repository entry type")
        if prefix:
            if parts[0] != prefix:
                raise IntegrityError("Entry escaped pinned model directory")
            parts = parts[1:]
        if kind != "file" or not parts or parts[0] not in allowed:
            continue
        if not prefix and len(parts) != 1:
            raise IntegrityError("Nested tokenizer file")
        if prefix and (len(parts) < 2 or not parts[0].endswith(".mlmodelc")):
            raise IntegrityError("Not a compiled Core ML file")
        relative = "/".join(parts)
        if relative in selected:
            raise IntegrityError("Duplicate repository path")
        expected_digest(item)
        selected[relative] = item
    if prefix:
        for part in allowed:
            for required in ("coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"):
                if f"{part}/{required}" not in selected:
                    raise IntegrityError("Missing compiled Core ML file")
    elif set(selected) != allowed:
        raise IntegrityError("Missing required tokenizer file")
    if sum(item["size"] for item in selected.values()) > MAX_TOTAL_BYTES:
        raise IntegrityError("Repository payload too large")
    return selected


def download(repo, revision, source, destination, item):
    size = item["size"]
    algorithm, expected = expected_digest(item)
    digest = hashlib.new(algorithm)
    if algorithm == "sha1":
        digest.update(f"blob {size}\0".encode("ascii"))
    url = f"https://huggingface.co/{repo}/resolve/{revision}/{quote(source, safe='/')}"
    # Exclusive creation: never overwrite an existing file, and do not follow a symlink.
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    with urlopen(Request(url, headers={"User-Agent": "EchoFlow-CI-Whisper-benchmark"}), timeout=90) as response:
        with os.fdopen(os.open(destination, flags, 0o600), "wb") as target:
            count = 0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                count += len(chunk)
                if count > size:
                    raise IntegrityError("Downloaded file exceeds pinned size")
                target.write(chunk)
                digest.update(chunk)
    if count != size or digest.hexdigest() != expected:
        raise IntegrityError("Downloaded file failed pinned repository digest/size verification")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True, help="new model folder under RUNNER_TEMP")
    args = parser.parse_args()
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    if not runner_temp.is_dir() or args.directory.parent.resolve(strict=True) != runner_temp:
        raise IntegrityError("Model destination must be a new direct child of RUNNER_TEMP")
    if args.directory.is_symlink():
        raise IntegrityError("Refusing a symlink model destination")

    model = select_entries(tree(MODEL_REPO, MODEL_REV, MODEL_PREFIX), MODEL_PREFIX, MODEL_PARTS)
    tokenizer = select_entries(tree(TOKEN_REPO, TOKENIZER_COMMIT), "", TOKEN_FILES)
    if sum(item["size"] for item in (*model.values(), *tokenizer.values())) > MAX_TOTAL_BYTES:
        raise IntegrityError("Combined repository payload too large")

    args.directory.mkdir(mode=0o700)  # Fails if the target exists; never delete or replace anything.
    for repo, revision, files, prefix in (
        (MODEL_REPO, MODEL_REV, model, MODEL_PREFIX),
        (TOKEN_REPO, TOKENIZER_COMMIT, tokenizer, ""),
    ):
        for relative, item in sorted(files.items()):
            destination = args.directory.joinpath(*safe_parts(relative))
            destination.parent.mkdir(parents=True, exist_ok=True)
            source = f"{prefix}/{relative}" if prefix else relative
            download(repo, revision, source, destination, item)
    print(f"Verified {len(model)} compiled-model files and {len(tokenizer)} tokenizer files in RUNNER_TEMP.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # URL/network errors can embed CDN signed query strings; never print their details.
        print(f"Whisper benchmark model preparation failed ({type(error).__name__}); no benchmark was run.", file=sys.stderr)
        sys.exit(1)
