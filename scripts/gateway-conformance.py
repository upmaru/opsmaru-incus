"""Build only the pinned, unmodified upstream CLI; never install or start Incus."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build_cli(source, destination):
    reference = json.loads((source / "priv/incus/reference.json").read_text())
    env = os.environ.copy()
    env.update(GOTOOLCHAIN="local", CGO_ENABLED="0", GOFLAGS="", GOWORK="off", GOENV="off")
    go = subprocess.check_output(["mise", "which", "go"], cwd=source, text=True).strip()
    env.pop("GOROOT", None)
    env["GOROOT"] = subprocess.check_output([go, "env", "GOROOT"], cwd=source, env=env, text=True).strip()
    module = json.loads(subprocess.check_output(
        ["mise", "exec", "--", "go", "mod", "download", "-json",
         reference["module"] + "@" + reference["tag"]],
        cwd=source / "test/reference", env=env, text=True))
    if module.get("Origin", {}).get("Hash") != reference["revision"]:
        raise SystemExit("upstream module origin does not match the reference revision")
    expected = reference["module"] + " " + reference["tag"] + " " + module["Sum"]
    if expected not in (source / "test/reference/go.sum").read_text().splitlines():
        raise SystemExit("upstream module content is not pinned by go.sum")
    subprocess.run([go, "mod", "verify"], cwd=source / "test/reference", env=env, check=True)
    with tempfile.TemporaryDirectory(prefix="incus-cli-source-") as directory:
        upstream = Path(directory) / (reference["module"] + "@" + reference["tag"])
        # Extract the module zip verified by Go against the checksum pinned in
        # go.sum, rather than trusting a mutable extracted module cache.
        with zipfile.ZipFile(module["Zip"]) as archive:
            archive.extractall(directory)
        subprocess.run([go, "build", "-mod=readonly",
                        "-trimpath", "-o", str(destination), "./cmd/incus"],
                       cwd=upstream, env=env, check=True)
        subprocess.run([go, "mod", "verify"], cwd=upstream, env=env, check=True)
    return {
        "repository": reference["repository"], "revision": reference["revision"],
        "tag": reference["tag"], "module_sum": module["Sum"],
        "module_zip_sha256": sha256(module["Zip"]),
        "binary_sha256": sha256(destination),
        "go": subprocess.check_output(["mise", "exec", "--", "go", "version"],
                                      cwd=source, text=True).strip(),
        # --version is Cobra's local flag; the `version` subcommand contacts a
        # configured remote and must never be used for build provenance.
        "version": subprocess.check_output([str(destination), "--version"],
                env={**env, "INCUS_CONF": str(destination.parent / "version-only-conf")}, text=True).strip(),
        "source_modified": False,
    }


if __name__ == "__main__":
    source = Path(__file__).resolve().parents[1]
    destination = Path(sys.argv[1]).resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    provenance = build_cli(source, destination)
    destination.with_suffix(".provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(json.dumps(provenance, indent=2))
