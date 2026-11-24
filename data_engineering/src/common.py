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
