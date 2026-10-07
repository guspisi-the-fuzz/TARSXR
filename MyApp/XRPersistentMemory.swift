import Foundation

/// Explicit, device-owned facts. Model replies are never written to this store.
struct XRMemoryFact: Codable, Equatable {
    let key: String
    let subject: String
    let statement: String
    let source: String
    let scope: String
    let createdAt: Double
    let updatedAt: Double
}

struct XRMemoryDocument: Codable {
    let schemaVersion: Int
    let ownerID: String
    var revision: String
    var facts: [XRMemoryFact]
    // Negative lookup markers contain keys only, never the deleted statement.
    var forgotten: [String]
}

enum XRMemoryError: Error, LocalizedError {
    case unavailable, invalid, full, missing, changed, unsupported, ambiguous
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Não consegui acessar a memória no XR. Não confirmei nenhuma gravação."
        case .invalid: return "A memória precisa de verificação. Não vou apagar nem substituir o arquivo existente."
        case .full: return "A memória local atingiu o limite de registros. Nenhuma lembrança foi descartada."
        case .missing: return "Essa lembrança não está salva. Use guarde para criar uma nova."
        case .changed: return "A memória mudou durante o pedido. Faça a pergunta novamente."
        case .unsupported: return "Use uma informação com sujeito explícito, por exemplo: guarde, a Mel é minha gata."
        case .ambiguous: return "Há mais de uma lembrança para essa referência. Diga o nome ou a relação completa; não vou escolher nem substituir uma delas."
        }
    }
}

@MainActor
final class XRPersistentMemory {
    static let maxFacts = 128
    static let maxDeleted = 256
    static let maxBytes = 262144
    private let url: URL
    private let writer: (Data, URL) throws -> Void
    private let now: () -> Double
    private let seed = XRMemoryDocument(schemaVersion: 1, ownerID: UUID().uuidString,
                                       revision: UUID().uuidString, facts: [], forgotten: [])

    init(url: URL, now: @escaping () -> Double = { Date().timeIntervalSince1970 },
         writer: ((Data, URL) throws -> Void)? = nil) {
        self.url = url; self.now = now
        self.writer = writer ?? Self.diskWrite
    }

