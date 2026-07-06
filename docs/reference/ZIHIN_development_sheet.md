# ZIHIN — Development Sheet
### "mymind, ama arka planda LLM API yok" → sıfır marjinal maliyet, sürdürülebilir

> Codename: **ZIHIN** (istediğin gibi rename et). Hedef: mymind'ın çekirdek deneyimini (visual second-brain, otomatik etiketleme, semantic search, reading mode) **tamamen on-device ML** ile yeniden inşa etmek. Backend inference yok = kullanıcı başına maliyet ~$0.

---

## 0. TL;DR (önce bunu oku)

mymind'ın tüm "AI" özellikleri aslında üç kovaya giriyor ve **hiçbiri LLM gerektirmiyor**:

| mymind "AI" özelliği | Gerçekte ne | LLM gerekir mi? |
|---|---|---|
| Image auto-tagging | Image classification | ❌ On-device (Vision) |
| Image text recognition | OCR | ❌ On-device (Vision) |
| Same Vibe (benzer görsel) | Image embedding + distance | ❌ On-device (Vision) |
| Search by color | k-means renk çıkarımı | ❌ Saf algoritma |
| Reading mode / temiz makale | HTML readability parsing | ❌ Client-side |
| Article summary | Extractive summarization (TextRank) | ❌ On-device |
| Semantic/associative search | Sentence embeddings + cosine | ❌ On-device (NaturalLanguage / CLIP) |
| Smart Spaces (oto-gruplama) | Embedding clustering / saved search | ❌ On-device |
| Serendipity | Random + spaced repetition | ❌ Trivial |

**Sürdürülebilirlik tezi:**
- **Inference** = Apple Vision + NaturalLanguage frameworks → cihazda çalışır, $0.
- **Sync** = CloudKit → Apple host eder, kullanıcının iCloud kotasından düşer, sana $0.
- **Storage/Search** = lokal SQLite + brute-force cosine → $0.
- **Sonuç:** Kullanıcı başına marjinal maliyet ≈ $0. Tek gelir, tek gider modeli mümkün (one-time / sub).

