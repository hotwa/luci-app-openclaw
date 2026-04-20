#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen


OWNER_REPO = os.environ.get("GITHUB_REPOSITORY", "")
if "/" not in OWNER_REPO:
    raise SystemExit("错误: 缺少 GITHUB_REPOSITORY")
OWNER, REPO = OWNER_REPO.split("/", 1)

GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
if not GITHUB_TOKEN:
    raise SystemExit("错误: 缺少 GITHUB_TOKEN")

GITEA_API_BASE = os.environ.get("GITEA_API_BASE", "").rstrip("/")
GITEA_REPO = os.environ.get("GITEA_REPO", "")
GITEA_TOKEN = os.environ.get("GITEA_TOKEN", "")

KEEP_APP_RELEASES = max(1, int(os.environ.get("KEEP_APP_RELEASES", "1")))


def request_json(method: str, url: str, token: str | None = None, auth_style: str = "bearer"):
    headers = {
        "Accept": "application/vnd.github+json"
        if "api.github.com" in url
        else "application/json",
        "User-Agent": "codex-openclaw-cleanup",
    }
    if token:
        if auth_style == "bearer":
            headers["Authorization"] = f"Bearer {token}"
        else:
            headers["Authorization"] = f"token {token}"

    req = Request(url, method=method, headers=headers)
    try:
        with urlopen(req, timeout=60) as resp:
            raw = resp.read()
        if not raw:
            return None
        return json.loads(raw.decode("utf-8"))
    except HTTPError as exc:
        if exc.code == 404:
            return None
        body = exc.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"{method} {url} failed: {exc.code} {exc.reason}\n{body}") from exc


def github_api(method: str, path: str):
    return request_json(method, f"https://api.github.com{path}", GITHUB_TOKEN, "bearer")


def gitea_api(method: str, path: str):
    if not GITEA_API_BASE or not GITEA_REPO or not GITEA_TOKEN:
        return None
    return request_json(method, f"{GITEA_API_BASE}{path}", GITEA_TOKEN, "token")


def delete_github_release(release_id: int):
    github_api("DELETE", f"/repos/{OWNER}/{REPO}/releases/{release_id}")


def delete_github_tag(tag_name: str):
    encoded = quote(f"tags/{tag_name}", safe="/")
    try:
        github_api("DELETE", f"/repos/{OWNER}/{REPO}/git/refs/{encoded}")
    except RuntimeError as exc:
        if "404" in str(exc):
            return
        raise


def delete_github_release_asset(release_id: int, asset_id: int):
    github_api("DELETE", f"/repos/{OWNER}/{REPO}/releases/{release_id}/assets/{asset_id}")


def delete_github_run(run_id: int):
    github_api("DELETE", f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}")


def delete_gitea_release(release_id: int):
    gitea_api("DELETE", f"/repos/{GITEA_REPO}/releases/{release_id}")


def delete_gitea_tag(tag_name: str):
    try:
        gitea_api("DELETE", f"/repos/{GITEA_REPO}/tags/{quote(tag_name, safe='')}")
    except RuntimeError as exc:
        if "404" in str(exc) or "405" in str(exc) or "409" in str(exc):
            return
        raise


def list_github_releases():
    releases = []
    page = 1
    while True:
        batch = github_api("GET", f"/repos/{OWNER}/{REPO}/releases?per_page=100&page={page}") or []
        if not batch:
            break
        releases.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return releases


def list_github_runs():
    runs = []
    page = 1
    while True:
        batch = github_api("GET", f"/repos/{OWNER}/{REPO}/actions/runs?per_page=100&page={page}") or {}
        workflow_runs = batch.get("workflow_runs") or []
        if not workflow_runs:
            break
        runs.extend(workflow_runs)
        if len(workflow_runs) < 100:
            break
        page += 1
    return runs


