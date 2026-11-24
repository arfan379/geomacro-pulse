"""Validasi ringan data mentah (data tetap mentah, tidak diubah).

Cek: file ada, duplikat tanggal, null, tanggal bolong, nilai tak wajar, data basi.
ERROR   -> masalah serius, exit code 1 (job GitHub Actions akan gagal)
WARNING -> perlu diperhatikan, ditangani di notebook Colab
INFO    -> catatan saja
Hasil dicatat ke logs/ingestion.log dan data/raw/validation_report.json.

Pakai:  python -m src.validate
"""
import json
import sys
from datetime import datetime, timezone

import pandas as pd

from src.common import RAW_DIR, get_logger, read_existing

log = get_logger("validate")
REPORT_PATH = RAW_DIR / "validation_report.json"

# nama sumber -> (file, opsi cek)
SPECS = {
    "market": ("market.parquet", dict(daily_max_age=5)),
    "fred": ("fred.parquet", dict(daily_max_age=7, check_nulls=False)),  # seri bulanan memang banyak null
    "gdelt": ("gdelt_daily.parquet", dict(calendar=True, daily_max_age=3)),
}


class Report:
    def __init__(self):
        self.issues: list[dict] = []
        self.summary: dict = {}

    def add(self, source: str, level: str, check: str, detail: str):
        self.issues.append({"source": source, "level": level, "check": check, "detail": detail})
        {"ERROR": log.error, "WARNING": log.warning}.get(level, log.info)("[%s] %s: %s", source, check, detail)

    @property
    def n_errors(self) -> int:
        return sum(i["level"] == "ERROR" for i in self.issues)

    @property
    def n_warnings(self) -> int:
        return sum(i["level"] == "WARNING" for i in self.issues)


def _ranges(dates) -> list[str]:
    """Ringkas tanggal berurutan jadi rentang 'a s/d b'."""
    dates = list(dates)
    if not dates:
        return []
    out, start, prev = [], dates[0], dates[0]
    fmt = lambda a, b: str(a.date()) if a == b else f"{a.date()} s/d {b.date()}"
    for d in dates[1:]:
        if (d - prev).days == 1:
            prev = d
            continue
        out.append(fmt(start, prev))
        start = prev = d
    out.append(fmt(start, prev))
    return out


def _load(source: str, filename: str, rep: Report):
    path = RAW_DIR / filename
    if not path.exists():
        rep.add(source, "ERROR", "file_hilang", f"{filename} tidak ditemukan")
        return None
    df = read_existing(path)
    if df is None or df.empty:
        rep.add(source, "ERROR", "kosong", f"{filename} kosong")
        return None
    rep.summary[source] = {
        "rows": len(df),
        "start": str(df["date"].min().date()),
        "end": str(df["date"].max().date()),
    }
    dup = int(df["date"].duplicated().sum())
    if dup:
        rep.add(source, "ERROR", "duplikat", f"{dup} tanggal duplikat")
    return df


def _emit_grouped(rep, source, check, groups):
    """Gabungkan kolom yang punya masalah identik jadi satu pesan."""
    for (level, detail), cols in groups.items():
        label = ", ".join(cols) if len(cols) <= 3 else f"{len(cols)} kolom ({', '.join(cols[:3])}, ...)"
        rep.add(source, level, check, f"{label}: {detail}")


def _check_columns(source, df, rep, *, calendar=False, daily_max_age=5, check_nulls=True):
    today = pd.Timestamp(datetime.now(timezone.utc).date())
    n = len(df)
    gap_groups, stale_groups = {}, {}

    for col in df.columns.drop("date"):
        s = df[["date", col]].dropna()

        if check_nulls and n - len(s):
            nn = n - len(s)
            pct = nn / n * 100
            rep.add(source, "WARNING" if pct > 5 else "INFO", "null", f"{col}: {nn} null ({pct:.1f}%)")

        if len(s) < 3:
            rep.add(source, "WARNING", "data_sedikit", f"{col}: hanya {len(s)} observasi")
            continue

        d = s["date"].sort_values().reset_index(drop=True)
        gaps = d.diff().dt.days.iloc[1:]
        daily = calendar or gaps.median() <= 4

        # tanggal bolong
        if calendar:  # GDELT: semua hari kalender harus ada
            missing = pd.date_range(d.min(), d.max()).difference(d)
            if len(missing):
                r = _ranges(missing)
                detail = f"{len(missing)} hari hilang -> {r[:10]}{' ...' if len(r) > 10 else ''}"
                gap_groups.setdefault(("WARNING", detail), []).append(col)
        else:  # pasar/FRED: toleransi akhir pekan panjang (4 hari), seri bulanan (45 hari)
            limit = 4 if daily else 45
            big = gaps[gaps > limit]
            if len(big):
                desc = "; ".join(f"{d[i-1].date()} -> {d[i].date()} ({int(gaps[i])} hari)" for i in big.index[:8])
                gap_groups.setdefault(("WARNING", f"{len(big)} celah besar: {desc}"), []).append(col)

        # data basi
        age = (today - d.iloc[-1]).days
        max_age = daily_max_age if daily else 100
        if age > max_age:
            detail = f"terakhir {d.iloc[-1].date()} ({age} hari lalu, batas {max_age})"
            stale_groups.setdefault(("ERROR" if daily else "WARNING", detail), []).append(col)

    _emit_grouped(rep, source, "tanggal_bolong", gap_groups)
    _emit_grouped(rep, source, "data_basi", stale_groups)


def _check_values(source, df, rep):
    if source == "market":
        for c in [c for c in df.columns if c.endswith("_close") and c != "oil_close"]:
            bad = int((df[c] <= 0).sum())
            if bad:
                rep.add(source, "ERROR", "nilai_tak_wajar", f"{c}: {bad} nilai <= 0")
    elif source == "gdelt":
        rules = {"n_events": (1, None), "conflict_share": (0, 1),
                 "avgtone_mean": (-100, 100), "goldstein_mean": (-10, 10)}
        for c, (lo, hi) in rules.items():
            if c not in df:
                continue
            bad = pd.Series(False, index=df.index)
            if lo is not None:
                bad |= df[c] < lo
            if hi is not None:
                bad |= df[c] > hi
            if bad.any():
                rep.add(source, "ERROR", "nilai_tak_wajar", f"{c}: {int(bad.sum())} nilai di luar [{lo}, {hi}]")
        med = df["n_events"].median()
        low = df[df["n_events"] < 0.2 * med]
        if len(low):
            rep.add(source, "WARNING", "hari_sepi",
                    f"{len(low)} hari dengan n_events < 20% median ({int(med)}), kemungkinan file parsial: "
                    f"{[str(x.date()) for x in low['date'].head(8)]}")


def run_validation(sources=None) -> Report:
    rep = Report()
    for source in sources or SPECS:
        filename, opts = SPECS[source]
        df = _load(source, filename, rep)
        if df is None:
            continue
        _check_columns(source, df, rep, **opts)
        _check_values(source, df, rep)

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "n_errors": rep.n_errors,
        "n_warnings": rep.n_warnings,
        "summary": rep.summary,
        "issues": rep.issues,
    }
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(payload, indent=2, ensure_ascii=False, default=str), encoding="utf-8")
    log.info("Validasi selesai: %d ERROR, %d WARNING. Laporan: %s", rep.n_errors, rep.n_warnings, REPORT_PATH.name)
    return rep


def main() -> int:
    return 1 if run_validation().n_errors else 0


if __name__ == "__main__":
    sys.exit(main())

