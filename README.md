# geomacro-pulse

Pipeline data untuk riset prediksi *market shock* dari sinyal geopolitik (GDELT) dan indikator makro-keuangan (yfinance, FRED).

Pengambilan data dikerjakan di lokal (VS Code), hasilnya disinkronkan ke Google Drive, lalu analisis dan modelling dikerjakan di Google Colab.

## Status

- [x] Tahap 0: setup proyek, git, virtual environment
- [x] Tahap 1: ingestion yfinance, FRED, GDELT (incremental)
- [x] Tahap 2: validasi ringan (null, duplikat, tanggal bolong, nilai tak wajar, data basi)
- [x] Tahap 3: sinkronisasi ke Google Drive (OAuth)
- [ ] Tahap 4: otomasi harian dengan GitHub Actions
- [ ] Analisis dan modelling di Colab (belum dimulai)

## Arsitektur

```text
[Lokal / VS Code]                        [Google Drive]              [Colab]
yfinance, FRED, GDELT  ──► validasi ──►  My Drive/geomacro/raw  ──►  drive.mount()
(incremental update)                     (jembatan)                  analisis & modelling
```

Lokal hanya menulis ke Drive, Colab hanya membaca dari Drive. Data mentah tidak masuk git.

## Struktur folder

```text
geomacro-pulse/
├── config/settings.yaml      # ticker, seri FRED, folder Drive
├── data/raw/                 # parquet mentah (di-ignore git)
├── src/
│   ├── common.py             # path, logging, upsert parquet
│   ├── ingestion/            # market.py, fred.py, gdelt.py
│   ├── cloud/gdrive_sync.py  # upload/update ke Drive
│   ├── validate.py           # validasi data mentah
│   └── run_ingestion.py      # entry point
├── notebooks/                # notebook Colab (menyusul)
└── requirements.txt
```

## Cara pakai

### 1. Setup

```bash
git clone https://github.com/arfan379/geomacro-pulse.git
cd geomacro-pulse
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env        # lalu isi FRED_API_KEY
```

API key FRED gratis di [fred.stlouisfed.org](https://fred.stlouisfed.org) (My Account → API Keys).

### 2. Akses Google Drive (sekali saja)

1. Buat project di Google Cloud Console dan aktifkan **Google Drive API**.
2. Buat **OAuth client ID** bertipe *Desktop app*, unduh JSON-nya, simpan sebagai `client_secret.json` di root proyek.
3. Jalankan login sekali:

```bash
python -m src.cloud.gdrive_sync --auth
```

Refresh token tersimpan di `.env`. Scope yang dipakai `drive.file`, jadi skrip hanya bisa mengakses file yang ia buat sendiri. Folder tujuan (`geomacro/raw`) dibuat otomatis.

### 3. Menjalankan

```bash
python -m src.run_ingestion                  # tarik data baru + validasi
python -m src.run_ingestion --sync           # + upload ke Drive (dilewati kalau ada kegagalan)
python -m src.run_ingestion --start 2021-01-01   # tarik rentang lebih panjang
python -m src.run_ingestion --only market fred   # sumber tertentu saja
python -m src.validate                       # validasi saja
python -m src.cloud.gdrive_sync              # upload saja
```

Semua perintah bersifat incremental: hanya tanggal yang belum ada yang ditarik. Exit code 1 kalau ada sumber gagal atau validasi menemukan ERROR.

## Data

| File | Isi | Frekuensi |
|---|---|---|
| `market.parquet` | `sp500_close`, `vix_close`, `gold_close`, `oil_close`, `dxy_close`, `sp500_volume` | hari bursa |
| `fred.parquet` | `yield_10y`, `yield_2y`, `cpi`, `fed_funds` | harian dan bulanan, tidak di-forward-fill |
| `gdelt_daily.parquet` | jumlah event konflik (verbal, material, kekerasan, protes), `conflict_share`, Goldstein scale dan AvgTone (rata-rata biasa dan berbobot mention), `mentions_sum` | harian |
| `validation_report.json` | temuan validasi terakhir | tiap run |

Semua file memakai kolom `date` dan disimpan **mentah**. Alignment zona waktu, join, dan penanganan celah dikerjakan di notebook.

## Catatan penting soal data

- **Tanggal GDELT** adalah tanggal file harian (UTC), bukan tanggal kejadian. Satu file baru lengkap setelah hari UTC berakhir, jadi di analisis data GDELT hari *t* sebaiknya dipakai untuk prediksi *t+1* agar tidak ada kebocoran informasi.
- **Tanggal FRED** adalah tanggal observasi, bukan tanggal rilis. CPI bulan *M* baru terbit sekitar pertengahan bulan *M+1*, jadi harus di-lag.
- **Celah yang diketahui** (terdeteksi validasi):
  - GDELT: file harian tanggal 14 Juni sampai 1 Juli 2025 tidak tersedia di server (404).
  - FRED: CPI bulan Oktober 2025 tidak tersedia.
- GDELT memakai file events versi 1.0 (satu file per hari). Menarik 1 tahun data memakan waktu sekitar 1 jam.

## Keamanan

`.env`, `client_secret.json`, dan file token ada di `.gitignore`. Jangan commit file-file itu. Untuk GitHub Actions, simpan `FRED_API_KEY`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, dan `GOOGLE_REFRESH_TOKEN` sebagai GitHub Secrets.

## Rencana

Analisis di Colab (EDA dan alignment, fitur dan target, regime detection, model ensemble, interpretasi) akan ditambahkan di folder `notebooks/` setelah desain analisisnya matang.