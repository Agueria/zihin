# ZİHİN — Tasarım Spesifikasyonu (v1.0)

**Tarih:** 2026-07-06
**Durum:** Kullanıcı onaylı tasarım (brainstorming çıktısı)
**Referanslar:** `docs/reference/ZIHIN_dev_sheet_SWIFT.md` (kod-seviyesi taban), `docs/reference/ZIHIN_development_sheet.md` (strateji)

---

## 1. Ürün tanımı

Tek tap'le not/görsel/link/video/PDF kaydet; cihaz ne olduğunu anlar, OCR'lar, etiketler,
aranabilir yapar. Klasör yok, organizasyon yükü yok, **hiçbir içerik buluttaki bir yapay
zekâya gitmez**. MyMind'ın çekirdek deneyiminin tamamen on-device ML ile yeniden inşası.

- **Hedef:** App Store'da yayınlanacak ürün (TestFlight kapılı fazlarla).
- **Sürdürülebilirlik tezi:** inference cihazda ($0), sync CloudKit private DB
  (kullanıcının iCloud kotası, $0), storage/arama lokal ($0). Tek sabit gider Apple
  Developer $99/yıl. One-time veya düşük abonelik fiyatlaması yapısal olarak mümkün.
- **Konumlandırma:** MyMind'ın bilinen zayıflıklarının ($5.99+/ay, güvenilmez offline,
  kapalı veri) tam karşısı: lokal-first, şifreli, "own your data" (Obsidian export).
- **Diller:** TR + EN (UI ve içerik işleme).

### Kapsam dışı (v1.0 ve sonrası için bilinçli)
- Sosyal özellik, paylaşım, collaboration
- Long-form doküman editörü (Notion değiliz)
- Cloud LLM chat (tez bunun üstüne kurulu)
- **Uzak video indirme — hiçbir koşulda yok** (bkz. §7)

### İçerik tipleri
`note`, `quote`, `link`, `image`, `pdf`, `video` (video = cihazdaki dosya; linkle gelen
video sosyal link kartıdır, bkz. §7).

---

## 2. Platform ve teknoloji

| Karar | Değer |
|---|---|
| Platform | Native iOS (Swift 6, SwiftUI), min iOS 17, Xcode 16 |
| DB | GRDB.swift (**GRDB-with-SQLCipher ürünü**) — SQLite + FTS5 + şifreleme |
| HTML parse | SwiftSoup (OG meta + readability heuristiği) |
| ML | Vision, NaturalLanguage, Core ML (multilingual embedder), Speech (on-device) |
| Sync | CloudKit private DB, custom zone |
| Concurrency | Strict Concurrency Checking = Complete |
| Bundle ID | `app.zihin.Zihin`, App Group `group.app.zihin`, container `iCloud.app.zihin` |

**Geliştirme akışı (Windows→Mac):** Kaynak ağacı + adım adım Xcode kurulum dokümanı bu
repoda (Windows) üretilir; derleme/test Mac + iPhone'da yapılır. Build hataları Mac'te
Claude Code (`ecc:swift-build-resolver`) ile kapatılır.

---

## 3. Mimari

### 3.1 Katmanlar

```
Share Extension (hafif) ──┐
In-app capture ───────────┴─► IngestionService ─► EnrichmentQueue (ana app)
                                    │                    │
                              DatabaseManager (GRDB: item + FTS5 + BLOB vektör)
                                    │
             ┌──────────────────────┼──────────────────────┐
        SearchService          SwiftUI UI            CloudKitSyncService
     (FTS5+cosine+RRF)   (Timeline/Detail/Spaces/…)      (Faz 3)
```

DB dosyası ve asset klasörü App Group container'ında; app + extension ortak erişir.
ML asla buluta gitmez; CloudKit yalnızca veri taşır.

### 3.2 İki aşamalı capture (SWIFT sheet'ten sapma — kritik)

