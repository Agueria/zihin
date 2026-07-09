import Foundation

// MARK: - FoundationModels (F2: iOS 26+ rafine katmanı, §4.3 #3)

/// FoundationModels (iOS 26+) ile konu rafine etme.
/// §4.3 #3: LLM yalnız rafine eder, hiçbir şeyi tek başına belirlemez.
/// Fallback: lexicon + embedding zaten yeterli.
enum FoundationModels {
    /// Mevcut sınıflandırmayı LLM ile rafine et — yeni konu önerisi dahil.
    /// iOS 26 ve SystemLanguageModel.available == .available ise çalışır.
    static func refine(
        text: String,
        currentTopics: [TopicClassification],
        availableTopics: [Topic]
    ) async -> [TopicClassification] {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            guard let model = SystemLanguageModel.default,
                  model.availability == .available else {
                return currentTopics
            }
            do {
                let schema: TopicSchema = .init(topics: availableTopics.map { .init(id: $0.id, name: $0.name) })
                let prompt = """
                Bu metni incele ve aşağıdaki konulardan hangilerine uygun olduğunu belirt.
                Yeni bir konu önermek de isteyebilirsin.

                Mevcut sınıflandırmalar:
                \(currentTopics.map { "  - \($0.name) (\($0.score:.2f))" }.joined(separator: "\n"))

                Mevcut konu havuzu:
                \(schema.topics.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))

                Yanıtını JSON olarak ver:
                {
                  "confirmed": ["topic-id", ...],
                  "rejected": ["topic-id", ...],
                  "newTopic": {
                    "name": "yeni konu adı",
                    "reason": "neden bu konu",
                    "id": "tech-ai-xxx"
                  }
                }
                """

                let result = try await model.generate(
                    TopicClassificationResponse.self,
                    from: prompt
                )
                return applyRefinement(result, currentTopics: currentTopics, availableTopics: availableTopics)
            } catch {
                print("[FoundationModels] Refine failed: \(error)")
                return currentTopics
            }
        }
        #endif
        return currentTopics
    }

    /// Metinden yeni konu önerisi (yalnız LLM ile).
    static func suggestNewTopic(text: String) async -> (name: String, reason: String)? {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            guard let model = SystemLanguageModel.default,
                  model.availability == .available else {
                return nil
            }
            do {
                let prompt = """
                Bu metinden yeni bir konu öner. Kısa ve açıklayıcı bir isim ve nedenini ver.

                Metin:
                \(text.prefix(2000))

                Yanıtını JSON olarak ver:
                {
                  "name": "Konu Adı",
                  "reason": "Neden bu konu"
                }
                """
                let result = try await model.generate(NewTopicResponse.self, from: prompt)
                return (name: result.name, reason: result.reason)
            } catch {
                print("[FoundationModels] Suggest failed: \(error)")
                return nil
            }
        }
        #endif
        return nil
    }

    private struct TopicSchema: Codable {
        var topics: [TopicEntry]
        struct TopicEntry: Codable {
            var id: String
            var name: String
        }
    }

    private struct TopicClassificationResponse: Codable {
        var confirmed: [String]
        var rejected: [String]
        var newTopic: NewTopicResponse?
        struct NewTopicResponse: Codable {
            var name: String
            var reason: String
            var id: String
        }
    }

    private struct NewTopicResponse: Codable {
        var name: String
        var reason: String
    }

    private func applyRefinement(
        _ response: TopicClassificationResponse,
        currentTopics: [TopicClassification],
        availableTopics: [Topic]
    ) -> [TopicClassification] {
        var filtered: [TopicClassification] = []
        for ct in currentTopics {
            if response.confirmed.contains(ct.topicId) {
                filtered.append(ct)
            } else if response.rejected.contains(ct.topicId) {
                continue
            } else {
                filtered.append(ct)
            }
        }
        if let newTopic = response.newTopic, !newTopic.name.isEmpty {
            let topic = availableTopics.first { $0.id == newTopic.id }
            let newClass = TopicClassification(
                topicId: newTopic.id,
                name: newTopic.name,
                score: 0.7,
                margin: 0.2,
                source: "llm"
            )
            filtered.append(newClass)
        }
        return filtered
    }
}

// MARK: - Extractive özet (TextRank)