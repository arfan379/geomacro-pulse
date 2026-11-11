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
