#!/usr/bin/env python3
"""Recursively copy current KV v2 secrets from one Vault to another."""

import os
import sys
from urllib.parse import quote

import requests


PROD_VAULT_ADDR = os.environ["PROD_VAULT_ADDR"].rstrip("/")
PROD_VAULT_TOKEN = os.environ["PROD_VAULT_TOKEN"]
NON_PROD_VAULT_ADDR = os.environ["NON_PROD_VAULT_ADDR"].rstrip("/")
NON_PROD_VAULT_TOKEN = os.environ["NON_PROD_VAULT_TOKEN"]

# Logical KV paths do not include /v1, /data, or /metadata.
KV_MOUNT = os.getenv("VAULT_KV_MOUNT", "secret").strip("/")
BASE_PATH = os.getenv(
    "VAULT_BASE_PATH", "redisenterprise-prod/rec-license"
).strip("/")
TIMEOUT = 15


def api_path(path: str) -> str:
    """URL-encode a Vault logical path while retaining slash separators."""
    return quote(path, safe="/")


def check_health(name: str, address: str) -> None:
    response = requests.get(f"{address}/v1/sys/health", timeout=TIMEOUT)
    health = response.json()

    if health.get("initialized") is not True:
        raise RuntimeError(f"{name} Vault is not initialized")
    if health.get("sealed") is not False:
        raise RuntimeError(f"{name} Vault is sealed")

    print(f"{name} Vault is initialized and unsealed.")


def list_secret_paths(session: requests.Session, folder: str):
    """Yield every leaf secret path below a KV v2 metadata folder."""
    url = (
        f"{PROD_VAULT_ADDR}/v1/{api_path(KV_MOUNT)}/metadata/"
        f"{api_path(folder)}"
    )
    response = session.request("LIST", url, timeout=TIMEOUT)
    if response.status_code == 404:
        return
    response.raise_for_status()

    keys = response.json().get("data", {}).get("keys", [])
    for key in keys:
        child_path = f"{folder.rstrip('/')}/{key}"
        if key.endswith("/"):
            yield from list_secret_paths(session, child_path.rstrip("/"))
        else:
            yield child_path


def secret_exists(session: requests.Session, path: str) -> bool:
    """Return whether the base path is itself a readable secret."""
    url = (
        f"{PROD_VAULT_ADDR}/v1/{api_path(KV_MOUNT)}/data/"
        f"{api_path(path)}"
    )
    response = session.get(url, timeout=TIMEOUT)
    if response.status_code == 404:
        return False
    response.raise_for_status()
    return isinstance(response.json().get("data", {}).get("data"), dict)


def read_secret(session: requests.Session, path: str) -> dict:
    url = (
        f"{PROD_VAULT_ADDR}/v1/{api_path(KV_MOUNT)}/data/"
        f"{api_path(path)}"
    )
    response = session.get(url, timeout=TIMEOUT)
    response.raise_for_status()

    secret = response.json().get("data", {}).get("data")
    if not isinstance(secret, dict):
        raise RuntimeError(f"Invalid KV v2 data returned for {path}")
    return secret


def write_secret(session: requests.Session, path: str, secret: dict) -> None:
    url = (
        f"{NON_PROD_VAULT_ADDR}/v1/{api_path(KV_MOUNT)}/data/"
        f"{api_path(path)}"
    )
    response = session.post(url, json={"data": secret}, timeout=TIMEOUT)
    response.raise_for_status()


def main() -> None:
    check_health("Prod", PROD_VAULT_ADDR)
    check_health("Non-prod", NON_PROD_VAULT_ADDR)

    prod = requests.Session()
    prod.headers.update({"X-Vault-Token": PROD_VAULT_TOKEN})

    non_prod = requests.Session()
    non_prod.headers.update({"X-Vault-Token": NON_PROD_VAULT_TOKEN})

    # A KV path can be a secret, a folder, or both. Include the base secret
    # itself when present, then include every leaf below it.
    paths = []
    if secret_exists(prod, BASE_PATH):
        paths.append(BASE_PATH)
    paths.extend(list_secret_paths(prod, BASE_PATH))
    paths = list(dict.fromkeys(paths))
    if not paths:
        raise RuntimeError(f"No secrets found below {KV_MOUNT}/{BASE_PATH}")

    print(f"Found {len(paths)} secret(s) below {KV_MOUNT}/{BASE_PATH}.")

    for number, path in enumerate(paths, start=1):
        print(f"[{number}/{len(paths)}] Copying {KV_MOUNT}/{path}")
        secret = read_secret(prod, path)
        write_secret(non_prod, path, secret)

    print(f"Successfully copied {len(paths)} secret(s).")


if __name__ == "__main__":
    try:
        main()
    except (
        requests.RequestException,
        KeyError,
        ValueError,
        RuntimeError,
    ) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
