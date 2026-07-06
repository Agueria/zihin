# ZİHİN — İlerleme / Kaldığın Yer Dosyası

> Her oturum bu dosyayı günceller. Yeni oturuma başlarken ÖNCE bunu,
> sonra `docs/superpowers/specs/2026-07-06-zihin-design.md` (spec) oku.

## Durum: Faz 0-2 kaynak kodu üretimi (Windows'ta, derlenmemiş)

**Son güncelleme:** 2026-07-06 (oturum 1)

### Bitti ✅
- [x] Tasarım spec'i yazıldı ve onaylandı → `docs/superpowers/specs/2026-07-06-zihin-design.md`
- [x] Referans sheet'ler repoya kopyalandı → `docs/reference/`

### Kaynak dosyalar — HEPSİ YAZILDI ✅ (oturum 1'de tamamlandı)
- [x] `Zihin/Data/Models.swift` — Item/Tag/ItemTag/Space/ItemSpace/MetaField + ItemStatus
- [x] `Zihin/Data/DatabaseManager.swift` — GRDB + FTS5 + SQLCipher bayrağı + migration v1
- [x] `Zihin/Data/ItemRepository.swift` — CRUD + timeline + pending + random + spaces
- [x] `Zihin/Data/Stores.swift` — VectorStore + AssetStore + KeychainKey
- [x] `Zihin/ML/VisionService.swift` — OCR + classify (düzeltilmiş filtre) + feature print
- [x] `Zihin/ML/TextServices.swift` — dil + NER + Stopwords + RAKE + TextRank
- [x] `Zihin/ML/EmbeddingService.swift` — NLEmbedding fallback + WordPiece Core ML embedder
- [x] `Zihin/ML/ColorService.swift` — k-means + NamedColors (TR)
- [x] `Zihin/Capture/IngestionService.swift` — HAFİF capture (ext+app ortak), pending yazar
- [x] `Zihin/Capture/EnrichmentQueue.swift` — ana app, iki aşamalı enrichment (spec §3.2)
- [x] `Zihin/Capture/LinkServices.swift` — OG parse + readability + social (VİDEO İNDİRME YOK)
- [x] `Zihin/Capture/MediaServices.swift` — video kare+STT (on-device-only) + PDF
- [x] `Zihin/Search/SearchService.swift` — parser + FTS5 + cosine + RRF + SameVibe
- [x] `Zihin/UI/AppRoot.swift` — @main + LibraryStore + RootView (scenePhase→enrich)
- [x] `Zihin/UI/TimelineView.swift` — grid + CardView + LocalImage + NewNoteSheet
- [x] `Zihin/UI/DetailViews.swift` — router + Article/Image/Video/Note detail
- [x] `Zihin/UI/SearchView.swift`
- [x] `Zihin/UI/SpacesView.swift` — smart space (kayıtlı arama) CRUD
- [x] `Zihin/UI/ExtrasViews.swift` — Serendipity + Settings
- [x] `ShareExtension/ShareViewController.swift` — yalnız ham kayıt yazar
- [x] `docs/SETUP_MAC.md` — Xcode kurulum + embedder model dönüştürme rehberi

### Sıradaki adımlar (yeni oturum buradan devam eder) ⏭️
1. **Mac'te:** `docs/SETUP_MAC.md` izle → derle (hatalar için `ecc:swift-build-resolver`).
3. Faz 0 kapısı: cihazda OCR + classify + cosine kanıtı.
4. Unit testler (TextRank/RAKE/kmeans/RRF/VectorStore/QueryParser) — YAZILMADI.
5. Faz 3 kodu — YAZILMADI: CloudKitSyncService (spec §8), ObsidianExporter (E1).
6. Faz 4: onboarding, ikon, App Store metadata.

### Önemli kararlar / spec'ten sapmalar (oturum 1)
- **Embedding modeli:** MiniLM yerine **distiluse-base-multilingual-cased-v2** (512-dim).
  Sebep: MiniLM tokenizer'ı SentencePiece (Swift'te ağır); distiluse WordPiece (~60 satır Swift).
  ~135MB fp16. Dönüştürme script'i pooling+dense+normalize'ı modele gömer → Swift sadece
  tokenize edip 512 float okur. Spec §5 güncellenecek.
- **Darwin notification kaldırıldı:** scenePhase `.active` tetiklemesi yeterli (paylaşımdan
  dönünce app foreground olur). Az kod, az hata.
- **DomainEnricher (E4) yazılmadı** — spec'te zaten v1.x.
- Model dosyaları (`Embedder.mlmodelc`, `vocab.txt`) git'te YOK; Mac'te üretilir.
- SQLCipher: DuckDuckGo GRDB fork + `ZIHIN_ENCRYPTED` derleme bayrağı.

### Bilinmesi gerekenler
- Kod Windows'ta yazıldı, **hiç derlenmedi** — ilk Mac derlemesinde ufak API düzeltmeleri normal.
- `rules.md` (Desktop) BOŞ geldi — kurallar bekleniyor, gelirse uygula.
- Kullanıcı tercihi: Türkçe, az token, faz kapılı ilerleme, video indirme ASLA yok.
- Git: branch `main`, her batch commit.
