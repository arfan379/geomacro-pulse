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
