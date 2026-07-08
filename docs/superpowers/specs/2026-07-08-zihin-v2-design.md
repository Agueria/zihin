# ZİHİN v2 — Anlam Katmanı, Space'ler, Kavram Grafiği (Tasarım Spesifikasyonu)

**Tarih:** 2026-07-08
**Durum:** Onay bekliyor
**Öncül:** [2026-07-06-zihin-design.md](2026-07-06-zihin-design.md) (v1.0)

---

## 1. Problem

Kullanıcı yedi şikâyet bildirdi. Kod incelemesi ve **cihaz üzerinde ölçüm**, bunların büyük
kısmının bağımsız bug olmadığını, tek bir kök nedenin türevleri olduğunu gösterdi.

| # | Şikâyet | Gerçek sebep |
|---|---|---|
| 1 | Notu düzenleyemiyorum | `ItemRepository`'de güncelleme yolu hiç yok |
| 2 | İçeriğin AI ile ilgili olduğunu anlayıp `ai` etiketi eklemeli | Etiketleme yalnız NER + RAKE; soyutlama yapamaz |
| 3 | Space'leri otomatik önermeli | Hiç yazılmamış |
| 4 | Başlık ekleyebilmeliyim | `title`, gövdenin ilk 80 karakteriyle doldurulmuş |
| 5 | Arama gelişmeli | FTS5 OR semantiği, ağırlıksız bm25, Türkçe morfoloji yok |
| 6 | Yeni space bütün notları yutuyor | **Kök neden A + tasarım hatası B** |
| 7 | Graph saçma / düzenlenemiyor | **Kök neden A + veri modeli eksikliği** |
| — | Space'te nota tıklayınca boş ekran | SwiftUI `navigationDestination` tip çakışması |

### Kök neden A — embedding modeli hiç üretilmemiş

[`EmbeddingService.swift:12`](../../../Zihin/ML/EmbeddingService.swift) önce `MultilingualEmbedder`'ı
dener; o da bundle'da `Embedder.mlmodelc` + `vocab.txt` arar. **İkisi de repoda yok**
(`.gitignore` `*.mlmodelc`'yi yok sayıyor, `docs/SETUP_MAC.md §5`'teki `convert_embedder.py`
hiç çalıştırılmamış). Dolayısıyla her embedding, **Türkçe metne uygulanan İngilizce
`NLEmbedding`**'den geliyor.

### Kök neden B — arama fonksiyonu üyelik yüklemi olarak kullanılıyor

[`SpacesView.swift:111`](../../../Zihin/UI/SpacesView.swift) space üyeliği için
`SearchService.search()` çağırıyor. `search()` hiçbir kesme noktası uygulamıyor
([`SearchService.swift:70`](../../../Zihin/Search/SearchService.swift)): RRF skoru sıfırdan
büyük her şeyi sıralı döndürüyor. Bir **sıralama** fonksiyonunu **boolean üyelik** olarak
kullanmak, mükemmel bir embedder'la bile space'i şişirir.

---

## 2. Ölçümler

Tasarımın tamamı, tahmine değil, macOS 26 / Swift 6.3 üzerinde koşturulan iki probe'a dayanıyor.
Probe kaynakları: `scratchpad/probe.swift`, `scratchpad/probe2.swift` (proje kodu değil).

### 2.1 Mevcut kod yolu ölçüldü — sistematik olarak yanlış

`NLEmbedding.sentenceEmbedding(for: .english)`, Türkçe metinde:

```
Alakasız not çiftleri:   AI↔Yemek 0.821   App↔Yemek 0.858   AI↔App 0.733
Zero-shot (4 konu):      üç notun ÜÇÜ de "yazılım" çıktı
                         Yemek notu → "yazılım", en yüksek marjla (+0.138)
```

`SearchService` eşiği `> 0.15`, `KnowledgeGraph` eşiği `>= 0.5`. **Her ikisini de her şey
geçiyor.** Şikâyet #6 ve #7 doğrudan buradan.

### 2.2 İki API ölü

```
NLEmbedding.sentenceEmbedding(for: .turkish)  →  nil
NLEmbedding.wordEmbedding(for: .turkish)      →  nil
```

