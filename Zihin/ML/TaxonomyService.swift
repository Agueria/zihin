import Foundation

// F2: Taksonomi yükleme + topic sınıflandırma pipeline'ı (§4.3)
// core_topics.json → topic tablosu; prototip ifadelerinden vektör üretimi.

// MARK: - JSON şeması

struct TaxonomyFile: Codable {
    let version: String
    let description: String
    let topics: [TaxonomyNode]
}

struct TaxonomyNode: Codable {
    let id: String
    let name: String
    let parentId: String?
    let phrases: [String]?
    let children: [TaxonomyNode]?
}

// MARK: - TaxonomyService

enum TaxonomyService {
    /// core_topics.json'u yükle, düz listeye çevir.
    static func loadCoreTopics() -> [TaxonomyNode] {
        guard let url = Bundle.main.url(forResource: "core_topics", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(TaxonomyFile.self, from: data) else {
            return []
        }
        var flat: [TaxonomyNode] = []
        func walk(_ nodes: [TaxonomyNode]) {
            for node in nodes {
                flat.append(node)
                if let children = node.children { walk(children) }
            }
        }
        walk(file.topics)
        return flat
    }

    /// Taksonomiyi veritabanına yükle (idempotent — yalnız eksik olanları ekler).
    /// İlk açılışta veya reindex'te çağrılır.
    static func seedTopicsIfNeeded() {
        let repo = ItemRepository()
        let existing = (try? repo.topics()) ?? []
        let existingIds = Set(existing.map(\.id))

        let coreNodes = loadCoreTopics()
        guard !coreNodes.isEmpty else { return }

        for node in coreNodes {
            guard !existingIds.contains(node.id) else { continue }
            let topic = Topic(id: node.id, name: node.name,
                              parentId: node.parentId, isCore: true,
                              createdAt: Date())
            try? repo.saveTopic(topic)
            if let phrases = node.phrases, !phrases.isEmpty {
                try? repo.saveTopicPhrases(topicId: node.id, phrases: phrases)
            }
        }
    }

    /// Bir topic için prototip vektörleri üret (prototip ifadelerinin embedding'i).
    /// §4.3 #2: prototip merkezi karşılaştırmada kullanılır.
    static func prototypeVectors(for topicId: String) -> [[Float]] {
        let repo = ItemRepository()
        let phrases = (try? repo.db.read { d in
            try String.fetchAll(d, sql: """
                SELECT phrase FROM topic_phrase WHERE topicId = ?
                """, arguments: [topicId])
        }) ?? []

        var vectors: [[Float]] = []
        for phrase in phrases {
            // Her ifade için embedding — chunk'ın ilk vektörünü al
            if let vecs = EmbeddingService.embed(phrase), let first = vecs.first {
                vectors.append(first)
            }
        }
        return vectors
    }

    /// Sınıflandırma için tüm topic'leri prototip vektörleriyle birlikte döndür (cache'lenebilir).
    static func topicsWithPrototypes() -> [(id: String, name: String, prototypes: [[Float]])] {
        let repo = ItemRepository()
        let topics = (try? repo.topics()) ?? []
        var result: [(id: String, name: String, prototypes: [[Float]])] = []
        for topic in topics {
            let protos = prototypeVectors(for: topic.id)
            guard !protos.isEmpty else { continue }
            result.append((topic.id, topic.name, protos))
        }
        return result
    }
}
