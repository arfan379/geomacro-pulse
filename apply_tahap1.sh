#!/usr/bin/env bash
# Tahap 1 - tulis modul ingestion ke proyek geomacro-pulse.
# Jalankan dari DALAM folder geomacro-pulse:  bash apply_tahap1.sh
set -euo pipefail
[ -d src ] && [ -d config ] || { echo "Jalankan dari root geomacro-pulse (harus ada folder src/ dan config/)"; exit 1; }
mkdir -p src/ingestion logs
touch src/__init__.py src/ingestion/__init__.py
cat > src/common.py << 'GEOMACRO_EOF'
"""Utilitas bersama: path, setting, logging, upsert parquet."""
import logging
from pathlib import Path

import pandas as pd
import yaml
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw"
LOG_DIR = ROOT / "logs"

load_dotenv(ROOT / ".env")


def load_settings() -> dict:
    with open(ROOT / "config" / "settings.yaml", encoding="utf-8") as f:
        return yaml.safe_load(f)


def get_logger(name: str) -> logging.Logger:
    logger = logging.getLogger(name)
    if logger.handlers:
        return logger
    logger.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s | %(levelname)s | %(name)s | %(message)s")
    sh = logging.StreamHandler()
    sh.setFormatter(fmt)
    logger.addHandler(sh)
    LOG_DIR.mkdir(exist_ok=True)
    fh = logging.FileHandler(LOG_DIR / "ingestion.log", encoding="utf-8")
    fh.setFormatter(fmt)
    logger.addHandler(fh)
    return logger


def read_existing(path: Path):
    """Baca parquet lama (kolom 'date' jadi datetime), atau None kalau belum ada."""
    if not path.exists():
        return None
    df = pd.read_parquet(path)
    df["date"] = pd.to_datetime(df["date"])
    return df


def upsert_parquet(new: pd.DataFrame, path: Path) -> pd.DataFrame:
    """Gabung data baru ke file lama. Kalau tanggal sama, data baru menang."""
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    new = new.copy()
    new["date"] = pd.to_datetime(new["date"]).dt.normalize()
    old = read_existing(path)
    df = new if old is None else pd.concat([old, new], ignore_index=True)
    df = (
        df.drop_duplicates(subset="date", keep="last")
        .sort_values("date")
        .reset_index(drop=True)
    )
    df.to_parquet(path, index=False)
    return df
GEOMACRO_EOF
cat > src/ingestion/market.py << 'GEOMACRO_EOF'
"""Data pasar harian dari yfinance (S&P 500, VIX, emas, minyak, DXY)."""
from datetime import timedelta

import pandas as pd
import yfinance as yf

from src.common import RAW_DIR, get_logger, load_settings, read_existing, upsert_parquet

log = get_logger("market")
OUT = RAW_DIR / "market.parquet"
OVERLAP_DAYS = 7  # tarik ulang 7 hari terakhir untuk menangkap koreksi data


def fetch_market(start: str | None = None) -> pd.DataFrame:
    cfg = load_settings()
    tickers = cfg["market_tickers"]

    existing = read_existing(OUT)
    if start is None:
        if existing is not None and len(existing):
            start = (existing["date"].max() - timedelta(days=OVERLAP_DAYS)).strftime("%Y-%m-%d")
        else:
            start = cfg["start_date"]
    log.info("Tarik yfinance mulai %s untuk %s", start, list(tickers.values()))

    raw = yf.download(
        list(tickers.values()),
        start=start,
        auto_adjust=True,
        progress=False,
        group_by="column",
    )
    if raw.empty:
        raise RuntimeError("yfinance mengembalikan data kosong")

    close = raw["Close"].rename(columns={v: k for k, v in tickers.items()})
    close.columns = [f"{c}_close" for c in close.columns]
    out = close.copy()
    out["sp500_volume"] = raw["Volume"][tickers["sp500"]]

    out.index = pd.to_datetime(out.index).tz_localize(None)
    out.index.name = "date"
    out = out.dropna(how="all").reset_index()

    df = upsert_parquet(out, OUT)
    log.info("market.parquet: %d baris, %s s/d %s", len(df), df["date"].min().date(), df["date"].max().date())
    return df