Tasarım sırasında "Türkçe word embedding ortalaması" bir fallback olarak düşünülmüştü.
**Öyle bir API yok.** Ölçüm bunu erken eledi.

### 2.3 `NLContextualEmbedding` — Türkçe destekli

```
modelIdentifier: 5C45D94E-BAB4-4927-94B6-8B5745C46289
scripts: ["Latn"]      dimension: 512      revision: 1      maxSeqLen: 256
languages(20): cs da de en es fi fr hr hu id it nb nl pl pt ro sk sv tr vi
hasAvailableAssets: true
```

Türkçe destekleniyor. Bundle maliyeti **0 MB** (asset talep üzerine iner).

### 2.4 Merkezleme (centering) — tasarımın merkezindeki bulgu

Etiketli 12 Türkçe not, 4 konu. Mean-pool'lanmış bağlamsal embedding'ler **anizotropiktir**:
tüm vektörler dar bir koni içinde yaşar, mutlak cosine eşiği anlamsızdır.

| | aynı konu ort. | farklı konu ort. | **ayrışma** | aralık genişliği | en iyi τ ile doğruluk |
|---|---|---|---|---|---|
| ham mean-pool | +0.896 | +0.859 | **+0.037** | 0.125 | %84 |
| **+ merkezleme** | +0.144 | −0.140 | **+0.284** | 0.679 | **%92** |

Korpus ortalaması `μ` çıkarılınca ayrışma **7.7×**, dinamik aralık **5.4×** artıyor;
merkezlenmiş cosine `[−0.39, +0.29]` aralığına yayılıyor ve `τ≈+0.03` işaretli, anlamlı bir
karar sınırı hâline geliyor.

### 2.5 Zero-shot: merkezleme > prototip; prototip = güvenli susma

```
ham  + tek ifade        3/12   ← şans seviyesi (%25). Kullanılamaz.
ham  + prototip         8/12
merkezli + tek ifade   11/12   ort. marj +0.067
merkezli + prototip     9/12   ort. marj +0.145   ← marj 2×
```

n=12'de 11/12 ile 9/12 arasındaki fark **gürültüdür**; doğruluk üzerinden prototip lehine
çıkarım yapılamaz. Ancak prototipler **marjı ikiye katlıyor**. Marj, "bu notun hiçbir konusu
yok" diyebilmenin (abstention) tek yolu. Prototipler doğruluk için değil, **güvenle susmak**
için kullanılacak.

### 2.6 256 token sınırı

2600 karakterlik metin `sequenceLength: 256`'ya **kırpılıyor**. Uzun notlar, PDF metinleri ve
video transcript'leri için parçalama (chunking) zorunlu. Mevcut kod bunu bilmiyor.

---

## 3. Kararlar

| Karar | Seçim | Gerekçe |
|---|---|---|
| Embedder | `NLContextualEmbedding` varsayılan | 0 MB, Türkçe destekli (§2.3) |
| Gelişmiş model | Opsiyonel indirme (~80MB) | Contrastive encoder merkezlemeye ihtiyaç duymaz |
| Benzerlik ölçütü | **Merkezlenmiş** cosine | §2.4 — ham cosine kullanılamaz |
| Konu ataması | Prototip + merkezleme + marj eşiği | §2.5 |
| Taksonomi | Hibrit: küratörlü çekirdek + keşfedilen | Kullanıcı seçimi |
| Cihaz-içi LLM | FoundationModels + `availability` kontrolü | Kullanıcı seçimi; fallback her zaman var |
| Deployment target | **iOS 26.0'a yükseltilir** | Aşağıda (2026-07-09 kararı) |
| Graph kenarları | Yalnız konu üzerinden + manuel + kNN önerisi | Kullanıcı seçimi |
| Reindex | Arka planda sessiz + Ayarlar'dan manuel tetik | Kullanıcı seçimi |

### 3.1 Deployment target — nihai karar (2026-07-09)

Kullanıcı spec incelemesinde **deployment target'ın iOS 26.0'a yükseltilmesini** seçti.
`project.yml` `deploymentTarget.iOS = "26.0"` olur.

Sonuçlar:

