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
