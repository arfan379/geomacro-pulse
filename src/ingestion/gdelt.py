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
