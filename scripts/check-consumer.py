"""Build a committed revision in an isolated consumer without sibling paths.

OPSMARU_INCUS_FIXTURE_REVISION must identify an existing implemented commit.
The optional repository override is development/fixture-only. Production
consumers use the documented published immutable Git revision.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1]
revision = os.environ.get("OPSMARU_INCUS_FIXTURE_REVISION") or (source / "test/consumer/revision.txt").read_text().strip()
with tempfile.TemporaryDirectory(prefix="opsmaru-incus-consumer-") as directory:
    root = Path(directory)
    shutil.copytree(source / "test/consumer", root / "consumer")
    if not (root / "consumer/mix.lock").is_file():
        shutil.copy(source / "mix.lock", root / "consumer/mix.lock")
    shutil.copy(source / "mise.toml", root / "consumer/mise.toml")
    env = os.environ.copy()
    for key in ["DATABASE_URL", "OIDC_ISSUER", "SECRET_KEY_BASE", "OPSMARU_MODE"]:
        env.pop(key, None)
    env.update(MIX_ENV="test", PHX_SERVER="true", PORT="not-a-port", OPSMARU_INCUS_FIXTURE_REVISION=revision)
    for args in [["mise", "trust"], ["mise", "exec", "--", "mix", "deps.get"],
                 ["mise", "exec", "--", "mix", "compile", "--warnings-as-errors"],
                 ["mise", "exec", "--", "mix", "test"]]:
        subprocess.run(args, cwd=root / "consumer", env=env, check=True)
    if env.get("OPSMARU_INCUS_FIXTURE_LOCK_OUTPUT"):
        shutil.copy(root / "consumer/mix.lock", env["OPSMARU_INCUS_FIXTURE_LOCK_OUTPUT"])

    # A client-only consumer without tama_mcp, Plug, Cowboy or Phoenix: the
    # library and its operation descriptors must compile without warnings.
    shutil.copytree(source / "test/consumer/client_only", root / "client")
    shutil.copy(source / "mise.toml", root / "client/mise.toml")
    for args in [["mise", "trust"], ["mise", "exec", "--", "mix", "deps.get"],
                 ["mise", "exec", "--", "mix", "deps.compile"]]:
        subprocess.run(args, cwd=root / "client", env=env, check=True)
    build = subprocess.run(["mise", "exec", "--", "mix", "deps.compile", "opsmaru_incus", "--force"],
                           cwd=root / "client", env=env, check=True, capture_output=True, text=True)
    print(build.stdout, build.stderr)
    if "warning" in (build.stdout + build.stderr).lower():
        raise SystemExit("client-only build of opsmaru_incus emitted warnings")
    for args in [["mise", "exec", "--", "mix", "compile", "--warnings-as-errors"],
                 ["mise", "exec", "--", "mix", "test"]]:
        subprocess.run(args, cwd=root / "client", env=env, check=True)
    print(f"Isolated consumers (Macus-compatible host and client-only) passed at {revision}; installed/runtime acceptance remains separate")