    static func deviceStore() throws -> XRPersistentMemory {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask, appropriateFor: nil, create: true)
        return XRPersistentMemory(url: base.appendingPathComponent("TARSMemory", isDirectory: true)
                                    .appendingPathComponent("memory-v1.json"))
    }

    nonisolated static func key(_ text: String) -> String {
        var words = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if let first = words.first, ["a", "o", "as", "os", "the"].contains(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    nonisolated private static func validText(_ value: String, max: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= max &&
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    nonisolated static func validSubject(_ subject: String) -> Bool {
        let normalized = key(subject)
        guard validText(subject, max: 80), !normalized.isEmpty, normalized.utf8.count <= 80 else { return false }
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " .'-"))
        guard subject.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let ambiguous = ["ele", "ela", "eles", "elas", "isso", "isto", "aquilo", "voce", "eu", "it", "he", "she", "they", "you", "i"]
        let reserved = ["tars", "core", "esp32", "seguranca", "safety", "hora atual", "data atual", "current time", "current date"]
        let first = normalized.split(separator: " ").first.map(String.init) ?? ""
        return !ambiguous.contains(normalized) && !reserved.contains(normalized)
            && !["when", "how", "quando", "como", "senha", "password", "token"].contains(first)
    }

    private func checkPath() throws {
        var path = url
        // Protect this store from accidentally following links outside its directory.
        for _ in 0..<2 {
            if (try? FileManager.default.attributesOfItem(atPath: path.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                throw XRMemoryError.invalid
            }
            path.deleteLastPathComponent()
        }
    }

    private func readBytes() throws -> Data? {
        try checkPath()
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attrs[.size] as? NSNumber)?.intValue ?? (Self.maxBytes + 1) <= Self.maxBytes else {
                throw XRMemoryError.invalid
            }
            return try Data(contentsOf: url)
        } catch let e as NSError where e.domain == NSCocoaErrorDomain &&
            [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(e.code) {
            return nil
        } catch let e as XRMemoryError { throw e }
        catch { throw XRMemoryError.unavailable }
    }

    func load() throws -> XRMemoryDocument {
        guard let bytes = try readBytes() else { return seed }
        do {
            let document = try JSONDecoder().decode(XRMemoryDocument.self, from: bytes)
            guard document.schemaVersion == 1, UUID(uuidString: document.ownerID) != nil,
                  UUID(uuidString: document.revision) != nil, document.facts.count <= Self.maxFacts,
                  document.forgotten.count <= Self.maxDeleted,
                  Set(document.facts.map(\.key)).count == document.facts.count,
                  Set(document.forgotten).count == document.forgotten.count else { throw XRMemoryError.invalid }
            for fact in document.facts {
                guard Self.validSubject(fact.subject), fact.key == Self.key(fact.subject),
                      Self.validText(fact.statement, max: 480), fact.source == "explicit_user",
                      fact.scope == "local_owner", fact.createdAt.isFinite, fact.updatedAt.isFinite,
                      (0..<7258118400).contains(fact.createdAt), fact.updatedAt >= fact.createdAt,
                      fact.updatedAt < 7258118400, !document.forgotten.contains(fact.key)
                else { throw XRMemoryError.invalid }
            }
            for key in document.forgotten {
                guard Self.validText(key, max: 80), Self.key(key) == key else { throw XRMemoryError.invalid }
            }
            return document
        } catch let e as XRMemoryError { throw e }
        catch { throw XRMemoryError.invalid }
    }

    private func commit(_ next: XRMemoryDocument, expected: Data?) throws {
        try Task.checkCancellation()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= Self.maxBytes else { throw XRMemoryError.full }
        guard try readBytes() == expected else { throw XRMemoryError.changed }
        do { try writer(data, url) } catch { throw XRMemoryError.unavailable }
        guard try readBytes() == data else { throw XRMemoryError.unavailable }
    }

    func save(subject: String, statement: String, correction: Bool) throws -> XRMemoryFact {
        try Task.checkCancellation()
        guard Self.validSubject(subject), Self.validText(statement, max: 480) else { throw XRMemoryError.unsupported }
        let expected = try readBytes()
        var document = try load()
        let key = Self.key(subject)
        let matches = facts(for: subject, document: document)
        guard matches.count <= 1 else { throw XRMemoryError.ambiguous }
        let index = matches.first.flatMap { existing in document.facts.firstIndex { $0.key == existing.key } }
        if correction && index == nil { throw XRMemoryError.missing }
        // An explicit correction is required before replacing a different fact.
        if !correction, let index, document.facts[index].statement != statement { throw XRMemoryError.changed }
        if let index, document.facts[index].statement == statement { return document.facts[index] }
        guard index != nil || document.facts.count < Self.maxFacts else { throw XRMemoryError.full }
        let timestamp = now()
        guard timestamp.isFinite, (0..<7258118400).contains(timestamp) else { throw XRMemoryError.unavailable }
        let previous = index.map { document.facts[$0] }
        let fact = XRMemoryFact(key: key, subject: subject, statement: statement, source: "explicit_user",
            scope: "local_owner", createdAt: previous?.createdAt ?? timestamp,
            updatedAt: max(timestamp, previous?.updatedAt ?? timestamp))
        if let index { document.facts[index] = fact } else { document.facts.append(fact) }
        let newKeys = XRMemoryIntent.referenceKeys(subject: fact.subject, statement: fact.statement)
        document.forgotten.removeAll { newKeys.contains($0) }
        if let previous {
            // Explicit alias-based correction may change the primary subject. Do not
            // leave the old name as a live alias or revive it from remote history.
            let remainingKeys = Set(document.facts.flatMap {
                XRMemoryIntent.referenceKeys(subject: $0.subject, statement: $0.statement)
            })
            let stale = XRMemoryIntent.identityKeys(subject: previous.subject, statement: previous.statement)
                .subtracting(remainingKeys).subtracting(document.forgotten)
            guard document.forgotten.count + stale.count <= Self.maxDeleted else { throw XRMemoryError.full }
            document.forgotten.append(contentsOf: stale.sorted())
        }
        document.revision = UUID().uuidString
        try commit(document, expected: expected)
        return fact
    }


    /// Rename one explicitly identified person while preserving the saved relationship.
    /// The operation is atomic and never chooses among multiple matches.
    func renameIdentity(old: String, new: String) throws -> XRMemoryFact {
        try Task.checkCancellation()
        guard Self.validSubject(old), Self.validSubject(new) else { throw XRMemoryError.unsupported }
        let expected = try readBytes()
        var document = try load()
        let oldKey = Self.key(old), newKey = Self.key(new)
        let affected = document.facts.enumerated().filter { _, fact in
            if fact.key == oldKey { return true }
            if let split = XRMemoryIntent.splitAttributeSubject(fact.subject) {
                return Self.key(split.entity) == oldKey
            }
            return XRMemoryIntent.referenceKeys(subject: fact.subject, statement: fact.statement).contains(oldKey)
        }
        guard !affected.isEmpty else { throw XRMemoryError.missing }
        // Reject collisions before changing any fact.
        let affectedIndexes = Set(affected.map(\.offset))
        for (index, fact) in document.facts.enumerated() where !affectedIndexes.contains(index) {
            let aliases = XRMemoryIntent.referenceKeys(subject: fact.subject, statement: fact.statement)
            if aliases.contains(newKey) || fact.key == newKey { throw XRMemoryError.changed }
        }
        let timestamp = now()
        guard timestamp.isFinite, (0..<7258118400).contains(timestamp) else { throw XRMemoryError.unavailable }
        var primary: XRMemoryFact?
        for (index, previous) in affected {
            let newSubject: String
            if let split = XRMemoryIntent.splitAttributeSubject(previous.subject) {
                newSubject = XRMemoryIntent.attributeSubject(entity: new, attribute: split.attribute)
            } else if previous.key == oldKey || Self.key(previous.subject) == oldKey {
                newSubject = new
            } else {
                newSubject = previous.subject
            }
            let statement = previous.statement.replacingOccurrences(of: old, with: new)
            let replacement = XRMemoryFact(key: Self.key(newSubject), subject: newSubject, statement: statement,
                source: previous.source, scope: previous.scope, createdAt: previous.createdAt,
                updatedAt: max(timestamp, previous.updatedAt))
            document.facts[index] = replacement
            if primary == nil || replacement.key == newKey { primary = replacement }
        }
        guard Set(document.facts.map(\.key)).count == document.facts.count else { throw XRMemoryError.changed }
        let liveAliases = Set(document.facts.flatMap { XRMemoryIntent.referenceKeys(subject: $0.subject, statement: $0.statement) })
        let stale = Set([oldKey]).subtracting(liveAliases).subtracting(document.forgotten)
        guard document.forgotten.count + stale.count <= Self.maxDeleted else { throw XRMemoryError.full }
        document.forgotten.append(contentsOf: stale.sorted())
        document.forgotten.removeAll { liveAliases.contains($0) }
        document.revision = UUID().uuidString
        try commit(document, expected: expected)
        return primary ?? document.facts[affected[0].offset]
    }

    /// Save several attributes atomically enough for this single-process store. Existing
    /// attributes are updated only when correction is explicitly requested.
    func saveAttributes(_ values: [(subject: String, statement: String)], correction: Bool) throws -> [XRMemoryFact] {
        guard !values.isEmpty, values.count <= 8 else { throw XRMemoryError.unsupported }
        let before = try readBytes()
        var saved: [XRMemoryFact] = []
        do {
            for value in values {
                let doc = try load()
                let exists = !facts(for: value.subject, document: doc).isEmpty
                saved.append(try save(subject: value.subject, statement: value.statement,
                                      correction: correction || exists))
            }
            return saved
        } catch {
            let current = try? readBytes()
            if current != before {
                if let before { try writer(before, url) }
                else { try? FileManager.default.removeItem(at: url) }
            }
            throw error
        }
    }

    func entityName(for reference: String, document: XRMemoryDocument) -> String? {
        if XRMemoryIntent.canonicalRelationQuery(reference) != nil {
            let matches = facts(for: reference, document: document)
            let names = matches.compactMap { XRMemoryIntent.displayName(subject: $0.subject, statement: $0.statement) }
            return names.count == 1 ? names[0] : nil
        }
        return reference
    }

    func attributeFact(entity: String, attribute: XRMemoryIntent.Attribute,
                       document: XRMemoryDocument) -> XRMemoryFact? {
        let subject = XRMemoryIntent.attributeSubject(entity: entity, attribute: attribute)
        return document.facts.first { $0.key == Self.key(subject) }
    }

    /// Store multiple explicit facts from one user command. Validation happens first;
    /// rollback restores the exact previous bytes if any later write fails.
    func saveMany(_ values: [(subject: String, statement: String)]) throws -> [XRMemoryFact] {
        guard !values.isEmpty, values.count <= 8 else { throw XRMemoryError.unsupported }
        let before = try readBytes()
        var saved: [XRMemoryFact] = []
        do {
            for value in values { saved.append(try save(subject: value.subject, statement: value.statement, correction: false)) }
            return saved
        } catch {
            // Sequential save uses the same verified writer. Restore only our own writes.
            let current = try? readBytes()
            if current != before {
                if let before {
                    do { try writer(before, url) } catch { throw XRMemoryError.unavailable }
                } else {
                    do { try FileManager.default.removeItem(at: url) }
                    catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileNoSuchFileError { }
                    catch { throw XRMemoryError.unavailable }
                }
            }
            throw error
        }
    }

    @discardableResult
    func forget(subject: String) throws -> Bool {
        guard Self.validSubject(subject) else { throw XRMemoryError.unsupported }
        let expected = try readBytes()
        var document = try load()
        let key = XRMemoryIntent.referenceKey(subject)
        let matches = facts(for: subject, document: document)
        guard matches.count <= 1 else { throw XRMemoryError.ambiguous }
        if matches.isEmpty && document.forgotten.contains(key) { return false }
        let removedKeys = Set(matches.map(\.key))
        document.facts.removeAll { removedKeys.contains($0.key) }
        let liveAliases = Set(document.facts.flatMap {
            XRMemoryIntent.referenceKeys(subject: $0.subject, statement: $0.statement)
        })
        var markers: Set<String> = [key]
        for fact in matches {
            markers.formUnion(XRMemoryIntent.identityKeys(subject: fact.subject, statement: fact.statement))
        }
        markers.subtract(liveAliases); markers.subtract(document.forgotten)
        guard document.forgotten.count + markers.count <= Self.maxDeleted else { throw XRMemoryError.full }
        document.forgotten.append(contentsOf: markers.sorted())
        document.revision = UUID().uuidString
        try commit(document, expected: expected)
        return !matches.isEmpty
    }

    /// Read-only compatibility with existing schema-v1 names and subjects.
    func facts(for subject: String, document: XRMemoryDocument) -> [XRMemoryFact] {
        let key = XRMemoryIntent.canonicalRelationQuery(subject) ?? XRMemoryIntent.referenceKey(subject)
        guard !document.forgotten.contains(key) else { return [] }
        return document.facts.filter {
            XRMemoryIntent.referenceKeys(subject: $0.subject, statement: $0.statement).contains(key)
        }
    }

    func context(for text: String, document: XRMemoryDocument, followUpKeys: [String] = []) -> [String: Any] {
        let query = " " + Self.key(text) + " "
        let selected = document.facts.filter { fact in
            let aliases = XRMemoryIntent.referenceKeys(subject: fact.subject, statement: fact.statement)
                .subtracting(document.forgotten)
            return aliases.contains { query.contains(" " + $0 + " ") } || followUpKeys.contains(fact.key)
        }.prefix(4)
        return ["schema_version": 1, "source": "xr_explicit_memory", "owner_id": document.ownerID,
                "revision": document.revision, "facts": selected.map { fact in
            ["key": fact.key, "subject": fact.subject, "statement": fact.statement,
             "source": fact.source, "scope": fact.scope, "updated_at": fact.updatedAt] as [String: Any]
        }]
    }

    #if DEBUG
    /// File-node metadata only. Never creates a store, reads facts or changes permissions.
    func diagnosticMetadata() -> [String: Any] {
        func node(_ candidate: URL) -> String {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeRegular: return "file"
                case .typeDirectory: return "directory"
                case .typeSymbolicLink: return "symlink"
                default: return "other"
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
                return "missing"
            } catch { return "unavailable" }
        }
        return ["file_node": node(url), "parent_node": node(url.deletingLastPathComponent()),
                "path_matches_device_contract": url.path.hasSuffix("/Library/Application Support/TARSMemory/memory-v1.json")]
    }
    #endif

    nonisolated private static func diskWrite(_ data: Data, _ url: URL) throws {
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
