#!/usr/bin/env bash
# Tahap 0 - geomacro-pulse
# Jalankan di terminal VS Code (macOS/Linux/WSL/Git Bash):
#   bash setup_tahap0.sh
set -euo pipefail

PROJECT="geomacro-pulse"

mkdir -p "$PROJECT" && cd "$PROJECT"

# ---------- Struktur folder ----------
mkdir -p config data/raw src/ingestion src/cloud notebooks .github/workflows
touch data/raw/.gitkeep
touch src/__init__.py src/ingestion/__init__.py src/cloud/__init__.py

# ---------- .gitignore ----------
cat > .gitignore << 'EOF'
# environment & secret
.venv/
.env
credentials*.json
token*.json
client_secret*.json
*.pem

# data mentah (jembatan lewat Drive, bukan git)
data/raw/*
!data/raw/.gitkeep

# python
__pycache__/
*.pyc
.ipynb_checkpoints/
.DS_Store
EOF

# ---------- requirements.txt ----------
cat > requirements.txt << 'EOF'
yfinance
fredapi
pandas
pyarrow
requests
pyyaml
python-dotenv
google-api-python-client
google-auth
google-auth-oauthlib
tenacity
EOF

# ---------- config/settings.yaml ----------
cat > config/settings.yaml << 'EOF'
start_date: "2025-01-01"   # mulai 1 tahun dulu

market_tickers:
  sp500: "^GSPC"
  vix: "^VIX"
  gold: "GC=F"
  oil: "CL=F"
  dxy: "DX-Y.NYB"

fred_series:
  yield_10y: "DGS10"
  yield_2y: "DGS2"
  cpi: "CPIAUCSL"
  fed_funds: "FEDFUNDS"

drive:
  folder_id: "ISI_FOLDER_ID_DRIVE"   # dari URL folder: drive.google.com/drive/folders/<ID>
EOF

# ---------- .env.example ----------
cat > .env.example << 'EOF'
FRED_API_KEY=isi_api_key_fred
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_REFRESH_TOKEN=
EOF
[ -f .env ] || cp .env.example .env

# ---------- README ----------
cat > README.md << 'EOF'
# geomacro-pulse
Ingestion data (GDELT, yfinance, FRED) di lokal -> Google Drive -> analisis & modelling di Colab.
EOF

# ---------- Git ----------
if [ ! -d .git ]; then
  git init -b main
  git add .
  git commit -m "Tahap 0: scaffold proyek"
fi

# ---------- Virtual environment ----------
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate 2>/dev/null || source .venv/Scripts/activate
python -m pip install --upgrade pip
pip install -r requirements.txt

echo
echo "Selesai. Aktifkan venv dengan:"
echo "  macOS/Linux : source .venv/bin/activate"
echo "  Windows     : .venv\\Scripts\\activate"
echo "Lalu lanjut ke langkah manual (FRED key & Google Cloud)."