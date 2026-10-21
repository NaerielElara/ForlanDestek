import brotli
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
stage = root / "flutter/build/windows/x64/runner/Release"
package = root / "dist/ForlanDestek-1.17.0-portable.exe"
blob = (root / "libs/portable/data.bin").read_bytes()
assert blob[:8] == b"rustdesk"
offset = 8
verified = {}
while blob[offset:offset + 8] != b"rustdesk":
    length = int.from_bytes(blob[offset:offset + 4], "big")
    offset += 4
    name = blob[offset:offset + length].decode().replace("\\", "/").removeprefix("./")
    offset += length
    length = int.from_bytes(blob[offset:offset + 4], "big")
    offset += 4
    content = brotli.decompress(blob[offset:offset + length])
    offset += length
    md5 = blob[offset:offset + 32].decode()
    offset += 32
    relative = Path(name)
    assert not relative.is_absolute() and ".." not in relative.parts
    assert hashlib.md5(content).hexdigest() == md5
    assert (stage / relative).read_bytes() == content, name
    verified[name] = hashlib.sha256(content).hexdigest()
assert blob[offset + 8:].decode().replace("\\", "/") == "./ForlanDestek.exe"
content = package.read_bytes()
assert blob in content
assert "data/flutter_assets/assets/forlan-message.wav" in verified
assert "data/flutter_assets/assets/forlan-connection.wav" not in verified
important = ["ForlanDestek.exe", "librustdesk.dll", "flutter_windows.dll", "data/app.so", "data/flutter_assets/assets/forlan-message.wav"]
assert all(name in verified for name in important)
result = {
    "file": package.name,
    "bytes": len(content),
    "sha256": hashlib.sha256(content).hexdigest(),
    "verifiedPayloadFiles": len(verified),
    "embeddedArchiveMatches": True,
    "connectionSoundAbsent": True,
    "payloadHashes": {name: verified[name] for name in important},
}
(root / ".codex/package-1.17-verification.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
print(json.dumps(result, indent=2))
