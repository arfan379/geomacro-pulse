#!/usr/bin/env bash
set -e
BASE=/home/admindata/Documents/cobaaa/geomacro-pulse
DL=~/Downloads                                # folder tempat file hasil unduhan; ubah kalau beda
NB="$DL/geomacro_lengkap.ipynb"
PPT="$DL/NAMA-PPT-MU.pptx"                    # ganti dengan nama file PPT-mu
PDF="$DL/NAMA-PPT-MU.pdf"                     # opsional; kalau tidak ada akan dilewati
README="$DL/README.md"
ZIP=$(ls -t "$DL"/figures-*.zip 2>/dev/null | head -1 || true)

cd "$BASE"
mkdir -p data_engineering analysis/figures analysis/presentation

# 1. pindahkan semua milik pipeline (yang tidak ada dilewati)
for f in src config data requirements.txt .env.example .env client_secret.json logs; do
  if [ -e "$f" ]; then mv "$f" data_engineering/; echo "pindah: $f -> data_engineering/"; fi
done

# 2. perbarui .gitignore (aman dijalankan berulang)
sed -i 's#^data/raw/\*$#data_engineering/data/raw/*#; s#^!data/raw/\.gitkeep$#!data_engineering/data/raw/.gitkeep#' .gitignore
echo "--- .gitignore (baris data):"; grep -n "data/raw" .gitignore

# 3. salin file analisis
cp_if() { if [ -f "$1" ]; then cp "$1" "$2" && echo "salin: $2"; else echo "LEWATI (tidak ada): $1"; fi; }
cp_if "$NB"     analysis/geomacro_lengkap.ipynb
cp_if "$PPT"    analysis/presentation/presentasi.pptx
cp_if "$PDF"    analysis/presentation/presentasi.pdf
cp_if "$README" README.md

# 4. grafik dari zip hasil unduhan Drive
if [ -n "$ZIP" ]; then
  TMP=$(mktemp -d); python3 -m zipfile -e "$ZIP" "$TMP"
  F=$(find "$TMP" -type d -name figures | head -1); [ -z "$F" ] && F="$TMP"
  cp_if "$(ls "$F"/17_*.png 2>/dev/null | head -1)" analysis/figures/pr_curve.png
  cp_if "$(ls "$F"/20_*.png 2>/dev/null | head -1)" analysis/figures/bootstrap_selisih.png
  cp_if "$(ls "$F"/12_*.png 2>/dev/null | head -1)" analysis/figures/shock_sp500.png
else
  echo "LEWATI: zip figures-*.zip tidak ditemukan di $DL"
fi

# 5. cek sebelum commit
git add -A
echo; echo "=== git status ==="; git status --short
echo; echo "=== file rahasia/data yang ter-stage (harus kosong) ==="
git diff --cached --name-only | grep -E '\.env$|client_secret|\.parquet|logs/' || echo "(aman: tidak ada)"