# ZİHİN — Mac Kurulum Rehberi (Xcode 16, iOS 17+)

> Bu repo Windows'ta üretildi; kod hiç derlenmedi. İlk derlemede ufak API düzeltmeleri
> normaldir — hataları Mac'te Claude Code (`ecc:swift-build-resolver`) ile kapat.

## 1. Proje oluştur
1. Xcode → **New Project → iOS → App**
   - Name: `Zihin` • Interface: **SwiftUI** • Storage: **None** • Min deployment: **iOS 17.0**
   - Bundle ID: `app.zihin.Zihin`
2. Xcode'un ürettiği `ContentView.swift` ve `ZihinApp.swift`'i SİL (bizim `UI/AppRoot.swift` @main içeriyor).
3. Bu repodaki `Zihin/` klasörünü (Data, ML, Capture, Search, UI) projeye sürükle
   → "Copy items if needed" + ana app target'ı işaretli.

## 2. Share Extension target
1. **File → New → Target → Share Extension**, Name: `ShareExtension`.
2. Xcode'un ürettiği `ShareViewController.swift`'i bizimkiyle değiştir (repodaki `ShareExtension/`).
3. ShareExtension **Info.plist** → `NSExtension` → `NSExtensionAttributes` →
   `NSExtensionActivationRule`'ı **Dictionary** yap ve ekle:
   - `NSExtensionActivationSupportsWebURLWithMaxCount` = 1
   - `NSExtensionActivationSupportsImageWithMaxCount` = 10
   - `NSExtensionActivationSupportsMovieWithMaxCount` = 1
   - `NSExtensionActivationSupportsText` = YES
   - `NSExtensionActivationSupportsFileWithMaxCount` = 5
4. Şu dosyalara **ShareExtension target membership** de ekle (File Inspector):
   `Models.swift, DatabaseManager.swift, ItemRepository.swift, Stores.swift, IngestionService.swift`
   (Enrichment/UI dosyaları extension'a EKLENMEZ — bellek limiti, spec §3.2.)

## 3. Capabilities (her iki target)
| Capability | Değer | Target |
|---|---|---|
| App Groups | `group.app.zihin` | app + extension |
| Keychain Sharing | `app.zihin.shared` (listede İLK sırada) | app + extension |
| iCloud → CloudKit | `iCloud.app.zihin` | yalnız app (Faz 3'te kullanılacak, şimdi açman yeterli) |

## 4. Paketler + şifreleme bayrağı
1. **File → Add Package Dependencies:**
   - `https://github.com/duckduckgo/GRDB.swift` (SQLCipher'lı GRDB) → **app + extension**
   - `https://github.com/scinfu/SwiftSoup` → yalnız app
2. Her iki target → Build Settings → **Active Compilation Conditions** → `ZIHIN_ENCRYPTED` ekle
   (Debug + Release). Bu, `DatabaseManager`'daki SQLCipher passphrase kodunu açar (E3, gün 1).
   - Düz resmi GRDB kullanmak istersen bayrağı ekleme; DB şifresiz çalışır.
3. Build Settings → **Strict Concurrency Checking = Complete** (iki target).

## 5. Embedding modeli (TR semantic arama — bir kez üret)
```bash
pip install sentence-transformers coremltools torch
python convert_embedder.py
```
`convert_embedder.py`:
```python
import torch, coremltools as ct
from sentence_transformers import SentenceTransformer

st = SentenceTransformer("sentence-transformers/distiluse-base-multilingual-cased-v2")
bert, dense = st[0].auto_model.eval(), st[2].linear.eval()   # print(st) ile doğrula: [Transformer, Pooling, Dense]

class Wrapper(torch.nn.Module):
    def __init__(self, bert, dense):
        super().__init__(); self.bert, self.dense = bert, dense
    def forward(self, input_ids, attention_mask):
        h = self.bert(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state
        m = attention_mask.unsqueeze(-1).to(h.dtype)
        pooled = (h * m).sum(1) / m.sum(1).clamp(min=1e-9)
        return torch.nn.functional.normalize(self.dense(pooled), dim=-1)  # (1, 512)

w = Wrapper(bert, dense).eval()
ex_ids = torch.zeros((1, 128), dtype=torch.int32)
ex_mask = torch.ones((1, 128), dtype=torch.int32)
traced = torch.jit.trace(w, (ex_ids, ex_mask))
ml = ct.convert(traced,
    inputs=[ct.TensorType(name="input_ids", shape=(1, 128), dtype=ct.converters.mil.mil.types.int32),
            ct.TensorType(name="attention_mask", shape=(1, 128), dtype=ct.converters.mil.mil.types.int32)],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16)
ml.save("Embedder.mlpackage")
st.tokenizer.save_pretrained("tok")   # tok/vocab.txt çıkar
```
- `Embedder.mlpackage` + `tok/vocab.txt` dosyalarını **yalnız app target'a** sürükle
  (vocab dosya adı `vocab.txt` kalmalı). ~135MB — git'e girmez (.gitignore'da).
- **Model olmadan da derlenir/çalışır:** `MultilingualEmbedder.shared` nil olur,
  Apple EN embedding'e düşer. Önce modelsiz derleyip sonra eklemek en hızlı yol.

## 6. Ana app Info.plist izin metinleri
| Key | Örnek değer |
|---|---|
| `NSPhotoLibraryUsageDescription` | Kaydettiğin görselleri ve videoları içe aktarmak için. |
| `NSSpeechRecognitionUsageDescription` | Videolardaki konuşmayı cihazında metne çevirmek için. |
| `NSMicrophoneUsageDescription` | Ekran kaydı içeriğini işlemek için. |

## 6b. Unit test target'ı
1. **File → New → Target → Unit Testing Bundle**, Name: `ZihinTests` (Host: Zihin app).
2. Repodaki `ZihinTests/AlgorithmTests.swift`'i target'a ekle → `Cmd+U` ile koş.
   Saf algoritmaları (TextRank/RAKE/kmeans/RRF/parser/exporter) cihazsız doğrular.

## 7. İlk çalıştırma (Faz 0 kapısı)
1. Gerçek iPhone'da çalıştır (Simulator'da Vision/Speech sınırlı).
2. `+` ile not ekle → kartta özet/etiket oluşmalı.
3. Photos'tan yazılı bir screenshot paylaş → ≤2 sn'de kart, app'e dönünce ≤30 sn'de
   OCR + ≥3 etiket + renk.
4. Ara sekmesinde OCR'daki bir kelimeyi ara → kart çıkmalı; "mavi" → mavi görseller.
5. ✅ ise Faz 0 kapısı geçildi → `PROGRESS.md` güncelle, Faz 1 kalanlarına geç.

## 8. Bilinen sınırlar (v1.0 kararları)
- Uzak video asla indirilmez (spec §7) — Settings'te ekran kaydı ipucu var.
- STT yalnız on-device destekleyen dillerde çalışır; yoksa transcript boş kalır.
- CloudKit sync + Obsidian export kodu henüz yazılmadı (Faz 3, spec §8/§10).
