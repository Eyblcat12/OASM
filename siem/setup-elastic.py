#!/usr/bin/env python3
"""Configure OASM's local Elastic collectors without copying browser cookies."""

import getpass
import http.cookiejar
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPCookieProcessor, ProxyHandler, Request, build_opener


def prompt(label, default=None):
    suffix = f" [{default}]" if default else ""
    value = input(label + suffix + ": ").strip() or default
    if not value:
        raise ValueError(f"{label} is required")
    return value


def origin(value):
    parsed = urlsplit(value)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("Use an HTTP(S) origin without embedded credentials")
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise ValueError("Use the origin only, without a path, query or fragment")
    return value.rstrip("/")


def write_private(path, content):
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        output.write(content)


def describe_api_error(error):
    """Expose the failing endpoint and known error codes, never response secrets."""
    path = urlsplit(error.url).path
    details = {}
    try:
        details = json.loads(error.read(4096))
    except (ValueError, OSError):
        pass
    if not isinstance(details, dict):
        details = {}
    code = details.get("code")
    # Only print codes with the shape used by Better Auth. Do not echo arbitrary
    # response messages, which may contain request data or a proxy's HTML page.
    code = code if isinstance(code, str) and re.fullmatch(r"[A-Z][A-Z0-9_]{1,79}", code) else None
    location = "sign-in" if path == "/api/auth/sign-in/email" else "workspace listing" if path == "/api/workspaces" else "workspace read check"
    text = f"OASM {location} failed: HTTP {error.code} at {path}"
    if code:
        text += f" (code={code})"
    hints = {
        "INVALID_ORIGIN": "Use the exact browser origin configured as BASE_URL in the running OASM API, including scheme and port.",
        "MISSING_OR_NULL_ORIGIN": "Check that the console proxy forwards the Origin header to OASM.",
        "BANNED_USER": "Ask an OASM administrator to check whether this account is active and approved.",
        "USER_BANNED": "Ask an OASM administrator to check whether this account is active and approved.",
        "EMAIL_NOT_VERIFIED": "Complete the account's email verification and approval in OASM.",
        "INVALID_EMAIL_OR_PASSWORD": "Check the account by signing in to the same console with a private browser window.",
    }
    hint = hints.get(code)
    if not hint:
        if location == "sign-in":
            hint = "Check sign-in in a private browser window and the OASM API authentication log. This is not an Elasticsearch error."
        elif error.code == 401:
            hint = "Sign-in did not produce a usable session. Check the browser origin, HTTPS and cookie settings."
        else:
            hint = "Check this account's workspace membership and the read permission for the failing endpoint."
    return text + "\n" + hint