> ⚠️ Bu mimari **iOS-native + CloudKit** üzerine kurulu. Cross-platform (Android) istersen sürdürülebilirlik tezi bozulur (kendi sync backend'in + ML Kit lazım olur). Karar Bölüm 4'te.

---

## 1. Ürün Konumlandırma

**Tek cümle:** Kaydet-ve-unut. Tek tap'le not/görsel/link/makale kaydedersin; uygulama ne olduğunu anlar, etiketler, aranabilir yapar — klasör yok, organizasyon yok.

**Kime:**
- Görsel düşünenler, designer, araştırmacı, developer
- ADHD / "açık tab paralizi" yaşayanlar (mymind'ın en güçlü kullanıcı segmenti — review'larda net)
- Privacy-bilinçli kullanıcılar (lokal-first + E2E senin farklılaştırıcın)

**Ne YAPMAYACAĞIZ (scope kontrolü):**
- Sosyal özellik yok, paylaşım/collab yok (mymind de yapmıyor, bilinçli)
- Long-form doküman editörü olmayacak (Notion değiliz)
- Cloud LLM chat yok (tüm tez bunun üstüne kurulu)

---

## 2. mymind Özellik Envanteri (parity hedefi)

Klonlarken hedef alınacak özellikler:

**Capture (yakalama)**
- Tek tap kaydetme: not, link/website, image, PDF, video/GIF, quote/highlight
- Share Sheet entegrasyonu (Safari, Photos, herhangi bir app'ten paylaş)
- Content-type farkındalığı: makale → reader view, ürün → fiyat/detay, kitap → kapak, tarif → adımlar

**Organize (otomatik)**
- Image auto-tagging (obje, renk, brand)
- Article concept extraction (otomatik etiket)
- Smart Spaces (bir tag/tema/aramaya göre oto-gruplama)
- Manuel Tags & Spaces (özel projeler için)
- Top of mind (pin)

**Find (arama)**
- Associative search: renk, keyword, brand, tarih, phrase
- Image içi text arama (OCR sonucu)
- Same Vibe (benzer mood'da görseller)

**Recall (hatırlatma)**
- Serendipity (rastgele yeniden gösterim, keep/forget)
- Timeline view (ana görünüm)

**Sistem**
- Dark/light mode
- Cihazlar arası sync
- Privacy-first (tracking yok, ads yok)

---

## 3. ÇEKİRDEK STRATEJİ — On-Device ML Mimarisi

> Bu bölüm senin sorunun asıl cevabı. Her mymind özelliğini hangi cihaz-içi tekniğe map'liyoruz.

### 3.1 Apple'ın bedava silahları

Native iOS'te şu iki framework **tüm AI işini ücretsiz, offline, API'siz** halleder:

**`Vision` framework**
| API | Ne yapar | mymind karşılığı |
|---|---|---|
| `VNRecognizeTextRequest` | OCR (çok dilli + el yazısı) | Image text recognition |
| `VNClassifyImageRequest` | Image classification (~1000+ sınıf taksonomi) | Image auto-tagging |
| `VNGenerateImageFeaturePrintRequest` → `VNFeaturePrintObservation.computeDistance` | Image embedding + benzerlik mesafesi | **Same Vibe** + duplicate detection |
| `VNGenerateAttentionBasedSaliencyImageRequest` | Önemli bölge tespiti | Akıllı thumbnail crop |
| `VNDetectBarcodesRequest` / face / animal | Obje tespiti | Ekstra etiketler |

**`NaturalLanguage` framework**
| API | Ne yapar | mymind karşılığı |
|---|---|---|
| `NLEmbedding.sentenceEmbedding` | Cümle embedding (cihazda) | Semantic search temeli |
| `NLTagger` (`.nameType`) | NER — kişi/yer/organizasyon | Brand/entity etiketleme |
| `NLTagger` (lemma, POS) | Kök bulma, kelime türü | Keyword normalizasyon |
| `NLLanguageRecognizer` | Dil tespiti | TR/EN içerik ayrımı |

> **Türkçe notu:** `NLEmbedding.sentenceEmbedding` her dilde yok (İngilizce var). Türkçe içerik için **bundled bir Core ML multilingual embedding modeli** taşı (aşağıda 3.4).

### 3.2 Capture pipeline — adım adım (LLM yok)

Bir item kaydedilince çalışan **enrichment pipeline**:

```
SAVE → tip tespiti → tipe göre enrichment → embedding üret → index'e yaz
```

**A) URL/Website kaydedildiğinde**
1. Hidden `WKWebView`'da yükle
2. **Mozilla Readability.js** inject et → temiz makale HTML + plain text çıkar (reader mode)
3. Open Graph meta parse et (`og:title`, `og:image`, `og:type`, `product:price` …) → content-type + kapak/fiyat
4. **Extractive summary**: TextRank ile en önemli 2-3 cümleyi seç (Bölüm 3.3)
5. **Keyword extraction**: NER (`NLTagger`) + YAKE/RAKE → otomatik etiketler
6. Sentence embedding üret → vektör sakla

**B) Image/Screenshot kaydedildiğinde**
1. `VNRecognizeTextRequest` → içindeki tüm metin (aranabilir hale gelir)
2. `VNClassifyImageRequest` → top-N etiket (obje sınıfları)
3. `VNGenerateImageFeaturePrintRequest` → feature print sakla (Same Vibe + dedup)
4. **Renk paleti**: downscale + k-means (k=5) → dominant renkler → en yakın isimli renge map ("kırmızı", "lacivert") → renkle arama
5. (Opsiyonel) MobileCLIP image embedding → text→image cross-modal arama (3.4)

**C) Not/Quote kaydedildiğinde**
1. Plain text → keyword extraction (NER + YAKE)
2. Sentence embedding → semantic search index

