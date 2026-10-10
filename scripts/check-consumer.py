"""Build a committed revision in an isolated consumer without sibling paths.

OPSMARU_FIXTURE_REVISION must identify an existing implemented commit.
The optional repository override is development/fixture-only. Production
consumers use the documented published immutable Git revision.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1]
revision = os.environ.get("OPSMARU_FIXTURE_REVISION") or (source / "test/consumer/revision.txt").read_text().strip()
with tempfile.TemporaryDirectory(prefix="opsmaru-consumer-") as directory:
    root = Path(directory)
    shutil.copytree(source / "test/consumer", root / "consumer")
    if not (root / "consumer/mix.lock").is_file():
        shutil.copy(source / "mix.lock", root / "consumer/mix.lock")
    shutil.copy(source / "mise.toml", root / "consumer/mise.toml")
    env = os.environ.copy()
    for key in ["DATABASE_URL", "OIDC_ISSUER", "SECRET_KEY_BASE", "OPSMARU_MODE"]:
        env.pop(key, None)
    env.update(MIX_ENV="test", PHX_SERVER="true", PORT="not-a-port", OPSMARU_FIXTURE_REVISION=revision)
    for args in [["mise", "trust"], ["mise", "exec", "--", "mix", "deps.get"],
                 ["mise", "exec", "--", "mix", "compile", "--warnings-as-errors"],
                 ["mise", "exec", "--", "mix", "test"]]:
        subprocess.run(args, cwd=root / "consumer", env=env, check=True)
    if env.get("OPSMARU_FIXTURE_LOCK_OUTPUT"):
        shutil.copy(root / "consumer/mix.lock", env["OPSMARU_FIXTURE_LOCK_OUTPUT"])
    print(f"Isolated consumer passed at {revision}; installed/runtime acceptance remains separate")
