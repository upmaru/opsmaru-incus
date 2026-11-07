"""Validate explicit G6 live-gateway inputs and record an UNRUN gate.

This preflight performs no backend I/O, starts no host and runs no native CLI.
Live protocol acceptance remains a separate, incomplete task (G6 / 7.4).
"""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit


class InvalidConfig(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidConfig(message)


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "configuration contains duplicate fields")
        result[key] = value
    return result


def invalid_constant(_value):
    raise InvalidConfig("configuration contains a non-JSON numeric constant")


def project_name(value):
    return isinstance(value, str) and re.fullmatch(
        r"opsmaru-acceptance-gateway-[a-z0-9][a-z0-9-]{0,62}", value)


def private_reference(value, field):
    require(isinstance(value, str) and Path(value).is_absolute(),
            field + " requires an absolute file reference")
    require(Path(value).is_file(), field + " file is unavailable")


def https_endpoint(config, field):
    require(isinstance(config, dict), field + " is required")
    url = config.get("https")
    require(isinstance(url, str), field + " requires an explicit HTTPS origin")
    try:
        parsed = urlsplit(url)
        port = parsed.port
    except ValueError:
        raise InvalidConfig(field + " has an invalid HTTPS origin") from None
    require(parsed.scheme == "https" and bool(parsed.hostname) and
            parsed.username is None and parsed.password is None and
            parsed.path in ("", "/") and not parsed.query and not parsed.fragment and
            (port is None or 0 < port <= 65535), field + " has an invalid HTTPS origin")
    for name in ("server_certificate", "client_certificate", "client_key"):
        private_reference(config.get(name), field + "." + name)


def validate(config):
    require(isinstance(config, dict), "configuration must be an object")
    require(config.get("allow_namespaced_mutations") is True,
            "explicit allow_namespaced_mutations=true is required")
    require(config.get("expected_version") == "7.0.1", "expected_version must be pinned to 7.0.1")
    project = config.get("project")
    require(project_name(project),
            "a dedicated opsmaru-acceptance-gateway project is required")
    for side in ("source", "target"):
        endpoint = config.get(side)
        require(isinstance(endpoint, dict), side + " configuration is required")
        require(project_name(endpoint.get("project", project)), side + ".project requires a dedicated namespace")
        https_endpoint(endpoint.get("gateway"), side + ".gateway")
        backend = endpoint.get("backend")
        require(isinstance(backend, dict), side + ".backend is required")
        if "socket" in backend:
            require("https" not in backend and isinstance(backend["socket"], str) and
                    Path(backend["socket"]).is_absolute(), side + ".backend requires one explicit transport")
        else:
            https_endpoint(backend, side + ".backend")
        for name in ("image", "pool"):
            require(isinstance(endpoint.get(name), str) and bool(endpoint[name].strip()),
                    side + "." + name + " is required")
    require(config["source"]["backend"] != config["target"]["backend"] or
            config["source"].get("project", project) != config["target"].get("project", project),
            "source and target require separate backend or project selections")
    report = config.get("report")
    require(isinstance(report, str) and Path(report).is_absolute(), "report requires an absolute path")
    require(not Path(report).exists() and not Path(report).is_symlink(), "report already exists")
    return Path(report)


def main():
    path = os.environ.get("OPSMARU_GATEWAY_ACCEPTANCE_CONFIG")
    require(isinstance(path, str) and Path(path).is_absolute(),
            "OPSMARU_GATEWAY_ACCEPTANCE_CONFIG requires an explicit absolute path")
    try:
        with Path(path).open("rb") as input_file:
            raw = input_file.read(65537)
        require(len(raw) <= 65536, "configuration exceeds 64 KiB")
        config = json.loads(raw, object_pairs_hook=unique_fields, parse_constant=invalid_constant)
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise InvalidConfig("configuration file is unavailable or invalid JSON") from None
    report = validate(config)
    result = {
        "schema": "opsmaru-incus-gateway-preflight/v1",
        "evidence": "configuration-preflight",
        "phase": "unrun",
        "project": config["project"],
        "projects": {side: config[side].get("project", config["project"]) for side in ("source", "target")},
        "config_sha256": hashlib.sha256(raw).hexdigest(),
        "backend_access": "unrun",
        "protocol_acceptance": "unrun",
        "mutation_authorization": "explicit; unused by preflight",
        "required_live_checks": ["fresh-project-and-backend-identity", "native-protocols",
                                 "migration-source-and-target-relay-pull-push",
                                 "denial-interruption-and-operation-reconciliation"],
        "typed_client_coverage": "unchanged",
        "installed_host": "unrun",
        "macus_hardware": "unrun",
    }
    # Exclusive, owner-private report; never overwrite an earlier run's journal.
    fd = os.open(report, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(result, output, indent=2)
        output.write("\n")
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except InvalidConfig as error:
        print("Gateway acceptance preflight refused: " + str(error), file=sys.stderr)
        sys.exit(2)
    except OSError:
        # Do not print file contents, URLs, credential references or parser input.
        print("Gateway acceptance preflight refused; check explicit private configuration and unused report path.", file=sys.stderr)
        sys.exit(2)
