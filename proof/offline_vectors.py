#!/usr/bin/env python3
"""
proof/offline_vectors.py: Production helper for offline proof-only vector inputs.

Provides authoritative validation and processing for:
  - ML-KEM: mlkem-keygen.json, mlkem-encdec.json
  - HPKE: hpke-vectors.json
  - Wycheproof: wycheproof-p384.json

Contract specifications:
  - When IYI_PROOF_INPUTS_DIR is set:
      * Path must be absolute.
      * Required files must exist:
          - mlkem-keygen.json
          - mlkem-encdec.json
          - hpke-vectors.json
          - wycheproof-p384.json
      * Byte SHA-256 digests must match authoritative pinned values:
          - ML-KEM keygen: d7a62a2c3476957f56dd8d24f9004ea6776ccfe995ffe71a65bb9506dc9c7b1b
          - ML-KEM encdec: a556952ce869bb89c3a3196a701dad89647c193a34c86eafb61a9d710d5b810f
          - HPKE vectors:  61fc662f01996cd06d713dacf5e133167bd309a1f329442d53f1e21a47b3ede6
          - Wycheproof:    ffa7835fe1de359dff762c8f1272b98acebd5578e2f855d969051ff956c6dca3
      * Wycheproof provenance: C2SP/wycheproof commit d17cc89fa5c8f4f4d378b5385ebf75da5d0926c9,
        git blob 737e3b4f705b6d600c36aecfc7a5b9712f5095b4, exactly 790 unique tcIds.
      * Missing or corrupt data MUST fail nonzero with no network/fallback/skip.
  - When IYI_PROOF_INPUTS_DIR is absent:
      * Scripts retain preexisting unchanged normal behavior.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

# Authoritative SHA-256 digests
MLKEM_KEYGEN_SHA256 = "d7a62a2c3476957f56dd8d24f9004ea6776ccfe995ffe71a65bb9506dc9c7b1b"
MLKEM_ENCDEC_SHA256 = "a556952ce869bb89c3a3196a701dad89647c193a34c86eafb61a9d710d5b810f"
HPKE_VECTORS_SHA256 = "61fc662f01996cd06d713dacf5e133167bd309a1f329442d53f1e21a47b3ede6"
WYCHEPROOF_P384_SHA256 = "ffa7835fe1de359dff762c8f1272b98acebd5578e2f855d969051ff956c6dca3"

WYCHEPROOF_COMMIT = "d17cc89fa5c8f4f4d378b5385ebf75da5d0926c9"
WYCHEPROOF_GIT_BLOB = "737e3b4f705b6d600c36aecfc7a5b9712f5095b4"
WYCHEPROOF_CASE_COUNT = 790


class OfflineVectorsError(Exception):
    """Raised when offline vector validation or processing fails."""


def get_proof_inputs_dir(env_var: str = "IYI_PROOF_INPUTS_DIR") -> Path:
    """Return validated Path for the offline proof inputs directory."""
    raw = os.environ.get(env_var, "").strip()
    if not raw:
        raise OfflineVectorsError(f"{env_var} is not set")
    if not os.path.isabs(raw):
        raise OfflineVectorsError(f"{env_var} must be an absolute path: {raw}")
    path = Path(raw)
    if not path.is_dir():
        raise OfflineVectorsError(f"{env_var} directory does not exist: {raw}")
    return path


def verify_file_digest(path: Path, expected_sha256: str) -> bytes:
    """Verify that path exists, is a file, and has the exact expected SHA-256 digest."""
    if not path.is_file():
        raise OfflineVectorsError(f"Missing required vector file: {path}")
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != expected_sha256:
        raise OfflineVectorsError(
            f"{path.name}: sha256 {digest}, not authoritative {expected_sha256}"
        )
    return data


def process_mlkem_vectors(inputs_dir: Path, output_file: Path) -> dict[str, int]:
    """Validate ML-KEM files and produce acvp-all.json containing every ML-KEM-768 case."""
    keygen_path = inputs_dir / "mlkem-keygen.json"
    encdec_path = inputs_dir / "mlkem-encdec.json"

    keygen_bytes = verify_file_digest(keygen_path, MLKEM_KEYGEN_SHA256)
    encdec_bytes = verify_file_digest(encdec_path, MLKEM_ENCDEC_SHA256)

    try:
        keygen_data = json.loads(keygen_bytes)
        encdec_data = json.loads(encdec_bytes)
    except Exception as e:
        raise OfflineVectorsError(f"Failed to parse ML-KEM JSON: {e}") from e

    keep = {
        "keyGen": ("d", "z", "ek", "dk"),
        "encapsulation": ("ek", "m", "c", "k"),
        "decapsulation": ("dk", "c", "k", "reason"),
        "decapsulationKeyCheck": ("dk", "testPassed", "reason"),
        "encapsulationKeyCheck": ("ek", "testPassed", "reason"),
    }
    out: dict[str, list[dict]] = {k: [] for k in keep}
    for data in (keygen_data, encdec_data):
        for g in data.get("testGroups", []):
            if g.get("parameterSet") != "ML-KEM-768":
                continue
            f = g.get("function", "keyGen")
            if f not in keep:
                continue
            for t in g.get("tests", []):
                case_dict = {"tcId": t["tcId"]}
                for field in keep[f]:
                    case_dict[field] = t[field]
                out[f].append(case_dict)

    output_file.parent.mkdir(parents=True, exist_ok=True)
    with output_file.open("w", newline="\n") as f:
        json.dump(out, f)

    return {k: len(v) for k, v in out.items()}


def cut_hpke_vectors_data(vectors_list: list[dict], shape: str = "every") -> list[dict]:
    """Cut HPKE vectors matching the suites std/hpke supports."""
    fields = (
        "mode", "kem_id", "kdf_id", "aead_id", "info", "ikmR", "ikmE", "ikmS",
        "skRm", "skEm", "skSm", "pkRm", "pkEm", "pkSm", "psk", "psk_id", "enc",
        "shared_secret", "key", "base_nonce"
    )
    out = []
    for v in vectors_list:
        if v.get("kem_id") not in (0x10, 0x11, 0x20) or v.get("kdf_id") not in (1, 2, 3) or v.get("aead_id") not in (1, 2, 3, 0xFFFF):
            continue
        case = {k: v[k] for k in fields if k in v}
        sealed = v["encryptions"]
        base = int(v.get("base_nonce") or "0", 16)
        for i, e in enumerate(sealed):
            if e["pt"] != sealed[0]["pt"] or bytes.fromhex(e["aad"]) != b"Count-%d" % i or int(e["nonce"], 16) ^ base != i:
                raise OfflineVectorsError(f"HPKE encryption {i} is not expected format")
        case["count"] = len(sealed)
        case["ciphertexts_sha256"] = hashlib.sha256(b"".join(bytes.fromhex(e["ct"]) for e in sealed)).hexdigest()
        case["encryptions"] = [dict(e, seq=i) for i, e in enumerate(sealed) if shape == "every" or i in (0, 1, 2, 255, 256)]
        case["exports"] = v["exports"]
        out.append(case)
    return out


def process_hpke_vectors(
    inputs_dir: Path,
    every_out: Path,
    subset_out: Path | None = None,
    vendored_vectors: Path | None = None,
) -> tuple[int, int, int]:
    """Validate hpke-vectors.json and cut every.json and subset.json."""
    hpke_path = inputs_dir / "hpke-vectors.json"
    hpke_bytes = verify_file_digest(hpke_path, HPKE_VECTORS_SHA256)

    try:
        raw_vectors = json.loads(hpke_bytes)
    except Exception as e:
        raise OfflineVectorsError(f"Failed to parse HPKE JSON: {e}") from e

    subset_data = cut_hpke_vectors_data(raw_vectors, shape="subset")
    if vendored_vectors is not None:
        if not vendored_vectors.is_file():
            raise OfflineVectorsError(f"Missing vendored vectors file: {vendored_vectors}")
        vendored_data = json.loads(vendored_vectors.read_text())
        if subset_data != vendored_data:
            raise OfflineVectorsError("HPKE cut subset does not match vendored vectors value for value")

    if subset_out is not None:
        subset_out.parent.mkdir(parents=True, exist_ok=True)
        with subset_out.open("w", newline="\n") as f:
            f.write("[\n" + ",\n".join(json.dumps(c, separators=(",", ":")) for c in subset_data) + "\n]\n")

    every_data = cut_hpke_vectors_data(raw_vectors, shape="every")
    every_out.parent.mkdir(parents=True, exist_ok=True)
    with every_out.open("w", newline="\n") as f:
        f.write("[\n" + ",\n".join(json.dumps(c, separators=(",", ":")) for c in every_data) + "\n]\n")

    total_vectors = len(every_data)
    total_encryptions = sum(c["count"] for c in every_data)
    total_exports = sum(len(c["exports"]) for c in every_data)
    return total_vectors, total_encryptions, total_exports


def process_wycheproof_vectors(inputs_dir: Path, output_file: Path) -> int:
    """Validate wycheproof-p384.json and produce wycheproof.txt ensuring all 790 cases."""
    wycheproof_path = inputs_dir / "wycheproof-p384.json"
    wycheproof_bytes = verify_file_digest(wycheproof_path, WYCHEPROOF_P384_SHA256)

    try:
        data = json.loads(wycheproof_bytes)
    except Exception as e:
        raise OfflineVectorsError(f"Failed to parse Wycheproof JSON: {e}") from e

    lines = []
    tc_ids = set()
    for group in data.get("testGroups", []):
        for test in group.get("tests", []):
            tc_id = test["tcId"]
            tc_ids.add(tc_id)
            private = int(test["private"], 16) if test.get("private") else 0
            if private >= 2**384:
                private_hex = test["private"]
            else:
                private_hex = f"{private:096x}"
            lines.append(f'{tc_id} {test["result"]} {private_hex} {test.get("public") or "-"} {test.get("shared") or "-"}')

    if len(tc_ids) != WYCHEPROOF_CASE_COUNT or len(lines) != WYCHEPROOF_CASE_COUNT:
        raise OfflineVectorsError(
            f"Expected exactly {WYCHEPROOF_CASE_COUNT} unique tcIds from C2SP blob {WYCHEPROOF_GIT_BLOB}, "
            f"got {len(tc_ids)} unique, {len(lines)} total"
        )

    output_file.parent.mkdir(parents=True, exist_ok=True)
    with output_file.open("w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    return len(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Process offline proof vector inputs")
    parser.add_argument("kind", choices=["mlkem", "hpke", "wycheproof"], help="Vector kind")
    parser.add_argument("output", type=Path, help="Output destination file")
    parser.add_argument("--inputs-dir", type=Path, default=None, help="Path to offline inputs directory")
    parser.add_argument("--subset-out", type=Path, default=None, help="Output for HPKE subset.json")
    parser.add_argument("--vendored", type=Path, default=None, help="Vendored HPKE vectors file for verification")

    args = parser.parse_args(argv)

    try:
        inputs_dir = args.inputs_dir if args.inputs_dir is not None else get_proof_inputs_dir()

        if args.kind == "mlkem":
            counts = process_mlkem_vectors(inputs_dir, args.output)
            print("  " + ", ".join(f"{v} {k}" for k, v in counts.items()))
        elif args.kind == "hpke":
            nv, ne, nx = process_hpke_vectors(inputs_dir, args.output, subset_out=args.subset_out, vendored_vectors=args.vendored)
            print(f"  {nv} vectors, {ne} encryptions, {nx} exports")
        elif args.kind == "wycheproof":
            count = process_wycheproof_vectors(inputs_dir, args.output)
            print(f"  {count} Wycheproof P-384 vectors verified and extracted")
        return 0
    except OfflineVectorsError as err:
        print(f"  FAIL IYI_PROOF_INPUTS_DIR: {err}", file=sys.stderr)
        return 1
    except Exception as err:
        print(f"  FAIL IYI_PROOF_INPUTS_DIR unexpected error: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