GEOMACRO_EOF
cat > src/ingestion/fred.py << 'GEOMACRO_EOF'
"""Data makro dari FRED (yield curve, CPI, fed funds rate)."""
import os
from datetime import timedelta

import pandas as pd
from fredapi import Fred
from tenacity import retry, stop_after_attempt, wait_exponential

from src.common import RAW_DIR, get_logger, load_settings, read_existing, upsert_parquet

log = get_logger("fred")
OUT = RAW_DIR / "fred.parquet"
OVERLAP_DAYS = 120  # seri bulanan sering direvisi, jadi tarik ulang jendela yang lebih lebar


@retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=2, max=30), reraise=True)
def _get(fred: Fred, series_id: str, start: str) -> pd.Series:
    return fred.get_series(series_id, observation_start=start)


def fetch_fred(start: str | None = None) -> pd.DataFrame:
    key = os.getenv("FRED_API_KEY", "")
    if not key or key.startswith("isi_"):
        raise RuntimeError("FRED_API_KEY belum diisi di file .env")

    cfg = load_settings()
    existing = read_existing(OUT)
    if start is None:
        if existing is not None and len(existing):
            start = (existing["date"].max() - timedelta(days=OVERLAP_DAYS)).strftime("%Y-%m-%d")
        else:
            start = cfg["start_date"]
    log.info("Tarik FRED mulai %s: %s", start, cfg["fred_series"])

    fred = Fred(api_key=key)
    series = {name: _get(fred, sid, start) for name, sid in cfg["fred_series"].items()}

    df = pd.concat(series, axis=1)  # tidak di-ffill; alignment dikerjakan di Colab
    df.index = pd.to_datetime(df.index)
    df.index.name = "date"
    df = df.dropna(how="all").reset_index()

    out = upsert_parquet(df, OUT)
    log.info("fred.parquet: %d baris, %s s/d %s", len(out), out["date"].min().date(), out["date"].max().date())
    return out
GEOMACRO_EOF
cat > src/ingestion/gdelt.py << 'GEOMACRO_EOF'
"""Event GDELT 1.0 (file harian) -> agregasi harian.

Satu file per hari: http://data.gdeltproject.org/events/YYYYMMDD.export.CSV.zip
Tanggal agregasi = tanggal FILE (kapan event masuk ke GDELT), bukan SQLDATE,
supaya tidak ada informasi dari masa depan yang bocor ke hari sebelumnya.
"""
import io
from datetime import datetime, timedelta, timezone

import numpy as np
import pandas as pd
import requests
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential

from src.common import RAW_DIR, get_logger, load_settings, read_existing, upsert_parquet

log = get_logger("gdelt")
OUT = RAW_DIR / "gdelt_daily.parquet"

URL = "http://data.gdeltproject.org/events/{d}.export.CSV.zip"
# Indeks kolom (0-based) di file events GDELT: ID, EventRootCode, QuadClass,
# GoldsteinScale, NumMentions, NumArticles, AvgTone
USECOLS = [0, 28, 29, 30, 31, 33, 34]
NAMES = ["event_id", "root_code", "quad_class", "goldstein", "num_mentions", "num_articles", "avg_tone"]
CHECKPOINT_EVERY = 30  # simpan tiap 30 hari supaya progres tidak hilang kalau terputus


@retry(
    retry=retry_if_exception_type(requests.RequestException),
    stop=stop_after_attempt(4),
    wait=wait_exponential(multiplier=2, max=60),
    reraise=True,
)
def _download(day: pd.Timestamp) -> bytes | None:
    r = requests.get(URL.format(d=day.strftime("%Y%m%d")), timeout=120)
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return r.content


def _parse(content: bytes) -> pd.DataFrame:
    df = pd.read_csv(
        io.BytesIO(content),
        sep="\t",
        header=None,
        usecols=USECOLS,
        names=NAMES,
        compression="zip",
        on_bad_lines="skip",
        low_memory=False,
    )
    for c in NAMES[1:]:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    return df.dropna(subset=["root_code", "quad_class", "goldstein", "avg_tone"])