def main():
    if os.name != "posix":
        raise ValueError("Run this command in Linux or a Docker-integrated WSL distribution")
    repo = Path(__file__).resolve().parent
    directory = Path.home() / "oasm-siem-managed"
    if (directory / "collector.env").exists():
        raise ValueError(f"A collector is already configured at {directory}. Use its start command below the guide.")

    project = prompt("OASM Compose project", "oasm-upstream-restore")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", project):
        raise ValueError("Invalid Docker Compose project name")
    result = subprocess.run([
        "docker", "ps", "--filter", f"label=com.docker.compose.project={project}",
        "--filter", "label=com.docker.compose.service=core-api", "--format", "{{.ID}}",
    ], check=True, capture_output=True, text=True)
    identifiers = result.stdout.split()
    if len(identifiers) != 1:
        raise ValueError("Expected one running core-api in the selected project")
    image = subprocess.check_output([
        "docker", "inspect", "--format", "{{.Config.Image}}", identifiers[0],
    ], text=True).strip()
    networks = json.loads(subprocess.check_output([
        "docker", "inspect", "--format", "{{json .NetworkSettings.Networks}}", identifiers[0],
    ], text=True))
    default_network = "oasm_net" if "oasm_net" in networks else next(iter(networks))
    network = prompt("OASM Docker network", default_network)
    if network not in networks:
        raise ValueError("The selected network is not attached to core-api")
    public = origin(prompt("OASM browser origin", "http://localhost:6276"))
    internal = origin(prompt("OASM internal API origin", "http://core-api:6277"))
    email = prompt("OASM collector account email")
    password = getpass.getpass("OASM collector account password: ")
    if not password:
        raise ValueError("The collector account password is required")

    cookies = http.cookiejar.CookieJar()
    client = build_opener(ProxyHandler({}), HTTPCookieProcessor(cookies))

    def request(path):
        with client.open(Request(public + path), timeout=10) as response:
            return json.load(response)

    payload = json.dumps({"email": email, "password": password}).encode()
    login = Request(public + "/api/auth/sign-in/email", data=payload,
                    headers={"Content-Type": "application/json", "Origin": public})
    with client.open(login, timeout=10) as response:
        response.read()
    print("OASM sign-in accepted. Checking workspace access...")

    workspaces = []
    page = 1
    while True:
        data = request(f"/api/workspaces?limit=100&page={page}")
        workspaces.extend(data["data"])
        if not data.get("hasNextPage"):
            break
        page += 1
    if not workspaces:
        raise ValueError("The account cannot read any workspaces")
    for number, workspace in enumerate(workspaces, 1):
        print(f"  {number}. {workspace['name']}")
    selection = int(prompt("Workspace number", "1"))
    if not 1 <= selection <= len(workspaces):
        raise ValueError("Invalid workspace selection")
    workspace = workspaces[selection - 1]["id"]
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", workspace):
        raise ValueError("Unexpected workspace identifier")
    for path in (f"/api/workspaces/{workspace}/audit?limit=1", "/api/vulnerabilities?limit=1", "/api/assets?limit=1"):
        with client.open(Request(public + path, headers={"X-Workspace-ID": workspace}), timeout=10) as response:
            response.read()

    endpoint = origin(prompt("Elasticsearch URL reachable from the VM containers"))
    if urlsplit(endpoint).hostname in ("localhost", "127.0.0.1", "::1"):
        raise ValueError("Use an Elasticsearch address reachable from Docker containers, rather than loopback")
    key = getpass.getpass("Elasticsearch API key (encoded): ").strip()
    if not key or any(character.isspace() for character in key):
        raise ValueError("Expected the encoded API key without an Authorization prefix")

    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    for folder in ("private", "state", "out"):
        (directory / folder).mkdir(mode=0o700, exist_ok=True)
        (directory / folder).chmod(0o700)
    account = dict(workspace=workspace, email=email, password=password, origin=public)
    write_private(directory / "private/oasm-account.json", json.dumps(account))
    write_private(directory / "private/elastic.json", json.dumps({"authorization": "ApiKey " + key}))
    # Vector runs as root inside Docker. The enclosing host directory is private.
    (directory / "private/elastic.json").chmod(0o444)
    values = dict(
        OASM_SIEM_DIR=str(directory), OASM_SOURCE_HOST=socket.gethostname(),
        OASM_COLLECTOR_UID=str(os.getuid()), OASM_COLLECTOR_GID=str(os.getgid()),
        OASM_PROJECT=project, OASM_RESULTS_IMAGE=image, OASM_DOCKER_NETWORK=network,
        OASM_BASE_URL=internal, ELASTIC_ENDPOINT=endpoint,
    )
    template = (repo / "vector-elastic.yaml").read_text(encoding="utf-8")
    rendered = template.replace(json.dumps("${ELASTIC_ENDPOINT}"), json.dumps(endpoint))
    rendered = rendered.replace("com.docker.compose.project=${OASM_PROJECT}", "com.docker.compose.project=" + project)
    write_private(directory / "vector.yaml", rendered)
    (directory / "vector.yaml").chmod(0o444)
    env = "".join(name + "='" + value.replace("'", "\\'") + "'\n" for name, value in values.items())
    write_private(directory / "collector.env", env)
    command = ["docker", "compose", "--env-file", str(directory / "collector.env"),
               "-f", str(repo / "compose.elastic.yaml")]
    subprocess.run(command + ["config", "--quiet"], check=True)
    print("Configuration saved. Run these commands:")
    print(shlex.join(command + ["run", "--rm", "--no-deps", "vector", "validate", "--no-environment", "/etc/vector/vector.yaml"]))
    print(shlex.join(command + ["up", "-d"]))
    print(shlex.join(command + ["logs", "--tail", "30"]))


if __name__ == "__main__":
    try:
        main()
    except HTTPError as error:
        print(describe_api_error(error), file=sys.stderr)
        sys.exit(1)
    except (URLError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Setup could not finish: {error}", file=sys.stderr)
        sys.exit(1)
