#!/usr/bin/env bash
# Tahap 3 - sinkronisasi Google Drive. Jalankan dari DALAM folder geomacro-pulse:  bash apply_tahap3.sh
set -euo pipefail
[ -f src/validate.py ] || { echo "Jalankan dari root geomacro-pulse (Tahap 1-2 harus sudah terpasang)"; exit 1; }
[ -f client_secret.json ] || echo "PERINGATAN: client_secret.json belum ada di folder ini"
mkdir -p src/cloud && touch src/cloud/__init__.py
cat > src/cloud/gdrive_sync.py << 'GEOMACRO_EOF'
"""Sinkronisasi data/raw -> Google Drive (jembatan ke Colab).

Pakai OAuth user credentials (file dimiliki akunmu, bukan service account) dengan
scope drive.file: skrip hanya bisa menyentuh file/folder yang DIA buat sendiri.
Folder tujuan (settings.yaml -> drive.folder_path, default geomacro/raw) dibuat otomatis.

Pemakaian:
  python -m src.cloud.gdrive_sync --auth     # sekali saja: login & simpan refresh token ke .env
  python -m src.cloud.gdrive_sync            # upload/update semua file di data/raw
  python -m src.cloud.gdrive_sync --files data/raw/market.parquet
"""
import argparse
import hashlib
import json
import os
import socket
import ssl
import sys
from pathlib import Path

from google.auth.exceptions import RefreshError
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaFileUpload
from tenacity import retry, retry_if_exception, stop_after_attempt, wait_exponential

from src.common import RAW_DIR, ROOT, get_logger, load_settings

log = get_logger("gdrive")

SCOPES = ["https://www.googleapis.com/auth/drive.file"]
TOKEN_URI = "https://oauth2.googleapis.com/token"
FOLDER_MIME = "application/vnd.google-apps.folder"
DEFAULT_FOLDER_PATH = "geomacro/raw"
ENV_PATH = ROOT / ".env"


# ---------------------------------------------------------------- auth
def _set_env(key: str, value: str) -> None:
    """Tulis/ubah satu baris KEY=value di .env."""
    lines = ENV_PATH.read_text(encoding="utf-8").splitlines() if ENV_PATH.exists() else []
    for i, line in enumerate(lines):
        if line.startswith(f"{key}="):
            lines[i] = f"{key}={value}"
            break
    else:
        lines.append(f"{key}={value}")
    ENV_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


def authorize(open_browser: bool = True) -> None:
    """Login Google sekali, lalu simpan client id/secret/refresh token ke .env."""
    from google_auth_oauthlib.flow import InstalledAppFlow

    secret = ROOT / "client_secret.json"
    if not secret.exists():
        raise FileNotFoundError(f"{secret} tidak ditemukan")
    flow = InstalledAppFlow.from_client_secrets_file(str(secret), SCOPES)
    creds = flow.run_local_server(port=0, open_browser=open_browser, access_type="offline", prompt="consent")
    if not creds.refresh_token:
        raise RuntimeError(
            "Google tidak mengembalikan refresh token. Cabut akses lama di "
            "myaccount.google.com/permissions lalu jalankan --auth lagi."
        )
    data = json.loads(secret.read_text(encoding="utf-8"))
    info = data.get("installed") or data.get("web")
    _set_env("GOOGLE_CLIENT_ID", info["client_id"])
    _set_env("GOOGLE_CLIENT_SECRET", info["client_secret"])
    _set_env("GOOGLE_REFRESH_TOKEN", creds.refresh_token)
    log.info("Otorisasi berhasil. Kredensial disimpan di .env (jangan di-commit).")
    print("\nUntuk GitHub Actions (Tahap 4), simpan 3 nilai di .env sebagai GitHub Secrets:")
    print("  GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN")


def get_service():
    cid = os.getenv("GOOGLE_CLIENT_ID")
    secret = os.getenv("GOOGLE_CLIENT_SECRET")
    refresh = os.getenv("GOOGLE_REFRESH_TOKEN")
    if not (cid and secret and refresh):
        raise RuntimeError("Kredensial Google belum ada di .env. Jalankan: python -m src.cloud.gdrive_sync --auth")
    creds = Credentials(
        token=None, refresh_token=refresh, token_uri=TOKEN_URI,
        client_id=cid, client_secret=secret, scopes=SCOPES,
    )
    try:
        creds.refresh(Request())
    except RefreshError as e:
        raise RuntimeError(
            f"Refresh token ditolak ({e}). Kemungkinan kedaluwarsa (consent screen masih 'Testing'?) "
            "atau akses dicabut. Jalankan --auth lagi."
        ) from e
    return build("drive", "v3", credentials=creds, cache_discovery=False)


