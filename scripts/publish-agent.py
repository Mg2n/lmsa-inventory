#!/usr/bin/env python3
"""Sign and publish the agent for self-update.

Reads agent/InventorySync.ps1, signs "InventorySync|<version>|<sha256>" with
secrets/agent_signing_key.pem (RSA-SHA256, PKCS#1 v1.5) and writes:
  web/public/agent/InventorySync-<version>.ps1
  web/public/agent/manifest.json
Deploying the web app (git push) publishes them; store PCs pick them up within 6 hours.

Usage:  source ~/venv/bin/activate && python scripts/publish-agent.py
"""
import base64
import hashlib
import json
import pathlib
import re
import sys

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

ROOT = pathlib.Path(__file__).resolve().parent.parent
src = ROOT / "agent" / "InventorySync.ps1"
key_path = ROOT / "secrets" / "agent_signing_key.pem"
out = ROOT / "web" / "public" / "agent"

data = src.read_bytes()
m = re.search(rb"\$AgentVersion = '([0-9]+\.[0-9]+\.[0-9]+)'", data)
if not m:
    sys.exit("agent version not found")
version = m.group(1).decode()
sha = hashlib.sha256(data).hexdigest()

key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
sig = key.sign(f"InventorySync|{version}|{sha}".encode(), padding.PKCS1v15(), hashes.SHA256())
# self-check with the public key that ships to the store PC
key.public_key().verify(sig, f"InventorySync|{version}|{sha}".encode(), padding.PKCS1v15(), hashes.SHA256())

out.mkdir(parents=True, exist_ok=True)
for old in out.glob("InventorySync-*.ps1"):
    if old.name != f"InventorySync-{version}.ps1":
        old.unlink()
(out / f"InventorySync-{version}.ps1").write_bytes(data)
manifest = {"version": version, "file": f"InventorySync-{version}.ps1", "sha256": sha,
            "signature": base64.b64encode(sig).decode()}
(out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"published agent {version}  sha256={sha[:16]}…")
