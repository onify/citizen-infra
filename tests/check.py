#!/usr/bin/env python3
"""Check a configured installation, or run offline checks with test inputs."""

import argparse
import base64
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SECRET_KEYS = (
    "ONIFY_initialLicense",
    "ONIFY_adminUser_password",
    "ONIFY_apiTokens_app_secret",
    "ONIFY_client_secret",
)


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def env_file(path):
    require(path.is_file(), f"Missing {path}; copy and fill in the example first.")
    values = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        require(separator and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key),
                f"Invalid KEY=value entry in {path.name}, line {number}.")
        require(key not in values, f"Duplicate key {key} in {path.name}.")
        values[key] = value
    return values


def render(path):
    return subprocess.check_output(["kubectl", "kustomize", str(path)], text=True)


def validate_schema(rendered, version):
    require(shutil.which("kubeconform"), "Install kubeconform to use --schema.")
    subprocess.run(["kubeconform", "-strict", "-summary", "-kubernetes-version", version],
                   input=rendered, text=True, check=True)


def resources(rendered):
    # ponytail: reads kubectl's canonical YAML; use a YAML parser if input formats expand.
    result = {}
    for doc in rendered.strip().split("\n---\n"):
        kind = re.search(r"(?m)^kind: (\S+)$", doc).group(1)
        name = re.search(r"(?m)^  name: (\S+)$", doc).group(1)
        result[kind, name] = doc
    return result


def check(path):
    secrets = env_file(path / "secrets.env")
    config = env_file(path / "config.env")
    require(not set(SECRET_KEYS).intersection(config),
            "Keep authentication values in secrets.env, not config.env.")
    for key in SECRET_KEYS:
        require(bool(secrets.get(key, "").strip()), f"Fill in {key} in secrets.env.")
        require(not secrets[key].strip().startswith("REPLACE_WITH_"),
                f"Replace the placeholder for {key} in secrets.env.")
    for key in ("ONIFY_client_code", "ONIFY_client_instance", "ONIFY_db_indexPrefix"):
        require(bool(config.get(key, "").strip()), f"Fill in {key} in config.env.")
    rendered = render(path)
    require("REPLACE_WITH_" not in rendered, "Select all image repositories and tags.")
    require(not re.search(r"(?m)^\s+image: onify-(api|app|gateway)-image$", rendered),
            "Set image replacements for API, app and Gateway in kustomization.yaml.")
    objects = resources(rendered)
    namespaces = [name for kind, name in objects if kind == "Namespace"]
    require(len(namespaces) == 1, "Declare one installation namespace.")
    require(("Namespace", namespaces[0]) in resources((path / "namespace.yaml").read_text()),
            "Set the same namespace in namespace.yaml and kustomization.yaml.")
    for (kind, name), doc in objects.items():
        if kind in ("StatefulSet", "Deployment", "Service", "ConfigMap", "Secret", "Ingress", "PersistentVolumeClaim"):
            require(f"  namespace: {namespaces[0]}" in doc,
                    f"{kind}/{name} must use the installation namespace.")
    workloads = {key for key in objects if key[0] in ("StatefulSet", "Deployment")}
    require(workloads == {
        ("StatefulSet", "onify-api"), ("StatefulSet", "onify-worker"),
        ("StatefulSet", "onify-app"), ("StatefulSet", "onify-elasticsearch"),
        ("Deployment", "onify-gateway"),
    }, "Expected API, worker, app, Elasticsearch and Gateway workloads.")
    secret_name = next((name for kind, name in objects
                        if kind == "Secret" and name.startswith("onify-api-secrets-")), None)
    require(secret_name, "Keep the generated onify-api-secrets Secret and its content hash.")
    for name in ("onify-api", "onify-worker"):
        require(f"name: {secret_name}" in objects["StatefulSet", name],
                f"{name} must reference the generated Secret.")
    app = objects["StatefulSet", "onify-app"]
    require("ONIFY_API_URL_INTERNAL" in app and "http://onify-api:8181" in app,
            "App must proxy browser API requests to the internal API.")
    require("secretRef:" not in app, "API credentials must not be passed to the app.")
    app_ingress = objects["Ingress", "onify-app"]
    require("path: /\n" in app_ingress and "number: 4000" in app_ingress
            and "/helix" not in app_ingress, "App Ingress must serve / on port 4000.")
    ingresses = "\n".join(doc for (kind, _), doc in objects.items() if kind == "Ingress")
    require("onify-gateway" not in ingresses and "onify-elasticsearch" not in ingresses,
            "Gateway and Elasticsearch must stay internal.")
    require("port: 8686" in objects["Service", "onify-gateway"],
            "Gateway Service must use port 8686.")
    for (kind, name), doc in objects.items():
        if kind == "Service":
            require("type: ClusterIP" in doc, f"{name} must use ClusterIP.")
    elasticsearch = objects["StatefulSet", "onify-elasticsearch"]
    require("persistentVolumeClaim:" in elasticsearch
            and "mountPath: /usr/share/elasticsearch/data" in elasticsearch,
            "Elasticsearch must mount persistent customer data.")
    return rendered


