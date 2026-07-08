# ZİHİN v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild Zihin's semantic layer on `NLContextualEmbedding` with corpus-mean centering, add typed tags + a curated/discovered topic taxonomy with abstention, materialize space membership, replace the item-item similarity graph with an explainable concept (bipartite) graph, and rewrite search (lemma + weighted bm25 + MMR).

**Architecture:** Swift 6 / SwiftUI / GRDB (SQLCipher fork). On-device only. An `EmbeddingProvider` protocol replaces the single `EmbeddingService.embed`. Similarity is always computed on **centered** vectors (`v − μ`), never raw cosine with an absolute threshold. A GRDB migration `v2` adds chunk vectors, typed tags, topics, materialized `item_space`, graph tables, and an `embedding_meta` store for the frozen corpus mean μ. FoundationModels (iOS 26) refines classification when the hardware supports it; the lexicon+prototype path is primary.

**Tech Stack:** Swift 6.0, SwiftUI, GRDB 7 (DuckDuckGo fork, exactVersion 3.0.0), NaturalLanguage (`NLContextualEmbedding`, `NLTagger`), FoundationModels (iOS 26), CoreML (optional 80 MB sentence model), CloudKit.

## Global Constraints

- **Deployment target: iOS 26.0** (raised from 17.0 per 2026-07-09 decision). FoundationModels always compiles; gate its *use* on `SystemLanguageModel.default.availability == .available`.
- **Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`.** All shared types `Sendable`; DB access through `DatabasePool`.
- **GRDB dependency pinned `exactVersion: "3.0.0"`** — do not change to `from:`.
- **No absolute cosine threshold anywhere.** Similarity = centered cosine / L2 on `v − μ`; ranking is top-K. F0 regression test asserts the old `> 0.15` / `>= 0.5` thresholds are gone.
- **Every vector carries `embeddingModel` + `embeddingRevision`.** Mismatch triggers reindex; mismatched vectors are never read for similarity.
- **512 dimensions** for both providers.
- **All processing on-device.** No content leaves the device (privacy copy in Settings must stay true).
- **Turkish-first.** Copy in Turkish; algorithms validated on Turkish text.
- Verification (build, XCTest, gates) runs on **macOS 26 + Xcode** — not in this Windows dev environment. Each phase ends with the exact commands to run there.

---

## File Structure

**New files**
- `Zihin/ML/EmbeddingProvider.swift` — `EmbeddingProvider` protocol, `ContextualProvider` (NLContextualEmbedding), `SentenceProvider` (optional mlmodelc from App Group), `EmbeddingCoordinator` (active provider + chunking).
- `Zihin/ML/Centering.swift` — `CorpusMean` (μ store: running Σv/count + frozen μ, μ₀ blend, daily refresh), `Centered` similarity helpers.
- `Zihin/ML/Chunking.swift` — token-window chunker (~200 tokens), doc-mean + max-pool helpers.
- `Zihin/ML/TopicClassifier.swift` — lexicon → centered-prototype (abstention) → optional FoundationModels refine. Config holds `τ_topic`, `δ`.
- `Zihin/ML/TopicDiscovery.swift` — kNN graph over centered vectors → connected components → c-TF-IDF candidate name.
- `Zihin/ML/FoundationModelsRefiner.swift` — `@Generable` taxonomy-constrained classification, availability-guarded.
- `Zihin/Data/Taxonomy.swift` — models `Topic`, `TopicPhrase`, `ItemTopic`, `ProfileNode`, `ProfileTopic`, `ManualEdge`, `GraphPosition`, `EmbeddingMeta`, `ItemChunk`; typed `TagKind`.
- `Zihin/Data/TopicRepository.swift` — topic CRUD, item_topic upserts, prototypes, discovery inputs.
- `Zihin/Data/GraphRepository.swift` — graph_position, manual_edge (normalized undirected + batch), profile nodes, bipartite edge queries.
- `Zihin/Data/SpaceMembership.swift` — `matches()` predicate, rule parser, membership recompute → materializes `item_space`.
- `Zihin/Features/ConceptGraph.swift` — bipartite node/edge model + off-main-actor force layout, replaces item-item semantic edges in `KnowledgeGraph`.
- `Zihin/Support/Route.swift` — `enum Route: Hashable { case item(String), space(String) }`.
- `Zihin/Resources/topics.json` — ~40 curated core topics, hierarchical, 3–6 TR/EN phrases each.
- `Zihin/Resources/mu0.bin` — 512-float general-Turkish corpus mean (bootstrap). *(placeholder generated on Mac from probe; see Task F0.6)*
- `Zihin/ML/ModelDownloader.swift` — background URLSession + SHA-256 → App Group (optional sentence model).

**Modified files**
- `Zihin/Data/DatabaseManager.swift` — add migration `v2` (all §4.2 DDL) + FTS5 rebuild with `lemmaText` and bm25 weights.
- `Zihin/Data/Models.swift` — `Item` gains `embeddingModel`, `embeddingRevision`, `lemmaText`; `Tag` gains `kind`; `Space` gains `rule`, `threshold`; `ItemSpace` gains `source`, `excluded`.
- `Zihin/Data/ItemRepository.swift` — `updateContent(id:title:text:)`; `sharedTagPairs` becomes topic-based; chunk read/write; drop title-from-prefix reads.
- `Zihin/Capture/IngestionService.swift` — remove `title = prefix(80)` (all cases).
- `Zihin/Capture/EnrichmentQueue.swift` — produce chunks + doc vector via coordinator; call `TopicClassifier`; update μ running sum; typed tags; recompute affected space membership.
- `Zihin/Search/SearchService.swift` — lemma pattern, AND-first/OR-fallback + prefix, weighted bm25, RRF + recency/pin/topic boost + score floor, MMR, `topic:`/`type:`/`in:space` filters, centered vector max-pool top-K.
- `Zihin/ML/EmbeddingService.swift` — becomes a thin shim over `EmbeddingCoordinator` (keep `MultilingualEmbedder` as `SentenceProvider` backend, read from disk).
- `Zihin/UI/SpacesView.swift`, `GraphView.swift`, `TimelineView.swift`, `ExtrasViews.swift`, `OnboardingView.swift`, `DetailViews.swift`, `AppRoot.swift` — `Route` navigation; note edit + title field; graph rewrite UI (suggest/undo/pin/profile); Settings reindex + optional-model toggle; onboarding profile + model prompt.
- `Zihin/Sync/CloudKitSyncService.swift` — sync item_topic/graph_position/manual_edge/profile/topic; never sync vectors/chunks.
- `project.yml` — deploymentTarget 26.0; add `Zihin/Resources` bundle; FoundationModels framework.
- `ZihinTests/AlgorithmTests.swift` + new `ZihinTests/*` — gate tests per phase.

---

## Phase F0 — Foundation (embedding, μ, chunking, migration v2, versioning, reindex)

*Gate (Mac): golden set of ~40 labeled TR notes → separation ≥ 0.20, zero-shot ≥ 80%. Regression: no centered-less absolute cosine threshold in the codebase.*

### Task F0.1: Data model columns + migration v2 skeleton
**Files:** Modify `Zihin/Data/Models.swift`, `Zihin/Data/DatabaseManager.swift`; Create `Zihin/Data/Taxonomy.swift`; Test `ZihinTests/MigrationTests.swift`.
**Interfaces — Produces:** `Item.embeddingModel: String?`, `Item.embeddingRevision: Int?`, `Item.lemmaText: String?`; `enum TagKind: String { topic, entity, color, keyword }`; `Tag.kind: String`; `Space.rule: String?`, `Space.threshold: Double?`; `ItemSpace.source: String`, `ItemSpace.excluded: Bool`; new records `Topic`, `TopicPhrase`, `ItemTopic`, `ItemChunk`, `ManualEdge`, `GraphPosition`, `ProfileNode`, `ProfileTopic`, `EmbeddingMeta`.
- [ ] Add columns to `Item`, `Tag`, `Space`, `ItemSpace` structs (Codable/Persistable) matching §4.2.
- [ ] Register migration `v2` with all §4.2 DDL: `ALTER TABLE item ADD …`; `CREATE TABLE item_chunk/topic/topic_phrase/item_topic/graph_position/manual_edge/profile_node/profile_topic/embedding_meta`; `ALTER TABLE tag ADD kind`; `ALTER TABLE item_space ADD source/excluded`; `ALTER TABLE space ADD rule/threshold`. Note: `item_space` already exists (ALTER, not CREATE).
- [ ] In `v2`, set every existing item `status='pending'`, `embedding=NULL` (reindex, §4.8).
- [ ] Test: open in-memory/temp DB, run migrator, assert new columns exist (`PRAGMA table_info`) and new tables exist.
- [ ] Commit: `feat(F0): migration v2 schema + typed models`.

### Task F0.2: EmbeddingProvider protocol + ContextualProvider
**Files:** Create `Zihin/ML/EmbeddingProvider.swift`; Test `ZihinTests/EmbeddingProviderTests.swift`.
**Interfaces — Produces:** `protocol EmbeddingProvider: Sendable { var modelIdentifier: String { get }; var revision: Int { get }; var dimension: Int { get }; func embed(_ text: String) -> [[Float]]? }`; `struct ContextualProvider: EmbeddingProvider` (NLContextualEmbedding `.latin`, dimension 512, requests assets, chunk→one vector each).
- [ ] Define protocol.
- [ ] Implement `ContextualProvider`: lazily create `NLContextualEmbedding(script: .latin)`, `requestAssets` (async → cached ready flag), mean-pool token embeddings per chunk to one 512-vec.
- [ ] Test (pure, no model): protocol conformance + `modelIdentifier`/`revision`/`dimension` constants; `embed("")` returns nil. (Model-backed embedding asserted on Mac.)
- [ ] Commit: `feat(F0): EmbeddingProvider + ContextualProvider`.

### Task F0.3: Chunking
**Files:** Create `Zihin/ML/Chunking.swift`; Test `ZihinTests/ChunkingTests.swift`.
**Interfaces — Produces:** `enum Chunker { static func chunks(_ text: String, targetTokens: Int = 200) -> [String] }`; `enum Pooling { static func maxPool(_ vs: [[Float]]) -> [Float]; static func meanPool(_ vs: [[Float]]) -> [Float] }`.
- [ ] Implement word-window chunker (~200 tokens, split on whitespace, no chunk > ~256 tokens per §2.6).
- [ ] Implement max-pool (element-wise max) + mean-pool (element-wise average, guards empty).
- [ ] Tests: short text → 1 chunk; 1000-word text → multiple chunks each ≤ window; maxPool/meanPool dimensions + known values.
- [ ] Commit: `feat(F0): token-window chunking + pooling`.

### Task F0.4: Corpus mean μ (Centering)
**Files:** Create `Zihin/ML/Centering.swift`; Test `ZihinTests/CenteringTests.swift`.
**Interfaces — Produces:** `struct CorpusMean { let mu: [Float]; func center(_ v: [Float]) -> [Float] }`; `enum CenteringStore { static func runningAdd(_ v: [Float], db:) ; static func frozenMu(db:) -> CorpusMean; static func refreshFrozenMuIfNeeded(db:) ; static func blend(userSum:[Float], count:Int, mu0:[Float], k:Int=50) -> [Float] }`; centered cosine `Centered.cosine(_ a:[Float], _ b:[Float], mu:[Float])`.
- [ ] Implement μ blend `μ = (n·μ_user + k·μ₀)/(n+k)`, k=50, where μ_user = Σv/count.
- [ ] Store Σv/count/model/revision in `embedding_meta` (key `"sum"`); frozen μ (key `"frozen"`) with refresh guarded to ≤ once/day or on reindex.
- [ ] `center(v) = v − μ`; `Centered.cosine` centers both then cosine.
- [ ] Tests: blend with n=0 → μ₀; blend converges to μ_user as n≫k; centered cosine of identical vectors after centering; refresh writes only when stale.
- [ ] Commit: `feat(F0): corpus mean μ + centered similarity`.

### Task F0.5: EmbeddingCoordinator + reindex plumbing
**Files:** Create/replace `Zihin/ML/EmbeddingService.swift` (shim) + coordinator in `EmbeddingProvider.swift`; Modify `Zihin/Data/ItemRepository.swift` (chunk read/write, model-version stamping); Test `ZihinTests/CoordinatorTests.swift`.
**Interfaces — Produces:** `actor EmbeddingCoordinator { static let shared; var active: EmbeddingProvider; func embedDocument(_ text) -> (doc:[Float], chunks:[[Float]])?; func stamp(_ item: inout Item) }`; `ItemRepository.saveChunks(_ vectors:[[Float]], itemId:)`, `chunks(itemId:) -> [[Float]]`, `itemsNeedingReindex(model:revision:) -> [Item]`.
- [ ] Coordinator: chunk text → provider.embed each → doc vector = mean-pool of chunk vectors; expose chunks separately (search uses max-pool).
- [ ] `stamp`: set `item.embeddingModel = active.modelIdentifier`, `item.embeddingRevision = active.revision`.
- [ ] Repo: `item_chunk` upsert/read; query items whose model/revision ≠ active (reindex candidates).
- [ ] `EmbeddingService.embed` shim delegates to coordinator doc vector (keeps existing callers compiling).
- [ ] Tests: coordinator doc vector = mean of stubbed chunk vectors; stamp sets fields; reindex query returns mismatches only.
- [ ] Commit: `feat(F0): embedding coordinator + reindex plumbing`.

### Task F0.6: μ₀ bootstrap asset + wiring, FTS5 rebuild
**Files:** Create `Zihin/Resources/mu0.bin`; Modify `DatabaseManager.swift` (FTS5 with `lemmaText` + bm25 weights), `project.yml` (Resources bundle, iOS 26); Test `ZihinTests/FTSWeightTests.swift`.
- [ ] Generate `mu0.bin` (512 floats) — placeholder zero-vector committed now; regenerate on Mac from probe corpus (documented in file header comment / SETUP note).
- [ ] Rebuild FTS5 in migration: add `lemmaText` column; define bm25 column weights `title ≫ summary > textContent > transcript > ocrText > frameText`.
- [ ] `project.yml`: `deploymentTarget.iOS: "26.0"`, add `Zihin/Resources` to sources, ensure FoundationModels weak-linked.
- [ ] Test: FTS table has `lemmatext` column; a title match outranks an ocrText match (bm25 weighting) on seeded rows.
- [ ] Commit: `feat(F0): μ₀ bootstrap + FTS5 lemma/bm25 rebuild + iOS 26 target`.

### Task F0.7: Wire enrichment to coordinator + μ update
**Files:** Modify `Zihin/Capture/EnrichmentQueue.swift`; Test `ZihinTests/EnrichmentWiringTests.swift` (logic-level).
- [ ] In each enrich branch, build doc+chunks via `EmbeddingCoordinator`, save chunks, stamp model/revision, add vector to μ running sum, compute `lemmaText` via `NLTagger(.lemma)`.
- [ ] Regression gate test: assert `> 0.15` and `>= 0.5` similarity thresholds no longer exist by reading `SearchService.swift`/`KnowledgeGraph.swift` sources.
- [ ] Commit: `feat(F0): enrichment uses centered embedding stack`.

---

## Phase F1 — Correctness (Route, matches()⟂search(), edit + title)

*Gate (Mac): two spaces' intersection < 50%; UI space→detail opens; edited note re-indexes.*

### Task F1.1: Route enum + navigation
**Files:** Create `Zihin/Support/Route.swift`; Modify `SpacesView.swift`, `GraphView.swift`, `TimelineView.swift`, `ExtrasViews.swift`, `DetailViews.swift`.
**Interfaces — Produces:** `enum Route: Hashable { case item(String), space(String) }`.
- [ ] Replace all `navigationDestination(for: String.self)` + `NavigationLink(value: id)` with `Route`. Register both cases once at each stack root; `.item` → `DetailRouter`, `.space` → `SpaceItemsView`.
- [ ] Commit: `fix(F1): Route enum removes navigationDestination collision`.

### Task F1.2: matches() ⟂ search() + membership materialization
**Files:** Create `Zihin/Data/SpaceMembership.swift`; Modify `SpacesView.swift` (read materialized members, not `search()`), `ItemRepository.swift`; Test `ZihinTests/SpaceMembershipTests.swift`.
**Interfaces — Produces:** `enum SpaceMembership { static func matches(space:Space, item:Item, ctx:) -> Bool; static func recompute(spaceId:String); static func recomputeAll() }`; rule parser `topic:x AND type:y AND after:date`.
- [ ] `matches()` boolean predicate: manual ∪ rule ∪ (semantic centered cosine ≥ `space.threshold`, capped), honoring `excluded`.
- [ ] Materialize into `item_space(source, excluded)`; `SpaceItemsView` reads members from table.
- [ ] Recompute on enrichment end + rule change (remove `.task { search() }`).
- [ ] Tests: rule parser; two distinct-topic spaces have <50% overlap on seeded items; excluded item stays out.
- [ ] Commit: `feat(F1): materialized space membership (matches ⟂ search)`.

### Task F1.3: Note edit + title
**Files:** Modify `ItemRepository.swift` (`updateContent`), `IngestionService.swift` (drop prefix(80)), `NoteDetailView`/`NewNoteSheet` in UI, display-time title derivation.
**Interfaces — Produces:** `ItemRepository.updateContent(id:String, title:String?, text:String)` → sets dirty, status=.pending.
- [ ] Remove `item.title = String(s.prefix(80))` everywhere; store title only when user gives one.
- [ ] `updateContent` marks pending → EnrichmentQueue re-embeds/re-summarizes/re-tags; FTS auto-syncs.
- [ ] Add title field to new-note sheet + an edit affordance on note detail.
- [ ] Display helper: title = `item.title ?? derived(firstLine/summary)`, not written to DB.
- [ ] Tests: `updateContent` sets pending+dirty; ingestion no longer writes prefix title.
- [ ] Commit: `feat(F1): note editing + optional titles`.

---

## Phase F2 — Intelligence (taxonomy, lexicon, prototype+abstention, FoundationModels, discovery, space suggestion)

*Gate (Mac): AI note gets `ai` tag; topicless note gets NO tag.*

### Task F2.1: Taxonomy resource + loader + prototypes
**Files:** Create `Zihin/Resources/topics.json`, `Zihin/Data/TopicRepository.swift`; Test `ZihinTests/TaxonomyTests.swift`.
- [ ] `topics.json`: ~40 core topics, hierarchical (`parentId`), each 3–6 TR/EN phrases.
- [ ] Loader seeds `topic`/`topic_phrase` with `isCore=1` on first run; prototype vector = mean of phrase embeddings (centered at read time).
- [ ] Tests: JSON parses; seeding is idempotent; hierarchy links resolve.
- [ ] Commit: `feat(F2): curated taxonomy + seeding`.

### Task F2.2: Lexicon + centered-prototype classifier with abstention
**Files:** Create `Zihin/ML/TopicClassifier.swift`; Test `ZihinTests/TopicClassifierTests.swift`.
**Interfaces — Produces:** `struct TopicClassifier { var config: Config (τ_topic=0.05, δ=0.05); func classify(docVector:[Float], text:String, mu:[Float], prototypes:) -> [(topicId,score,source)] }`.
- [ ] Layer 1 lexicon map `{opus,claude,gpt,llm,token,prompt,embedding,mlx}→ai` etc., score 1.0, source `lexicon`.
- [ ] Layer 2 centered prototype cosine: assign topic only if `score ≥ τ_topic` AND margin(top1−top2) `≥ δ`; else abstain (no tag).
- [ ] Config holds τ/δ (calibrated on Mac golden set; not frozen constants).
- [ ] Tests: lexicon hit → ai; clearly-on-topic synthetic vectors → assigned; ambiguous (small margin) → abstain (empty).
- [ ] Commit: `feat(F2): lexicon + centered-prototype classifier with abstention`.

### Task F2.3: FoundationModels refiner (availability-guarded)
**Files:** Create `Zihin/ML/FoundationModelsRefiner.swift`; Test `ZihinTests/RefinerAvailabilityTests.swift`.
- [ ] `@Generable` type constrained to taxonomy topic names; call only when `SystemLanguageModel.default.availability == .available`; refines layers 1+2 and may propose a new topic name.
- [ ] When unavailable, `classify` returns layers 1+2 unchanged (fallback primary).
- [ ] Test: refiner is optional — classifier output identical whether refiner present or nil on the fallback path.
- [ ] Commit: `feat(F2): FoundationModels refiner (optional)`.

### Task F2.4: Topic discovery + space suggestion
**Files:** Create `Zihin/ML/TopicDiscovery.swift`; Modify `SpaceMembership.swift` (suggestion); Test `ZihinTests/DiscoveryTests.swift`.
**Interfaces — Produces:** `enum TopicDiscovery { static func candidates(vectors:[(id,[Float])], mu:[Float]) -> [Candidate] }` (kNN → connected components → c-TF-IDF name).
- [ ] Build kNN graph over centered vectors of topicless items; percentile-threshold edges; connected components ≥ min size.
- [ ] c-TF-IDF over component members → candidate name; surfaced as "name this topic?" (accepted → `topic` with `isCore=0`, prototype = member centroid).
- [ ] Large+pure component → suggest a space.
- [ ] Tests: two synthetic clusters → two candidates; below-min cluster → none.
- [ ] Commit: `feat(F2): topic + space discovery (c-TF-IDF)`.

### Task F2.5: Typed tags + wire classifier into enrichment
**Files:** Modify `EnrichmentQueue.swift`, `ItemRepository.attachTags` (accept `kind`), `TopicRepository` (item_topic upsert).
- [ ] Enrichment: NER→`entity`, colors→`color`, RAKE→`keyword`, classifier→`item_topic` (+`topic` tag). Graph/spaces read only `topic`.
- [ ] Tests: enrichment writes correct kinds; color word never produces a topic edge.
- [ ] Commit: `feat(F2): typed tags + topic assignment in enrichment`.

---

## Phase F3 — Concept graph (bipartite, positions, manual edges, suggestions, profiles)

*Gate (Mac): 250 items build < 1s and off main thread; pinned node persists; undo batch fully removed.*

### Task F3.1: GraphRepository (positions, manual edges, profiles)
**Files:** Create `Zihin/Data/GraphRepository.swift`; Test `ZihinTests/GraphRepositoryTests.swift`.
**Interfaces — Produces:** `nodeKey` scheme `"item:<uuid>"|"topic:<uuid>"|"profile:<uuid>"`; `addManualEdge(a,b,origin,batchId)` (normalize aKey<bKey, UNIQUE), `deleteBatch(batchId)`, `savePosition(nodeKey,x,y,pinned)`, `positions()`, profile CRUD.
- [ ] Implement normalized undirected `manual_edge`; batch delete; `graph_position` upsert/read; profile node/topic CRUD.
- [ ] Tests: duplicate edge rejected; batch delete removes exactly the batch; position round-trips; pinned flag persists.
- [ ] Commit: `feat(F3): graph repository (edges, positions, profiles)`.

### Task F3.2: ConceptGraph model + off-main-actor layout
**Files:** Create `Zihin/Features/ConceptGraph.swift`; Modify `KnowledgeGraph.swift` (delegate/replace); Test `ZihinTests/ConceptGraphTests.swift`.
**Interfaces — Produces:** bipartite `Node(kind: item|topic|profile)`, `Edge(kind: itemTopic|topicTopic|profileTopic|manual, weight)`; `func build(...) async -> ConceptGraphData` runs layout off `MainActor`.
- [ ] Edges: item–topic (`item_topic.score`), topic–topic (parent + co-occurrence/IDF), profile–topic (1.0), item–item **only** manual_edge. Weight = topic IDF; `minShared:1` for typed topics.
- [ ] Force layout in a detached task/`nonisolated`; pinned nodes fixed; isolated nodes shown as a "loners" cluster (not hidden).
- [ ] Tests: bipartite invariant (no auto item–item edge); IDF weighting; pinned node not moved by layout; loners counted not dropped.
- [ ] Commit: `feat(F3): bipartite concept graph + off-main-actor layout`.

### Task F3.3: Graph UI — suggest / undo / pin / profile
**Files:** Modify `GraphView.swift`; Modify `ExtrasViews.swift`/`OnboardingView.swift` (profile declaration).
- [ ] "Bağlantı öner" → kNN(k=3) dashed faint edges → Save (`origin:suggested`, batchId) / Undo (batch delete). Drag two nodes → manual edge (`origin:user`). Drag persists position (pinned).
- [ ] Profile node from onboarding/Settings ("Meslek: yazılımcı"). Loners shown at edge.
- [ ] Commit: `feat(F3): graph suggestion/undo/pin/profile UI`.

---

## Phase F4 — Search (lemma, weighted bm25, MMR, filters)

*Gate (Mac): `yazılımcı` finds `yazılım` note; title match beats ocrText match.*

### Task F4.1: Lemma shadow column + query build
**Files:** Modify `EnrichmentQueue.swift` (write `lemmaText`), `SearchService.swift`; Test `ZihinTests/LemmaSearchTests.swift`.
- [ ] Populate `lemmaText` via `NLTagger(.lemma)` at enrichment; FTS indexes it.
- [ ] Replace `matchingAnyTokenIn` (OR) with AND-first / OR-fallback + prefix (`token*`) for as-you-type.
- [ ] Tests: query pattern is AND-joined with fallback; lemma column feeds FTS.
- [ ] Commit: `feat(F4): lemma column + AND-first/prefix query`.

### Task F4.2: Weighted bm25 + RRF boosts + score floor + MMR + filters
**Files:** Modify `SearchService.swift`; Test `ZihinTests/RankingTests.swift`.
**Interfaces — Produces:** parser adds `topic:`, `type:`, `in:space`; ranking = RRF(k=60) + recency decay + pin boost + topic boost + score floor; MMR diversification; vector side centered max-pool top-K (no absolute threshold).
- [ ] Weighted `bm25(item_fts, wTitle, …)`; RRF fuse FTS + centered-vector max-pool ranks; add boosts + floor; MMR to avoid 10 near-duplicates.
- [ ] Parser: `topic:ai`, `type:note`, `in:space`.
- [ ] Tests: title-weighted result ordering; MMR reduces near-duplicate run; `type:note` filters; vector side uses centered similarity (no `>0.15`).
- [ ] Commit: `feat(F4): weighted bm25 + boosts + MMR + filters`.

---

## Phase F5 — Optional sentence model (download, verify, load, switch)

*Gate (Mac): switching model triggers reindex; interrupted download does not crash.*

### Task F5.1: ModelDownloader + SentenceProvider from disk
**Files:** Create `Zihin/ML/ModelDownloader.swift`; Modify `EmbeddingProvider.swift` (`SentenceProvider` reads App Group), `EmbeddingService.swift` (existing `MultilingualEmbedder` → disk-backed).
**Interfaces — Produces:** `actor ModelDownloader { func download() async throws; var isInstalled: Bool }` (background URLSession + SHA-256 → App Group); `SentenceProvider(modelURL:)`.
- [ ] Background download with SHA-256 verify → App Group; partial/interrupted download leaves no half state.
- [ ] `SentenceProvider` loads `Embedder.mlmodelc` + `vocab.txt` from App Group (not bundle).
- [ ] Tests: SHA-256 mismatch rejects; installed flag false until verified.
- [ ] Commit: `feat(F5): optional model downloader + disk SentenceProvider`.

### Task F5.2: Switch provider + reindex + Settings/onboarding UI
**Files:** Modify `EmbeddingCoordinator` (switch active), `ExtrasViews.swift` (Settings toggle + reindex button + progress), `OnboardingView.swift` (offer ~80 MB model), `AppRoot.swift` (kick reindex on mismatch).
- [ ] Switching provider changes modelIdentifier/revision → coordinator marks all pending → EnrichmentQueue reindexes; μ refrozen.
- [ ] Settings: "Gelişmiş anlamsal model (~80 MB)" toggle, "Yeniden indeksle" button, progress via existing badge. Onboarding prompt with size warning.
- [ ] Commit: `feat(F5): model switch + reindex + settings/onboarding`.

---

## CloudKit (folded into F2/F3 tasks, verified last)
- [ ] `CloudKitSyncService`: sync `item_topic`, `graph_position`, `manual_edge`, `profile_node`, `topic`; never sync `embedding`/`item_chunk`. Keep LWW. Commit: `feat: CloudKit syncs concept layer, not vectors`.

---

## Per-phase verification (run on macOS 26 + Xcode)
```bash
brew install xcodegen && xcodegen generate
xcodebuild -scheme Zihin -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme Zihin -destination 'platform=iOS Simulator,name=iPhone 16' test
```
Each phase's gate (§5 of the spec) is asserted by that phase's XCTest file plus the golden-set/probe measurements where noted.

## Self-Review Notes
- Every spec §4 subsystem maps to a task: §4.1→F0.2–F0.7, §4.2→F0.1, §4.3→F2.1–F2.5, §4.4→F1.2, §4.5→F1.1/F1.3, §4.6→F3.1–F3.3, §4.7→F4.1–F4.2, §4.8→F0.1/F5.2, §4.9→CloudKit task.
- Risk mitigations (§6) covered: asset-not-downloaded → ContextualProvider requestAssets + FTS-only fallback (F0.2/F4); μ instability → μ₀ blend (F0.4/F0.6); μ drift → frozen μ daily (F0.4); 512-dim collision → model+revision stamping (F0.1/F0.5).
- Names are consistent across tasks (`EmbeddingCoordinator`, `CorpusMean`, `SpaceMembership.matches`, `Route`, `nodeKey`).