- FoundationModels **her zaman derlenir**; `if #available(iOS 26, *)` kapılamasına gerek
  kalmaz. Ancak Apple Intelligence donanımı olmayan iOS 26 cihazları için
  `SystemLanguageModel.default.availability == .available` kontrolü **korunur** — LLM yolu
  yalnız donanım destekliyorsa devreye girer.
- Lexicon + merkezlenmiş prototip fallback'i **birincil** kalır (§4.3): LLM yoksa etiketleme
  ve konu ataması yine tam çalışır. Bu, Apple Intelligence'sız iOS 26 cihazlarını kapsar.
- iOS 17-25 cihazları artık desteklenmez.

*Önceki yorum (target'ı 17.0'da tutmak) bu kararla geçersiz kılındı.*

---

## 4. Mimari

### 4.1 Embedding katmanı

```
protocol EmbeddingProvider: Sendable {
    var modelIdentifier: String { get }
    var revision: Int { get }
    var dimension: Int { get }
    func embed(_ text: String) -> [[Float]]?     // chunk başına bir vektör
}

ContextualProvider   NLContextualEmbedding(script: .latin)   varsayılan, 0 MB
SentenceProvider     Embedder.mlmodelc (App Group'tan)       opsiyonel indirme
```

Üç vazgeçilmez unsur:

**(a) Model kimliği kayıtta.** Her iki sağlayıcı da **512 boyutlu**. Model değişince
`VectorStore.cosine` *çökmez* — sessizce anlamsız sayı üretir. `item.embeddingModel` +
`item.embeddingRevision` kolonları zorunlu; uyuşmazlık reindex tetikler.

**(b) Korpus ortalaması `μ` birinci sınıf artefakt.** Merkezleme korpusa bağlıdır.
Benzerlik **okuma anında** `l2(v − μ)` üzerinden hesaplanır; ham vektörler diskte değişmez.