# ---------------------------------------------------------------- helper Drive
def _esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace("'", "\\'")


def _md5(path: Path) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _is_transient(exc: BaseException) -> bool:
    if isinstance(exc, HttpError):
        return exc.resp.status in (429, 500, 502, 503, 504)
    return isinstance(exc, (ConnectionError, TimeoutError, socket.timeout, ssl.SSLError))


_retry = retry(
    retry=retry_if_exception(_is_transient),
    stop=stop_after_attempt(5),
    wait=wait_exponential(multiplier=2, max=60),
    reraise=True,
)


@_retry
def _find_folder(service, name: str, parent_id: str):
    q = f"mimeType='{FOLDER_MIME}' and name='{_esc(name)}' and '{parent_id}' in parents and trashed=false"
    res = service.files().list(q=q, spaces="drive", fields="files(id,name)", pageSize=10).execute(num_retries=2)
    files = res.get("files", [])
    return files[0]["id"] if files else None


@_retry
def _create_folder(service, name: str, parent_id: str) -> str:
    meta = {"name": name, "mimeType": FOLDER_MIME, "parents": [parent_id]}
    return service.files().create(body=meta, fields="id").execute(num_retries=2)["id"]


def ensure_folder_path(service, folder_path: str) -> str:
    """Pastikan 'a/b/c' ada di My Drive (buat kalau belum), kembalikan ID folder terakhir."""
    parent = "root"
    for part in [p for p in folder_path.strip("/").split("/") if p]:
        fid = _find_folder(service, part, parent)
        if fid is None:
            fid = _create_folder(service, part, parent)
            log.info("Folder Drive dibuat: %s", part)
        parent = fid
    return parent


@_retry
def _list_files(service, name: str, folder_id: str) -> list[dict]:
    q = f"name='{_esc(name)}' and '{folder_id}' in parents and trashed=false and mimeType!='{FOLDER_MIME}'"
    res = service.files().list(
        q=q, spaces="drive", fields="files(id,name,md5Checksum,modifiedTime)", pageSize=10
    ).execute(num_retries=2)
    return res.get("files", [])


@_retry
def _upload(service, path: Path, folder_id: str, file_id: str | None) -> str:
    mime = "application/json" if path.suffix == ".json" else "application/octet-stream"
    media = MediaFileUpload(str(path), mimetype=mime, resumable=True)  # dibuat ulang tiap percobaan
    if file_id:
        return service.files().update(fileId=file_id, media_body=media, fields="id").execute(num_retries=2)["id"]
    meta = {"name": path.name, "parents": [folder_id]}
    return service.files().create(body=meta, media_body=media, fields="id").execute(num_retries=2)["id"]


def upload_or_update(service, file_path, folder_id: str) -> str:
    """Upload file baru, atau update isi file bernama sama di folder itu.

    Return: 'created' | 'updated' | 'skipped' (isi sama persis, tidak diunggah ulang).
    """
    path = Path(file_path)
    if not path.is_file():
        raise FileNotFoundError(path)

    matches = _list_files(service, path.name, folder_id)
    if len(matches) > 1:
        log.warning("%s: ada %d file bernama sama di Drive; yang pertama diupdate", path.name, len(matches))

    if matches:
        existing = matches[0]
        if existing.get("md5Checksum") == _md5(path):
            log.info("Lewati %s (isi sama dengan di Drive)", path.name)
            return "skipped"
        _upload(service, path, folder_id, existing["id"])
        log.info("Update %s (%.1f MB)", path.name, path.stat().st_size / 1e6)
        return "updated"

    _upload(service, path, folder_id, None)
    log.info("Upload baru %s (%.1f MB)", path.name, path.stat().st_size / 1e6)
    return "created"


