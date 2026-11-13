# geomacro-pulse

![Python](https://img.shields.io/badge/python-3.10%2B-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Status](https://img.shields.io/badge/status-data%20pipeline%20siap%2C%20analisis%20belum-yellow)

Pipeline data untuk riset prediksi *market shock* dari sinyal geopolitik (GDELT) dan indikator makro-keuangan (yfinance, FRED).

## Tentang proyek

Pertanyaan yang ingin dijawab: apakah berita dan event geopolitik dunia memberi informasi tambahan untuk memprediksi guncangan pasar, dibanding model yang hanya memakai data pasar dan makro?

Menjawabnya butuh data dari tiga sumber yang bentuknya berbeda-beda: harga pasar harian, indikator makro yang sebagian bulanan, dan jutaan event berita per tahun. Repo ini mengurus bagian itu, yaitu menarik, merapikan, memeriksa, dan menyimpan data supaya analisis di Colab bisa langsung mulai dari data yang bersih dan terdokumentasi. Penggunanya saya sendiri, tapi strukturnya cukup umum untuk dipakai siapa saja yang meneliti hubungan berita dan pasar.

Analisis dan modelling belum dikerjakan. Yang sudah selesai adalah pipeline datanya.

```text
yfinance + FRED + GDELT  →  validasi  →  Google Drive  →  Colab
      (lokal, incremental)               (jembatan)       (analisis)
```

## Contoh keluaran

Belum ada visualisasi karena analisisnya belum ada. Ini cuplikan log dari satu kali jalan, supaya terlihat apa yang dilaporkan pipeline:

```text
validate | [fred]  tanggal_bolong: cpi: 1 celah besar: 2025-09-01 -> 2025-11-01 (61 hari)
validate | [gdelt] tanggal_bolong: 11 kolom (...): 18 hari hilang -> ['2025-06-14 s/d 2025-07-01']
validate | Validasi selesai: 0 ERROR, 2 WARNING. Laporan: validation_report.json
gdrive   | Sync selesai ke 'My Drive/geomacro/raw': {'created': 4, 'updated': 0, 'skipped': 0}
```

## Fitur utama

- **Incremental.** Run berikutnya hanya menarik tanggal yang belum ada. Pasar menarik ulang 7 hari terakhir, FRED 120 hari (data bulanan sering direvisi), dan hari GDELT yang gagal otomatis dicoba lagi.
- **Validasi dua tingkat.** ERROR (file hilang, tanggal duplikat, harga ≤ 0, data basi) membuat exit code 1. WARNING (celah tanggal, banyak null) hanya dicatat ke `validation_report.json`.
- **Sinkronisasi ke Drive tanpa duplikat.** File dicari berdasarkan nama lalu di-update, dan file yang isinya sama (cek MD5) tidak diunggah ulang. Ada retry untuk error sementara.
- **Sync yang berhati-hati.** Upload dilewati kalau ada sumber yang gagal atau validasi menemukan ERROR, supaya data rusak tidak sampai ke Colab.
- **Data tetap mentah.** Alignment zona waktu, join, dan penanganan celah dikerjakan di notebook supaya prosesnya terdokumentasi.

Isi data di `data/raw/` (Parquet, kolom `date`):

| File | Isi |
|---|---|
| `market.parquet` | S&P 500, VIX, emas, minyak, DXY (`*_close`) dan `sp500_volume` |
| `fred.parquet` | `yield_10y`, `yield_2y`, `cpi`, `fed_funds` (tidak di-forward-fill) |
| `gdelt_daily.parquet` | `n_events`, `n_verbal_conflict`, `n_material_conflict`, `n_violent`, `n_protest`, `conflict_share`, `goldstein_mean/wmean`, `avgtone_mean/wmean`, `mentions_sum` |
| `validation_report.json` | temuan validasi dari run terakhir |

Konflik = QuadClass 3 (verbal) dan 4 (material), kekerasan = kode CAMEO 18–20, protes = kode 14. Versi `wmean` dibobot jumlah mention.

## Tech stack

- **Pipeline (sudah ada):** Python 3.10+, pandas, pyarrow, yfinance, fredapi, requests, tenacity, Google Drive API (OAuth), PyYAML, python-dotenv
- **Analisis (rencana, di Colab):** scikit-learn, LightGBM, CatBoost, SHAP, Gaussian Mixture Model untuk regime detection

## Instalasi dan menjalankan

```bash
git clone https://github.com/arfan379/geomacro-pulse.git
cd geomacro-pulse
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Isi `FRED_API_KEY` di `.env` (gratis di [fred.stlouisfed.org](https://fred.stlouisfed.org), menu My Account → API Keys). Lalu:

```bash
python -m src.run_ingestion                     # tarik data + validasi
python -m src.run_ingestion --start 2021-01-01  # rentang lebih panjang
python -m src.validate                          # validasi saja
```

Run pertama untuk GDELT lambat: sekitar 1 jam per 677 hari data, karena satu file per hari. Setelah itu cepat.

Untuk upload ke Google Drive (opsional, dibutuhkan kalau datanya mau dibaca di Colab):

1. Di Google Cloud Console, aktifkan Drive API dan buat OAuth client ID bertipe *Desktop app*. Simpan JSON-nya sebagai `client_secret.json` di root proyek.
2. Login sekali: `python -m src.cloud.gdrive_sync --auth`
3. Upload: `python -m src.run_ingestion --sync` atau `python -m src.cloud.gdrive_sync`

Folder `geomacro/raw` dibuat otomatis di My Drive, dan di Colab dibaca dari `/content/drive/MyDrive/geomacro/raw/`. Jangan biarkan consent screen berstatus *Testing*, karena refresh token kedaluwarsa dalam 7 hari.

## Asumsi dan trade-off

- **GDELT 1.0 (file harian), bukan 2.0 (15 menit).** Jauh lebih ringan dan sederhana, tapi lebih kasar, dan beberapa hari memang tidak tersedia di server (14 Juni sampai 1 Juli 2025). Agregasinya juga global, tidak per negara atau topik, jadi detail geografis hilang.
- **Tanggal GDELT adalah tanggal file (UTC), bukan tanggal kejadian.** Ini mencegah kebocoran informasi dari masa depan. Konsekuensinya, satu file baru lengkap setelah hari UTC berakhir, sehingga di analisis data hari *t* sebaiknya dipakai untuk memprediksi *t+1*.
- **FRED mencatat tanggal observasi, bukan tanggal rilis.** CPI bulan *M* baru terbit sekitar pertengahan bulan *M+1*, jadi harus di-lag. CPI Oktober 2025 juga tidak tersedia.
- **OAuth user credentials, bukan service account.** Service account sering kena `storageQuotaExceeded` di My Drive pribadi. Scope `drive.file` dipilih supaya skrip hanya bisa menyentuh file buatannya sendiri, dengan konsekuensi folder tujuan harus dibuat oleh skrip, bukan manual.
- **Drive sebagai jembatan, bukan database.** Sederhana dan gratis, tapi tidak ada kontrol konkurensi: yang menulis terakhir menang.
- **yfinance adalah scraper tidak resmi.** Bisa berubah atau terlambat sewaktu-waktu, makanya ada validasi data basi.
- **Data yang ditarik secara default baru sekitar 1 tahun.** Itu tipis untuk model dengan target kejadian langka. Rentang lebih panjang perlu ditarik sebelum modelling serius.

## Kontribusi dan lisensi

Ini proyek riset pribadi yang masih berjalan. Issue dan saran terbuka lewat tab Issues, dan pull request kecil (perbaikan bug, sumber data tambahan) dipersilakan. Untuk perubahan besar, buka issue dulu supaya arahnya cocok.

Dirilis dengan lisensi [MIT](LICENSE). Proyek ini untuk keperluan riset dan belajar, bukan nasihat investasi.