def aggregate_day(df: pd.DataFrame, day: pd.Timestamp) -> dict:
    m = df["num_mentions"].fillna(1).clip(lower=1)
    g, t = df["goldstein"], df["avg_tone"]
    quad, root = df["quad_class"], df["root_code"]
    n = len(df)
    n_verbal = int((quad == 3).sum())
    n_material = int((quad == 4).sum())
    return {
        "date": day,
        "n_events": n,
        "n_verbal_conflict": n_verbal,
        "n_material_conflict": n_material,
        "n_violent": int(root.isin([18, 19, 20]).sum()),  # assault, fight, mass violence
        "n_protest": int((root == 14).sum()),
        "conflict_share": (n_verbal + n_material) / n if n else np.nan,
        "goldstein_mean": g.mean(),
        "goldstein_wmean": (g * m).sum() / m.sum(),
        "avgtone_mean": t.mean(),
        "avgtone_wmean": (t * m).sum() / m.sum(),
        "mentions_sum": int(m.sum()),
    }


def fetch_gdelt(start: str | None = None, end: str | None = None, limit: int | None = None):
    cfg = load_settings()
    start_ts = pd.Timestamp(start or cfg["start_date"]).normalize()
    if end:
        end_ts = pd.Timestamp(end).normalize()
    else:  # file hari ini belum lengkap, jadi berhenti di kemarin (UTC)
        end_ts = pd.Timestamp(datetime.now(timezone.utc).date()) - timedelta(days=1)

    existing = read_existing(OUT)
    have = set(existing["date"]) if existing is not None else set()
    wanted = [d for d in pd.date_range(start_ts, end_ts) if d not in have]
    if limit:
        wanted = wanted[:limit]
    log.info("GDELT: %d hari perlu ditarik (%s s/d %s)", len(wanted), start_ts.date(), end_ts.date())

    rows: list[dict] = []
    missing: list[str] = []

    def flush():
        if rows:
            out = upsert_parquet(pd.DataFrame(rows), OUT)
            log.info("Checkpoint: gdelt_daily.parquet = %d baris", len(out))
            rows.clear()

    try:
        for i, day in enumerate(wanted, 1):
            try:
                content = _download(day)
            except requests.RequestException as e:
                log.warning("Gagal unduh %s: %s", day.date(), e)
                missing.append(str(day.date()))
                continue
            if content is None:
                log.warning("File %s tidak ada di server (404)", day.date())
                missing.append(str(day.date()))
                continue
            df = _parse(content)
            if df.empty:
                log.warning("File %s kosong setelah dibersihkan", day.date())
                missing.append(str(day.date()))
                continue
            rows.append(aggregate_day(df, day))
            if i % CHECKPOINT_EVERY == 0:
                flush()
    finally:
        flush()

    if missing:
        log.warning("Hari yang tidak terambil (%d): %s", len(missing), missing)
    return read_existing(OUT)
GEOMACRO_EOF
cat > src/run_ingestion.py << 'GEOMACRO_EOF'
"""Entry point ingestion.

Contoh:
  python -m src.run_ingestion                        # semua sumber, incremental
  python -m src.run_ingestion --only market fred
  python -m src.run_ingestion --only gdelt --gdelt-limit 2   # uji coba 2 hari
Exit code 1 kalau ada sumber yang gagal (supaya GitHub Actions menandai job gagal).
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

    if failed:
        log.error("Selesai dengan kegagalan: %s", failed)
        return 1
    log.info("Semua sumber selesai")
    return 0


if __name__ == "__main__":
    sys.exit(main())
GEOMACRO_EOF
grep -qx "logs/" .gitignore 2>/dev/null || echo "logs/" >> .gitignore
echo "Tahap 1 terpasang. Uji coba:"
echo "  python -m src.run_ingestion --only gdelt --gdelt-limit 2"