def list_gitea_releases():
    if not GITEA_API_BASE or not GITEA_REPO or not GITEA_TOKEN:
        return []

    releases = []
    page = 1
    while True:
        batch = gitea_api("GET", f"/repos/{GITEA_REPO}/releases?limit=100&page={page}") or []
        if not batch:
            break
        releases.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return releases


def parse_version_from_openclaw_env():
    path = Path("root/usr/bin/openclaw-env")
    if not path.exists():
        return set()

    text = path.read_text(encoding="utf-8", errors="ignore")
    versions = set()
    for key in ("NODE_VERSION_V1", "NODE_VERSION_V2"):
        match = re.search(rf'^{key}="([^"]+)"$', text, re.M)
        if match:
            versions.add(match.group(1))
    return versions


def cleanup_github_app_releases():
    releases = [
        item
        for item in list_github_releases()
        if re.match(r"^v\d", item.get("tag_name") or "")
    ]
    releases.sort(
        key=lambda item: (
            item.get("published_at")
            or item.get("created_at")
            or item.get("updated_at")
            or "",
            int(item.get("id") or 0),
        ),
        reverse=True,
    )

    for release in releases[KEEP_APP_RELEASES:]:
        tag_name = release.get("tag_name") or ""
        release_id = int(release["id"])
        print(f"==> 删除 GitHub 旧 release: {tag_name} (id={release_id})")
        delete_github_release(release_id)
        if tag_name:
            delete_github_tag(tag_name)


def cleanup_github_node_bins_assets():
    release = github_api("GET", f"/repos/{OWNER}/{REPO}/releases/tags/node-bins")
    if not release:
        return

    desired_versions = parse_version_from_openclaw_env()
    if not desired_versions:
        print("==> 跳过 node-bins 资产清理: 无法从 openclaw-env 读取版本")
        return

    desired_assets = {
        f"node-v{version}-linux-arm64-musl.tar.xz" for version in desired_versions
    }
    assets = github_api("GET", f"/repos/{OWNER}/{REPO}/releases/{int(release['id'])}/assets") or []
    for asset in assets:
        name = asset.get("name") or ""
        if name and name not in desired_assets:
            print(f"==> 删除 GitHub node-bins 旧资产: {name}")
            delete_github_release_asset(int(release["id"]), int(asset["id"]))


def cleanup_github_workflow_runs():
    runs = [
        item
        for item in list_github_runs()
        if item.get("status") == "completed"
    ]
    runs.sort(
        key=lambda item: (
            item.get("created_at") or "",
            int(item.get("id") or 0),
        ),
        reverse=True,
    )

    keep_by_path: set[str] = set()
    for run in runs:
        path = run.get("path") or run.get("workflow_name") or ""
        if not path:
            continue
        if path in keep_by_path:
            print(f"==> 删除 GitHub 旧 workflow run: {path} #{run['id']}")
            delete_github_run(int(run["id"]))
        else:
            keep_by_path.add(path)


def cleanup_gitea_app_releases():
    if not GITEA_API_BASE or not GITEA_REPO or not GITEA_TOKEN:
        return

    releases = [
        item
        for item in list_gitea_releases()
        if re.match(r"^v\d", item.get("tag_name") or "")
    ]
    releases.sort(
        key=lambda item: (
            item.get("published_at")
            or item.get("created_at")
            or item.get("updated_at")
            or "",
            int(item.get("id") or 0),
        ),
        reverse=True,
    )

    for release in releases[KEEP_APP_RELEASES:]:
        tag_name = release.get("tag_name") or ""
        release_id = int(release["id"])
        print(f"==> 删除 Gitea 旧 release: {tag_name} (id={release_id})")
        delete_gitea_release(release_id)
        if tag_name:
            delete_gitea_tag(tag_name)


def main():
    print("==> 开始清理 release / workflow 历史")
    cleanup_github_app_releases()
    cleanup_github_node_bins_assets()
    cleanup_github_workflow_runs()
    cleanup_gitea_app_releases()
    print("==> 清理完成")


if __name__ == "__main__":
    main()
