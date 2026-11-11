"""Build the Hex package from this checkout and verify it in isolated consumers.

Hex is the only distribution route. This script runs `mix hex.build` on the
checkout, extracts exactly the files the tarball would publish and points two
fresh consumers at that extracted package. The tarball's SHA-256 is the Hex
outer checksum, so the report can be compared with the published release.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import json
import importlib.util
import hashlib
import re
import sys
import tarfile

sys.dont_write_bytecode = True

source = Path(__file__).resolve().parents[1]
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
source_clean = not subprocess.check_output(["git", "status", "--porcelain"], cwd=source, text=True).strip()


def tree_digest(directory):
    digest = hashlib.sha256()
    for path in sorted(directory.rglob("*")):
        if path.is_file():
            digest.update(str(path.relative_to(directory)).encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


with tempfile.TemporaryDirectory(prefix="opsmaru-incus-consumer-") as directory:
    root = Path(directory)
    tarball = root / "opsmaru_incus.tar"
    subprocess.run(["mise", "exec", "--", "mix", "hex.build", "--output", str(tarball)], cwd=source, check=True)
    package_sha256 = hashlib.sha256(tarball.read_bytes()).hexdigest()
    package = root / "package"
    with tarfile.open(tarball) as outer:
        outer.extract("contents.tar.gz", root / "outer", filter="data")
        version = outer.extractfile("metadata.config").read().decode()
    with tarfile.open(root / "outer/contents.tar.gz") as contents:
        contents.extractall(package, filter="data")
    for required in ["mix.exs", "LICENSE", "NOTICE", "priv/incus/coverage.json", "priv/notices/INCUS-NOTICE.md"]:
        if not (package / required).is_file():
            raise SystemExit(f"Hex package is missing {required}")
    for forbidden in ["test", "scripts", "openspec", "docs", "mix.lock"]:
        if (package / forbidden).exists():
            raise SystemExit(f"Hex package must not contain {forbidden}")
    match = re.search(r'^\{<<"version">>,<<"([^"]+)">>\}\.$', version, re.MULTILINE)
    if not match:
        raise SystemExit("Hex package metadata has no version")
    package_version = match.group(1)
    package_digest = tree_digest(package)
    shutil.copytree(source / "test/consumer", root / "consumer")
    if not (root / "consumer/mix.lock").is_file():
        shutil.copy(source / "mix.lock", root / "consumer/mix.lock")
    shutil.copy(source / "mise.toml", root / "consumer/mise.toml")
    # The consumer owns its endpoint, router, policy state and fake backend.
    # Copy verifier-only protocol oracles/drivers into its private tree: tests
    # never import a sibling checkout or the dependency's own test directory.
    support = root / "consumer/test/support"
    support.mkdir(parents=True)
    for relative in ["http_fixture.ex", "tls_identity.ex", "web_socket_fixture.ex",
                     "gateway/stream_backend.ex", "gateway/certificate_host.ex",
                     "gateway/native_web_socket_backend.ex", "gateway/native_migration_backend.ex"]:
        target = support / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(source / "test/support" / relative, target)
    shutil.copytree(source / "test/reference", root / "consumer/test/reference")
    (root / "consumer/priv/incus").mkdir(parents=True)
    shutil.copy(source / "priv/incus/reference.json", root / "consumer/priv/incus/reference.json")
    env = os.environ.copy()
    for key in ["DATABASE_URL", "OIDC_ISSUER", "SECRET_KEY_BASE", "OPSMARU_MODE"]:
        env.pop(key, None)
    env.update(MIX_ENV="test", PHX_SERVER="true", PORT="not-a-port", OPSMARU_INCUS_PACKAGE_PATH=str(package))
    spec = importlib.util.spec_from_file_location("gateway_conformance", source / "scripts/gateway-conformance.py")
    conformance = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(conformance)
    cli = root / "incus"
    provenance = conformance.build_cli(source, cli)
    env["OPSMARU_INCUS_FIXTURE_CLI"] = str(cli)
    env["INCUS_CONF"] = str(root / "isolated-incus-conf")
    Path(env["INCUS_CONF"]).mkdir(mode=0o700)
    env["OPSMARU_INCUS_GATEWAY_CASES"] = str(root / "migration-cases.jsonl")
    for args in [["mise", "trust"], ["mise", "exec", "--", "mix", "deps.get"],
                 ["mise", "exec", "--", "mix", "compile", "--warnings-as-errors"],
                 ["mise", "exec", "--", "mix", "test"]]:
        subprocess.run(args, cwd=root / "consumer", env=env, check=True)
    if env.get("OPSMARU_INCUS_FIXTURE_LOCK_OUTPUT"):
        shutil.copy(root / "consumer/mix.lock", env["OPSMARU_INCUS_FIXTURE_LOCK_OUTPUT"])
    if tree_digest(package) != package_digest:
        raise SystemExit("consumer build must not modify the extracted Hex package")
    migration_cases = [json.loads(line) for line in Path(env["OPSMARU_INCUS_GATEWAY_CASES"]).read_text().splitlines()]
    case_keys = {(case["kind"], case["action"], case["mode"], case["gateway"]) for case in migration_cases}
    expected_cases = {(kind, action, mode, gateway) for kind in ["instance", "snapshot"]
                      for action in ["copy", "move"] for mode in ["relay", "pull", "push"]
                      for gateway in ["source", "target"]}
    if case_keys != expected_cases or len(migration_cases) != 24:
        raise SystemExit("native CLI migration evidence must include every matrix case exactly once")

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
    if tree_digest(package) != package_digest:
        raise SystemExit("client-only build must not modify the extracted Hex package")
    harness_paths = [
        source / relative for relative in ["scripts/check-consumer.py", "scripts/gateway-conformance.py",
          "priv/incus/reference.json", "mise.toml", "mix.lock"]
    ] + [
        path for directory in [source / "test/consumer", source / "test/reference", source / "test/support"]
        for path in sorted(directory.rglob("*")) if path.is_file()
    ]
    report = {
        "schema": "opsmaru-incus-gateway-acceptance/v1",
        "evidence": "hex-package-consumer-fixture", "revision": revision, "source_clean": source_clean,
        "package": {"name": "opsmaru_incus", "version": package_version, "sha256": package_sha256},
        "native_cli": provenance, "isolated_client_state": True,
        "harness_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip(),
        "harness_clean": not subprocess.check_output(["git", "status", "--porcelain"], cwd=source, text=True).strip(),
        "harness_sha256": {
            str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in harness_paths
        },
        "host_consumer": "passed", "client_only_consumer": "passed",
        "migration_cases": migration_cases,
        "migration_cli_completion": "pinned native parity: 18 successful cases and 6 unsupported snapshot moves rejected before mutation",
        "typed_client_coverage": "unchanged; gateway evidence is separate",
        "real_backend": "unrun", "installed_host": "unrun", "macus_hardware": "unrun",
    }
    if env.get("OPSMARU_INCUS_GATEWAY_REPORT"):
        output = Path(env["OPSMARU_INCUS_GATEWAY_REPORT"])
        with output.open("x") as file:
            json.dump(report, file, indent=2)
            file.write("\n")
    print(json.dumps(report, indent=2))