**Hepsi cihazda, internet bile gerekmez** (sadece URL fetch için lazım).

### 3.3 Summary — LLM olmadan "özet"

mymind "brief summary" veriyor. Biz **extractive summarization** kullanıyoruz (yeni cümle yazmaz, en önemli mevcut cümleleri seçer):

**TextRank algoritması (cihazda):**
1. Metni cümlelere böl
2. Her cümle çifti arası benzerlik = `NLEmbedding` sentence similarity (veya TF-IDF cosine)
3. Cümle-graph kur, **PageRank** çalıştır
4. En yüksek skorlu 2-3 cümle = özet

Kalite: gerçek "brief summary" için yeterli. Soyut/akıcı özet istersen → opsiyonel on-device küçük LLM (Bölüm 10, default KAPALI).

### 3.4 Semantic search — embedding stratejisi

**Seçenek A — Sadece text search (basit, MVP):**
`NLEmbedding` (EN) + bundled multilingual model (TR) → her item bir vektör → arama sorgusunu da embed et → **brute-force cosine** tüm vektörlere.

> Personal scale matematik: 2.000 item × 384-dim float ≈ 3 MB. Hepsi üzerinde cosine < 10 ms. **Vector DB GEREKMEZ** bu ölçekte. İleride `sqlite-vec` veya HNSW eklenir.

**Seçenek B — Cross-modal (güçlü, "search by what you remember"):**
**Apple MobileCLIP** (on-device CLIP, açık kaynak) bundle et:
- Image embedding + text embedding aynı uzayda
- "mavi sneaker fotoğrafı" yazarsın → hiç OCR/etiket olmasa bile görseli bulur
- Tamamen cihazda, $0
- ⚠️ Model boyutu app'i şişirir (~40-150MB tier'a göre). v1.5 özelliği olarak ekle, MVP'de A ile başla.

### 3.5 Smart Spaces (oto-gruplama)

İki yol:
1. **Saved search**: "react" araması → o tag/embedding'e uyan her şeyi otomatik gösteren dinamik space (basit, MVP)
2. **Clustering**: tüm embedding'lere k-means/HDBSCAN → otomatik tema kümeleri ("bunlar hep tipografi", "bunlar hep finans") (v2)

---

## 4. Tech Stack Kararı + Rubric

**Karar gerekiyor.** Aşağıdaki rubric (0-10, ağırlıklı):

| Kriter | Ağırlık | Native Swift/SwiftUI | React Native | Flutter |
|---|---|---|---|---|
| On-device ML erişimi (Vision/NL/CLIP) | ×3 | **10** | 5 | 5 |
| Sürdürülebilirlik (CloudKit bedava sync) | ×3 | **10** | 4 | 4 |
| App Store kalite/performans | ×2 | **9** | 7 | 8 |
| Senin mevcut skill (web/React) | ×2 | 4 | **8** | 5 |
| Android erişimi | ×1 | 2 | **8** | **9** |
| **Ağırlıklı toplam** | | **101** | 64 | 65 |

### ✅ Karar: **Native Swift + SwiftUI**

**Neden (sert ve net):**
1. Tüm sürdürülebilirlik tezin (bedava on-device inference + bedava CloudKit sync) **yalnızca native iOS'te** birinci sınıf çalışır. React Native seçersen ML Kit + kendi sync backend'ine düşersin → maliyet geri gelir → projenin tüm amacı çöker.
2. Vision + NaturalLanguage + MobileCLIP + CloudKit hepsi first-party, sıfır bağımlılık riski.
3. **Bonus (senin için):** Swift + Core ML + on-device/edge ML öğrenmek, "yet another React app"ten daha güçlü CV sinyali ve **embedded/edge-ML omurganla daha uyumlu**. Difficulty yüksek ama value yüksek → senin kendi decision engine'inde difficulty en sonda.

