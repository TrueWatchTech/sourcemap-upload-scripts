#!/usr/bin/env python3

"""
Upload an existing sourcemap.zip through OpenAPI with multipart upload.

This implementation uses only the Python standard library so customers only
need Python 3 and do not have to install extra packages.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Iterable, Optional
from urllib import error, request


DEFAULT_MERGE_PATHS = [
    "/api/v1/rum_sourcemap/part_merge",
    "/api/v1/rum_sourcemap/merge_file",
    "/api/v1/rum_sourcemap/merge_parts",
]

DEFAULT_CANCEL_PATHS = [
    "/api/v1/rum_sourcemap/upload_cancel",
    "/api/v1/rum_sourcemap/multipart_upload_cancel",
    "/api/v1/rum_sourcemap/cancel_upload",
]


class UploadError(RuntimeError):
    """Raised when the upload flow cannot continue."""


def log(message: str) -> None:
    from datetime import datetime

    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {message}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Upload an existing sourcemap.zip through OpenAPI."
    )
    parser.add_argument(
        "--endpoint",
        default=os.getenv("DF_OPENAPI_ENDPOINT", ""),
        help="OpenAPI base URL. Can also come from DF_OPENAPI_ENDPOINT.",
    )
    parser.add_argument(
        "--api-key",
        default=os.getenv("DF_API_KEY", os.getenv("DF_OPEN_API_KEY", "")),
        help="DF-API-KEY. Can also come from DF_API_KEY.",
    )
    parser.add_argument(
        "--app-id",
        default=os.getenv("DF_APP_ID", ""),
        help="RUM application ID. Can also come from DF_APP_ID.",
    )
    parser.add_argument(
        "--version",
        default=os.getenv("DF_VERSION", ""),
        help="Application version. Can also come from DF_VERSION.",
    )
    parser.add_argument(
        "--env",
        default=os.getenv("DF_ENV", ""),
        help="Deployment environment, for example daily or prod.",
    )
    parser.add_argument(
        "--file",
        default=os.getenv("DF_SOURCEMAP_FILE", ""),
        help="Path to sourcemap.zip. Can also come from DF_SOURCEMAP_FILE.",
    )
    parser.add_argument(
        "--need-cover",
        default=os.getenv("DF_NEED_COVER", "false"),
        help="Whether to overwrite an existing sourcemap. true or false.",
    )
    parser.add_argument(
        "--chunk-size-mb",
        type=int,
        default=int(os.getenv("DF_CHUNK_SIZE_MB", "10")),
        help="Multipart chunk size in MB. Maximum is 10.",
    )
    parser.add_argument(
        "--merge-path",
        default=os.getenv("DF_MERGE_PATH", ""),
        help="Override the merge endpoint path if your deployment uses a custom path.",
    )
    parser.add_argument(
        "--cancel-path",
        default=os.getenv("DF_CANCEL_PATH", ""),
        help="Override the cancel endpoint path if your deployment uses a custom path.",
    )
    return parser


def normalize_bool(value: str) -> bool:
    normalized = value.strip().lower()
    if normalized == "true":
        return True
    if normalized == "false":
        return False
    raise UploadError("--need-cover must be true or false")


def validate_args(args: argparse.Namespace) -> None:
    if not args.endpoint:
        raise UploadError("--endpoint is required")
    if not args.api_key:
        raise UploadError("--api-key is required")
    if not args.app_id:
        raise UploadError("--app-id is required")
    if not args.file:
        raise UploadError("--file is required")

    args.endpoint = args.endpoint.rstrip("/")
    file_path = Path(args.file)
    if not file_path.is_file():
        raise UploadError(f"File does not exist: {args.file}")
    if file_path.suffix.lower() != ".zip":
        raise UploadError("--file must point to a .zip file")
    if args.chunk_size_mb < 1 or args.chunk_size_mb > 10:
        raise UploadError("--chunk-size-mb must be between 1 and 10")

    if args.version and not args.env:
        log("Warning: --version is set without --env. The upload target may be less specific.")
    if args.env and not args.version:
        log("Warning: --env is set without --version. The upload target may be less specific.")


def parse_json_response(raw_body: bytes) -> dict:
    try:
        return json.loads(raw_body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise UploadError(f"OpenAPI returned non-JSON response: {raw_body.decode('utf-8', errors='replace')}") from exc


def http_post_json(endpoint: str, path: str, api_key: str, payload: dict) -> tuple[int, bytes]:
    body = json.dumps(payload).encode("utf-8")
    req = request.Request(
        url=f"{endpoint}{path}",
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "DF-API-KEY": api_key,
        },
    )
    return open_request(req)


def encode_multipart_form(fields: dict[str, str], file_field: str, file_path: Path) -> tuple[bytes, str]:
    # Build multipart/form-data manually so the script stays stdlib-only.
    boundary = f"----DFBoundary{uuid.uuid4().hex}"
    lines: list[bytes] = []

    for name, value in fields.items():
        lines.append(f"--{boundary}\r\n".encode("utf-8"))
        lines.append(
            f'Content-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode("utf-8")
        )

    filename = file_path.name
    mime_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    file_bytes = file_path.read_bytes()

    lines.append(f"--{boundary}\r\n".encode("utf-8"))
    lines.append(
        (
            f'Content-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'
            f"Content-Type: {mime_type}\r\n\r\n"
        ).encode("utf-8")
    )
    lines.append(file_bytes)
    lines.append(b"\r\n")
    lines.append(f"--{boundary}--\r\n".encode("utf-8"))

    return b"".join(lines), boundary


def http_post_multipart(
    endpoint: str,
    path: str,
    api_key: str,
    fields: dict[str, str],
    file_field: str,
    file_path: Path,
) -> tuple[int, bytes]:
    body, boundary = encode_multipart_form(fields, file_field, file_path)
    req = request.Request(
        url=f"{endpoint}{path}",
        data=body,
        method="POST",
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "DF-API-KEY": api_key,
        },
    )
    return open_request(req)


def open_request(req: request.Request) -> tuple[int, bytes]:
    try:
        with request.urlopen(req) as resp:
            return resp.getcode(), resp.read()
    except error.HTTPError as exc:
        return exc.code, exc.read()
    except error.URLError as exc:
        raise UploadError(f"Unable to reach OpenAPI: {exc.reason}") from exc


def ensure_success(status: int, body: bytes, action: str) -> dict:
    if status < 200 or status >= 300:
        raise UploadError(
            f"{action} failed with HTTP {status}: {body.decode('utf-8', errors='replace')}"
        )

    data = parse_json_response(body)
    if data.get("success") is not True:
        message = (
            data.get("message")
            or data.get("msg")
            or data.get("errorMessage")
            or data.get("error")
            or data.get("detail")
            or data.get("code")
            or "unknown error"
        )
        raise UploadError(
            f"{action} failed: {message} | response={json.dumps(data, ensure_ascii=False, separators=(',', ':'))}"
        )
    return data


def iter_chunks(file_path: Path, chunk_size_bytes: int, work_dir: Path) -> Iterable[Path]:
    # Persist chunk files in a temp directory so each part can be retried or inspected.
    with file_path.open("rb") as source:
        index = 0
        while True:
            chunk = source.read(chunk_size_bytes)
            if not chunk:
                break
            chunk_path = work_dir / f"chunk_{index:06d}"
            chunk_path.write_bytes(chunk)
            yield chunk_path
            index += 1


def init_upload(args: argparse.Namespace) -> str:
    payload = {
        "appId": args.app_id,
        "needCover": args.need_cover,
    }
    if args.version:
        payload["version"] = args.version
    if args.env:
        payload["env"] = args.env

    status, body = http_post_json(
        args.endpoint,
        "/api/v1/rum_sourcemap/multipart_upload_init",
        args.api_key,
        payload,
    )
    data = ensure_success(status, body, "multipart init")
    upload_id = ((data.get("content") or {}).get("uploadId")) or ""
    if not upload_id:
        raise UploadError(
            "Init succeeded but uploadId is empty. This usually means the same sourcemap already exists and overwrite is disabled."
        )
    log(f"Init succeeded, uploadId={upload_id}")
    return upload_id


def upload_parts(args: argparse.Namespace, upload_id: str, work_dir: Path) -> None:
    chunk_size_bytes = args.chunk_size_mb * 1024 * 1024
    chunks = list(iter_chunks(Path(args.file), chunk_size_bytes, work_dir))
    if not chunks:
        raise UploadError("No chunk files were created")

    for index, chunk_path in enumerate(chunks):
        log(f"Uploading part {index + 1}/{len(chunks)}")
        status, body = http_post_multipart(
            args.endpoint,
            "/api/v1/rum_sourcemap/upload_part",
            args.api_key,
            {
                "uploadId": upload_id,
                "chunkIndex": str(index),
            },
            "files",
            chunk_path,
        )
        ensure_success(status, body, f"upload part {index}")


def merge_upload(args: argparse.Namespace, upload_id: str) -> None:
    path_candidates = [args.merge_path] if args.merge_path else DEFAULT_MERGE_PATHS
    payload = {"uploadId": upload_id}

    # Prefer the confirmed OpenAPI path, then fall back to legacy guesses.
    for path in path_candidates:
        status, body = http_post_json(args.endpoint, path, args.api_key, payload)
        if status == 404:
            log(f"Merge endpoint {path} returned HTTP 404, trying next candidate")
            continue
        ensure_success(status, body, f"merge request ({path})")
        log(f"Merge succeeded via {path}")
        return

    raise UploadError(
        "Unable to merge uploaded parts. Re-run with --merge-path using the exact endpoint from your deployment docs if needed."
    )


def cancel_upload(args: argparse.Namespace, upload_id: str) -> None:
    path_candidates = [args.cancel_path] if args.cancel_path else DEFAULT_CANCEL_PATHS
    payload = {"uploadId": upload_id}

    # Try multiple known paths because private deployments can differ.
    for path in path_candidates:
        status, body = http_post_json(args.endpoint, path, args.api_key, payload)
        if 200 <= status < 300:
            try:
                data = parse_json_response(body)
            except UploadError:
                continue
            if data.get("success") is True:
                log(f"Cancelled multipart upload via {path}")
                return
    log(f"Best-effort cancel did not confirm success for uploadId={upload_id}")


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    upload_id: Optional[str] = None

    try:
        args.need_cover = normalize_bool(args.need_cover)
        validate_args(args)

        with tempfile.TemporaryDirectory(prefix="df-sourcemap-") as temp_dir:
            work_dir = Path(temp_dir)
            upload_id = init_upload(args)
            upload_parts(args, upload_id, work_dir)
            merge_upload(args, upload_id)

        file_size_bytes = Path(args.file).stat().st_size
        log("Upload complete")
        log(
            "Summary: "
            f"appId={args.app_id} "
            f"version={args.version or '<unset>'} "
            f"env={args.env or '<unset>'} "
            f"file={args.file} "
            f"sizeBytes={file_size_bytes}"
        )
        return 0
    except UploadError as exc:
        if upload_id:
            cancel_upload(args, upload_id)
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
