# Sistem Elquirazh ADV

## File untuk GitHub
- `index.html` — versi mobile terbaru yang sudah diuji.
- `elquirazh_adv_supabase_schema.sql` — schema database Supabase.

## Catatan penting
Versi `index.html` saat ini masih menyimpan data aplikasi menggunakan `localStorage` browser. File SQL Supabase belum terhubung langsung ke HTML ini.

Artinya:
- Upload `index.html` ke GitHub Pages/Vercel dapat menjalankan aplikasinya.
- Data transaksi masih tersimpan di browser/perangkat yang digunakan.
- SQL dapat dijalankan di Supabase SQL Editor untuk menyiapkan database.
- Agar data benar-benar tersimpan online dan bisa dipakai lintas HP/PC, HTML berikutnya perlu diintegrasikan dengan Supabase Auth + Supabase client.

## Keamanan
Jangan memasukkan `service_role` key Supabase ke `index.html` atau repository publik.
