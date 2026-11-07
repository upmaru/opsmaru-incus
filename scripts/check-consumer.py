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
import json
import importlib.util
import hashlib
import re
import sys

sys.dont_write_bytecode = True

source = Path(__file__).resolve().parents[1]
revision = os.environ.get("OPSMARU_INCUS_FIXTURE_REVISION") or (source / "test/consumer/revision.txt").read_text().strip()
if not re.fullmatch(r"[0-9a-f]{40}", revision):
    raise SystemExit("OPSMARU_INCUS_FIXTURE_REVISION must be an immutable 40-hex commit")
with tempfile.TemporaryDirectory(prefix="opsmaru-incus-consumer-") as directory:
    root = Path(directory)
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
    env.update(MIX_ENV="test", PHX_SERVER="true", PORT="not-a-port", OPSMARU_INCUS_FIXTURE_REVISION=revision)
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
    dependency = root / "consumer/deps/opsmaru_incus"
    fetched = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=dependency, text=True).strip()
    if fetched != revision or subprocess.check_output(["git", "status", "--porcelain"], cwd=dependency, text=True).strip():
        raise SystemExit("consumer dependency must remain the exact clean immutable revision")
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
    client_dependency = root / "client/deps/opsmaru_incus"
    if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=client_dependency, text=True).strip() != revision or subprocess.check_output(["git", "status", "--porcelain"], cwd=client_dependency, text=True).strip():
        raise SystemExit("client-only dependency must remain the exact clean immutable revision")
    harness_paths = [
        source / relative for relative in ["scripts/check-consumer.py", "scripts/gateway-conformance.py",
          "priv/incus/reference.json", "mise.toml", "mix.lock"]
    ] + [
        path for directory in [source / "test/consumer", source / "test/reference", source / "test/support"]
        for path in sorted(directory.rglob("*")) if path.is_file()
    ]
    report = {
        "schema": "opsmaru-incus-gateway-acceptance/v1",
        "evidence": "immutable-consumer-fixture", "revision": revision,
        "repository": env.get("OPSMARU_INCUS_FIXTURE_REPOSITORY", "https://github.com/upmaru/opsmaru-incus.git"),
        "native_cli": provenance, "isolated_client_state": True,
        "harness_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip(),
        "harness_clean": not subprocess.check_output(["git", "status", "--porcelain"], cwd=source, text=True).strip(),
        "harness_sha256": {
            str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in harness_paths
        },
        "published_repository": not bool(env.get("OPSMARU_INCUS_FIXTURE_REPOSITORY")) or env["OPSMARU_INCUS_FIXTURE_REPOSITORY"].startswith("https://github.com/"),
        "host_consumer": "passed", "client_only_consumer": "passed",
        "migration_cases": migration_cases,
        "migration_cli_completion": "partial: pinned CLI rejects snapshot move before any migration mutation",
        "typed_client_coverage": "unchanged; gateway evidence is separate",
        "real_backend": "unrun", "installed_host": "unrun", "macus_hardware": "unrun",
    }
    if env.get("OPSMARU_INCUS_GATEWAY_REPORT"):
        output = Path(env["OPSMARU_INCUS_GATEWAY_REPORT"])
        with output.open("x") as file:
            json.dump(report, file, indent=2)
            file.write("\n")
    print(json.dumps(report, indent=2))