**Tek istisna:** Android'i v1 launch'ta MUTLAKA istiyorsan → React Native + ML Kit + Firebase/Supabase, ama "sürdürülebilir, API'siz" hedefinden ödün verirsin. Bunu bilerek seç.

### Final stack (önerilen)
- **Dil/UI:** Swift 6, SwiftUI
- **Local DB:** SwiftData (veya Core Data) + SQLite FTS5 (full-text search)
- **Vektör:** embedding'ler BLOB olarak, in-memory cosine (MVP) → `sqlite-vec` (scale)
- **ML:** Vision, NaturalLanguage, (v1.5) Core ML + MobileCLIP
- **Article parse:** WKWebView + Readability.js (bundled JS)
- **Sync:** CloudKit (private database)
- **Yerel arama:** SQLite FTS5 (keyword) + cosine (semantic) hibrit

---

## 5. Sistem Mimarisi

```
┌─────────────────────────────────────────────────────────┐
│                     iOS App (SwiftUI)                    │
│                                                          │
│  ┌────────────┐   ┌──────────────┐   ┌───────────────┐  │
│  │  Capture   │   │   Library    │   │    Search     │  │
│  │  (Share    │   │  (timeline,  │   │  (hybrid:     │  │
│  │   Ext.)    │   │   spaces)    │   │   FTS+vector) │  │
│  └─────┬──────┘   └──────┬───────┘   └───────┬───────┘  │
│        │                 │                   │          │
│  ┌─────▼─────────────────▼───────────────────▼───────┐  │
│  │              Enrichment Engine                     │  │
│  │  Vision (OCR/classify/featureprint)               │  │
│  │  NaturalLanguage (embed/NER)                      │  │
│  │  Readability.js (article)                         │  │
│  │  ColorKit (k-means palette)                       │  │
│  │  TextRank (summary)                               │  │
│  └─────────────────────┬─────────────────────────────┘  │
│                        │                                 │
│  ┌─────────────────────▼─────────────────────────────┐  │
│  │   Local Store: SwiftData + SQLite FTS5 + vectors  │  │
│  └─────────────────────┬─────────────────────────────┘  │
└────────────────────────┼─────────────────────────────────┘
                         │  (mirror, $0)
                ┌────────▼────────┐
                │    CloudKit     │  ← Apple-hosted, user iCloud
                │ (private DB)    │     sync between devices
                └─────────────────┘
```

**Kritik:** ML asla buluta gitmez. CloudKit sadece **veriyi** (item + metadata + embedding) cihazlar arası taşır, inference yapmaz.

---

## 6. Data Model

Çekirdek tablolar (SwiftData entity / SQLite):

**`Item`**
| alan | tip | not |
|---|---|---|
| `id` | UUID | PK |
| `type` | enum | note / link / image / pdf / video / quote |
| `createdAt` | Date | |
| `title` | String? | |
| `url` | String? | link ise |
| `textContent` | String? | not / quote / makale gövdesi |
| `readerHTML` | String? | reader mode temiz HTML |
| `summary` | String? | extractive özet |
| `assetPath` | String? | local image/pdf yolu |
| `featurePrint` | Blob? | image embedding (Same Vibe) |
| `textEmbedding` | Blob? | semantic search vektörü |
| `ocrText` | String? | image içi metin |
| `dominantColors` | [String] | renk araması |
| `isPinned` | Bool | top of mind |
| `forgotten` | Bool | serendipity keep/forget |

**`Tag`** (`id`, `name`, `source`: auto/manual) — `Item`↔`Tag` many-to-many

**`Space`** (`id`, `name`, `query`: dinamik kural, `isSmart`: Bool)