def self_check(schema_version=None):
    with tempfile.TemporaryDirectory(prefix="onify-citizen-check-") as temp:
        root = Path(temp)
        shutil.copytree(ROOT / "kubernetes", root / "kubernetes")
        overlay = root / "examples" / "acme"
        shutil.copytree(ROOT / "examples" / "acme", overlay,
                        ignore=shutil.ignore_patterns("secrets.env"))
        kustomization = overlay / "kustomization.yaml"
        secret_file = overlay / "secrets.env"
        shutil.copy(overlay / "secrets.env.example", secret_file)
        failed = subprocess.run([sys.executable, __file__, str(overlay)], capture_output=True)
        assert failed.returncode != 0 and b"Fill in ONIFY_initialLicense" in failed.stderr
        secret_file.write_text("".join(f"{key}=test-only-{key}#!=$()\n" for key in SECRET_KEYS))
        failed = subprocess.run([sys.executable, __file__, str(overlay)], capture_output=True)
        assert failed.returncode != 0 and b"Select all image" in failed.stderr
        kustomization.write_text(re.sub(r"REPLACE_WITH_\w+", "selfcheck", kustomization.read_text()))
        original = check(overlay)
        assert original == render(overlay), "Unchanged inputs must render identically."
        if schema_version:
            validate_schema(original, schema_version)
        objects = resources(original)
        original_secret = next(key for key in objects if key[0] == "Secret")
        for key in SECRET_KEYS:
            encoded = re.search(rf"(?m)^  {key}: (\S+)$", objects[original_secret]).group(1)
            assert base64.b64decode(encoded).decode() == f"test-only-{key}#!=$()"
        api = objects["StatefulSet", "onify-api"]
        worker = objects["StatefulSet", "onify-worker"]
        assert re.search(r"image: (\S+)", api).group(1) == re.search(r"image: (\S+)", worker).group(1)
        assert "- worker\n" in worker
        assert ("PersistentVolumeClaim", "onify-elasticsearch-data") in objects
        assert "claimName: onify-elasticsearch-data" in objects["StatefulSet", "onify-elasticsearch"]
        config_file = overlay / "config.env"
        config_file.write_text(config_file.read_text().replace("ONIFY_logging_log=stdout,elastic", "ONIFY_logging_log=stdout"))
        reconfigured = resources(check(overlay))
        for name in ("onify-api", "onify-worker"):
            assert reconfigured["StatefulSet", name] != objects["StatefulSet", name]
        assert reconfigured["StatefulSet", "onify-app"] == objects["StatefulSet", "onify-app"]
        secret_file.write_text(secret_file.read_text().replace("test-only-ONIFY_client_secret", "changed-secret"))
        changed = resources(check(overlay))
        changed_secret = next(key for key in changed if key[0] == "Secret")
        assert changed_secret != original_secret, "Secret changes must trigger new pod references."
        for name in ("onify-api", "onify-worker"):
            assert original_secret[1] not in changed["StatefulSet", name]
        for source in (ROOT / "examples" / "elasticsearch").glob("backup-*.yaml"):
            shutil.copy(source, overlay / source.name)
        kustomization.write_text(kustomization.read_text().replace(
            "  - storage.yaml", "  - storage.yaml\n  - backup-storage.yaml")
            + "patches:\n  - path: backup-patch.yaml\n")
        with_backup = check(overlay)
        if schema_version:
            validate_schema(with_backup, schema_version)
        backup = resources(with_backup)
        elasticsearch = backup["StatefulSet", "onify-elasticsearch"]
        assert "claimName: onify-elasticsearch-data" in elasticsearch
        assert "claimName: onify-elasticsearch-backup" in elasticsearch
        assert "name: path.repo" in elasticsearch
        assert ("PersistentVolumeClaim", "onify-elasticsearch-backup") in backup
        kustomization.write_text(kustomization.read_text().replace("namespace: onify-citizen-test", "namespace: another-installation"))
        namespace_file = overlay / "namespace.yaml"
        failed = subprocess.run([sys.executable, __file__, str(overlay)], capture_output=True)
        assert failed.returncode != 0 and b"Set the same namespace" in failed.stderr
        namespace_file.write_text(namespace_file.read_text().replace("onify-citizen-test", "another-installation"))
        renamed = resources(check(overlay))
        assert ("Namespace", "another-installation") in renamed
        for (kind, _), doc in renamed.items():
            if kind != "Namespace":
                assert re.search(r"(?m)^  namespace: another-installation$", doc)
    print("Kustomize checks passed (no cluster access).")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("installation", nargs="?", type=Path)
    parser.add_argument("--schema", action="store_true", help="Validate with kubeconform.")
    parser.add_argument("--kubernetes-version", default="1.32.0", help="Schema version for --schema (default: 1.32.0).")
    args = parser.parse_args()
    if args.installation is None:
        self_check(args.kubernetes_version if args.schema else None)
    else:
        rendered = check(args.installation.resolve())
        if args.schema:
            validate_schema(rendered, args.kubernetes_version)
        print("Installation configuration and rendering checks passed (no cluster access).")