Share Extension **enrichment çalıştırmaz** (iOS extension bellek limiti ~120MB;
Vision + STT extension'da crash riski). Akış:

1. **Extension:** ham veriyi al → asset'i App Group'a kopyala →
   `Item(status: .pending)` olarak DB'ye yaz → Darwin notification gönder → çık.
2. **Ana app:** açılışta / foreground'da / `BGProcessingTask`'te `pending` item'ları
   çeker, `EnrichmentQueue` sırayla işler (`enriching` → `ready`).
3. **Hata yolu:** enrichment hatasında `enrichAttempts++`; 3 denemeden sonra
   `status = .failed`. Item ham haliyle görünür ve aranabilir kalır (başlık/ham metin
   FTS'e girer); kartta sessiz "yeniden dene" göstergesi.

Kart, `pending` durumda dahi timeline'da anında görünür (ham görsel/başlıkla) —
"2 saniyede kart" hissi korunur; zengin alanlar 5–30 sn içinde dolar.

### 3.3 Enrichment durum makinesi

`pending → enriching → ready` (hata: `enriching → pending[retry] → failed`).
UI `ready` olmayan item'da shimmer/progress gösterir.

---

## 4. Veri modeli

SWIFT sheet §5 şeması esas alınır (item, item_fts, tag, item_tag, space, meta_field).
**Eklemeler:**

| Kolon | Tip | Amaç |
|---|---|---|
| `item.status` | TEXT | `pending/enriching/ready/failed` |
| `item.lang` | TEXT | Tespit edilen dil (embedding/arama seçimi) |
| `item.enrichAttempts` | INT | Retry sayacı |

- FTS5: `title, textContent, ocrText, summary, transcript, frameText`;
  tokenizer `unicode61(diacritics: .remove)` (TR dostu). `t.synchronize(withTable:)`
  ile trigger-bazlı senkron.
- Embedding: `[Float]` little-endian BLOB (384-dim, ~1.5KB/item).
- Feature print: `VNFeaturePrintObservation` secure-coded archive BLOB.
- SQLCipher **gün 1'den açık** (E3); passphrase Keychain'de
  (`kSecAttrAccessibleAfterFirstUnlock`, App Group erişimli access group).

---

## 5. Enrichment pipeline (hepsi on-device)

| İş | Teknik | Notlar / sheet'ten sapmalar |
|---|---|---|
| OCR | `VNRecognizeTextRequest` (.accurate, tr-TR + en-US) | |
| Görsel etiket | `VNClassifyImageRequest` | **Düzeltme:** sheet'teki `hasMinimumRecall(0.0, forPrecision: 0.0)` filtresi anlamsız; `confidence > 0.3` + `hasMinimumPrecision(0.5, forRecall: 0.5)` kullanılır, eşik cihazda kalibre edilir |
| Same Vibe / dedup | `VNGenerateImageFeaturePrintRequest` + `computeDistance` | |
| Renk | Downscale (64px) + k-means (k=5) + isimli renk eşleme (TR) | **Düzeltme:** sheet'teki `ColorServiceRGB` köprü tipi kaldırılır; tek `internal RGB` tipi |
| Dil | `NLLanguageRecognizer` | `item.lang`'e yazılır |
| NER | `NLTagger(.nameType)` | kişi/yer/kurum → etiket |
| Keyword | RAKE (degree/freq) | TR stopword seti ~200 kelimeye genişletilir |
| Özet | TextRank: cümle embedding benzerliği + PageRank, top-3 cümle | Fallback: TF-cosine |
| **Embedding** | **distiluse-base-multilingual-cased-v2 (512-dim), Core ML, ~135MB fp16, gün 1'den bundle** | LLM değil, encoder — tez bozulmaz. MiniLM'den değiştirildi: MiniLM tokenizer'ı SentencePiece (Swift'te ağır), distiluse WordPiece (Swift'te ~60 satır). Pooling+dense+normalize modele gömülü. `NLEmbedding` (EN) fallback |
| Video (lokal dosya) | ≤20 kare sampling (1080p'ye downscale) + kare OCR + classify + orta kare feature print/renk | |
| STT | `SFSpeechRecognizer`, **yalnızca `requiresOnDeviceRecognition = true`** | **Düzeltme:** on-device desteklenmiyorsa transcript ATLANIR; asla server'a düşülmez. Gizlilik vaadi mutlaktır |
| PDF | PDFKit text extraction | Taranmış PDF (text'siz) → sayfa render + OCR **v1.x** |

**Embedding modeli üretimi:** Mac'te bir kez `coremltools` ile dönüştürme
(reçete SWIFT sheet §6.3). Üretilen `.mlpackage` git'e girmez (`.gitignore`);
Xcode projesine dosya referansı olarak eklenir, üretim adımı kurulum dokümanında
yazılıdır.

---

## 6. Arama (hybrid)

SWIFT sheet §10 esas alınır:

1. `SearchQueryParser`: sorgudan renk adı + tarih ifadesi ("bugün/dün/hafta") ayıklar.
2. **FTS5** bm25 sıralaması (keyword, anında).
3. **Vektör:** sorgu embed → brute-force cosine (eşik 0.15, top-200).
4. **RRF** (k=60) ile füzyon; renk/tarih eşleşmesi filtre + boost.
5. Yalnız renk/tarih sorgusunda doğrudan filtreli listeleme.

- **Same Vibe:** seçili görselin feature print'i → tüm feature print'lere distance →
  en yakın 12.
- Ölçek: birkaç bin item'da brute-force < 10ms; 10k+ olursa `sqlite-vec`
  (arayüz değişmez).
- **DoD:** "mavi" → mavi baskın görseller; "react state" → kelime geçmese de ilgili
  item'lar; görselden benzer bulma çalışır; görsel içi metin aranır.

---

## 7. Link, social ve video politikası

### Normal link/makale
`LinkMetadataService` (OG/meta parse) → SwiftSoup readability heuristiği (temiz HTML +
plain text) → TextRank özet → NER/RAKE etiket → embedding. Poster görseli image
pipeline'dan geçer (OCR + renk + feature print). Fetch başarısızsa çıplak URL kartı.

### Sosyal linkler (Instagram/TikTok/YouTube/X/Reddit/Vimeo)
- Sinyaller: **poster karesi** (OCR + etiket + renk + feature print) + **caption/başlık**
  (embedding + keyword + özet). Bu, kategorileme ve arama için birincil ve yeterli yol
  (MyMind paritesi).
- **Uzak video hiçbir koşulda indirilmez/çekilmez.** Sheet'teki `og:video` indirme
  kodu tamamen çıkarıldı (App Store 5.2.2 + platform ToS riski; ürün kararı).
- Linkle gelen videoda kare analizi/STT **yapılamaz** (veri cihazda değil) — beklenti
  bu şekilde netleşti.

### Tam video analizi (kare OCR + on-device STT)
Yalnızca **dosyası cihazda olan** videolarda: Photos'tan paylaşım, ekran kaydı, kamera.
Settings'te ipucu: "Reels'i tam analiz etmek istersen ekran kaydet, Photos'tan paylaş."

### E4 zengin kartlar (v1.x)
GitHub repo / YouTube süre-kanal / X alıntı kartları — yalnızca public metadata/oEmbed.

---

## 8. Sync (CloudKit, Faz 3)

SWIFT sheet §11 esas: private DB + `zihinZone`, dirty-flag push, change-token pull,
last-writer-wins (`updatedAt`).

- **v1.0:** metadata + embedding + feature print sync (~2KB/kayıt).
  **Asset'ler (görsel/video/pdf) v1.1'de `CKAsset`** olarak; ilk sürümde karşı cihazda
  "içerik bu cihazda değil" placeholder'ı.
- **Düzeltme:** change token `UserDefaults.standard` değil App Group
  `UserDefaults(suiteName:)`.
- Tetikleme: foreground'da bootstrap → push → pull; ileride CloudKit push notification.
- **Dürüst gizlilik dili:** SQLCipher cihazda şifreler; CloudKit'te veri Apple altyapı
  şifrelemesiyle durur (E2E değil). Pazarlama metni buna uygun yazılır. Gerçek E2E
  (CryptoKit alan şifreleme) v2 adayı.

---

## 9. UI (SwiftUI)

SWIFT sheet §12 esas alınır:

- **RootView:** TabView — Zihin (timeline), Ara, Space'ler, Keşfet (Serendipity), Ayarlar.
- **Timeline:** `LazyVGrid(adaptive 160)` masonry-vari grid; pin üstte; context menu
  (sabitle/unut); pull-to-refresh; `pending` kartlarda shimmer.
- **CardView:** tip-bazlı (image/video-poster/link/pdf/note) render.
- **Detail:** ArticleDetail (WKWebView reader), ImageDetail (OCR + Same Vibe şeridi),
  VideoDetail (player + transcript + kare yazıları), NoteDetail (özet + metin).
- **Spaces:** manuel + smart (kayıtlı arama — dinamik dolar/boşalır).
- **Serendipity:** rastgele kart akışı, keep/forget.
- **Yayın kalitesi ekleri:** onboarding (3 ekran + izin akışları: Photos/Speech),
  boş-durum tasarımları, Dynamic Type + VoiceOver taban desteği, dark/light.
- Görsel kimlik (ikon, tipografi, marka) Faz 4'te ayrı tasarım çalışması
  (frontend-design süreciyle).

---

## 10. Eklentiler (E1–E5) sürümleme

| Eklenti | Sürüm | Not |
|---|---|---|
| E3 Şifreli DB (SQLCipher) | **v1.0, gün 1** | Sonradan eklemek migration cehennemi |
| E1 Obsidian/Markdown export | **v1.0 (Faz 3)** | Item → md + frontmatter; klasöre yaz |
| E4 Domain zengin kartlar | v1.x | Public metadata/oEmbed only |
| E2 Knowledge graph | v1.x | Embedding benzerliği → bağlantı görünümü |
| E5 On-device LLM (MLX) | v2, default KAPALI | Tezle çelişmez ama v1 kapsamı dışı |

---

## 11. Test stratejisi

- **Unit (saf algoritmalar):** TextRank, RAKE, k-means, RRF füzyon, VectorStore
  encode/decode/cosine, SearchQueryParser, NamedColors eşleme, Stopwords.
  Altın girdi/çıktı dosyalarıyla; XCTest.
- **DB:** in-memory GRDB ile migration, FTS senkron, repository CRUD testleri.
- **Entegrasyon (cihazda, manuel plan):** Vision/STT çıktıları deterministik değil →
  "OCR şu kelimeyi içermeli" tarzı gevşek assertion'lı kontrol listesi;
  Simulator'da Vision/Speech sınırlı, gerçek iPhone şart.
- **DoD örnekleri:** screenshot paylaş → ≤2sn kart + ≤30sn'de ≥3 etiket ve aranabilir
  OCR; iki cihaz senkron ≤30sn.

---

## 12. Fazlar ve kapılar

| Faz | İçerik | Kapı |
|---|---|---|
| **0** | Xcode proje + App Group + Share Ext iskeleti; Vision OCR/classify + embedding cosine spike; embedder modeli dönüştürme | Cihazda OCR + etiket + cosine kanıtlandı |
| **1** | Data layer + görsel/not capture (iki aşamalı) + enrichment + hybrid arama + timeline/detail UI | **TestFlight #1** — günlük kendi kullanımı |
| **2** | Link/reader, social (poster+caption), lokal video pipeline, PDF, Spaces, Same Vibe, Serendipity | **TestFlight #2** — MyMind çekirdek paritesi |
| **3** | CloudKit sync (metadata), E1 Obsidian export, E3 doğrulama | **TestFlight #3** — iki cihaz senkron |
| **4** | Onboarding, ikon/görsel kimlik, gizlilik metinleri (App Privacy), App Store metadata, fiyatlama | **App Store submission** |

---

## 13. Riskler

| Risk | Etki | Önlem |
|---|---|---|
| Swift öğrenme eğrisi | Orta | Faz 0 spike küçük; Mac'te Claude Code pair-programming |
| TR embedding kalitesi | Orta | MiniLM gün 1'den bundle; FTS5 her durumda çalışır |
| Share Ext bellek limiti | Yüksek → **çözüldü** | İki aşamalı capture (§3.2) |
| App Store reddi (3. taraf içerik) | Yüksek → **çözüldü** | Video indirme tamamen kapsam dışı (§7) |
| Model boyutu (~90MB) | Düşük | Kabul edildi; gerekirse on-demand resource |
| CloudKit edge-case'ler | Orta | Offline-first; sync additive, Faz 3'te izole |
| Scope creep | Yüksek | Faz kapıları + §1 kapsam dışı listesi bağlayıcı |

---

## 14. SWIFT sheet'e göre değişiklik özeti

1. Share Extension'da enrichment YOK → iki aşamalı capture + `status` kolonu (§3.2).
2. `og:video` indirme kodu tamamen çıkarıldı; sosyal video = poster + caption (§7).
3. STT on-device-only; server fallback yok (§5).
4. `VNClassifyImageRequest` filtre düzeltmesi (§5).
5. `NamedColors` köprü tipi kaldırıldı (§5).
6. Multilingual embedder placeholder değil, gün 1'de gerçek model (§5).
7. CloudKit token App Group UserDefaults'a (§8).
8. Asset sync v1.1'e ertelendi (§8).
9. SQLCipher (E3) gün 1'den açık (§4, §10).
10. E2E iddiası dürüst dile çevrildi (§8).