**`MetaField`** (content-type'a özel: price, author, brand, recipeSteps…) — `Item`'a bağlı key-value

> FTS5 virtual table: `Item(title, textContent, ocrText, summary)` üzerinde full-text. Vektörler ayrı kolonda BLOB.

---

## 7. Capture Pipeline (kod akışı, dil-agnostik pseudocode)

```
func enrich(item):
    item.lang = NLLanguageRecognizer(item.text)

    switch item.type:
      case LINK:
          html = WKWebView.load(item.url)
          item.readerHTML, item.text = Readability(html)
          meta = parseOpenGraph(html)
          item.title, item.coverImage, price = meta
          item.summary = TextRank(item.text, n=3)
          tags = NER(item.text) + YAKE(item.text)

      case IMAGE:
          item.ocrText      = Vision.recognizeText(image)
          classTags         = Vision.classify(image)      // top 5
          item.featurePrint = Vision.featurePrint(image)
          item.colors       = kMeansPalette(image, k=5)
          tags = classTags + namedColors(item.colors)

      case NOTE, QUOTE:
          tags = NER(item.text) + YAKE(item.text)

    item.textEmbedding = embed(item.text ?? item.ocrText)  // NLEmbedding / CLIP
    item.tags = dedupe(tags)
    store(item); indexFTS(item)
    CloudKit.save(item)   // background
```

**Definition of done (capture):** Bir screenshot paylaşıldığında 2 sn içinde kart oluşuyor; içindeki metin aranabiliyor; en az 3 otomatik etiket var; benzer görsel sorgusunda çıkıyor.

---

## 8. Search Pipeline (hybrid)

mymind'ın "renk/keyword/brand/tarih ne aklına gelirse" hissi = **hibrit arama**:

```
func search(query):
    # 1. Sinyal tespiti
    if query == renk ismi:        results += filterByColor(query)
    if query == tarih ifadesi:    results += filterByDate(parseDate(query))

    # 2. Keyword (lexical) — anında
    results += FTS5.match(query)           // title/text/ocr/summary

    # 3. Semantic (vector) — yakın anlam
    qv = embed(query)
    results += topK_cosine(qv, allEmbeddings, k=30)

    # 4. Birleştir + skorla (reciprocal rank fusion)
    return rerank(results)
```

**Same Vibe** ayrı akış: seçili görselin `featurePrint`'i → `computeDistance` tüm görsellere → en yakınları göster.

**Definition of done (search):** "mavi" yazınca mavi baskın görseller; "react state management" yazınca o konuyla ilgili (kelime birebir geçmese de) item'lar; bir görselden "benzerlerini bul" çalışıyor.

---

## 9. Modül Kırılımı + Definition of Done

| # | Modül | İçerik | DoD |
|---|---|---|---|
| M1 | **Capture core** | Share Extension, item create, local store | Safari/Photos'tan paylaş → kart oluşuyor |
| M2 | **Enrichment: Vision** | OCR, classify, featureprint, color | Image kaydedince etiket+OCR+renk dolu |
| M3 | **Enrichment: Text** | Readability, OG parse, NER, YAKE, TextRank | Link kaydedince reader view + özet + tag |
| M4 | **Embedding + Search** | NLEmbedding, FTS5, hybrid search | Keyword + semantic arama çalışıyor |
| M5 | **Library UI** | Timeline grid, kart tipleri, detail view | Tüm tipler doğru render (makale/ürün/not) |
| M6 | **Tags & Spaces** | Manuel + Smart Spaces (saved search) | Smart space dinamik dolup boşalıyor |
| M7 | **Same Vibe** | Feature print distance UI | Görselden benzer görselleri buluyor |
| M8 | **Serendipity** | Random resurfacing, keep/forget | Günlük rastgele kart akışı |
| M9 | **CloudKit sync** | Private DB mirror | İki cihaz arası senkron |
| M10 | **Polish** | Dark/light, settings, onboarding, icon | App Store submission-ready |

---

## 10. "Birkaç Şey Daha" — Senin Eklemelerin (farklılaştırıcılar)

mymind'ın üstüne koyacağın, **profilinle uyumlu ve hâlâ $0** olan eklemeler. Hepsi opsiyonel; karar senin:

**E1 — Obsidian / Markdown export & vault sync** ⭐ (sen zaten Obsidian kullanıyorsun)
- Her item → markdown + frontmatter (tags, source, date)
- Bir lokal vault klasörüne yaz → "own your data"
- mymind'da YOK, privacy-kitlesinin sevdiği şey

**E2 — Knowledge graph / connections view** ⭐
- Item'lar arası embedding similarity → graph
- "bu kayıt şunlarla bağlantılı" görünümü
- Görsel düşünenler + ADHD kitlesi için güçlü recall

**E3 — Lokal-first + E2E encryption** ⭐
- mymind "private" diyor ama lokal-first değil
- SQLCipher / cihazda şifreli store → senin güçlü farkın
- RE/security omurganla da uyumlu sinyal

**E4 — Share Sheet'ten otomatik content-type zenginleştirme**
- GitHub repo paylaşınca → repo metadata kartı
- YouTube → süre/kanal kartı
- Tweet/X → temiz alıntı kartı

**E5 (v2, opsiyonel) — On-device küçük LLM (DEFAULT KAPALI)**
- Apple **MLX** framework ile 1-3B quantized model
- Soyut özet / "zihnine soru sor" özelliği
- Cihazda çalışır → hâlâ $0, ama RAM/pil maliyeti yüksek
- **Sadece power-user toggle'ı olarak.** Tezini bozmaz çünkü cloud API değil.

> Öneri: MVP'de E1 + E3'ü koy (düşük efor, yüksek farklılaşma). E2'yi v1.5, E5'i v2.

---

## 11. Sürdürülebilirlik / Maliyet Analizi

**Kullanıcı başına aylık maliyet tablosu:**

| Kalem | Kim öder | Senin maliyetin |
|---|---|---|
| Image/text inference | Cihaz (Vision/NL) | **$0** |
| Embedding üretimi | Cihaz | **$0** |
| Article parsing | Cihaz (WKWebView) | **$0** |
| Search | Cihaz (lokal) | **$0** |
| Sync storage | Kullanıcının iCloud kotası (CloudKit private DB) | **$0** |
| **Toplam / kullanıcı** | | **≈ $0** |

**Sabit giderler (kullanıcıdan bağımsız):**
- Apple Developer Program: $99/yıl
- (Opsiyonel) landing page hosting: ~$0-5/ay

**Sonuç:** 10 kullanıcı da 100.000 kullanıcı da sana neredeyse aynı maliyet. Bu yüzden **one-time satın alma** veya **düşük sub** modeli sürdürülebilir. LLM-API'li bir klon olsaydı her aktif kullanıcı sana token maliyeti bindirir, ücretsiz tier kanını emerdi — senin tasarladığın model bundan yapısal olarak bağışık.

> Bu tek başına bir pazarlama hikayesi: *"Tamamen cihazında çalışır. Hiçbir şey buluttaki bir AI'a gönderilmez."* — privacy kitlesine birebir.

---

## 12. Yol Haritası (gerçekçi)

> Bir hafta MVP sevdiğini biliyorum ama bu, Swift öğrenme eğrisi + 3 framework içeriyor. Dürüst tahmin:

**Faz 0 — Spike (3-5 akşam)**
Swift/SwiftUI + Vision "hello world": bir görseli OCR'la + classify et + ekranda göster. Embedding + cosine'i bir playground'da kanıtla. **DoD:** "bunu yapabilirim" netliği.

**Faz 1 — Walking skeleton MVP (1.5-2 hafta)**
M1 + M2 + M4 + M5. Sadece: image & not kaydet, OCR + etiket, keyword + semantic search, basit grid. **DoD:** Kendin günlük kullanabilir hale gelir.

**Faz 2 — Parity (2-3 hafta)**
M3 (reader/link), M6 (spaces), M7 (Same Vibe), M8 (serendipity). **DoD:** mymind'ın çekirdeğine eşdeğer.

**Faz 3 — Differentiate + ship (1-2 hafta)**
M9 (CloudKit), E1/E3, M10 polish. App Store submission. **DoD:** TestFlight → App Store.

**Faz 4 — v1.5+**
MobileCLIP cross-modal search, E2 graph, E5 opsiyonel LLM.

---

## 13. Risk Register

| Risk | Etki | Önlem |
|---|---|---|
| Swift öğrenme eğrisi seni yavaşlatır | Orta | Faz 0 spike'ı küçük tut; Claude Code ile pair-program |
| Türkçe sentence embedding zayıf (`NLEmbedding` EN-merkezli) | Orta | Bundled multilingual Core ML modeli (LaBSE/MiniLM distill) |
| MobileCLIP app boyutunu şişirir | Düşük | v1.5'e ertele; tier seçilebilir |
| Reader parsing bazı sitelerde bozuk | Düşük | Open Graph fallback; "metni elle ekle" |
| CloudKit private DB öğrenme/edge-case | Orta | Önce tamamen offline ship et, sync'i Faz 3'te ekle |
| Scope creep ("her özelliği koyayım") | **Yüksek** | Bölüm 1 "yapmayacaklar"a sadık kal; MVP = 4 modül |
| **Strateji riski:** bu proje embedded/MİT omurganı yemesin | **Yüksek** | Aşağı bak ↓ |

**Strateji notu (co-founder modu, sert):** Bu bir tertiary-track / portfolio-product bahsi. MİT/embedded omurgana *doğrudan* hizmet etmiyor. Yapılmaya değer **eğer**: (a) scope'u sıkı tutarsan, (b) **on-device/edge-ML açısını öne çıkarırsan** — transfer edilebilir, etkileyici beceri orada. Açık uçlu bir para çukuruna dönüşüp embedded zamanını yerse, kapat. CV sinyali olarak "yet another web app"ten iyi; ama omurga değil, dal.

---

## 14. İlk 60 Dakika Battle Plan

**Objective:** Swift + Vision'ın bu işi yapabildiğini kendi gözünle kanıtla. Karar netleşsin.

- **0-5 dk** — Xcode aç, yeni iOS App (SwiftUI) projesi. Bir test görseli ekle (içinde metin olan bir screenshot).
- **5-50 dk** — Tek hedef: `VNRecognizeTextRequest` ile o görselin metnini çıkar + `VNClassifyImageRequest` ile top-5 etiketi al, ikisini ekrana bas.
  - Apple "Recognizing Text in Images" sample'ını referans al.
- **50-60 dk** — Sonucu logla: ekran görüntüsü al, repo'ya `README` + commit (`feat: on-device OCR + classify POC`).

**DoD:** Ekranda gerçek OCR metni + gerçek etiketler görüyorsun. Artık "yapılır mı" sorusu kapandı; "yapacak mıyım" kararı kaldı.

---

## Ek: Kaynaklar / Kütüphaneler

- **Vision** — Apple Developer docs: OCR, image classification, feature print
- **NaturalLanguage** — `NLEmbedding`, `NLTagger`
- **MobileCLIP** — Apple açık kaynak (on-device CLIP), cross-modal search
- **MLX** — Apple, on-device LLM (sadece opsiyonel E5 için)
- **Readability.js** — Mozilla, makale çıkarımı (WKWebView'a inject)
- **SwiftSoup** — HTML/OG meta parsing
- **CloudKit** — sync, private database
- **SQLite FTS5** — full-text search
- **sqlite-vec** — (scale ettiğinde) vektör arama uzantısı
- Color extraction: k-means tabanlı palette (ColorThief mantığı, Swift'e port)
- Extractive summary: TextRank (PageRank + sentence similarity)
- Keyword: YAKE / RAKE / KeyBERT (lokal model)

---

*Hazırlandı: ZIHIN dev sheet v1. Stack kararı verince M1-M2-M4-M5'le başla. Sorular: hangi modülü Claude Code'a paslamak istersin → ben sana o modül için birebir prompt yazarım.*