def sync_raw(paths=None) -> dict:
    """Sinkronkan file data/raw (parquet + laporan validasi) ke Drive."""
    if paths:
        files = [Path(p) for p in paths]
    else:
        files = sorted(RAW_DIR.glob("*.parquet"))
        report = RAW_DIR / "validation_report.json"
        if report.exists():
            files.append(report)
    if not files:
        raise RuntimeError(f"Tidak ada file untuk disinkronkan di {RAW_DIR}")

    folder_path = load_settings().get("drive", {}).get("folder_path", DEFAULT_FOLDER_PATH)
    service = get_service()
    folder_id = ensure_folder_path(service, folder_path)

    counts = {"created": 0, "updated": 0, "skipped": 0}
    for f in files:
        counts[upload_or_update(service, f, folder_id)] += 1
    log.info("Sync selesai ke 'My Drive/%s': %s", folder_path, counts)
    return counts


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--auth", action="store_true", help="login Google sekali & simpan refresh token")
    p.add_argument("--no-browser", action="store_true", help="jangan buka browser otomatis (cetak URL saja)")
    p.add_argument("--files", nargs="*", help="sinkronkan file tertentu saja")
    args = p.parse_args()
    try:
        if args.auth:
            authorize(open_browser=not args.no_browser)
        else:
            sync_raw(args.files)
        return 0
    except Exception:
        log.exception("gdrive_sync gagal")
        return 1


if __name__ == "__main__":
    sys.exit(main())
GEOMACRO_EOF
cat > src/run_ingestion.py << 'GEOMACRO_EOF'
"""Entry point ingestion + validasi.

Contoh:
  python -m src.run_ingestion                        # semua sumber, incremental, lalu validasi
  python -m src.run_ingestion --only market fred
  python -m src.run_ingestion --only gdelt --gdelt-limit 2 --skip-validate   # uji coba
  python -m src.run_ingestion --sync                 # + upload ke Google Drive kalau semuanya sukses
Exit code 1 kalau ada sumber gagal, validasi menemukan ERROR, atau sync gagal
(supaya GitHub Actions menandai job gagal).
"""
import argparse
import sys

from src.common import get_logger

log = get_logger("run")
SOURCES = ["market", "fred", "gdelt"]


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--only", nargs="+", choices=SOURCES, default=SOURCES)
    p.add_argument("--start", help="paksa tanggal mulai (YYYY-MM-DD)")
    p.add_argument("--gdelt-limit", type=int, help="batasi jumlah hari GDELT (untuk uji coba)")
    p.add_argument("--skip-validate", action="store_true", help="lewati validasi di akhir")
    p.add_argument("--sync", action="store_true", help="upload data/raw ke Google Drive (dilewati kalau ada kegagalan)")
    args = p.parse_args()

    failed = []
    for name in args.only:
        log.info("=== %s ===", name)
        try:
            if name == "market":
                from src.ingestion.market import fetch_market
                fetch_market(args.start)
            elif name == "fred":
                from src.ingestion.fred import fetch_fred
                fetch_fred(args.start)
            elif name == "gdelt":
                from src.ingestion.gdelt import fetch_gdelt
                fetch_gdelt(start=args.start, limit=args.gdelt_limit)
        except Exception:
            log.exception("Sumber %s gagal", name)
            failed.append(name)

    if not args.skip_validate:
        log.info("=== validasi ===")
        try:
            from src.validate import run_validation
            rep = run_validation([s for s in args.only if s not in failed])
            if rep.n_errors:
                failed.append("validasi")
        except Exception:
            log.exception("Validasi crash")
            failed.append("validasi")

    if args.sync:
        if failed:
            log.warning("Sync ke Drive dilewati karena ada kegagalan: %s", failed)
        else:
            log.info("=== sync Drive ===")
            try:
                from src.cloud.gdrive_sync import sync_raw
                sync_raw()
            except Exception:
                log.exception("Sync Drive gagal")
                failed.append("sync")

    if failed:
        log.error("Selesai dengan kegagalan: %s", failed)
        return 1
    log.info("Semua selesai")
    return 0


if __name__ == "__main__":
    sys.exit(main())
GEOMACRO_EOF
# folder Drive dibuat otomatis oleh skrip, jadi folder_id manual diganti folder_path
sed -i.bak 's|^  folder_id:.*|  folder_path: "geomacro/raw"   # dibuat otomatis di Drive (scope drive.file)|' config/settings.yaml && rm -f config/settings.yaml.bak
pip install -q google-api-python-client google-auth google-auth-oauthlib tenacity
echo "Tahap 3 terpasang. Langkah berikutnya:"
echo "  python -m src.cloud.gdrive_sync --auth   # login Google (sekali saja)"
echo "  python -m src.cloud.gdrive_sync          # upload data/raw ke Drive"