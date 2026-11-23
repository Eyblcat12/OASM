#!/usr/bin/env python3
"""Manage Nuclei's scheduling timeout without editing upstream source."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


TARGET = "/app/resources/connectors/manifest.json"


def docker(*args, capture=True):
    result = subprocess.run(["docker", *args], text=True,
                            capture_output=capture, check=True)
    return result.stdout.strip() if capture else None


def discover(container):
    labels = json.loads(docker("inspect", "--format", "{{json .Config.Labels}}", container)) or {}
    if labels.get("com.docker.compose.service") != "core-api":
        raise ValueError("Select a Compose core-api container, not a connector or collector")
    project = labels.get("com.docker.compose.project", "")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", project):
        raise ValueError("Cannot identify a valid Compose project")
    directory = Path(labels.get("com.docker.compose.project.working_dir", ""))
    if not directory.is_absolute() or not directory.is_dir():
        raise ValueError("Run on the original Linux/WSL Compose host; its project directory must exist")
    files = labels.get("com.docker.compose.project.config_files", "").split(",")
    if not files or any(not Path(file).is_absolute() or not Path(file).is_file() for file in files):
        raise ValueError("Compose source files are missing; restore them before applying changes")
    env_files = labels.get("com.docker.compose.project.environment_file", "")
    env_files = env_files.split(",") if env_files else [str(directory / ".env")]
    if any(not Path(file).is_absolute() or not Path(file).is_file() for file in env_files):
        raise ValueError("Deployment .env files are missing; no changes applied")
    root = Path.home() / ".local/share/ncs-oasm/runtime" / project
    overlay = root / "compose.runtime.yaml"
    files = list(dict.fromkeys(file for file in files if Path(file) != overlay))
    if not files:
        raise ValueError("No base Compose configuration found")
    return project, directory, files, env_files, root


def compose_args(deployment, managed=False):
    project, directory, files, env_files, root = deployment
    args = ["compose", "--project-directory", str(directory), "-p", project]
    for file in env_files:
        args.extend(["--env-file", file])
    for file in files:
        args.extend(["-f", file])
    if managed:
        args.extend(["-f", str(root / "compose.runtime.yaml")])
    # Preserve the independently managed worker policy in all future commands.
    worker_overlay = root / "compose.worker.yaml"
    if worker_overlay.exists() and str(worker_overlay) not in files:
        args.extend(["-f", str(worker_overlay)])
    return args


def read_manifest(container):
    with tempfile.TemporaryDirectory(prefix="oasm-manifest-") as directory:
        dest = Path(directory) / "manifest.json"
        docker("cp", f"{container}:{TARGET}", str(dest))
        return json.loads(dest.read_text(encoding="utf-8"))


def set_timeout(manifest, minutes):
    entries = [entry for entry in manifest.get("connectors", []) if entry.get("slug") == "nuclei"]
    if len(entries) != 1:
        raise ValueError("Expected exactly one Nuclei manifest entry")
    entry = entries[0]
    defaults = entry.setdefault("resourceDefaults", {})
    if not isinstance(defaults, dict):
        raise ValueError("Invalid Nuclei resourceDefaults; no changes applied")
    old = defaults.get("timeoutSeconds", 600)
    defaults["timeoutSeconds"] = minutes * 60
    return old


def write_file(path, contents):
    # Replace atomically with a private file. The API container must be recreated
    # after changing the manifest, since registry contents are cached at startup.
    fd, temporary = tempfile.mkstemp(prefix=".runtime-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(contents)
        # The manifest contains public connector metadata; API images can run
        # as non-root. Directory 0700 still protects files from other host users.
        os.chmod(temporary, 0o644 if path.name == "manifest.json" else 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configure_worker(deployment, jobs, check):
    if not 1 <= jobs <= 16:
        raise ValueError("Worker jobs must be from 1 to 16; choose 1 on the current small VM")
    command = compose_args(deployment)
    ids = docker(*command, "ps", "-a", "-q", "oasm-worker").split()
    if len(ids) != 1:
        raise ValueError("This convenience command requires exactly one existing worker replica")
    running_image = docker("inspect", "--format", "{{.Config.Image}}", ids[0])
    config = json.loads(docker(*command, "config", "--format", "json"))
    if config.get("services", {}).get("oasm-worker", {}).get("image") != running_image:
        raise ValueError("Compose selects a different worker image; use the deployment upgrade procedure first")
    print(f"Worker policy: at most {jobs} claimed jobs concurrently per worker; pool limits unchanged")
    if check:
        print("Read-only check passed. No files changed and no containers restarted.")
        return
    root = deployment[-1]
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    path = root / "compose.worker.yaml"
    previous = path.read_text() if path.exists() else None
    if previous is not None:
        write_file(path.with_name(path.name + ".previous"), previous)
    overlay = {"services": {"oasm-worker": {"environment": {"WORKER_MAX_CONCURRENCY": str(jobs)}}}}
    write_file(path, json.dumps(overlay, indent=2) + "\n")
    command = compose_args(deployment)
    try:
        docker(*command, "config", "--quiet")
    except subprocess.CalledProcessError:
        if previous is None:
            path.unlink(missing_ok=True)
        else:
            write_file(path, previous)
        raise ValueError("Compose validation failed; worker policy restored; worker was not restarted")
    print("Recreating worker only. Run after active scans finish or are cancelled; ongoing scans can be interrupted.", flush=True)
    docker(*command, "up", "-d", "--no-deps", "--pull", "never", "--force-recreate",
           "--scale", "oasm-worker=1", "--wait", "--wait-timeout", "180", "oasm-worker", capture=False)
    new_worker = docker(*command, "ps", "-q", "oasm-worker")
    env = json.loads(docker("inspect", "--format", "{{json .Config.Env}}", new_worker))
    # Never print the rest of Config.Env: it contains the worker key.
    if f"WORKER_MAX_CONCURRENCY={jobs}" not in env:
        raise ValueError("Worker concurrency verification failed")
    print(f"Verified WORKER_MAX_CONCURRENCY={jobs}\nSaved overlay: {path}")
    print("Check Workers Online. Retry failed runs manually; this command does not start scans.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", default="oasm-api", help="API container name (default: oasm-api)")
    commands = parser.add_subparsers(dest="command", required=True)
    timeout = commands.add_parser("timeout", help="set Nuclei timeout in minutes and recreate API")
    timeout.add_argument("minutes", type=int)
    timeout.add_argument("--check", action="store_true", help="read-only inspection; do not write or restart")
    worker = commands.add_parser("worker-jobs", help="set claimed job concurrency for one existing worker replica")
    worker.add_argument("jobs", type=int)
    worker.add_argument("--check", action="store_true", help="inspect without changing files or restarting")
    commands.add_parser("apply", help="apply minutes saved in the managed settings.json")
    commands.add_parser("status", help="show stack status and active/saved timeout")
    args = parser.parse_args()
    if os.name != "posix":
        raise ValueError("Run in Linux or Ubuntu WSL integrated with the deployment Docker engine")
    deployment = discover(args.container)
    project, _, _, _, root = deployment
    settings = root / "settings.json"
    if args.command == "worker-jobs":
        configure_worker(deployment, args.jobs, args.check)
        return
    if args.command == "status":
        manifest = read_manifest(args.container)
        old = set_timeout(manifest, 60)
        print(f"Project: {project}; active manifest timeout: {old} seconds")
        if settings.exists():
            saved = json.loads(settings.read_text())
            print(f"Saved timeout: {saved['nuclei_timeout_minutes']} minutes; settings: {settings}")
        docker(*compose_args(deployment), "ps", "-a", capture=False)
        return
    if args.command == "apply":
        if not settings.exists():
            raise ValueError("No saved configuration. Run: manage-runtime.py timeout 60")
        minutes = json.loads(settings.read_text())["nuclei_timeout_minutes"]
    else:
        minutes = args.minutes
    # Worker connector-connect deadline is five minutes. Keep the job budget
    # above it, and reject accidental unbounded or multi-day execution settings.
    if type(minutes) is not int or not 10 <= minutes <= 1440:
        raise ValueError("Timeout must be an integer from 10 to 1440 minutes")
    manifest = read_manifest(args.container)
    old = set_timeout(manifest, minutes)
    print(f"Project: {project}; Nuclei timeout: {old} -> {minutes * 60} seconds")
    if args.command == "timeout" and args.check:
        print("Read-only check passed. No files changed and no containers restarted.")
        return
    running_image = docker("inspect", "--format", "{{.Config.Image}}", args.container)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    paths = [root / "manifest.json", root / "compose.runtime.yaml", settings]
    previous = {path: path.read_text() if path.exists() else None for path in paths}
    # Keep one previous version for operator recovery, without saving secrets.
    for path, content in previous.items():
        if content is not None:
            write_file(path.with_name(path.name + ".previous"), content)
    overlay = {"services": {"core-api": {"volumes": [{
        "type": "bind", "source": str(root / "manifest.json"),
        "target": TARGET, "read_only": True,
    }]}}}
    write_file(paths[0], json.dumps(manifest, indent=2) + "\n")
    write_file(paths[1], json.dumps(overlay, indent=2) + "\n")
    write_file(settings, json.dumps({"nuclei_timeout_minutes": minutes}, indent=2) + "\n")
    command = compose_args(deployment, managed=True)
    try:
        # Resolved config can contain secrets. Inspect only the image field in
        # memory; never log or persist the resolved configuration.
        resolved = json.loads(docker(*command, "config", "--format", "json"))
        image = resolved.get("services", {}).get("core-api", {}).get("image")
        if image != running_image:
            raise ValueError("Compose selects a different API image; use the deployment upgrade procedure first")
    except (subprocess.CalledProcessError, ValueError):
        for path, content in previous.items():
            if content is None:
                path.unlink(missing_ok=True)
            else:
                write_file(path, content)
        raise ValueError("Compose validation/image check failed; managed files restored; API was not restarted")
    print("Recreating core-api only. Run while no scans are active; worker connections can briefly drop.", flush=True)
    docker(*command, "up", "-d", "--no-deps", "--pull", "never", "--force-recreate", "--wait", "--wait-timeout", "180", "core-api", capture=False)
    new_api = docker(*command, "ps", "-q", "core-api")
    verify = ('const m=require("' + TARGET + '");'
              'const n=m.connectors.find(x=>x.slug==="nuclei");'
              f'if(n?.resourceDefaults?.timeoutSeconds!=={minutes * 60}) process.exit(1);'
              'console.log("Verified timeoutSeconds="+n.resourceDefaults.timeoutSeconds)')
    docker("exec", new_api, "node", "-e", verify, capture=False)
    print(f"Saved settings: {settings}\nApplies to newly dispatched jobs; does not extend jobs already running.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"Runtime configuration failed: {error}", file=sys.stderr)
        print("Do not start another scan until API health and worker connectivity have been checked.", file=sys.stderr)
        sys.exit(1)