`embedding_meta` iki şey tutar: sürekli biriken **toplam** (`Σv`, `count`) ve karşılaştırmalarda
fiilen kullanılan **donmuş `μ`**. Toplam her item'da güncellenir; donmuş `μ` **günde en çok bir
kez** (veya reindex'te) tazelenir. Ayrım şart: `μ` her notta kaysaydı space üyeliği ve graph
kenarları her yazışta titrerdi.

*Soğuk başlangıç:* 5 notta `μ` anlamsızdır. Genel Türkçe korpustan hesaplanmış `μ₀` bundle'a
gömülür (512 float = 2 KB) ve harmanlanır:

```
μ = (n · μ_user + k · μ₀) / (n + k),   k = 50
```

**(c) Chunking.** ~200 token'lık pencereler (§2.6). `item_chunk(itemId, idx, vector)`.
Arama chunk düzeyinde **max-pool** (pasaj erişiminin standardı); konu ataması ve graph için
doküman ortalaması.

**Opsiyonel indirme.** Ayarlar'da *"Gelişmiş anlamsal model (~80 MB)"*; onboarding'de de
sorulur, boyut uyarısı gösterilir. Arka plan `URLSession` + SHA-256 doğrulaması → App Group'a
yazılır. Mevcut [`MultilingualEmbedder`](../../../Zihin/ML/EmbeddingService.swift) **silinmez**;
bundle yerine diskten okuyacak biçimde `SentenceProvider` olur. Model değişimi → tam reindex.

### 4.2 Veri modeli (migration v2)

```sql
-- item
ALTER TABLE item ADD embeddingModel     TEXT;
ALTER TABLE item ADD embeddingRevision  INTEGER;
ALTER TABLE item ADD lemmaText          TEXT;     -- NLTagger(.lemma) gölge kolonu
-- title artık NULL kalabilir; prefix(80) hilesi kaldırılır

CREATE TABLE item_chunk (
    itemId TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    idx    INTEGER NOT NULL,
    vector BLOB NOT NULL,
    PRIMARY KEY (itemId, idx));

-- etiketlere tip
ALTER TABLE tag ADD kind TEXT NOT NULL DEFAULT 'keyword';   -- topic|entity|color|keyword

-- taksonomi
CREATE TABLE topic (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, parentId TEXT REFERENCES topic(id),
    isCore BOOLEAN NOT NULL DEFAULT 0, createdAt DATETIME NOT NULL);
CREATE TABLE topic_phrase (topicId TEXT NOT NULL REFERENCES topic(id) ON DELETE CASCADE,
                           phrase TEXT NOT NULL);
CREATE TABLE item_topic (
    itemId TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    topicId TEXT NOT NULL REFERENCES topic(id) ON DELETE CASCADE,
    score REAL NOT NULL,
    source TEXT NOT NULL,                    -- lexicon|embedding|llm|manual
    PRIMARY KEY (itemId, topicId));

-- space üyeliği materyalize
-- DİKKAT: item_space v1 migration'ında ZATEN yaratılmış (boş duruyor) → ALTER, CREATE değil
ALTER TABLE item_space ADD source   TEXT NOT NULL DEFAULT 'manual';  -- manual|rule|semantic
ALTER TABLE item_space ADD excluded BOOLEAN NOT NULL DEFAULT 0;      -- "buraya ait değil"
ALTER TABLE space ADD rule      TEXT;
ALTER TABLE space ADD threshold REAL;

-- graph
CREATE TABLE graph_position (nodeKey TEXT PRIMARY KEY, x REAL, y REAL,
                             pinned BOOLEAN NOT NULL DEFAULT 0);
CREATE TABLE manual_edge (
    id TEXT PRIMARY KEY,
    aKey TEXT NOT NULL, bKey TEXT NOT NULL,  -- yönsüz: DAİMA aKey < bKey normalize edilir
    origin TEXT NOT NULL,                    -- user|suggested
    batchId TEXT,                            -- toplu geri alma için
    createdAt DATETIME NOT NULL,
    UNIQUE (aKey, bKey));                    -- çift kenar imkânsız
CREATE TABLE profile_node  (id TEXT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE profile_topic (profileId TEXT NOT NULL REFERENCES profile_node(id) ON DELETE CASCADE,
                            topicId   TEXT NOT NULL REFERENCES topic(id) ON DELETE CASCADE,
                            PRIMARY KEY (profileId, topicId));

-- μ ve model durumu
CREATE TABLE embedding_meta (key TEXT PRIMARY KEY, vector BLOB, count INTEGER,
                             model TEXT, revision INTEGER);
```

`nodeKey` şeması: `"item:<uuid>"`, `"topic:<uuid>"`, `"profile:<uuid>"`.

FTS5 tablosu yeniden kurulur: `lemmaText` kolonu eklenir, `bm25` ağırlıkları tanımlanır
(`title ≫ summary > textContent > transcript > ocrText > frameText`).

### 4.3 Etiketleme

Üç katman, **kesinlik sırasıyla**:

1. **Lexicon** — küratörlü eşleme: `{opus, claude, gpt, llm, token, prompt, embedding, mlx} → ai`.
   Eşleşirse kesin atama, `source = lexicon`, `score = 1.0`.
2. **Merkezlenmiş prototip cosine** — konu, `score ≥ τ_topic` **ve** `marj ≥ δ` ise atanır.
   İkisinden biri sağlanmazsa **hiçbir etiket atanmaz** (abstention). §2.5'in doğrudan sonucu.

   *Başlangıç değerleri:* `τ_topic = 0.05`, `δ = 0.05`. Probe'da en iyi tek eşik `τ = +0.031`,
   prototip marj ortalaması `+0.145` ölçüldü — bu değerler o aralıktan seçildi. **Nihai
   değerler F0 kapısındaki golden set üzerinde kalibre edilir**; sabit sayı olarak
   dondurulmaz, `TopicClassifier` yapılandırmasında tutulur.
3. **FoundationModels** — `#available(iOS 26, *)` ve `SystemLanguageModel.default.availability
   == .available` ise: `@Generable` ile taksonomiye kısıtlanmış üretim. Hem 1+2'yi rafine eder
   hem *yeni konu adı* önerir. Yoksa 1+2 tek başına yeterlidir.

**Hibrit taksonomi.** ~40 küratörlü çekirdek konu, hiyerarşik
(`Teknoloji > Yapay Zekâ > Dil Modelleri`), her biri 3-6 TR/EN prototip ifadesiyle, JSON kaynak
olarak bundle'da. Üzerine **keşif**: konusuz item'ların merkezlenmiş vektörleri üzerinde kNN
grafiği → yüzdelik eşikte bağlı bileşenler → **c-TF-IDF** ile aday ad →
*"Bu 9 not yeni bir konu gibi duruyor. Adlandırayım mı?"* Kabul edilen konu aynı `topic`
tablosuna `isCore = 0` ile girer; prototipi = üyelerin merkezi.

**Tip ayrımının önemi:** bugün RAKE keyword'leri, NER varlıkları ve **renk adları** tek torbada.
[`sharedTagPairs`](../../../Zihin/Data/ItemRepository.swift) `"mavi"`yi anlamsal bağ sanıyor.
`tag.kind` bunu bitiriyor; graph ve space'ler yalnız `topic`'e bakar.

### 4.4 Space

`search()` ve `matches()` **ayrılır**:

- `search(q) -> [Item]` — recall, sıralı, eşiksiz. Aramada doğru davranış.
- `matches(space, item) -> Bool` — precision, boolean. Üyelikte doğru davranış.

Space üç kaynaktan üye alır, hepsi `item_space`'e **materyalize** edilir:

| Kaynak | Kural |
|---|---|
| `manual` | Kullanıcı ekledi |
| `rule` | `topic:ai AND type:note AND after:2026-01` — deterministik, eşiksiz |
| `semantic` | Merkezlenmiş cosine ≥ `space.threshold` + üst sınır + "neden eşleşti" gerekçesi |

`excluded` bayrağı, kullanıcının "bu buraya ait değil" kararını kalıcı kılar. Üyelik
enrichment sonunda ve kural değişiminde yeniden hesaplanır — `.task` içinde `search()`
koşturmak biter.

**Otomatik space önerisi:** §4.3'teki keşif boru hattıyla aynı. Yeterince büyük ve saf bir
küme çıkarsa space önerilir.

### 4.5 Navigasyon ve düzenleme

`String` yerine tek bir route tipi — çakışma tip düzeyinde imkânsız hâle gelir:

```swift
enum Route: Hashable { case item(String), space(String) }
```

Bugün [`SpacesView.swift:55`](../../../Zihin/UI/SpacesView.swift) ve `:110` aynı
`NavigationStack` içinde `String` için iki destination kaydediyor; dıştaki kazanıyor, item
id'siyle `spaces.first(where:)` `nil` dönüyor, `else` dalı olmadığı için **boş view** push
ediliyor. Dört ekranın hepsi `Route`'a geçer.

Düzenleme:

- `ItemRepository.updateContent(id:title:text:)` → `dirty = true`, `status = .pending`
- `EnrichmentQueue` yeniden embed / özet / etiket üretir; FTS `synchronize(withTable:)`
  sayesinde kendini günceller
- `NewNoteSheet`'e başlık alanı
- [`IngestionService.swift:21`](../../../Zihin/Capture/IngestionService.swift)'deki
  `item.title = String(s.prefix(80))` **kaldırılır**; başlık boşsa görüntüleme anında türetilir,
  veritabanına yazılmaz

### 4.6 Kavram grafiği

Düğüm tipleri: `item`, `topic`, `profile`.

**Kenarlar:**

| Kenar | Kaynak | Ağırlık |
|---|---|---|
| item — topic | `item_topic` | `score` |
| topic — topic | `parentId` (hiyerarşi) + birlikte-geçiş | co-occurrence / IDF |
| profile — topic | `profile_topic` | 1.0 |
| item — item | **yalnız `manual_edge`** | 1.0 |

Item'lar **varsayılan olarak birbirine yalnız konular üzerinden** bağlanır. Her kenarın
açıklanabilir bir sebebi vardır ("ikisi de `ai` konusunda").

**Bağlantı önerisi akışı** (kullanıcı isteği):

1. "Bağlantı öner" düğmesi → merkezlenmiş vektörler üzerinde kNN (k=3)
2. Öneriler **kesikli, soluk** kenarlar olarak çizilir — henüz kalıcı değil
3. **Kaydet** → `manual_edge(origin: 'suggested', batchId: <yeni>)`
4. **Geri al** → `batchId` ile toplu silme

Kullanıcı ayrıca iki düğümü basılı tutup sürükleyerek elle kenar çizebilir
(`origin: 'user'`).

**Diğer düzeltmeler:**

- Ağırlık = **etiket IDF**'i. Nadir konu güçlü bağ. `"mavi"` artık `kind = color` olduğu için
  hiç kenar üretmez.
- `minShared: 2` düşer — tipli **1 ortak konu** gerçek bağdır.
- `graph_position` → sürüklenen düğüm pinlenir; force layout yalnız pinsizleri hareket ettirir.
- Layout **MainActor dışına** taşınır. Bugün [`GraphView.swift:43`](../../../Zihin/UI/GraphView.swift)
  `.task` içinde O(n²) cosine + 150 iterasyon koşturuyor; 250 item'da UI donuyor.
- İzole düğümler gizlenmez ([`KnowledgeGraph.swift:89`](../../../Zihin/Features/KnowledgeGraph.swift)),
  kenarda "yalnızlar" kümesi olarak gösterilir.
- `profile_node` → onboarding/Ayarlar'dan *"Meslek: yazılımcı"*. Kullanıcının aradığı düğüm bu;
  nottan türetilemez, **beyan edilir**.

### 4.7 Arama

1. `NLTagger(.lemma)` ile `lemmaText` gölge kolonu → `yazılımcı` ≡ `yazılım`.
   (Alternatif `trigram` tokenizer index'i şişirir ve sıralamayı bozar.)
2. `FTS5Pattern(matchingAnyTokenIn:)` (**OR**) yerine **AND-önce / OR-fallback**;
   yazarken prefix eşleşme.
3. `bm25(item_fts, …)` kolon ağırlıkları — `title` ≫ `ocrText`.
4. RRF (k=60) korunur; üstüne recency decay + pin boost + topic boost + **skor tabanı**.
5. **MMR** çeşitlendirme — 10 benzer not sayfayı doldurmasın.
6. Parser'a `topic:`, `type:`, `in:space` (renk/tarih zaten var).
7. Vektör tarafı: chunk max-pool, **merkezlenmiş**, mutlak eşik **yok** — top-K sıralama.
8. `allEmbeddings()` cache'lenir. `sqlite-vec`'e ancak ~10k item'dan sonra geçilir (v1.0 spec §6).

### 4.8 Reindex

Mevcut tüm embedding'ler çöp (§2.1); en az bir kez reindex kaçınılmaz.

- **Arka planda, sessiz.** Migration v2 tüm item'ları `status = pending`,
  `embedding = NULL` yapar. `EnrichmentQueue` mevcut akışıyla işler. Kartlardaki
  "işleniyor" rozeti zaten var.
- **Ayarlar'da "Yeniden indeksle" düğmesi** — kullanıcı isterse tetikler.
- `embeddingModel` / `embeddingRevision` uyuşmazlığı her zaman aynı yolu tetikler; opsiyonel
  model indirmesi bunu otomatik kapsar.
- Arama ve graph, doldukça iyileşir; kısmi sonuç bozuk sonuçtan iyidir.

### 4.9 CloudKit

- Vektörler ve `item_chunk` **eşitlenmez** — yerelde yeniden üretilebilir, item başına ~2 KB tasarruf
- `item_topic`, `graph_position`, `manual_edge`, `profile_node` eşitlenir
- `topic` tablosu eşitlenir (kullanıcı taksonomisi cihazlar arası tutarlı olmalı)
- Mevcut LWW politikası korunur

---

## 5. Doğrulama kapıları

Her fazın geçiş şartı sallantılı yargı değil, ölçüm.

| Faz | İçerik | Kapı |
|---|---|---|
| **F0** Temel | `EmbeddingProvider`, `μ`, chunking, migration v2, model versiyonlama, reindex | ~40 etiketli Türkçe nottan golden set: **ayrışma ≥ 0.20**, zero-shot doğruluk **≥ %80**. Regresyon testi: kod tabanında merkezlenmemiş mutlak cosine eşiği **yok** |
| **F1** Doğruluk | `Route` enum, `matches()` ⟂ `search()`, edit + başlık | Aynı korpusta iki farklı space'in kesişimi **< %50**. UI testi: space → not detayı açılıyor. Düzenlenen not yeniden indeksleniyor |
| **F2** Zekâ | Taksonomi çekirdeği, lexicon, prototip + abstention, FoundationModels, keşif, space önerisi | AI notu `ai` etiketi alıyor; **konusuz not hiç etiket almıyor** |
| **F3** Graph | Bipartite model, `graph_position`, `manual_edge`, öneri akışı, profil düğümleri | 250 item'da build **< 1 s** ve **main thread'de değil**; pinlenen düğüm yeniden açılışta yerinde; "geri al" batch'i tamamen siliyor |
| **F4** Arama | Lemma, bm25 ağırlıkları, MMR, filtreler | `yazılımcı` → `yazılım` notunu buluyor; `title` eşleşmesi `ocrText` eşleşmesini yeniyor |
| **F5** Opsiyonel model | İndirme, SHA-256, disk yükleme, geçiş | Model değişince reindex tetikleniyor; yarım kalan indirme çökmeye yol açmıyor |

**F0 kapısı geçilmeden F2 ve F3 doğrulanamaz** — çöp vektörle hiçbir konu ataması veya graph
kenarı anlamlı değildir. F1'deki iki düzeltme (`Route` çakışması, üyelik eşiği) F0'dan
bağımsızdır ve önce çıkabilir.

---

## 6. Riskler

| Risk | Etki | Azaltma |
|---|---|---|
| `NLContextualEmbedding` asset'i cihazda inmemiş olabilir | Embedding üretilemez | `requestAssets()` + indirilene kadar yalnız FTS5 ile çalış; kullanıcıya sessiz kal |
| `μ` az notta kararsız | Erken kullanıcıda kötü sonuç | `μ₀` bundle bootstrap + harmanlama (k=50) |
| Merkezleme `μ` değişince tüm benzerlikleri kaydırır | Space üyeliği titreşir | Donmuş `μ` günde en çok bir kez tazelenir (§4.1b); tazelendiğinde üyelik topluca yeniden hesaplanır |
| Küratörlü taksonomi bakım yükü | Etiketler eskir | Keşif katmanı boşlukları doldurur; `isCore = 0` konular kullanıcıya ait |
| FoundationModels iki kod yolu | Bakım maliyeti | Fallback yolu **birincil** kabul edilir; LLM yalnız rafine eder, hiçbir şeyi tek başına belirlemez |
| Reindex uzun sürer | Kullanıcı bozuk sanır | Arka plan + mevcut "işleniyor" rozeti + Ayarlar'da ilerleme |
| 512-dim çakışması iki model arasında | **Sessiz veri bozulması** | `embeddingModel` + `revision` kolonları; uyuşmazlıkta vektör okunmaz |

---

## 7. Kapsam dışı

- `sqlite-vec` (< 10k item'da gereksiz)
- Görsel/video asset'lerinin CloudKit eşitlemesi (v1.1)
- Çok kullanıcılı / paylaşımlı space'ler
- Graph'ta zaman ekseni / animasyon
- Taksonominin cihazlar arası çatışma çözümü (LWW yeterli kabul edildi)

---

## 8. Değişiklik özeti (v1.0 spec'ine göre)

- **§6 Arama:** "eşik 0.15" **iptal**. Mutlak cosine eşiği hiçbir yerde kullanılmaz.
  Merkezlenmiş cosine + top-K sıralama.
- **§9 UI:** Space'in "manuel" yarısı nihayet uygulanır. Düzenleme ve başlık eklenir.
- **§10 E2 Knowledge graph:** Item-item benzerlik grafiğinden **kavram grafiğine** geçilir.
  Kenarlar konular üzerinden; item-item kenarları yalnız kullanıcı onayıyla.
- **§5 Enrichment:** Etiketler tiplenir (`topic|entity|color|keyword`). Konu ataması
  abstention'lı prototip sınıflandırmasıyla yapılır.
- **E5 On-device LLM:** "v2, default KAPALI" → **v2'de opsiyonel rafine katmanı**, fallback
  birincil.
- `EmbeddingService` tek fonksiyondan `EmbeddingProvider` protokolüne çıkar.
