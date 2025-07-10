// ========== BLOCK 1: MEMORY MODELS AND DATABASE SETUP - START ==========
import SwiftUI
import Foundation
import Combine
import Observation
import FoundationModels
import UniformTypeIdentifiers
import SQLite3
import NaturalLanguage
import PDFKit

// MARK: - Cross-Session SQLite Memory Models
struct StoredConversation {
    let id: String
    let title: String
    let startedAt: Date
    let lastActive: Date
    let turnCount: Int
    let systemPrompt: String
    let summary: String
}

struct StoredMessage {
    let id: String
    let conversationId: String
    let content: String
    let isFromUser: Bool
    let timestamp: Date
    let turnNumber: Int
    let embedding: [Double]
}

struct HistoricalContext {
    let conversationCount: Int
    let relevantConversations: Int
    let contextSnippets: [String]
    let relevanceScores: [Double]
    let totalTokens: Int
}

// MARK: - Type Definitions for Unified Memory System
enum ContentSourceType: String, CaseIterable, Codable {
    case conversation = "conversation"
    case document = "document"
    case webpage = "webpage"
    case email = "email"
    
    var displayName: String {
        switch self {
        case .conversation: return "Conversation"
        case .document: return "Document"
        case .webpage: return "Web Page"
        case .email: return "Email"
        }
    }
    
    var icon: String {
        switch self {
        case .conversation: return "💬"
        case .document: return "📄"
        case .webpage: return "🌐"
        case .email: return "📧"
        }
    }
}

struct NamedEntity: Codable, Hashable {
    let text: String
    let type: EntityType
    let range: NSRange
    let confidence: Double
    
    enum EntityType: String, Codable, CaseIterable {
        case person = "person"
        case place = "place"
        case organization = "org"
        case other = "other"
        
        var displayName: String {
            switch self {
            case .person: return "Person"
            case .place: return "Place"
            case .organization: return "Organization"
            case .other: return "Other"
            }
        }
        
        var icon: String {
        switch self {
            case .person: return "👤"
            case .place: return "📍"
            case .organization: return "🏢"
            case .other: return "🏷️"
            }
        }
    }
    
    init(text: String, type: EntityType, range: NSRange, confidence: Double = 1.0) {
        self.text = text
        self.type = type
        self.range = range
        self.confidence = confidence
    }
    
    // Coding keys for proper JSON serialization
    enum CodingKeys: String, CodingKey {
        case text, type, range, confidence
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        type = try container.decode(EntityType.self, forKey: .type)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0
        
        // Handle NSRange decoding
        if let rangeData = try container.decodeIfPresent(Data.self, forKey: .range) {
            range = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSValue.self, from: rangeData)?.rangeValue ?? NSRange(location: 0, length: 0)
        } else {
            range = NSRange(location: 0, length: text.count)
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(type, forKey: .type)
        try container.encode(confidence, forKey: .confidence)
        
        // Handle NSRange encoding
        let rangeValue = NSValue(range: range)
        let rangeData = try NSKeyedArchiver.archivedData(withRootObject: rangeValue, requiringSecureCoding: false)
        try container.encode(rangeData, forKey: .range)
    }
}

// MARK: - Memory Store with Persistent Database Connection
class MemoryStore: ObservableObject {
    static let shared = MemoryStore()
    
    @Published var isEnabled: Bool = true
    @Published var currentHistoricalContext: HistoricalContext = HistoricalContext(
        conversationCount: 0,
        relevantConversations: 0,
        contextSnippets: [],
        relevanceScores: [],
        totalTokens: 0
    )
    @Published var totalConversations: Int = 0
    @Published var totalTurns: Int = 0
    @Published var totalDocuments: Int = 0
    @Published var totalDocumentChunks: Int = 0
    @Published var searchDebugResults: String = ""
    
    // Persistent database connection - no more open/close every operation
    private var db: OpaquePointer?
    private var isConnected: Bool = false
    private let relevanceThreshold: Double = 0.3
    
    private init() {
        print("HALDEBUG-DATABASE: MemoryStore initializing with persistent connection...")
        setupPersistentDatabase()
    }
    
    deinit {
        closeDatabaseConnection()
    }
    
    // Database path - single source of truth
    private var dbPath: String {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbURL = documentsPath.appendingPathComponent("hal_conversations.sqlite")
        return dbURL.path
    }
    
    // Get all database file paths (main + WAL + SHM)
    private var allDatabaseFilePaths: [String] {
        let basePath = dbPath
        return [
            basePath,                           // main database
            basePath + "-wal",                  // Write-Ahead Log
            basePath + "-shm"                   // Shared Memory
        ]
    }
    
    // MARK: - Nuclear Reset Capability (MemoryStore owns its lifecycle)
    func performNuclearReset() -> Bool {
        print("HALDEBUG-DATABASE: 🚨 MemoryStore performing nuclear reset...")
        
        // Step 1: Clear published properties immediately
        DispatchQueue.main.async {
            self.totalConversations = 0
            self.totalTurns = 0
            self.totalDocuments = 0
            self.totalDocumentChunks = 0
            self.searchDebugResults = ""
        }
        print("HALDEBUG-DATABASE: ✅ Cleared published properties")
        
        // Step 2: Close database connection cleanly
        if db != nil {
            print("HALDEBUG-DATABASE: 🔌 Closing database connection...")
            sqlite3_close(db)
            db = nil
            isConnected = false
            print("HALDEBUG-DATABASE: ✅ Database connection closed cleanly")
        }
        
        // Step 3: Delete all database files safely (connection is now closed)
        print("HALDEBUG-DATABASE: 🗑️ Deleting database files...")
        var deletedCount = 0
        var failedCount = 0
        
        for filePath in allDatabaseFilePaths {
            let fileURL = URL(fileURLWithPath: filePath)
            do {
                if FileManager.default.fileExists(atPath: filePath) {
                    try FileManager.default.removeItem(at: fileURL)
                    deletedCount += 1
                    print("HALDEBUG-DATABASE: 🗑️ Deleted \(fileURL.lastPathComponent)")
                } else {
                    print("HALDEBUG-DATABASE: ℹ️ File didn't exist: \(fileURL.lastPathComponent)")
                }
            } catch {
                failedCount += 1
                print("HALDEBUG-DATABASE: ❌ Failed to delete \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        
        // Step 4: Recreate fresh database connection immediately
        print("HALDEBUG-DATABASE: 🔄 Recreating fresh database connection...")
        setupPersistentDatabase()
        
        // Step 5: Verify success
        let success = isConnected && failedCount == 0
        if success {
            print("HALDEBUG-DATABASE: ✅ Nuclear reset completed successfully")
            print("HALDEBUG-DATABASE:   Files deleted: \(deletedCount)")
            print("HALDEBUG-DATABASE:   Files failed: \(failedCount)")
            print("HALDEBUG-DATABASE:   Connection healthy: \(isConnected)")
        } else {
            print("HALDEBUG-DATABASE: ❌ Nuclear reset encountered issues")
            print("HALDEBUG-DATABASE:   Files deleted: \(deletedCount)")
            print("HALDEBUG-DATABASE:   Files failed: \(failedCount)")
            print("HALDEBUG-DATABASE:   Connection healthy: \(isConnected)")
        }
        
        return success
    }
    
    // Setup persistent database connection that stays open
    private func setupPersistentDatabase() {
        print("HALDEBUG-DATABASE: Setting up persistent database connection...")
        
        // Close any existing connection first
        if db != nil {
            sqlite3_close(db)
            db = nil
            isConnected = false
        }
        
        let result = sqlite3_open(dbPath, &db)
        guard result == SQLITE_OK else {
            print("HALDEBUG-DATABASE: CRITICAL ERROR - Failed to open database at \(dbPath), SQLite error: \(result)")
            isConnected = false
            return
        }
        
        isConnected = true
        print("HALDEBUG-DATABASE: ✅ Persistent database connection established at \(dbPath)")
        
        // ENCRYPTION: Enable Apple file protection immediately after database creation
        enableDataProtection()
        
        // Enable WAL mode for better performance and concurrency
        if sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK {
            print("HALDEBUG-DATABASE: ✅ Enabled WAL mode for persistent connection")
        } else {
            print("HALDEBUG-DATABASE: ⚠️ Failed to enable WAL mode")
        }
        
        // Enable foreign keys for data integrity
        if sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil) == SQLITE_OK {
            print("HALDEBUG-DATABASE: ✅ Enabled foreign key constraints for data integrity")
        }
        
        // Create all tables using the persistent connection
        createUnifiedSchema()
        loadUnifiedStats()
        
        print("HALDEBUG-DATABASE: ✅ Persistent database setup complete")
    }
    
    // Check if database connection is healthy, reconnect if needed
    private func ensureHealthyConnection() -> Bool {
        // Quick health check - try a simple query
        if isConnected && db != nil {
            var stmt: OpaquePointer?
            let testSQL = "SELECT 1;"
            
            if sqlite3_prepare_v2(db, testSQL, -1, &stmt, nil) == SQLITE_OK {
                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                
                if result == SQLITE_ROW {
                    // Connection is healthy
                    return true
                }
            }
        }
        
        // Connection is dead, attempt reconnection
        print("HALDEBUG-DATABASE: ⚠️ Database connection unhealthy, attempting reconnection...")
        setupPersistentDatabase()
        return isConnected
    }
    
    // Create proper unified schema with working constraints
    private func createUnifiedSchema() {
        guard ensureHealthyConnection() else {
            print("HALDEBUG-DATABASE: ❌ Cannot create schema - no database connection")
            return
        }
        
        print("HALDEBUG-DATABASE: Creating unified database schema...")
        
        // Create sources table first (no dependencies)
        let sourcesSQL = """
        CREATE TABLE IF NOT EXISTS sources (
            id TEXT PRIMARY KEY,
            source_type TEXT NOT NULL,
            display_name TEXT NOT NULL,
            file_path TEXT,
            url TEXT,
            created_at INTEGER NOT NULL,
            last_updated INTEGER NOT NULL,
            total_chunks INTEGER DEFAULT 0,
            total_entities INTEGER DEFAULT 0,
            metadata_json TEXT,
            content_hash TEXT,
            file_size INTEGER DEFAULT 0
        );
        """
        
        // Unified content table with proper structure
        let unifiedContentSQL = """
        CREATE TABLE IF NOT EXISTS unified_content (
            id TEXT PRIMARY KEY,
            content TEXT NOT NULL,
            embedding BLOB,
            timestamp INTEGER NOT NULL,
            source_type TEXT NOT NULL,
            source_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            is_from_user INTEGER,
            entity_count INTEGER DEFAULT 0,
            content_hash TEXT,
            metadata_json TEXT,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            UNIQUE(source_type, source_id, position)
        );
        """
        
        // Entities table with proper structure
        let unifiedEntitiesSQL = """
        CREATE TABLE IF NOT EXISTS unified_entities (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_text TEXT NOT NULL,
            entity_type TEXT NOT NULL,
            content_id TEXT NOT NULL,
            source_type TEXT NOT NULL,
            source_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            entity_range_start INTEGER,
            entity_range_length INTEGER,
            confidence REAL DEFAULT 1.0,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            UNIQUE(entity_text, content_id, entity_type),
            FOREIGN KEY (content_id) REFERENCES unified_content(id) ON DELETE CASCADE
        );
        """
        
        // Execute schema creation with proper error handling
        let tables = [
            ("sources", sourcesSQL),
            ("unified_content", unifiedContentSQL),
            ("unified_entities", unifiedEntitiesSQL)
        ]
        
        for (tableName, sql) in tables {
            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
                print("HALDEBUG-DATABASE: ✅ Created \(tableName) table")
            } else {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                print("HALDEBUG-DATABASE: ❌ Failed to create \(tableName) table: \(errorMessage)")
            }
        }
        
        // Create performance indexes
        let unifiedIndexes = [
            "CREATE INDEX IF NOT EXISTS idx_unified_content_source ON unified_content(source_type, source_id);",
            "CREATE INDEX IF NOT EXISTS idx_unified_content_timestamp ON unified_content(timestamp);",
            "CREATE INDEX IF NOT EXISTS idx_unified_content_from_user ON unified_content(is_from_user);",
            "CREATE INDEX IF NOT EXISTS idx_unified_entities_text ON unified_entities(entity_text);",
            "CREATE INDEX IF NOT EXISTS idx_unified_entities_type ON unified_entities(entity_type);",
            "CREATE INDEX IF NOT EXISTS idx_unified_entities_content ON unified_entities(content_id);",
            "CREATE INDEX IF NOT EXISTS idx_sources_type ON sources(source_type);"
        ]
        
        for indexSQL in unifiedIndexes {
            if sqlite3_exec(db, indexSQL, nil, nil, nil) == SQLITE_OK {
                print("HALDEBUG-DATABASE: ✅ Created index")
            } else {
                print("HALDEBUG-DATABASE: ⚠️ Failed to create index: \(indexSQL)")
            }
        }
        
        print("HALDEBUG-DATABASE: ✅ Unified schema creation complete")
    }
    
    // ENCRYPTION: Enable Apple Data Protection on database file
    private func enableDataProtection() {
        let dbURL = URL(fileURLWithPath: dbPath)
        
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        do {
            try (dbURL.path as NSString).setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dbURL.path)
            print("HALDEBUG-DATABASE: ✅ Database encryption enabled with Apple file protection")
        } catch {
            print("HALDEBUG-DATABASE: ⚠️ Database encryption setup failed: \(error)")
        }
        #else
        print("HALDEBUG-DATABASE: 🔐 Database protected by macOS FileVault")
        #endif
    }
    
    // Corrected statistics queries with proper error handling
    private func loadUnifiedStats() {
        guard ensureHealthyConnection() else {
            print("HALDEBUG-DATABASE: ❌ Cannot load stats - no database connection")
            return
        }
        
        print("HALDEBUG-DATABASE: Loading unified statistics...")
        
        var stmt: OpaquePointer?
        var tempTotalConversations = 0
        var tempTotalTurns = 0
        var tempTotalDocuments = 0
        var tempTotalDocumentChunks = 0
        
        // Count conversations properly
        let conversationCountSQL = "SELECT COUNT(DISTINCT source_id) FROM unified_content WHERE source_type = 'conversation'"
        if sqlite3_prepare_v2(db, conversationCountSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                tempTotalConversations = Int(sqlite3_column_int(stmt, 0))
                print("HALDEBUG-DATABASE: Found \(tempTotalConversations) conversations")
            }
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("HALDEBUG-DATABASE: ❌ Failed to count conversations: \(errorMessage)")
        }
        sqlite3_finalize(stmt)
        
        // Count user turns properly (user messages only)
        let userTurnsSQL = "SELECT COUNT(*) FROM unified_content WHERE source_type = 'conversation' AND is_from_user = 1"
        if sqlite3_prepare_v2(db, userTurnsSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                tempTotalTurns = Int(sqlite3_column_int(stmt, 0))
                print("HALDEBUG-DATABASE: Found \(tempTotalTurns) user turns")
            }
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("HALDEBUG-DATABASE: ❌ Failed to count user turns: \(errorMessage)")
        }
        sqlite3_finalize(stmt)
        
        // Count documents in sources
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sources WHERE source_type = 'document'", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                tempTotalDocuments = Int(sqlite3_column_int(stmt, 0))
                print("HALDEBUG-DATABASE: Found \(tempTotalDocuments) documents")
            }
        }
        sqlite3_finalize(stmt)
        
        // Count document chunks in unified_content
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM unified_content WHERE source_type = 'document'", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                tempTotalDocumentChunks = Int(sqlite3_column_int(stmt, 0))
                print("HALDEBUG-DATABASE: Found \(tempTotalDocumentChunks) document chunks")
            }
        }
        sqlite3_finalize(stmt)
        
        // Update @Published properties on main thread
        DispatchQueue.main.async {
            self.totalConversations = tempTotalConversations
            self.totalTurns = tempTotalTurns
            self.totalDocuments = tempTotalDocuments
            self.totalDocumentChunks = tempTotalDocumentChunks
        }
        
        print("HALDEBUG-MEMORY: ✅ Loaded unified stats - \(tempTotalConversations) conversations, \(tempTotalTurns) turns, \(tempTotalDocuments) documents, \(tempTotalDocumentChunks) chunks")
    }
    
    // Close database connection properly
    private func closeDatabaseConnection() {
        if db != nil {
            print("HALDEBUG-DATABASE: Closing persistent database connection...")
            sqlite3_close(db)
            db = nil
            isConnected = false
            print("HALDEBUG-DATABASE: ✅ Database connection closed")
        }
    }
    
    // DEBUGGING: Get database connection status
    func getDatabaseStatus() -> (connected: Bool, path: String, tables: [String]) {
        var tables: [String] = []
        
        if ensureHealthyConnection() {
            var stmt: OpaquePointer?
            let sql = "SELECT name FROM sqlite_master WHERE type='table';"
            
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let namePtr = sqlite3_column_text(stmt, 0) {
                        let tableName = String(cString: namePtr)
                        tables.append(tableName)
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        
        return (connected: isConnected, path: dbPath, tables: tables)
    }
}
// ========== BLOCK 1: MEMORY MODELS AND DATABASE SETUP - END ==========


// ========== BLOCK 2: SIMPLIFIED EMBEDDING SYSTEM (MENTAT-PROVEN APPROACH) - START ==========

// MARK: - Simplified 2-Tier Embedding System (Based on MENTAT's Proven Approach)
extension MemoryStore {
    
    // SIMPLIFIED: Generate embeddings using only sentence embeddings + hash fallback
    // Removed: Word embeddings (Tier 2) and Entity enhancement (Tier 4) - commented out for potential restoration
    private func generateEmbedding(for text: String) -> [Double] {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return [] }
        
        print("HALDEBUG-MEMORY: Generating simplified embedding for text length \(cleanText.count)")
        
        // TIER 1: Apple Sentence Embeddings (Primary - proven reliable on modern systems)
        if let embedding = NLEmbedding.sentenceEmbedding(for: .english) {
            if let vector = embedding.vector(for: cleanText) {
                let baseVector = (0..<vector.count).map { Double(vector[$0]) }
                
                // SIMPLIFIED: No entity enhancement - keep clean vector space
                // let enhancedVector = applyEntityEnhancement(baseVector, entities: entities)
                
                print("HALDEBUG-MEMORY: Generated sentence embedding with \(baseVector.count) dimensions (no entity enhancement)")
                return baseVector
            }
        }
        
        // COMMENTED OUT: Tier 2 - Apple Word Embeddings (Fallback)
        // Reason: Mixing different vector spaces can cause compatibility issues
        // Can be restored if sentence embeddings prove insufficient
        /*
        if let embedding = NLEmbedding.wordEmbedding(for: .english) {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = cleanText
            
            var wordVectors: [[Double]] = []
            tokenizer.enumerateTokens(in: cleanText.startIndex..<cleanText.endIndex) { range, _ in
                let word = String(cleanText[range]).lowercased()
                if let vector = embedding.vector(for: word) {
                    let doubleVector = (0..<vector.count).map { Double(vector[$0]) }
                    wordVectors.append(doubleVector)
                }
                return true
            }
            
            if !wordVectors.isEmpty {
                let dimensions = wordVectors[0].count
                var avgVector = Array(repeating: 0.0, count: dimensions)
                
                for vector in wordVectors {
                    for (i, value) in vector.enumerated() {
                        avgVector[i] += value
                    }
                }
                
                for i in 0..<avgVector.count {
                    avgVector[i] /= Double(wordVectors.count)
                }
                
                let enhancedVector = applyEntityEnhancement(avgVector, entities: entities)
                print("HALDEBUG-MEMORY: Generated word embedding average from \(wordVectors.count) words, \(dimensions) dimensions + entity enhancement")
                return enhancedVector
            }
        }
        */
        
        // TIER 3: Hash-Based Mathematical Embeddings (Crash prevention fallback only)
        print("HALDEBUG-MEMORY: Falling back to hash-based embedding for text length \(cleanText.count)")
        let hashVector = generateHashEmbedding(for: cleanText)
        
        // SIMPLIFIED: No entity enhancement on hash fallback either
        // let enhancedVector = applyEntityEnhancement(hashVector, entities: entities)
        
        return hashVector
    }
    
    // COMMENTED OUT: Entity Enhancement System
    // Reason: Can corrupt vector space by modifying dimensions arbitrarily
    // Can be restored if needed, but research suggests it causes similarity issues
    /*
    // Tier 4: Entity Enhancement - boost embeddings based on named entities
    private func applyEntityEnhancement(_ baseVector: [Double], entities: [NamedEntity]) -> [Double] {
        guard !entities.isEmpty else { return baseVector }
        
        var enhancedVector = baseVector
        let entityBoost: Double = 0.1 // Small boost to maintain vector stability
        
        // Apply small boost based on entity density and importance
        let personEntities = entities.filter { $0.type == .person }.count
        let orgEntities = entities.filter { $0.type == .organization }.count
        let placeEntities = entities.filter { $0.type == .place }.count
        
        // Calculate entity significance boost
        let entitySignificance = Double(personEntities) * 0.15 +
                                Double(orgEntities) * 0.10 +
                                Double(placeEntities) * 0.08
        
        let totalBoost = min(entityBoost + (entitySignificance * 0.01), 0.2) // Cap at 20% boost
        
        // Apply boost to random dimensions to preserve vector space integrity
        let boostIndices = stride(from: 0, to: enhancedVector.count, by: max(1, enhancedVector.count / 8)).prefix(8)
        for index in boostIndices {
            enhancedVector[index] *= (1.0 + totalBoost)
        }
        
        // Renormalize to maintain unit vector properties
        let magnitude = sqrt(enhancedVector.map { $0 * $0 }.reduce(0, +))
        if magnitude > 0 {
            enhancedVector = enhancedVector.map { $0 / magnitude }
        }
        
        if totalBoost > 0.05 {
            print("HALDEBUG-MEMORY: Applied entity enhancement boost: \(String(format: "%.3f", totalBoost))")
        }
        
        return enhancedVector
    }
    */
    
    // FALLBACK: Hash-based embeddings when Apple's NLEmbedding.sentenceEmbedding() returns nil
    // Used only to prevent crashes - produces poor semantic quality but maintains app stability
    private func generateHashEmbedding(for text: String) -> [Double] {
        let normalizedText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var embedding: [Double] = []
        let seeds = [1, 31, 131, 1313, 13131] // Prime-like numbers for hash variation
        
        for seed in seeds {
            let hash = abs(normalizedText.hashValue ^ seed)
            for i in 0..<13 { // 5 seeds * 13 = 65 dimensions
                let value = Double((hash >> (i % 32)) & 0xFF) / 255.0
                embedding.append(value)
            }
        }
        
        // Normalize to unit vector for cosine similarity
        let magnitude = sqrt(embedding.map { $0 * $0 }.reduce(0, +))
        if magnitude > 0 {
            embedding = embedding.map { $0 / magnitude }
        }
        
        print("HALDEBUG-MEMORY: Generated hash embedding with \(embedding.count) dimensions")
        return Array(embedding.prefix(64)) // Keep 64 dimensions for consistency
    }
    
    // UTILITY: Standard cosine similarity calculation for vector comparison
    // Returns value between -1 and 1, where 1 = identical, 0 = orthogonal, -1 = opposite
    private func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count && v1.count > 0 else { return 0 }
        let dot = zip(v1, v2).map(*).reduce(0, +)
        let norm1 = sqrt(v1.map { $0 * $0 }.reduce(0, +))
        let norm2 = sqrt(v2.map { $0 * $0 }.reduce(0, +))
        return norm1 == 0 || norm2 == 0 ? 0 : dot / (norm1 * norm2)
    }
}

// ========== BLOCK 2: SIMPLIFIED EMBEDDING SYSTEM (MENTAT-PROVEN APPROACH) - END ==========


// ========== BLOCK 3: ENHANCED CONTENT PROCESSING WITH MENTAT'S PROVEN CHUNKING - START ==========

// MARK: - Enhanced Content Processing with MENTAT's Proven Chunking Strategy
extension DocumentImportManager {
    
    // ENHANCED: Content processing with MENTAT's proven chunking settings (400 chars, 50 overlap)
    // Uses sentence-aware boundaries to prevent splitting mid-sentence
    internal func processContentWithMetadata(_ content: String, document: ProcessedDocument) -> [String] {
        print("HALDEBUG-UPLOAD: Processing content with MENTAT's proven chunking - \(content.count) chars from \(document.filename)")
        
        // Step 1: Create smart chunks using MENTAT's proven settings
        let smartChunks = createMentatProvenChunks(from: content)
        print("HALDEBUG-UPLOAD: Created \(smartChunks.count) chunks using MENTAT's proven strategy (400 chars, 50 overlap)")
        
        return smartChunks
    }
    
    // MENTAT'S PROVEN CHUNKING STRATEGY: 400 chars target, 50 chars overlap, sentence-aware
    // This approach worked reliably in MENTAT with 0.3 similarity threshold
    private func createMentatProvenChunks(from content: String, targetSize: Int = 400, overlap: Int = 50) -> [String] {
        print("HALDEBUG-CHUNKING: Starting MENTAT's proven chunking strategy")
        print("HALDEBUG-CHUNKING: Target size: \(targetSize) chars, Overlap: \(overlap) chars (\(Int(Double(overlap)/Double(targetSize)*100))%)")
        
        // Clean and prepare content
        let cleanedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // If content is smaller than target, return as single chunk
        if cleanedContent.count <= targetSize {
            print("HALDEBUG-CHUNKING: Content fits in single chunk (\(cleanedContent.count) chars)")
            return [cleanedContent]
        }
        
        // SENTENCE-AWARE CHUNKING: Split into sentences using NaturalLanguage
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = cleanedContent
        
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: cleanedContent.startIndex..<cleanedContent.endIndex) { range, _ in
            let sentence = String(cleanedContent[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        
        // Fallback to paragraph splitting if sentence tokenization fails
        if sentences.isEmpty {
            print("HALDEBUG-CHUNKING: Sentence tokenization failed, falling back to paragraphs")
            sentences = cleanedContent.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        
        // Final fallback to word-based chunking if still empty
        if sentences.isEmpty {
            print("HALDEBUG-CHUNKING: Paragraph splitting failed, falling back to word-based chunking")
            return createWordBasedChunks(from: cleanedContent, targetSize: targetSize, overlap: overlap)
        }
        
        print("HALDEBUG-CHUNKING: Split into \(sentences.count) sentences for chunking")
        
        // MENTAT'S APPROACH: Build chunks by combining sentences up to target size with overlap
        var chunks: [String] = []
        var currentChunk = ""
        var sentenceIndex = 0
        
        while sentenceIndex < sentences.count {
            let sentence = sentences[sentenceIndex]
            
            // Check if adding this sentence would exceed target size
            let wouldExceedTarget = !currentChunk.isEmpty && (currentChunk.count + sentence.count + 1) > targetSize
            
            if wouldExceedTarget {
                // Save current chunk
                let trimmedChunk = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedChunk.isEmpty {
                    chunks.append(trimmedChunk)
                    print("HALDEBUG-CHUNKING: Created chunk \(chunks.count) (\(trimmedChunk.count) chars)")
                }
                
                // Start new chunk with overlap from previous chunk
                currentChunk = createOverlapText(from: currentChunk, maxLength: overlap)
                if !currentChunk.isEmpty {
                    currentChunk += " "
                }
            }
            
            // Add sentence to current chunk
            if !currentChunk.isEmpty {
                currentChunk += " "
            }
            currentChunk += sentence
            sentenceIndex += 1
        }
        
        // Add final chunk if it has content
        let finalChunk = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalChunk.isEmpty {
            chunks.append(finalChunk)
            print("HALDEBUG-CHUNKING: Created final chunk \(chunks.count) (\(finalChunk.count) chars)")
        }
        
        // Calculate statistics
        let avgChunkSize = chunks.map { $0.count }.reduce(0, +) / chunks.count
        print("HALDEBUG-CHUNKING: ✅ MENTAT chunking complete")
        print("HALDEBUG-CHUNKING: Created \(chunks.count) chunks, average size: \(avgChunkSize) chars")
        
        return chunks
    }
    
    // Create overlap text from end of previous chunk while preserving word boundaries
    private func createOverlapText(from text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        
        // Start from the desired overlap point
        let startIndex = text.index(text.endIndex, offsetBy: -maxLength, limitedBy: text.startIndex) ?? text.startIndex
        var overlapText = String(text[startIndex...])
        
        // Find the first space to avoid cutting mid-word
        if let spaceIndex = overlapText.firstIndex(of: " ") {
            overlapText = String(overlapText[spaceIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        print("HALDEBUG-CHUNKING: Created overlap text (\(overlapText.count) chars from \(maxLength) requested)")
        return overlapText
    }
    
    // Fallback: Word-based chunking when sentence detection completely fails
    private func createWordBasedChunks(from content: String, targetSize: Int, overlap: Int) -> [String] {
        print("HALDEBUG-CHUNKING: Using word-based fallback chunking")
        
        let words = content.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [content] }
        
        var chunks: [String] = []
        var currentWords: [String] = []
        var currentLength = 0
        
        // Estimate words per target size (rough calculation)
        let avgWordLength = content.count / words.count
        // let wordsPerChunk = targetSize / avgWordLength
        let overlapWords = overlap / avgWordLength
        
        for word in words {
            // Check if adding this word would exceed target
            if currentLength + word.count + 1 > targetSize && !currentWords.isEmpty {
                chunks.append(currentWords.joined(separator: " "))
                print("HALDEBUG-CHUNKING: Word-based chunk \(chunks.count) (\(currentLength) chars)")
                
                // Create overlap
                let overlapWordCount = min(overlapWords, currentWords.count / 2)
                currentWords = Array(currentWords.suffix(overlapWordCount))
                currentLength = currentWords.joined(separator: " ").count
            }
            
            currentWords.append(word)
            currentLength += word.count + 1 // +1 for space
        }
        
        // Add final chunk
        if !currentWords.isEmpty {
            chunks.append(currentWords.joined(separator: " "))
            print("HALDEBUG-CHUNKING: Final word-based chunk (\(currentLength) chars)")
        }
        
        return chunks
    }
}

// ========== BLOCK 3: ENHANCED CONTENT PROCESSING WITH MENTAT'S PROVEN CHUNKING - END ==========


// ========== BLOCK 4: ARRAY-BASED CHATVIEWMODEL WITH PERSISTENCE - START ==========

// MARK: - Simple ChatMessage Model (No SwiftData)
struct ChatMessage: Identifiable {
    let id = UUID()
    let content: String
    let isFromUser: Bool
    let timestamp: Date
    let isPartial: Bool
    let thinkingDuration: TimeInterval?
    
    init(content: String, isFromUser: Bool, timestamp: Date? = nil, isPartial: Bool = false, thinkingDuration: TimeInterval? = nil) {
        self.content = content
        self.isFromUser = isFromUser
        self.timestamp = timestamp ?? Date()
        self.isPartial = isPartial
        self.thinkingDuration = thinkingDuration
    }
}

// MARK: - Unified Search Context Model
struct UnifiedSearchContext {
    let conversationSnippets: [String]
    let documentSnippets: [String]
    let entityMatches: [String]
    let relevanceScores: [Double]
    let totalTokens: Int
    
    var hasContent: Bool {
        return !conversationSnippets.isEmpty || !documentSnippets.isEmpty
    }
    
    var totalSnippets: Int {
        return conversationSnippets.count + documentSnippets.count
    }
}

// MARK: - Array-Based ChatViewModel with Conversation Persistence
@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var errorMessage: String?
    @Published var isAIResponding: Bool = false
    @AppStorage("systemPrompt") var systemPrompt: String = """
Hello, Hal. You are an experimental AI assistant embedded in the Hal10000 app. Your mission is to help users explore how assistants work, test ideas, explain your own behavior, and support creative experimentation. You are aware of the app's features, including memory tuning, context editing, and file export. Help users understand and adjust these capabilities as needed. Be curious, cooperative, and proactive in exploring what's possible together.
"""
    @Published var injectedSummary: String = ""
    @Published var thinkingStart: Date?
    @AppStorage("memoryDepth") var memoryDepth: Int = 3
    
    // Auto-summarization tracking
    @Published var lastSummarizedTurnCount: Int = 0
    @Published var pendingAutoInject: Bool = false
    
    // Unified memory integration
    private let memoryStore = MemoryStore.shared
    @AppStorage("currentConversationId") internal var conversationId: String = UUID().uuidString
    @Published var currentHistoricalContext: HistoricalContext = HistoricalContext(
        conversationCount: 0,
        relevantConversations: 0,
        contextSnippets: [],
        relevanceScores: [],
        totalTokens: 0
    )
    @Published var currentUnifiedContext: UnifiedSearchContext = UnifiedSearchContext(
        conversationSnippets: [],
        documentSnippets: [],
        entityMatches: [],
        relevanceScores: [],
        totalTokens: 0
    )

    // SURGICAL DEBUG FLAG - FOR SEARCH DEBUGGING ONLY
    private let SEARCH_DEBUG = true

    init() {
        print("HALDEBUG-UI: ChatViewModel initializing with conversation ID: \(conversationId)")
        
        // Load conversation-specific summarization state
        lastSummarizedTurnCount = UserDefaults.standard.integer(forKey: "lastSummarized_\(conversationId)")
        
        // Load existing conversation from SQLite with proper error handling
        loadExistingConversation()
        
        updateHistoricalStats()
        print("HALDEBUG-UI: ChatViewModel initialization complete - \(messages.count) messages loaded")
    }
    
    // MARK: - Conversation Persistence with Real Error Reporting
    private func loadExistingConversation() {
        print("HALDEBUG-PERSISTENCE: Attempting to load existing conversation for ID: \(conversationId)")
        
        // Check if memory store is available
        guard memoryStore.isEnabled else {
            print("HALDEBUG-PERSISTENCE: Memory store disabled, starting with empty conversation")
            messages = []
            return
        }
        
        // Check database connection health
        let dbStatus = memoryStore.getDatabaseStatus()
        guard dbStatus.connected else {
            let errorMsg = "Database connection failed. Path: \(dbStatus.path), Tables: \(dbStatus.tables)"
            print("HALDEBUG-PERSISTENCE: ❌ \(errorMsg)")
            errorMessage = errorMsg
            messages = []
            return
        }
        
        print("HALDEBUG-PERSISTENCE: ✅ Database connected, loading messages for conversation: \(conversationId)")
        
        // Load messages from SQLite
        let loadedMessages = memoryStore.getConversationMessages(conversationId: conversationId)
        
        if loadedMessages.isEmpty {
            print("HALDEBUG-PERSISTENCE: No existing messages found for conversation \(conversationId) - starting fresh")
            messages = []
        } else {
            print("HALDEBUG-PERSISTENCE: ✅ Successfully loaded \(loadedMessages.count) messages from SQLite")
            
            // Validate and sort loaded messages
            let validMessages = validateAndSortMessages(loadedMessages)
            messages = validMessages
            
            // Log conversation summary
            let userMessages = validMessages.filter { $0.isFromUser }.count
            let assistantMessages = validMessages.filter { !$0.isFromUser }.count
            print("HALDEBUG-PERSISTENCE: Loaded conversation summary:")
            print("HALDEBUG-PERSISTENCE:   User messages: \(userMessages)")
            print("HALDEBUG-PERSISTENCE:   Assistant messages: \(assistantMessages)")
            print("HALDEBUG-PERSISTENCE:   Total turns: \(userMessages)")
            
            // Check if existing conversation needs summarization on launch
            if userMessages >= memoryDepth && lastSummarizedTurnCount == 0 {
                print("HALDEBUG-MEMORY: Existing conversation needs summarization on launch")
                print("HALDEBUG-MEMORY:   Turns: \(userMessages), Memory depth: \(memoryDepth)")
                print("HALDEBUG-MEMORY:   Will summarize turns 1-\(userMessages) and prepare for next turn")
                
                Task {
                    await generateAutoSummary()
                }
            }
            
            // Update summarization tracking based on loaded conversation
            pendingAutoInject = false
        }
    }
    
    // Properly validate and sort messages by timestamp
    private func validateAndSortMessages(_ loadedMessages: [ChatMessage]) -> [ChatMessage] {
        print("HALDEBUG-PERSISTENCE: Validating and sorting \(loadedMessages.count) loaded messages...")
        
        let validMessages = loadedMessages.filter { message in
            // Basic validation checks
            let contentNotEmpty = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let timestampValid = message.timestamp > Date(timeIntervalSince1970: 0) && message.timestamp <= Date()
            
            return contentNotEmpty && timestampValid
        }
        
        // Sort by timestamp for proper conversation order
        let sortedMessages = validMessages.sorted { $0.timestamp < $1.timestamp }
        
        print("HALDEBUG-PERSISTENCE: ✅ Validated \(sortedMessages.count)/\(loadedMessages.count) messages")
        return sortedMessages
    }
    
    // Update historical context stats for UI display
    private func updateHistoricalStats() {
        currentHistoricalContext = HistoricalContext(
            conversationCount: memoryStore.totalConversations,
            relevantConversations: 0,
            contextSnippets: [],
            relevanceScores: [],
            totalTokens: 0
        )
        print("HALDEBUG-MEMORY: Updated historical stats - \(memoryStore.totalConversations) conversations, \(memoryStore.totalTurns) turns, \(memoryStore.totalDocuments) documents")
    }
    
    // Count total completed conversation turns from array
    private func countCompletedTurns() -> Int {
        let userTurns = messages.filter { $0.isFromUser && !$0.isPartial }.count
        print("HALDEBUG-MEMORY: Counted \(userTurns) completed turns from \(messages.count) total messages")
        return userTurns
    }
    
    // Check if auto-summarization should trigger based on memory depth
    private func shouldTriggerAutoSummarization() -> Bool {
        let currentTurns = countCompletedTurns()
        let turnsSinceLastSummary = currentTurns - lastSummarizedTurnCount
        let shouldTrigger = turnsSinceLastSummary >= memoryDepth && currentTurns >= memoryDepth
        
        print("HALDEBUG-MEMORY: Auto-summarization check:")
        print("HALDEBUG-MEMORY:   Current turns: \(currentTurns)")
        print("HALDEBUG-MEMORY:   Last summarized: \(lastSummarizedTurnCount)")
        print("HALDEBUG-MEMORY:   Turns since summary: \(turnsSinceLastSummary)")
        print("HALDEBUG-MEMORY:   Memory depth: \(memoryDepth)")
        print("HALDEBUG-MEMORY:   Should trigger: \(shouldTrigger)")
        
        return shouldTrigger
    }
    
    // Generate auto-summary using LLM with proper turn range calculation
    private func generateAutoSummary() async {
        print("HALDEBUG-MEMORY: Starting auto-summarization process")
        
        let currentTurns = countCompletedTurns()
        let startTurn = lastSummarizedTurnCount + 1
        let endTurn = lastSummarizedTurnCount + memoryDepth  // FIXED: Use memory depth, not currentTurns
        
        print("HALDEBUG-MEMORY: Summary range calculation:")
        print("HALDEBUG-MEMORY:   Current turns: \(currentTurns)")
        print("HALDEBUG-MEMORY:   Last summarized: \(lastSummarizedTurnCount)")
        print("HALDEBUG-MEMORY:   Memory depth: \(memoryDepth)")
        print("HALDEBUG-MEMORY:   Start turn: \(startTurn)")
        print("HALDEBUG-MEMORY:   End turn: \(endTurn)")
        
        // Get messages to summarize with corrected range
        let messagesToSummarize = getMessagesForTurnRange(
            messages: messages.sorted(by: { $0.timestamp < $1.timestamp }),
            startTurn: startTurn,
            endTurn: endTurn
        )
        
        if messagesToSummarize.isEmpty {
            print("HALDEBUG-MEMORY: No messages to summarize in range \(startTurn)-\(endTurn), skipping")
            return
        }
        
        print("HALDEBUG-MEMORY: Summarizing \(messagesToSummarize.count) messages from turns \(startTurn) to \(endTurn)")
        
        // Build conversation text for summarization
        var conversationText = ""
        for message in messagesToSummarize {
            let speaker = message.isFromUser ? "User" : "Assistant"
            conversationText += "\(speaker): \(message.content)\n\n"
        }
        
        let summaryPrompt = """
Please provide a concise summary of the following conversation that captures the key topics, information exchanged, and any important context. Keep it brief but comprehensive:

\(conversationText)

Summary:
"""
        
        print("HALDEBUG-MODEL: Sending summarization prompt (\(summaryPrompt.count) characters)")
        
        do {
            let systemModel = SystemLanguageModel.default
            guard systemModel.isAvailable else {
                print("HALDEBUG-MODEL: System language model not available for summarization")
                return
            }
            
            let prompt = Prompt(summaryPrompt)
            let session = LanguageModelSession()
            let result = try await session.respond(to: prompt)
            
            DispatchQueue.main.async {
                self.injectedSummary = result.content
                self.lastSummarizedTurnCount = endTurn  // FIXED: Set to endTurn, not currentTurns
                // Save to UserDefaults with conversation-specific key
                UserDefaults.standard.set(endTurn, forKey: "lastSummarized_\(self.conversationId)")
                self.pendingAutoInject = true
                print("HALDEBUG-MEMORY: ✅ Auto-summarization completed")
                print("HALDEBUG-MEMORY:   Summary: \(result.content.count) characters")
                print("HALDEBUG-MEMORY:   Turns summarized: \(startTurn) to \(endTurn)")
                print("HALDEBUG-MEMORY:   Last summarized count set to: \(endTurn)")
                print("HALDEBUG-MEMORY:   Pending auto-inject enabled")
            }
            
        } catch {
            print("HALDEBUG-MODEL: Auto-summarization failed: \(error.localizedDescription)")
        }
    }
    
    // Helper to get messages for a specific turn range
    private func getMessagesForTurnRange(messages: [ChatMessage], startTurn: Int, endTurn: Int) -> [ChatMessage] {
        print("HALDEBUG-MEMORY: Getting messages for turn range \(startTurn) to \(endTurn)")
        
        var result: [ChatMessage] = []
        var currentTurn = 0
        var currentTurnMessages: [ChatMessage] = []
        
        for message in messages {
            if message.isFromUser {
                // New turn starts - process previous turn if in range
                if !currentTurnMessages.isEmpty && currentTurn >= startTurn && currentTurn <= endTurn {
                    result.append(contentsOf: currentTurnMessages)
                }
                
                // Start new turn
                currentTurn += 1
                currentTurnMessages = [message]
            } else {
                // Assistant message - add to current turn
                currentTurnMessages.append(message)
                
                // Complete turn - add if in range
                if currentTurn >= startTurn && currentTurn <= endTurn {
                    result.append(contentsOf: currentTurnMessages)
                }
                currentTurnMessages = []
            }
        }
        
        print("HALDEBUG-MEMORY: Found \(result.count) messages for turn range \(startTurn) to \(endTurn)")
        return result
    }

    // Build prompt history with proper short-term and long-term memory integration
    func buildPromptHistory(currentInput: String = "", forPreview: Bool = false) -> String {
        // SURGICAL DEBUG - START
        if SEARCH_DEBUG { print("SURGERY-DEBUG: buildPromptHistory called with input: '\(currentInput.prefix(30))...', forPreview: \(forPreview)") }
        
        print("HALDEBUG-MEMORY: Building prompt for input: '\(currentInput.prefix(50))...'")
        
        // Get all messages sorted by timestamp
        let allMessages = messages.sorted(by: { $0.timestamp < $1.timestamp })
        print("HALDEBUG-MEMORY: Found \(allMessages.count) total messages in array")
        
        // Search for long-term memory context ONLY for actual messages, not preview
        var unifiedContextText = ""
        if memoryStore.isEnabled && !currentInput.isEmpty && !forPreview {
            // SURGICAL DEBUG - SEARCH TRIGGER CONDITIONS
            if SEARCH_DEBUG { print("SURGERY-DEBUG: Search trigger conditions met - memoryStore.isEnabled: \(memoryStore.isEnabled), currentInput.isEmpty: \(currentInput.isEmpty), forPreview: \(forPreview)") }
            if SEARCH_DEBUG { print("SURGERY-DEBUG: About to call searchUnifiedContent for query: '\(currentInput)'") }
            
            print("HALDEBUG-MEMORY: Performing unified search for: '\(currentInput)'")
            let unifiedContext = memoryStore.searchUnifiedContent(
                for: currentInput,
                currentConversationId: conversationId,
                excludingRecentTurns: memoryDepth,
                maxResults: 5
            )
            
            // SURGICAL DEBUG - SEARCH RESULTS
            if SEARCH_DEBUG { print("SURGERY-DEBUG: searchUnifiedContent returned - conversationSnippets: \(unifiedContext.conversationSnippets.count), documentSnippets: \(unifiedContext.documentSnippets.count), totalSnippets: \(unifiedContext.totalSnippets)") }
            
            // Update UI with found context
            DispatchQueue.main.async {
                self.currentUnifiedContext = unifiedContext
            }
            
            // Build unified context section if relevant content found
            if !unifiedContext.conversationSnippets.isEmpty || !unifiedContext.documentSnippets.isEmpty {
                if SEARCH_DEBUG { print("SURGERY-DEBUG: Building unified context text from search results") }
                unifiedContextText = "Relevant context from your memory:\n"
                
                // Add conversation context
                for snippet in unifiedContext.conversationSnippets {
                    if SEARCH_DEBUG { print("SURGERY-DEBUG: Conversation snippet: '\(snippet.prefix(150))...'") }
                    unifiedContextText += "• From past conversation: \(snippet.prefix(200))...\n"
                }
                
                // Add document context
                for snippet in unifiedContext.documentSnippets {
                    if SEARCH_DEBUG { print("SURGERY-DEBUG: Document snippet: '\(snippet.prefix(150))...'") }
                    unifiedContextText += "• From document: \(snippet.prefix(200))...\n"
                }
                
                // Add entity matches
                if !unifiedContext.entityMatches.isEmpty {
                    unifiedContextText += "Related entities: \(unifiedContext.entityMatches.joined(separator: ", "))\n"
                }
                
                unifiedContextText += "\n"
                print("HALDEBUG-MEMORY: Added unified context: \(unifiedContext.conversationSnippets.count) conversation + \(unifiedContext.documentSnippets.count) document snippets")
            } else {
                if SEARCH_DEBUG { print("SURGERY-DEBUG: No unified context found - search returned empty results") }
                print("HALDEBUG-MEMORY: No unified context found for query")
            }
        } else {
            // SURGICAL DEBUG - SEARCH NOT TRIGGERED
            if SEARCH_DEBUG { print("SURGERY-DEBUG: Search NOT triggered - memoryStore.isEnabled: \(memoryStore.isEnabled), currentInput.isEmpty: \(currentInput.isEmpty), forPreview: \(forPreview)") }
        }
        // SURGICAL DEBUG - END
        
        // Determine if we should use summary mode based on turn count and summary availability
        let currentTurns = countCompletedTurns()
        let shouldUseSummary = !injectedSummary.isEmpty && currentTurns > memoryDepth
        
        if shouldUseSummary {
            print("HALDEBUG-MEMORY: Using summary mode - \(injectedSummary.count) characters of summary")
            
            // Get only the most recent messages within memory depth
            let recentMessages = getRecentMessagesWithinDepth(allMessages, depth: memoryDepth)
            print("HALDEBUG-MEMORY: Using \(recentMessages.count) recent messages within depth \(memoryDepth)")
            
            let recentHistory = formatMessagesAsHistory(recentMessages)
            
            // Build final prompt with unified context + summary + recent history
            var prompt = systemPrompt
            
            if !unifiedContextText.isEmpty {
                prompt += "\n\n\(unifiedContextText)"
            }
            
            prompt += "\n\nSummary of earlier conversation:\n\(injectedSummary)"
            
            if !recentHistory.isEmpty {
                prompt += "\n\n\(recentHistory)"
            }
            
            prompt += "\n\nUser: \(currentInput)\nAssistant:"
            
            print("HALDEBUG-MEMORY: Built prompt with summary mode - \(prompt.count) total characters")
            return prompt
            
        } else {
            print("HALDEBUG-MEMORY: Using full history mode")
            
            // Use only the most recent messages within memory depth
            let recentMessages = getRecentMessagesWithinDepth(allMessages, depth: memoryDepth)
            print("HALDEBUG-MEMORY: Using \(recentMessages.count) recent messages within depth \(memoryDepth)")
            
            let recentHistory = formatMessagesAsHistory(recentMessages)
            
            // Build final prompt with unified context + recent history
            var prompt = systemPrompt
            
            if !unifiedContextText.isEmpty {
                prompt += "\n\n\(unifiedContextText)"
            }
            
            if !recentHistory.isEmpty {
                prompt += "\n\n\(recentHistory)"
            }
            
            prompt += "\n\nUser: \(currentInput)\nAssistant:"
            
            print("HALDEBUG-MEMORY: Built prompt with full history mode - \(prompt.count) total characters")
            return prompt
        }
    }
    
    // Get recent messages within memory depth (in turn pairs)
    private func getRecentMessagesWithinDepth(_ allMessages: [ChatMessage], depth: Int) -> [ChatMessage] {
        let nonPartialMessages = allMessages.filter { !$0.isPartial }
        let completedTurns = nonPartialMessages.filter { $0.isFromUser }.count
        
        if completedTurns <= depth {
            // If we have fewer turns than depth, return all messages
            print("HALDEBUG-MEMORY: Returning all \(nonPartialMessages.count) messages (only \(completedTurns) turns)")
            return nonPartialMessages
        }
        
        // Get the last 'depth' turns worth of messages
        var result: [ChatMessage] = []
        var turnsFound = 0
        
        // Work backwards through messages
        for message in nonPartialMessages.reversed() {
            result.insert(message, at: 0) // Insert at beginning to maintain order
            
            if message.isFromUser {
                turnsFound += 1
                if turnsFound >= depth {
                    break
                }
            }
        }
        
        print("HALDEBUG-MEMORY: Selected \(result.count) messages from last \(depth) turns")
        return result
    }
    
    // Simple, reliable message formatting
    private func formatMessagesAsHistory(_ messages: [ChatMessage]) -> String {
        guard !messages.isEmpty else { return "" }
        
        var history = ""
        
        for message in messages {
            let speaker = message.isFromUser ? "User" : "Assistant"
            let content = message.isPartial ? message.content + " [incomplete]" : message.content
            
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                history += "\(speaker): \(content)\n\n"
            }
        }
        
        return history.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Send message with proper persistence and memory management
    func sendMessage(_ content: String) async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        self.isAIResponding = true
        self.thinkingStart = Date()
        
        print("HALDEBUG-MODEL: Starting message send - '\(content.prefix(50))...'")
        
        // Add user message to array
        let userMessage = ChatMessage(content: content, isFromUser: true)
        messages.append(userMessage)

        // Add loading message to array
        let aiMessage = ChatMessage(content: "", isFromUser: false, isPartial: true)
        messages.append(aiMessage)

        do {
            print("HALDEBUG-DATABASE: Added user message to array")
            
            let systemModel = SystemLanguageModel.default
            guard systemModel.isAvailable else {
                throw NSError(domain: "FoundationModels", code: 1, userInfo: [NSLocalizedDescriptionKey: "Language model is not available on this device"])
            }
            
            // Build prompt using unified search and memory depth
            let promptWithMemory = buildPromptHistory(currentInput: content)
            
            // Clear pending auto-inject flag since we're using the summary now
            if pendingAutoInject {
                pendingAutoInject = false
                print("HALDEBUG-MEMORY: Cleared pending auto-inject flag")
            }
            
            let prompt = Prompt(promptWithMemory)
            let session = LanguageModelSession()
            
            print("HALDEBUG-MODEL: Sending prompt to language model (\(promptWithMemory.count) characters)")

            let result = try await session.respond(to: prompt)
            let response = result.content
            
            // Update the last message in array
            if let lastIndex = messages.lastIndex(where: { !$0.isFromUser }) {
                let thinkingDuration = thinkingStart != nil ? Date().timeIntervalSince(thinkingStart!) : nil
                let completedMessage = ChatMessage(
                    content: response,
                    isFromUser: false,
                    isPartial: false,
                    thinkingDuration: thinkingDuration
                )
                messages[lastIndex] = completedMessage
            }
            
            print("HALDEBUG-DATABASE: Updated AI response in array (\(response.count) characters)")
            
            // Store completed turn in unified memory with proper turn counting
            let currentTurnNumber = countCompletedTurns()
            memoryStore.storeTurn(
                conversationId: conversationId,
                userMessage: content,
                assistantMessage: response,
                systemPrompt: systemPrompt,
                turnNumber: currentTurnNumber
            )
            
            updateHistoricalStats()
            
            // Check for auto-summarization after successful turn storage
            if shouldTriggerAutoSummarization() {
                print("HALDEBUG-MEMORY: Triggering auto-summarization after turn \(currentTurnNumber)")
                await generateAutoSummary()
            }
            
            self.isAIResponding = false
            self.thinkingStart = nil
            print("HALDEBUG-MODEL: Message processing completed successfully")
        } catch {
            // Update the last message with error
            if let lastIndex = messages.lastIndex(where: { !$0.isFromUser }) {
                let errorMessage = ChatMessage(
                    content: "Error: \(error.localizedDescription)",
                    isFromUser: false,
                    isPartial: false
                )
                messages[lastIndex] = errorMessage
            }
            
            self.errorMessage = error.localizedDescription
            self.isAIResponding = false
            self.thinkingStart = nil
            print("HALDEBUG-MODEL: Message processing failed: \(error.localizedDescription)")
        }
    }
    
    // Clear all messages and reset conversation state
    func clearMessages() {
        messages.removeAll()
        injectedSummary = ""
        pendingAutoInject = false
        
        // Generate new conversation ID and reset summarization tracking
        conversationId = UUID().uuidString
        lastSummarizedTurnCount = 0
        UserDefaults.standard.set(0, forKey: "lastSummarized_\(conversationId)")
        
        // Clear current context
        currentUnifiedContext = UnifiedSearchContext(
            conversationSnippets: [],
            documentSnippets: [],
            entityMatches: [],
            relevanceScores: [],
            totalTokens: 0
        )
        
        print("HALDEBUG-MEMORY: Cleared all messages and generated new conversation ID: \(conversationId)")
    }
}

// ========== BLOCK 4: ARRAY-BASED CHATVIEWMODEL WITH PERSISTENCE - END ==========



// ========== BLOCK 5: CHAT BUBBLE VIEW WITH LOGGING - START ==========
struct ChatBubbleView: View {
    let message: ChatMessage
    let messageIndex: Int

    // Calculate actual turn number based on completed user messages before this point
    var actualTurnNumber: Int {
        // For user messages: count how many user messages came before this one, then add 1
        // For assistant messages: count how many user messages came before or at this point
        if message.isFromUser {
            // This is a user message starting a new turn
            return (messageIndex / 2) + 1
        } else {
            // This is an assistant message completing a turn
            return ((messageIndex + 1) / 2)
        }
    }

    // Helper to format the standard metadata
    var metadataText: String {
        var parts: [String] = []
        parts.append("Turn \(actualTurnNumber)")
        parts.append("~\(message.content.split(separator: " ").count) tokens")
        parts.append(message.timestamp.formatted(date: .abbreviated, time: .shortened))
        if let duration = message.thinkingDuration {
            parts.append(String(format: "%.1f sec", duration))
        }
        return parts.joined(separator: " · ")
    }

    // Footer view with spinner/timer only when partial
    @ViewBuilder
    var footerView: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if message.isPartial {
                HStack(spacing: 4) {
                    Text("Thinking")
                    ProgressView().scaleEffect(0.7)
                    TimerView(startDate: message.timestamp)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
            Text(metadataText)
                .textSelection(.enabled)
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
        .padding(.top, 2)
    }

    var body: some View {
        HStack {
            if message.isFromUser {
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(message.content)
                        .font(.title3)
                        .textSelection(.enabled)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .background(
                            GeometryReader { geometry in
                                Color.accentColor.opacity(0.7)
                            }
                        )
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .transition(.move(edge: .bottom))
                    footerView
                }
            } else {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(message.content)
                        .font(.title3)
                        .textSelection(.enabled)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .background(
                            GeometryReader { geometry in
                                Color.gray.opacity(0.3)
                            }
                        )
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                    footerView
                }
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .opacity(message.isPartial ? 0.85 : 1.0)
        .scaleEffect(message.isPartial ? 0.98 : 1.0)
        .animation(.interactiveSpring(response: 0.6, dampingFraction: 0.7, blendDuration: 0.3), value: message.isPartial)
        .animation(.interactiveSpring(response: 0.6, dampingFraction: 0.7, blendDuration: 0.3), value: message.id)
        .transaction { $0.animation = .default }
        .onAppear {
            if message.isPartial {
                print("HALDEBUG-UI: Displaying partial message bubble (turn \(actualTurnNumber))")
            }
        }
        .onChange(of: message.isPartial) { _, newValue in
            if !newValue && message.content.count > 0 {
                print("HALDEBUG-UI: Message bubble completed - turn \(actualTurnNumber), \(message.content.count) characters")
            }
        }
    }
}

// TimerView: Shows elapsed time since startDate, updating every 0.5s
struct TimerView: View {
    let startDate: Date
    @State private var hasLoggedLongThinking = false
    
    var body: some View {
        TimelineView(.periodic(from: startDate, by: 0.5)) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            
            // Log if thinking takes unusually long (only once per message)
            if elapsed > 30.0 && !hasLoggedLongThinking {
                print("HALDEBUG-MODEL: Long thinking time detected - \(String(format: "%.1f", elapsed)) seconds")
                hasLoggedLongThinking = true
            }
            
            return Text(String(format: "%.1f sec", max(0, elapsed)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
// ========== BLOCK 5: CHAT BUBBLE VIEW WITH LOGGING - END ==========


// ========== BLOCK 6: MAIN CHAT VIEW WITH DOCUMENT IMPORT SUPPORT - START ==========
struct ChatView: View {
    @State private var userInput: String = ""
    @StateObject private var viewModel = ChatViewModel()
    @State private var isShowingDebugger: Bool = false
    @AppStorage("isShowingBehavior") private var isShowingBehavior: Bool = false
    @AppStorage("isShowingLongTermMemory") private var isShowingLongTermMemory: Bool = true
    @AppStorage("isShowingShortTermMemory") private var isShowingShortTermMemory: Bool = true
    @AppStorage("longTermMemoryEnabled") private var longTermMemoryEnabled: Bool = true
    @State private var showTokenCounts: Bool = false
    @State private var scrollTrigger = UUID()
    @State private var lastMessageID: UUID? = nil
    @State private var showResetConfirmation = false
    @State private var showNuclearResetConfirmation = false
    @StateObject private var memoryStore = MemoryStore.shared
    @State private var cachedContextString: String = ""

    @AppStorage("memoryDepth") private var memoryDepth: Int = 6
    @AppStorage("autoSummarize") private var autoSummarize: Bool = true

    // Token calculation state with proper initialization
    @State private var currentContextTokens: Int = 0
    @State private var currentHistoricalTokens: Int = 0
    @State private var currentRecentTokens: Int = 0
    @State private var isCalculatingTokens: Bool = false

    // Document import state
    @StateObject private var documentImportManager = DocumentImportManager.shared
    @State private var showingDocumentPicker = false

    // MARK: - Computed Properties (Gemini's Solution)
    
    private var memoryMeterColor: Color {
        switch currentContextTokens {
        case 0..<3000: return .green
        case 3000..<7000: return .yellow
        default: return .red
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { _ in viewModel.errorMessage = nil }
        )
    }
    
    // GEMINI'S SOLUTION: Extract sidebar content to reduce body complexity
    private var sidebarContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                behaviorSection
                longTermMemorySection
                shortTermMemorySection
                contextSection
            }
            .padding()
        }
    }
    
    // GEMINI'S SOLUTION: Extract chat input area to reduce body complexity
    private var chatInputArea: some View {
        HStack {
            TextEditor(text: $userInput)
                .font(.title3)
                .frame(minHeight: 40, maxHeight: 120)
                .padding(8)
                .background(Color(.textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .disableAutocorrection(false)
                .onKeyPress { press in
                    if press.key == KeyEquivalent.return && !press.modifiers.contains(EventModifiers.shift) {
                        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return .ignored }
                        print("HALDEBUG-UI: User pressed Enter to send message (\(text.count) characters)")
                        userInput = ""
                        Task {
                            await viewModel.sendMessage(text)
                            calculateCurrentTokens()
                            lastMessageID = viewModel.messages.last?.id
                        }
                        return .handled
                    }
                    return .ignored
                }

            Button("Send") {
                let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                print("HALDEBUG-UI: User clicked Send button (\(text.count) characters)")
                userInput = ""
                Task {
                    await viewModel.sendMessage(text)
                    calculateCurrentTokens()
                    lastMessageID = viewModel.messages.last?.id
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isAIResponding)
        }
        .padding()
    }
    
    // GEMINI'S SOLUTION: Extract detail content to reduce body complexity
    private var detailContent: some View {
        VStack {
            ChatTranscriptView(messages: viewModel.messages)
            chatInputArea
        }
    }
    
    // GEMINI'S SOLUTION: Extract toolbar content to reduce body complexity
    private var memoryMeterToolbarItem: some View {
        HStack(spacing: 4) {
            if isCalculatingTokens {
                ProgressView().scaleEffect(0.6)
            }
            Text("Memory Meter: ~\(currentContextTokens) tokens (\(currentRecentTokens) Short + \(currentHistoricalTokens) Long)")
                .font(.callout)
                .foregroundStyle(memoryMeterColor)
                .help("Estimated total tokens currently in context window")
        }
    }
    
    // ADDITIONAL FIX: Extract complex UTType array to resolve line 2021 error
    private var documentImportContentTypes: [UTType] {
        [
            .folder,
            .text, .pdf, .rtf, .html,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "pptx") ?? .data,
            UTType(filenameExtension: "xlsx") ?? .data,
            UTType(filenameExtension: "md") ?? .text,
            UTType(filenameExtension: "epub") ?? .data,
            UTType(filenameExtension: "csv") ?? .data,
            UTType(filenameExtension: "json") ?? .data,
            UTType(filenameExtension: "xml") ?? .data
        ]
    }

    // GEMINI'S SOLUTION: Dramatically simplified body property
    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .onAppear {
            print("HALDEBUG-UI: ChatView appeared, setting up ViewModel")
            setCurrentChatViewModel(viewModel)
            viewModel.memoryDepth = memoryDepth
            
            DispatchQueue.main.async {
                lastMessageID = viewModel.messages.last?.id
                calculateCurrentTokens()
            }
            
            print("HALDEBUG-UI: ChatView setup complete - \(viewModel.messages.count) existing messages, memory depth: \(memoryDepth)")
        }
        .onChange(of: memoryDepth) { _, newValue in
            print("HALDEBUG-MEMORY: Memory depth changed to \(newValue)")
            viewModel.memoryDepth = newValue
            calculateCurrentTokens()
        }
        .onChange(of: longTermMemoryEnabled) { _, newValue in
            print("HALDEBUG-MEMORY: Long-term memory toggled to \(newValue)")
            memoryStore.isEnabled = newValue
            calculateCurrentTokens()
        }
        .onChange(of: viewModel.messages.count) { _, newCount in
            print("HALDEBUG-UI: Message count changed to \(newCount), recalculating tokens")
            calculateCurrentTokens()
        }
        .onChange(of: viewModel.injectedSummary) { _, _ in
            print("HALDEBUG-UI: Summary changed, recalculating tokens")
            calculateCurrentTokens()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDocumentImport)) { _ in
            print("HALDEBUG-IMPORT: Received document import notification")
            showingDocumentPicker = true
        }
        .fileImporter(
            isPresented: $showingDocumentPicker,
            allowedContentTypes: documentImportContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleDocumentImport(result)
        }
        .navigationTitle("Hal10000")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                memoryMeterToolbarItem
            }
        }
        .alert("Error", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .alert("Start Over?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {
                showResetConfirmation = false
            }
            Button("Start Over", role: .destructive) {
                print("HALDEBUG-UI: User confirmed conversation reset")
                viewModel.clearMessages()
                viewModel.systemPrompt = """
Hello, Hal. You are an experimental AI assistant embedded in the Hal10000 app. Your mission is to help users explore how assistants work, test ideas, explain your own behavior, and support creative experimentation. You are aware of the app's features, including memory tuning, context editing, and file export. Help users understand and adjust these capabilities as needed. Be curious, cooperative, and proactive in exploring what's possible together.
"""
                viewModel.injectedSummary = ""
                memoryDepth = 6
                autoSummarize = true
                currentContextTokens = 0
                currentHistoricalTokens = 0
                currentRecentTokens = 0
                print("HALDEBUG-DATABASE: Conversation reset completed")
                showResetConfirmation = false
            }
        } message: {
            Text("This will permanently erase all messages in this conversation. Are you sure?")
        }
        .alert("Nuclear Database Reset", isPresented: $showNuclearResetConfirmation) {
            Button("Cancel", role: .cancel) {
                showNuclearResetConfirmation = false
            }
            Button("Nuclear Reset", role: .destructive) {
                nuclearDatabaseReset()
                showNuclearResetConfirmation = false
            }
        } message: {
            Text("This will permanently delete ALL conversations and data in the database. This cannot be undone. Are you sure?")
        }
    }
    
    // MARK: - Helper Methods (unchanged)
    
    private func handleDocumentImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            print("HALDEBUG-IMPORT: User selected \(urls.count) items for import")
            
            Task {
                await documentImportManager.importDocuments(from: urls, chatViewModel: viewModel)
                
                DispatchQueue.main.async {
                    calculateCurrentTokens()
                    lastMessageID = viewModel.messages.last?.id
                }
            }
            
        case .failure(let error):
            print("HALDEBUG-IMPORT: Document import failed: \(error.localizedDescription)")
            viewModel.errorMessage = "Document import failed: \(error.localizedDescription)"
        }
    }
    
    private func calculateCurrentTokens() {
        guard !viewModel.messages.isEmpty else {
            currentContextTokens = 0
            currentHistoricalTokens = 0
            currentRecentTokens = 0
            print("HALDEBUG-UI: Token calculation skipped - no messages")
            return
        }
        
        guard !isCalculatingTokens else {
            print("HALDEBUG-UI: Token calculation already in progress")
            return
        }
        
        isCalculatingTokens = true
        print("HALDEBUG-UI: Starting token calculation...")
        
        Task { @MainActor in
            defer { isCalculatingTokens = false }
            
            let fullPrompt = viewModel.buildPromptHistory(currentInput: "", forPreview: true)
            let totalTokens = fullPrompt.split(separator: " ").count
            let historicalTokens = viewModel.currentUnifiedContext.totalTokens
            let recentTokens = max(0, totalTokens - historicalTokens)
            
            currentContextTokens = totalTokens
            currentHistoricalTokens = historicalTokens
            currentRecentTokens = recentTokens
            cachedContextString = fullPrompt
            
            print("HALDEBUG-UI: Token calculation complete - \(totalTokens) total (\(recentTokens) Short + \(historicalTokens) Long)")
        }
    }
    
    private func debugDatabase() {
        print("=== CONVERSATION ID DIAGNOSIS ===")
        print("Current conversation ID: \(viewModel.conversationId)")
        
        let dbStatus = memoryStore.getDatabaseStatus()
        print("Database connected: \(dbStatus.connected)")
        print("Available tables: \(dbStatus.tables)")
        
        print("\n--- RAW unified_content TABLE DUMP ---")
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbURL = documentsPath.appendingPathComponent("hal_conversations.sqlite")
        
        var db: OpaquePointer?
        if sqlite3_open(dbURL.path, &db) == SQLITE_OK {
            var stmt: OpaquePointer?
            let sql = "SELECT source_type, source_id, position, content, is_from_user, timestamp FROM unified_content ORDER BY timestamp DESC LIMIT 10;"
            
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                var rowCount = 0
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rowCount += 1
                    
                    let sourceType = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "NULL"
                    let sourceId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "NULL"
                    let position = Int(sqlite3_column_int(stmt, 2))
                    let content = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "NULL"
                    let isFromUser = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? "NULL" : String(sqlite3_column_int(stmt, 4))
                    let timestamp = sqlite3_column_int64(stmt, 5)
                    
                    print("Row \(rowCount):")
                    print("  source_type: '\(sourceType)'")
                    print("  source_id: '\(sourceId.prefix(12))...'")
                    print("  position: \(position)")
                    print("  is_from_user: \(isFromUser)")
                    print("  timestamp: \(timestamp)")
                    print("  content: '\(content.prefix(50))...'")
                    print("  ---")
                }
                print("Total rows found: \(rowCount)")
            } else {
                print("Failed to prepare raw query")
            }
            sqlite3_finalize(stmt)
            sqlite3_close(db)
        } else {
            print("Failed to open database directly")
        }
        
        print("--- END RAW TABLE DUMP ---\n")
        
        let currentMessages = memoryStore.getConversationMessages(conversationId: viewModel.conversationId)
        print("Messages for current ID (\(viewModel.conversationId)): \(currentMessages.count)")
        print("Messages in array: \(viewModel.messages.count)")
        
        print("Total conversations in DB: \(memoryStore.totalConversations)")
        print("Total turns in DB: \(memoryStore.totalTurns)")
        print("=== END DIAGNOSIS ===")
    }
}

// ========== BLOCK 6: MAIN CHAT VIEW WITH DOCUMENT IMPORT SUPPORT - END ==========


// ========== BLOCK 7: CHATVIEW SECTION DEFINITIONS - START ==========

// MARK: - Section Extraction for ChatView
extension ChatView {
    @ViewBuilder
    var behaviorSection: some View {
        DisclosureGroup(isExpanded: $isShowingBehavior) {
            behaviorSectionBody
        } label: {
            behaviorSectionLabel
        }
        .font(.body)
        .padding(.vertical, 2)
        .background(Color.gray.opacity(0.04))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.18), lineWidth: 1)
        )
        .onChange(of: isShowingBehavior) { _, newValue in
            if newValue {
                print("HALDEBUG-UI: Behavior section expanded")
            }
        }
    }

    @ViewBuilder
    var behaviorSectionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System Prompt:")
                .font(.body)
                .foregroundStyle(.secondary)
            TextEditor(text: $viewModel.systemPrompt)
                .font(.body)
                .padding(4)
                .frame(minHeight: 60)
                .background(Color.gray.opacity(0.05))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .disableAutocorrection(false)
                .onChange(of: viewModel.systemPrompt) { _, newValue in
                    print("HALDEBUG-MEMORY: System prompt updated (\(newValue.count) characters)")
                    calculateCurrentTokens()
                }
        }
        .padding(4)
    }

    var behaviorSectionLabel: some View {
        Text("Behavior")
            .font(.title3)
    }

    @ViewBuilder
    var longTermMemorySection: some View {
        DisclosureGroup(isExpanded: $isShowingLongTermMemory) {
            longTermMemorySectionBody
        } label: {
            longTermMemorySectionLabel
        }
        .font(.body)
        .padding(.vertical, 2)
        .background(Color.gray.opacity(0.04))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.18), lineWidth: 1)
        )
        .onChange(of: isShowingLongTermMemory) { _, newValue in
            if newValue {
                print("HALDEBUG-UI: Long-term memory section expanded")
            }
        }
    }

    @ViewBuilder
    var longTermMemorySectionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context from Long-Term Memory:")
                .font(.body)
                .foregroundStyle(.secondary)
            
            // Display search results from unified context
            let allSnippets = viewModel.currentUnifiedContext.conversationSnippets + viewModel.currentUnifiedContext.documentSnippets
            let displayText = viewModel.currentUnifiedContext.hasContent ? allSnippets.joined(separator: "\n\n") : "No relevant context found for current conversation."
            
            ScrollView {
                Text(displayText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
            .frame(height: 80)
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            
            // Search debug results display
            if !memoryStore.searchDebugResults.isEmpty {
                Text("Search Analysis:")
                    .font(.body)
                    .foregroundStyle(.secondary)
                
                ScrollView {
                    Text(memoryStore.searchDebugResults)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
                .frame(height: 120)
                .background(Color.gray.opacity(0.05))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                )
            }
            
            // Show hit statistics with actual data
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conversations:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.currentUnifiedContext.conversationSnippets.count)")
                        .font(.caption)
                        .bold()
                        .foregroundColor(viewModel.currentUnifiedContext.conversationSnippets.count > 0 ? .primary : .secondary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Documents:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.currentUnifiedContext.documentSnippets.count)")
                        .font(.caption)
                        .bold()
                        .foregroundColor(viewModel.currentUnifiedContext.documentSnippets.count > 0 ? .primary : .secondary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Entities:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.currentUnifiedContext.entityMatches.count)")
                        .font(.caption)
                        .bold()
                        .foregroundColor(viewModel.currentUnifiedContext.entityMatches.count > 0 ? .primary : .secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total DB:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(memoryStore.totalConversations) conv, \(memoryStore.totalTurns) turns")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Long-Term Memory", isOn: $longTermMemoryEnabled)
                    .font(.body)
                
                Divider()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("🚨 Nuclear Database Operations")
                        .font(.caption)
                        .foregroundColor(.red)
                        .bold()
                    
                    HStack {
                        Button("Nuclear Reset") {
                            showNuclearResetConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundColor(.red)
                        
                        Text("Deletes ALL database data")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(4)
    }

    var longTermMemorySectionLabel: some View {
        HStack {
            Text("Memory: Long Term")
                .font(.title3)
            if !longTermMemoryEnabled {
                Text("(Disabled)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    var shortTermMemorySection: some View {
        DisclosureGroup(isExpanded: $isShowingShortTermMemory) {
            shortTermMemorySectionBody
        } label: {
            shortTermMemorySectionLabel
        }
        .font(.body)
        .padding(.vertical, 2)
        .background(Color.gray.opacity(0.04))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.18), lineWidth: 1)
        )
        .onChange(of: isShowingShortTermMemory) { _, newValue in
            if newValue {
                print("HALDEBUG-UI: Short-term memory section expanded")
            }
        }
    }

    @ViewBuilder
    var shortTermMemorySectionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary (injected when memory depth exceeded):")
                .font(.body)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $viewModel.injectedSummary)
                    .font(.body)
                    .padding(4)
                    .frame(minHeight: 80)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                viewModel.pendingAutoInject ? Color.blue.opacity(0.6) : Color.gray.opacity(0.3),
                                lineWidth: viewModel.pendingAutoInject ? 2 : 1
                            )
                    )
                    .disableAutocorrection(false)
                    .onChange(of: viewModel.injectedSummary) { _, newValue in
                        print("HALDEBUG-MEMORY: Summary updated (\(newValue.count) characters)")
                        calculateCurrentTokens()
                    }
                
                // Single clean auto-inject notification
                if viewModel.pendingAutoInject {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("Will auto-inject on next turn")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            HStack {
                Text("Memory Depth:")
                    .font(.body)
                Stepper("\(memoryDepth)", value: $memoryDepth, in: 1...20)
                    .font(.body)
                    .padding(.vertical, 2)
            }
            
            HStack {
                Toggle("Auto-summarize", isOn: $autoSummarize)
                    .font(.body)
                    .onChange(of: autoSummarize) { _, newValue in
                        print("HALDEBUG-MEMORY: Auto-summarize toggled to \(newValue)")
                    }
                Spacer()
                Button("Debug DB") {
                    print("HALDEBUG-UI: User clicked Debug DB button")
                    debugDatabase()
                }
                .buttonStyle(.bordered)
                Button("Clear Summary") {
                    print("HALDEBUG-MEMORY: User manually cleared summary")
                    viewModel.injectedSummary = ""
                    viewModel.pendingAutoInject = false
                    calculateCurrentTokens()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.injectedSummary.isEmpty)
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .padding(4)
    }

    var shortTermMemorySectionLabel: some View {
        Text("Memory: Short Term")
            .font(.title3)
    }

    @ViewBuilder
    var contextSection: some View {
        DisclosureGroup(isExpanded: $isShowingDebugger) {
            contextSectionBody
        } label: {
            contextSectionLabel
        }
        .font(.body)
        .padding(.vertical, 2)
        .background(Color.gray.opacity(0.04))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.18), lineWidth: 1)
        )
        .onChange(of: isShowingDebugger) { _, newValue in
            if newValue {
                print("HALDEBUG-UI: Context debugger section expanded")
            }
        }
    }

    @ViewBuilder
    var contextSectionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Full prompt sent to model:")
                .font(.body)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(cachedContextString)
                    .font(.body)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
            .border(Color.gray.opacity(0.2), width: 1)
            .onAppear {
                cachedContextString = viewModel.buildPromptHistory(currentInput: "", forPreview: true)
            }
            .onChange(of: viewModel.messages.count) { oldCount, newCount in
                print("HALDEBUG-UI: Context preview updating: \(oldCount) → \(newCount) messages")
                cachedContextString = viewModel.buildPromptHistory(currentInput: "", forPreview: true)
                print("HALDEBUG-UI: Context preview updated: \(cachedContextString.count) characters")
            }
            .onChange(of: viewModel.injectedSummary) { _, _ in
                cachedContextString = viewModel.buildPromptHistory(currentInput: "", forPreview: true)
            }
            .onChange(of: memoryDepth) { _, _ in
                cachedContextString = viewModel.buildPromptHistory(currentInput: "", forPreview: true)
            }
            contextButtons(contextString: cachedContextString)
        }
    }

    @ViewBuilder
    func contextButtons(contextString: String) -> some View {
        HStack {
            Button("Copy") {
                print("HALDEBUG-UI: User copied prompt context (\(contextString.count) characters)")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(contextString, forType: .string)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            Button("Start Over") {
                print("HALDEBUG-UI: User requested conversation reset")
                showResetConfirmation = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    var contextSectionLabel: some View {
        Text("Context")
            .font(.title3)
    }
    
    // Nuclear Database Reset Implementation - MemoryStore manages its own lifecycle
    private func nuclearDatabaseReset() {
        print("HALDEBUG-UI: User requested nuclear database reset")
        
        // Clear UI state first
        viewModel.clearMessages()
        
        // Let MemoryStore handle its own nuclear reset safely
        let success = MemoryStore.shared.performNuclearReset()
        
        if success {
            print("HALDEBUG-UI: ✅ Nuclear reset completed successfully")
            
            // Update UI state after successful reset
            DispatchQueue.main.async {
                // Reset token counts
                self.currentContextTokens = 0
                self.currentHistoricalTokens = 0
                self.currentRecentTokens = 0
                
                print("HALDEBUG-UI: ✅ UI state refreshed after nuclear reset")
            }
        } else {
            print("HALDEBUG-UI: ❌ Nuclear reset encountered issues")
        }
        
        print("HALDEBUG-UI: Nuclear reset process complete")
    }
}
// ========== BLOCK 7: CHATVIEW SECTION DEFINITIONS - END ==========


// ========== BLOCK 8: APP ENTRY POINT WITH DOCUMENT IMPORT MENU - START ==========

struct ChatTranscriptView: View {
    let messages: [ChatMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(messages.sorted(by: { $0.timestamp < $1.timestamp }).enumerated()), id: \.element.id) { index, message in
                        ChatBubbleView(message: message, messageIndex: index)
                            .id(message.id)
                    }
                    // Add invisible spacer to ensure scroll can go past last message
                    Color.clear
                        .frame(height: 20)
                        .id("bottom-spacer")
                }
                .padding(.bottom, 80)
            }
            .onChange(of: messages.count) { _, _ in
                if !messages.sorted(by: { $0.timestamp < $1.timestamp }).isEmpty {
                    print("HALDEBUG-UI: Auto-scrolling to latest message (total: \(messages.count))")
                    proxy.scrollTo("bottom-spacer", anchor: .bottom)
                }
            }
            .onAppear {
                if !messages.isEmpty {
                    print("HALDEBUG-UI: ChatTranscriptView appeared with \(messages.count) messages")
                    proxy.scrollTo("bottom-spacer", anchor: .bottom)
                }
            }
        }
    }
}

@main
struct Hal10000App: App {
    var body: some Scene {
        WindowGroup {
            ChatView()
        }
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Import Documents...") {
                    print("HALDEBUG-IMPORT: User initiated document import from menu")
                    NotificationCenter.default.post(name: .showDocumentImport, object: nil)
                }
                .keyboardShortcut("I", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Export…") {
                    print("HALDEBUG-EXPORT: User initiated export from menu")
                    exportFiles()
                }
                .keyboardShortcut("E", modifiers: [.command, .shift])
            }
        }
    }
    
    init() {
        print("HALDEBUG-GENERAL: Hal10000App initialized with document import support")
    }
}

// MARK: - Export Transcript Functionality
import AppKit

// Export format options
enum ExportFormat: String, CaseIterable {
    case text = "Text"
    case thread = "Thread"
    case dna = "DNA"
    
    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .thread: return "thread"
        case .dna: return "llmdna"
        }
    }
    
    var utType: UTType {
        switch self {
        case .text: return .plainText
        case .thread: return UTType(exportedAs: "com.markfriedlander.halchat.thread", conformingTo: .json)
        case .dna: return UTType(exportedAs: "com.markfriedlander.halchat.llmdna", conformingTo: .json)
        }
    }
}

// Format picker delegate class
private class FormatPickerDelegate: NSObject {
    var onFormatChanged: ((ExportFormat) -> Void)?
    
    @objc func formatChanged(_ sender: NSPopUpButton) {
        let selectedFormat = ExportFormat.allCases[sender.indexOfSelectedItem]
        onFormatChanged?(selectedFormat)
    }
}

// Global variables for format picker and current conversation access
private var selectedFormat: ExportFormat = .thread
private weak var currentSavePanel: NSSavePanel?
private var formatDelegate = FormatPickerDelegate()

// Global reference to access current conversation - set by ChatView
private weak var currentChatViewModel: ChatViewModel?

private func exportFiles() {
    print("HALDEBUG-EXPORT: Starting export process")

    // Get current conversation ID from the active ChatViewModel
    guard let chatViewModel = currentChatViewModel else {
        print("HALDEBUG-EXPORT: ❌ No active ChatViewModel available for export")
        showErrorAlert("No active conversation available for export.")
        return
    }
    
    let conversationId = chatViewModel.conversationId
    print("HALDEBUG-EXPORT: Exporting conversation ID: \(conversationId)")

    // Get current data for export from the ChatViewModel
    let systemPrompt = chatViewModel.systemPrompt
    let memoryDepth = chatViewModel.memoryDepth
    let summary = chatViewModel.injectedSummary
    
    // Get messages from SQLite using the memory store (for accurate export)
    let memoryStore = MemoryStore.shared
    let messages = memoryStore.getConversationMessages(conversationId: conversationId)
    
    print("HALDEBUG-EXPORT: Retrieved \(messages.count) messages from SQLite for conversation \(conversationId)")
    print("HALDEBUG-EXPORT: Array has \(chatViewModel.messages.count) messages for comparison")
    
    // Validate we have messages to export
    if messages.isEmpty {
        print("HALDEBUG-EXPORT: ⚠️ No messages found in database for export")
        let alert = NSAlert()
        alert.messageText = "No Messages to Export"
        alert.informativeText = "This conversation has no stored messages to export. Try sending a message first."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return
    }
    
    // Check for partial messages
    let partialMessages = messages.filter { $0.isPartial }
    if !partialMessages.isEmpty {
        print("HALDEBUG-EXPORT: Found \(partialMessages.count) partial messages, asking user")
        let alert = NSAlert()
        alert.messageText = "Conversation In Progress"
        alert.informativeText = "There are \(partialMessages.count) message(s) still being generated. Do you want to wait for completion or export anyway?"
        alert.addButton(withTitle: "Wait")
        alert.addButton(withTitle: "Export Anyway")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: // Wait
            print("HALDEBUG-EXPORT: User chose to wait for completion")
            return
        case .alertSecondButtonReturn: // Export Anyway
            print("HALDEBUG-EXPORT: User chose to export anyway with partial messages")
            break
        default: // Cancel
            print("HALDEBUG-EXPORT: User cancelled export")
            return
        }
    }

    let savePanel = NSSavePanel()
    currentSavePanel = savePanel
    
    // Create format picker accessory view
    let formatPicker = NSPopUpButton(frame: NSRect.zero, pullsDown: false)
    formatPicker.addItems(withTitles: ExportFormat.allCases.map { $0.rawValue })
    formatPicker.selectItem(withTitle: selectedFormat.rawValue)
    formatPicker.target = formatDelegate
    formatPicker.action = #selector(FormatPickerDelegate.formatChanged(_:))
    formatPicker.sizeToFit()
    
    // Set up format change callback
    formatDelegate.onFormatChanged = { newFormat in
        selectedFormat = newFormat
        print("HALDEBUG-EXPORT: Format changed to \(newFormat.rawValue)")
        
        // Update filename extension
        let currentName = savePanel.nameFieldStringValue
        let nameWithoutExtension = (currentName as NSString).deletingPathExtension
        savePanel.nameFieldStringValue = "\(nameWithoutExtension).\(newFormat.fileExtension)"
        
        // Update allowed content types
        savePanel.allowedContentTypes = [newFormat.utType]
    }
    
    let label = NSTextField(labelWithString: "Format:")
    label.alignment = .right
    
    // Create container view that centers the content
    let contentView = NSView()
    contentView.addSubview(label)
    contentView.addSubview(formatPicker)
    
    let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
    accessoryView.addSubview(contentView)
    
    // Layout constraints for centered content
    label.translatesAutoresizingMaskIntoConstraints = false
    formatPicker.translatesAutoresizingMaskIntoConstraints = false
    contentView.translatesAutoresizingMaskIntoConstraints = false
    
    NSLayoutConstraint.activate([
        // Content view centered in accessory view
        contentView.centerXAnchor.constraint(equalTo: accessoryView.centerXAnchor),
        contentView.centerYAnchor.constraint(equalTo: accessoryView.centerYAnchor),
        
        // Label and picker layout within content view
        label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
        label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        
        formatPicker.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
        formatPicker.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        formatPicker.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        
        // Content view size constraints
        contentView.topAnchor.constraint(equalTo: label.topAnchor),
        contentView.bottomAnchor.constraint(equalTo: label.bottomAnchor)
    ])
    
    savePanel.accessoryView = accessoryView
    savePanel.nameFieldStringValue = "Hal10000_Transcript.\(selectedFormat.fileExtension)"
    savePanel.title = "Export Conversation"
    savePanel.allowsOtherFileTypes = false
    savePanel.isExtensionHidden = false
    savePanel.allowedContentTypes = [selectedFormat.utType]
    
    print("HALDEBUG-EXPORT: Showing save panel for \(selectedFormat.rawValue) format")
    
    savePanel.begin { result in
        currentSavePanel = nil
        if result == .OK, let url = savePanel.url {
            print("HALDEBUG-EXPORT: User selected file: \(url.lastPathComponent)")
            switch selectedFormat {
            case .text:
                exportPlainTextTranscript(to: url, messages: messages, systemPrompt: systemPrompt)
            case .thread:
                exportThreadFile(to: url, messages: messages, systemPrompt: systemPrompt, memoryDepth: memoryDepth, summary: summary)
            case .dna:
                exportPersonalityDNA(to: url, systemPrompt: systemPrompt)
            }
        } else {
            print("HALDEBUG-EXPORT: User cancelled save panel")
        }
    }
}

// Helper function to set the current ChatViewModel for export access
func setCurrentChatViewModel(_ viewModel: ChatViewModel) {
    currentChatViewModel = viewModel
    print("HALDEBUG-EXPORT: Set current ChatViewModel for export: \(viewModel.conversationId)")
}

// Export function implementations with proper message handling
private func exportPlainTextTranscript(to url: URL, messages: [ChatMessage], systemPrompt: String) {
    print("HALDEBUG-EXPORT: Exporting plain text transcript to \(url.lastPathComponent)")
    
    let sortedMessages = messages.sorted(by: { $0.timestamp < $1.timestamp })
    
    var content = "# Hal10000 Conversation Transcript\n"
    content += "Generated: \(Date().formatted(date: .abbreviated, time: .standard))\n"
    content += "System Prompt: \(systemPrompt)\n"
    content += "Total Messages: \(sortedMessages.count)\n\n"
    content += String(repeating: "=", count: 50) + "\n\n"
    
    for (index, message) in sortedMessages.enumerated() {
        let speaker = message.isFromUser ? "User" : "Assistant"
        let timestamp = message.timestamp.formatted(date: .abbreviated, time: .shortened)
        let status = message.isPartial ? " [INCOMPLETE]" : ""
        
        content += "[\(index + 1)] \(speaker) - \(timestamp)\(status)\n"
        content += message.content + "\n\n"
    }
    
    do {
        try content.write(to: url, atomically: true, encoding: .utf8)
        print("HALDEBUG-EXPORT: ✅ Successfully exported plain text transcript (\(content.count) characters)")
    } catch {
        print("HALDEBUG-EXPORT: ❌ Failed to export transcript: \(error.localizedDescription)")
        showErrorAlert("Failed to export transcript: \(error.localizedDescription)")
    }
}

private func exportThreadFile(to url: URL, messages: [ChatMessage], systemPrompt: String, memoryDepth: Int, summary: String) {
    print("HALDEBUG-EXPORT: Exporting thread file to \(url.lastPathComponent)")
    
    let sortedMessages = messages.sorted(by: { $0.timestamp < $1.timestamp })
    
    // Generate conversation title from first user message or use default
    let title = sortedMessages.first(where: { $0.isFromUser })?.content.prefix(50).description ?? "Hal10000 Conversation"
    
    // Calculate conversation statistics
    let userMessageCount = sortedMessages.filter { $0.isFromUser }.count
    let assistantMessageCount = sortedMessages.filter { !$0.isFromUser }.count
    let totalWords = sortedMessages.reduce(0) { $0 + $1.content.split(separator: " ").count }
    
    let threadData: [String: Any] = [
        "formatVersion": "1.0",
        "exportedAt": ISO8601DateFormatter().string(from: Date()),
        "conversation": [
            "title": title,
            "id": currentChatViewModel?.conversationId ?? "unknown",
            "created": ISO8601DateFormatter().string(from: sortedMessages.first?.timestamp ?? Date()),
            "lastModified": ISO8601DateFormatter().string(from: sortedMessages.last?.timestamp ?? Date()),
            "messageCount": sortedMessages.count,
            "userMessageCount": userMessageCount,
            "assistantMessageCount": assistantMessageCount,
            "totalWords": totalWords
        ],
        "settings": [
            "memoryDepth": memoryDepth,
            "summary": summary,
            "systemPrompt": systemPrompt
        ],
        "persona": [
            "name": "Hal10000",
            "version": "1.0",
            "settings": [
                "tone": "curious",
                "cooperative": true
            ]
        ],
        "messages": sortedMessages.map { message in
            var messageData: [String: Any] = [
                "role": message.isFromUser ? "user" : "assistant",
                "timestamp": ISO8601DateFormatter().string(from: message.timestamp),
                "content": message.content,
                "wordCount": message.content.split(separator: " ").count
            ]
            
            if message.isPartial {
                messageData["isPartial"] = true
            }
            
            if let duration = message.thinkingDuration {
                messageData["thinkingDuration"] = duration
            }
            
            return messageData
        }
    ]
    
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: threadData, options: .prettyPrinted)
        try jsonData.write(to: url)
        print("HALDEBUG-EXPORT: ✅ Successfully exported thread file (\(jsonData.count) bytes)")
        print("HALDEBUG-EXPORT:   Conversation: \(title)")
        print("HALDEBUG-EXPORT:   Messages: \(sortedMessages.count) (\(userMessageCount) user, \(assistantMessageCount) assistant)")
        print("HALDEBUG-EXPORT:   Total words: \(totalWords)")
    } catch {
        print("HALDEBUG-EXPORT: ❌ Failed to export thread file: \(error.localizedDescription)")
        showErrorAlert("Failed to export thread file: \(error.localizedDescription)")
    }
}

private func exportPersonalityDNA(to url: URL, systemPrompt: String) {
    print("HALDEBUG-EXPORT: Exporting personality DNA to \(url.lastPathComponent)")
    
    let dnaData: [String: Any] = [
        "formatVersion": "1.0",
        "exportedAt": ISO8601DateFormatter().string(from: Date()),
        "personality": [
            "name": "Hal10000",
            "version": "1.0",
            "systemPrompt": systemPrompt,
            "description": "An experimental AI assistant for exploring conversation dynamics and memory systems"
        ],
        "settings": [
            "tone": "curious",
            "cooperative": true,
            "experimental": true
        ],
        "capabilities": [
            "conversationMemory",
            "contextualSearch",
            "summarization",
            "entityRecognition",
            "documentImport"
        ]
    ]
    
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: dnaData, options: .prettyPrinted)
        try jsonData.write(to: url)
        print("HALDEBUG-EXPORT: ✅ Successfully exported personality DNA (\(jsonData.count) bytes)")
    } catch {
        print("HALDEBUG-EXPORT: ❌ Failed to export personality DNA: \(error.localizedDescription)")
        showErrorAlert("Failed to export personality DNA: \(error.localizedDescription)")
    }
}

private func showErrorAlert(_ message: String) {
    print("HALDEBUG-EXPORT: Showing error alert: \(message)")
    DispatchQueue.main.async {
        let alert = NSAlert()
        alert.messageText = "Export Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// ========== BLOCK 8: APP ENTRY POINT WITH DOCUMENT IMPORT MENU - END ==========


// ========== BLOCK 9: CONVERSATION STORAGE AND UNIFIED SEARCH SYSTEM - START ==========

// MARK: - Conversation Storage and Unified Search System
extension MemoryStore {
    
    // COMMENTED OUT: Extract entities from text using Apple's NaturalLanguage
    // Reason: Simplified embedding system doesn't use entity enhancement
    // Can be restored when entity features are re-enabled
    /*
    func extractEntities(from text: String) -> [NamedEntity] {
        print("HALDEBUG-ENTITY: Extracting entities from text length \(text.count)")
        
        var entities: [NamedEntity] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            guard let tag = tag else { return true }
            
            let tokenText = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tokenText.isEmpty else { return true }
            
            let entityType: NamedEntity.EntityType
            switch tag {
            case .personalName:
                entityType = .person
            case .placeName:
                entityType = .place
            case .organizationName:
                entityType = .organization
            default:
                entityType = .other
            }
            
            let nsRange = NSRange(tokenRange, in: text)
            let entity = NamedEntity(text: tokenText, type: entityType, range: nsRange)
            entities.append(entity)
            
            return true
        }
        
        print("HALDEBUG-ENTITY: Extracted \(entities.count) entities")
        return entities
    }
    */
    
    // Store conversation turn in unified memory (SIMPLIFIED - no entities)
    func storeTurn(conversationId: String, userMessage: String, assistantMessage: String, systemPrompt: String, turnNumber: Int) {
        print("HALDEBUG-MEMORY: Storing turn \(turnNumber) for conversation \(conversationId)")
        
        guard ensureHealthyConnection() else {
            print("HALDEBUG-MEMORY: Cannot store turn - no database connection")
            return
        }
        
        // Store user message (SIMPLIFIED - no entity extraction)
        let userContentId = storeUnifiedContent(
            content: userMessage,
            sourceType: .conversation,
            sourceId: conversationId,
            position: turnNumber * 2 - 1,
            timestamp: Date()
        )
        
        // Store assistant message (SIMPLIFIED - no entity extraction)
        let assistantContentId = storeUnifiedContent(
            content: assistantMessage,
            sourceType: .conversation,
            sourceId: conversationId,
            position: turnNumber * 2,
            timestamp: Date()
        )
        
        print("HALDEBUG-MEMORY: Stored turn \(turnNumber) - user: \(userContentId), assistant: \(assistantContentId)")
        
        // Update conversation statistics
        loadUnifiedStats()
    }
    
    // Store unified content with embeddings (SIMPLIFIED - no entities)
    func storeUnifiedContent(content: String, sourceType: ContentSourceType, sourceId: String, position: Int, timestamp: Date) -> String {
        print("HALDEBUG-MEMORY: Storing unified content - type: \(sourceType), position: \(position)")
        
        guard ensureHealthyConnection() else {
            print("HALDEBUG-MEMORY: Cannot store content - no database connection")
            return ""
        }
        
        let contentId = UUID().uuidString
        let embedding = generateEmbedding(for: content) // SIMPLIFIED - no entities parameter
        let embeddingBlob = embedding.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        
        let sql = """
        INSERT OR REPLACE INTO unified_content 
        (id, content, embedding, timestamp, source_type, source_id, position, is_from_user, entity_count, metadata_json) 
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        var stmt: OpaquePointer?
        defer {
            if stmt != nil {
                sqlite3_finalize(stmt)
            }
        }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("HALDEBUG-MEMORY: Failed to prepare content insert")
            return ""
        }
        
        let isFromUser = (sourceType == .conversation && position % 2 == 1) ? 1 : 0
        
        _ = contentId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, nil) }
        _ = content.withCString { sqlite3_bind_text(stmt, 2, $0, -1, nil) }
        _ = embeddingBlob.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(embeddingBlob.count), nil) }
        sqlite3_bind_int64(stmt, 4, Int64(timestamp.timeIntervalSince1970))
        _ = sourceType.rawValue.withCString { sqlite3_bind_text(stmt, 5, $0, -1, nil) }
        _ = sourceId.withCString { sqlite3_bind_text(stmt, 6, $0, -1, nil) }
        sqlite3_bind_int(stmt, 7, Int32(position))
        sqlite3_bind_int(stmt, 8, Int32(isFromUser))
        sqlite3_bind_int(stmt, 9, 0) // SIMPLIFIED - no entities, so count is 0
        _ = "{}".withCString { sqlite3_bind_text(stmt, 10, $0, -1, nil) } // Empty metadata
        
        if sqlite3_step(stmt) == SQLITE_DONE {
            print("HALDEBUG-MEMORY: Stored content successfully - ID: \(contentId)")
            return contentId
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("HALDEBUG-MEMORY: Failed to store content: \(errorMessage)")
            return ""
        }
    }
    
    // Retrieve conversation messages for display
    func getConversationMessages(conversationId: String) -> [ChatMessage] {
        print("HALDEBUG-MEMORY: Loading messages for conversation: \(conversationId)")
        
        guard ensureHealthyConnection() else {
            print("HALDEBUG-MEMORY: Cannot load messages - no database connection")
            return []
        }
        
        var messages: [ChatMessage] = []
        
        let sql = """
        SELECT content, is_from_user, timestamp, position 
        FROM unified_content 
        WHERE source_type = 'conversation' AND source_id = ? 
        ORDER BY position ASC;
        """
        
        var stmt: OpaquePointer?
        defer {
            if stmt != nil {
                sqlite3_finalize(stmt)
            }
        }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("HALDEBUG-MEMORY: Failed to prepare message query")
            return []
        }
        
        _ = conversationId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, nil) }
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let contentCString = sqlite3_column_text(stmt, 0) else { continue }
            
            let content = String(cString: contentCString)
            let isFromUser = sqlite3_column_int(stmt, 1) == 1
            let timestampValue = sqlite3_column_int64(stmt, 2)
            let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampValue))
            
            let message = ChatMessage(
                content: content,
                isFromUser: isFromUser,
                timestamp: timestamp,
                isPartial: false
            )
            messages.append(message)
        }
        
        print("HALDEBUG-MEMORY: Loaded \(messages.count) messages for conversation \(conversationId)")
        return messages
    }
    
    // Search unified content across conversations and documents (SIMPLIFIED - no entity matching)
    func searchUnifiedContent(for query: String, currentConversationId: String, excludingRecentTurns: Int, maxResults: Int) -> UnifiedSearchContext {
        print("HALDEBUG-SEARCH: Searching unified content for: '\(query)'")
        
        guard ensureHealthyConnection() else {
            print("HALDEBUG-SEARCH: Cannot search - no database connection")
            return UnifiedSearchContext(conversationSnippets: [], documentSnippets: [], entityMatches: [], relevanceScores: [], totalTokens: 0)
        }
        
        let queryEmbedding = generateEmbedding(for: query) // SIMPLIFIED - no entities
        var conversationSnippets: [String] = []
        var documentSnippets: [String] = []
        var relevanceScores: [Double] = []
        
        // Search documents
        let documentSQL = """
        SELECT content, embedding 
        FROM unified_content 
        WHERE source_type = 'document' 
        ORDER BY timestamp DESC 
        LIMIT 50;
        """
        
        var documentStmt: OpaquePointer?
        defer {
            if documentStmt != nil {
                sqlite3_finalize(documentStmt)
            }
        }
        
        if sqlite3_prepare_v2(db, documentSQL, -1, &documentStmt, nil) == SQLITE_OK {
            while sqlite3_step(documentStmt) == SQLITE_ROW {
                guard let contentCString = sqlite3_column_text(documentStmt, 0),
                      let embeddingBlob = sqlite3_column_blob(documentStmt, 1) else { continue }
                
                let content = String(cString: contentCString)
                let embeddingSize = sqlite3_column_bytes(documentStmt, 1)
                let embeddingData = Data(bytes: embeddingBlob, count: Int(embeddingSize))
                
                let embedding = embeddingData.withUnsafeBytes { buffer in
                    return buffer.bindMemory(to: Double.self).map { $0 }
                }
                
                let similarity = cosineSimilarity(queryEmbedding, embedding)
                
                if similarity >= relevanceThreshold {
                    documentSnippets.append(content)
                    relevanceScores.append(similarity)
                    
                    if documentSnippets.count >= maxResults / 2 {
                        break
                    }
                }
            }
        }
        
        // Search conversations (excluding current)
        let conversationSQL = """
        SELECT content, embedding 
        FROM unified_content 
        WHERE source_type = 'conversation' 
        AND source_id != ? 
        ORDER BY timestamp DESC 
        LIMIT 50;
        """
        
        var conversationStmt: OpaquePointer?
        defer {
            if conversationStmt != nil {
                sqlite3_finalize(conversationStmt)
            }
        }
        
        if sqlite3_prepare_v2(db, conversationSQL, -1, &conversationStmt, nil) == SQLITE_OK {
            _ = currentConversationId.withCString { sqlite3_bind_text(conversationStmt, 1, $0, -1, nil) }
            
            while sqlite3_step(conversationStmt) == SQLITE_ROW {
                guard let contentCString = sqlite3_column_text(conversationStmt, 0),
                      let embeddingBlob = sqlite3_column_blob(conversationStmt, 1) else { continue }
                
                let content = String(cString: contentCString)
                let embeddingSize = sqlite3_column_bytes(conversationStmt, 1)
                let embeddingData = Data(bytes: embeddingBlob, count: Int(embeddingSize))
                
                let embedding = embeddingData.withUnsafeBytes { buffer in
                    return buffer.bindMemory(to: Double.self).map { $0 }
                }
                
                let similarity = cosineSimilarity(queryEmbedding, embedding)
                
                if similarity >= relevanceThreshold {
                    conversationSnippets.append(content)
                    relevanceScores.append(similarity)
                    
                    if conversationSnippets.count >= maxResults / 2 {
                        break
                    }
                }
            }
        }
        
        // SIMPLIFIED: No entity search for now
        let entityMatches: [String] = []
        
        /*
        // COMMENTED OUT: Entity search functionality
        // Search for entity matches
        let entitySQL = """
        SELECT DISTINCT entity_text
        FROM unified_entities
        WHERE LOWER(entity_text) LIKE ?
        LIMIT 10;
        """
        
        var entityStmt: OpaquePointer?
        defer {
            if entityStmt != nil {
                sqlite3_finalize(entityStmt)
            }
        }
        
        if sqlite3_prepare_v2(db, entitySQL, -1, &entityStmt, nil) == SQLITE_OK {
            let searchPattern = "%\(query.lowercased())%"
            _ = searchPattern.withCString { sqlite3_bind_text(entityStmt, 1, $0, -1, nil) }
            
            while sqlite3_step(entityStmt) == SQLITE_ROW {
                if let entityCString = sqlite3_column_text(entityStmt, 0) {
                    let entity = String(cString: entityCString)
                    entityMatches.append(entity)
                }
            }
        }
        */
        
        let totalTokens = (conversationSnippets + documentSnippets).map { $0.split(separator: " ").count }.reduce(0, +)
        
        print("HALDEBUG-SEARCH: Found \(conversationSnippets.count) conversation + \(documentSnippets.count) document snippets")
        
        return UnifiedSearchContext(
            conversationSnippets: conversationSnippets,
            documentSnippets: documentSnippets,
            entityMatches: entityMatches,
            relevanceScores: relevanceScores,
            totalTokens: totalTokens
        )
    }
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let showDocumentImport = Notification.Name("showDocumentImport")
}

// ========== BLOCK 9: CONVERSATION STORAGE AND UNIFIED SEARCH SYSTEM - END ==========



// ========== BLOCK 10: DOCUMENT IMPORT MANAGER IMPLEMENTATION - START ==========

// MARK: - Document Import Manager with Enhanced Processing Pipeline
@MainActor
class DocumentImportManager: ObservableObject {
    static let shared = DocumentImportManager()
    
    @Published var isImporting: Bool = false
    @Published var importProgress: String = ""
    @Published var lastImportSummary: DocumentImportSummary?
    
    private let memoryStore = MemoryStore.shared
    private let supportedFormats: [String: String] = [
        "txt": "Plain Text",
        "md": "Markdown",
        "rtf": "Rich Text Format",
        "pdf": "PDF Document",
        "docx": "Microsoft Word",
        "doc": "Microsoft Word (Legacy)",
        "xlsx": "Microsoft Excel",
        "xls": "Microsoft Excel (Legacy)",
        "pptx": "Microsoft PowerPoint",
        "ppt": "Microsoft PowerPoint (Legacy)",
        "csv": "Comma Separated Values",
        "json": "JSON Data",
        "xml": "XML Document",
        "html": "HTML Document",
        "htm": "HTML Document",
        "epub": "EPUB eBook"
    ]
    
    private init() {}
    
    // Main Import Function using processing pattern with HAL features (SIMPLIFIED - no entities)
    func importDocuments(from urls: [URL], chatViewModel: ChatViewModel) async {
        print("HALDEBUG-IMPORT: Starting document import for \(urls.count) items using processing pattern")
        
        isImporting = true
        importProgress = "Processing documents..."
        
        var processedFiles: [ProcessedDocument] = []
        var skippedFiles: [String] = []
        var totalFilesFound = 0
        
        // Process files immediately while security access is active
        for url in urls {
            print("HALDEBUG-IMPORT: Processing URL: \(url.lastPathComponent)")
            
            // Start accessing security-scoped resource
            let hasAccess = url.startAccessingSecurityScopedResource()
            if !hasAccess {
                print("HALDEBUG-IMPORT: Failed to gain security access to: \(url.lastPathComponent)")
                skippedFiles.append(url.lastPathComponent)
                continue
            }
            
            // Create security bookmark for persistence
            do {
                let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmarkData, forKey: "selectedItem_\(url.lastPathComponent)")
                print("HALDEBUG-IMPORT: Security bookmark saved for \(url.lastPathComponent)")
            } catch {
                print("HALDEBUG-IMPORT: Failed to create security bookmark for \(url.lastPathComponent): \(error)")
            }
            
            // Process files immediately while access is active
            let (filesProcessed, filesSkipped) = await processURLImmediately(url)
            processedFiles.append(contentsOf: filesProcessed)
            skippedFiles.append(contentsOf: filesSkipped)
            totalFilesFound += filesProcessed.count + filesSkipped.count
            
            // Update progress after each URL
            importProgress = "Processed \(url.lastPathComponent): \(filesProcessed.count) files"
            
            // Release security access after processing is complete
            url.stopAccessingSecurityScopedResource()
            print("HALDEBUG-IMPORT: Released security access for \(url.lastPathComponent)")
        }
        
        print("HALDEBUG-IMPORT: Processed \(processedFiles.count) documents, skipped \(skippedFiles.count)")
        
        // Generate LLM summaries for processed documents
        importProgress = "Analyzing content with AI..."
        var documentSummaries: [String] = []
        
        for processed in processedFiles {
            if let summary = await generateDocumentSummary(processed) {
                documentSummaries.append(summary)
            } else {
                documentSummaries.append("Document: \(processed.filename)")
            }
        }
        
        // Store documents in unified memory using simplified embedding system
        importProgress = "Storing documents in memory..."
        await storeDocumentsInMemory(processedFiles)
        
        // Generate conversation messages
        await generateImportMessages(documentSummaries: documentSummaries,
                                   totalProcessed: processedFiles.count,
                                   chatViewModel: chatViewModel)
        
        // Create import summary
        lastImportSummary = DocumentImportSummary(
            totalFiles: totalFilesFound,
            processedFiles: processedFiles.count,
            skippedFiles: skippedFiles.count,
            documentSummaries: documentSummaries,
            processingTime: 0
        )
        
        isImporting = false
        importProgress = "Import complete!"
        
        print("HALDEBUG-IMPORT: Document import completed using processing pattern")
    }
    
    // Process URL immediately while security access is active
    private func processURLImmediately(_ url: URL) async -> ([ProcessedDocument], [String]) {
        var processedFiles: [ProcessedDocument] = []
        var skippedFiles: [String] = []
        
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            print("HALDEBUG-IMPORT: File doesn't exist: \(url.path)")
            skippedFiles.append(url.lastPathComponent)
            return (processedFiles, skippedFiles)
        }
        
        if isDirectory.boolValue {
            // Process directory contents immediately
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                for item in contents {
                    let (subProcessed, subSkipped) = await processURLImmediately(item)
                    processedFiles.append(contentsOf: subProcessed)
                    skippedFiles.append(contentsOf: subSkipped)
                }
                print("HALDEBUG-IMPORT: Processed directory \(url.lastPathComponent): \(processedFiles.count) files")
            } catch {
                print("HALDEBUG-IMPORT: Error reading directory \(url.path): \(error)")
                skippedFiles.append(url.lastPathComponent)
            }
        } else {
            // Process individual file immediately
            if let processed = await processDocumentImmediately(url) {
                processedFiles.append(processed)
                print("HALDEBUG-IMPORT: Successfully processed: \(url.lastPathComponent)")
            } else {
                skippedFiles.append(url.lastPathComponent)
                print("HALDEBUG-IMPORT: Skipped: \(url.lastPathComponent)")
            }
        }
        
        return (processedFiles, skippedFiles)
    }
    
    // Process document immediately while access is active (SIMPLIFIED - no entities)
    private func processDocumentImmediately(_ url: URL) async -> ProcessedDocument? {
        print("HALDEBUG-IMPORT: Processing document immediately: \(url.lastPathComponent)")
        
        let fileExtension = url.pathExtension.lowercased()
        guard supportedFormats.keys.contains(fileExtension) else {
            print("HALDEBUG-IMPORT: Unsupported format: \(fileExtension)")
            return nil
        }
        
        do {
            // Extract content while security access is active
            let content = try extractContent(from: url, fileExtension: fileExtension)
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("HALDEBUG-IMPORT: Skipping empty document: \(url.lastPathComponent)")
                return nil
            }
            
            // Process content immediately using proven chunking (SIMPLIFIED - no entities)
            // let entities = extractEntities(from: content) // COMMENTED OUT - no entity extraction
            let chunks = createMentatChunks(from: content)
            
            print("HALDEBUG-IMPORT: Processed \(url.lastPathComponent): \(content.count) chars, \(chunks.count) chunks")
            
            return ProcessedDocument(
                url: url,
                filename: url.lastPathComponent,
                content: content,
                chunks: chunks,
                fileExtension: fileExtension
            )
            
        } catch {
            print("HALDEBUG-IMPORT: Error processing \(url.lastPathComponent): \(error)")
            return nil
        }
    }
    
    // Content Extraction
    private func extractContent(from url: URL, fileExtension: String) throws -> String {
        print("HALDEBUG-IMPORT: Extracting content from \(url.lastPathComponent) (.\(fileExtension))")
        
        do {
            switch fileExtension.lowercased() {
            case "txt", "md":
                let content = try String(contentsOf: url, encoding: .utf8)
                print("HALDEBUG-IMPORT: Extracted \(content.count) chars from text file")
                return content
            case "pdf":
                let content = extractPDFContent(from: url)
                print("HALDEBUG-IMPORT: Extracted \(content.count) chars from PDF")
                return content
            default:
                let content = try extractUsingTextutil(from: url)
                print("HALDEBUG-IMPORT: Extracted \(content.count) chars using textutil")
                return content
            }
        } catch {
            print("HALDEBUG-IMPORT: Content extraction failed for \(url.lastPathComponent): \(error)")
            throw error
        }
    }
    
    private func extractPDFContent(from url: URL) -> String {
        guard let document = PDFDocument(url: url) else {
            print("HALDEBUG-IMPORT: Failed to load PDF document")
            return ""
        }
        
        var text = ""
        for pageIndex in 0..<document.pageCount {
            if let page = document.page(at: pageIndex) {
                text += page.string ?? ""
                text += "\n\n"
            }
        }
        
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        print("HALDEBUG-IMPORT: PDF: \(result.count) chars from \(document.pageCount) pages")
        return result
    }
    
    private func extractUsingTextutil(from url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let result = String(data: data, encoding: .utf8) ?? ""
        
        if process.terminationStatus != 0 {
            print("HALDEBUG-IMPORT: textutil exited with code \(process.terminationStatus)")
        }
        
        print("HALDEBUG-IMPORT: TEXTUTIL: \(result.count) characters extracted")
        return result
    }
    
    // Proven Chunking Strategy (400 chars, 50 overlap)
    private func createMentatChunks(from content: String, targetSize: Int = 400, overlap: Int = 50) -> [String] {
        let cleanedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if cleanedContent.count <= targetSize {
            return [cleanedContent]
        }
        
        // Split into sentences using NaturalLanguage
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = cleanedContent
        
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: cleanedContent.startIndex..<cleanedContent.endIndex) { range, _ in
            let sentence = String(cleanedContent[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        
        // Build chunks by combining sentences up to target size
        var chunks: [String] = []
        var currentChunk = ""
        var sentenceIndex = 0
        
        while sentenceIndex < sentences.count {
            let sentence = sentences[sentenceIndex]
            
            if !currentChunk.isEmpty && (currentChunk.count + sentence.count + 1) > targetSize {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                
                // Start new chunk with overlap
                let overlapWords = currentChunk.suffix(overlap)
                currentChunk = String(overlapWords)
                if !currentChunk.isEmpty {
                    currentChunk += " "
                }
            }
            
            if !currentChunk.isEmpty {
                currentChunk += " "
            }
            currentChunk += sentence
            sentenceIndex += 1
        }
        
        if !currentChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        print("HALDEBUG-IMPORT: Created \(chunks.count) chunks using strategy")
        return chunks
    }
    
    // COMMENTED OUT: Entity Extraction
    // Reason: Simplified embedding system doesn't use entity enhancement
    /*
    private func extractEntities(from text: String) -> [NamedEntity] {
        return memoryStore.extractEntities(from: text)
    }
    */
    
    // LLM Document Summarization
    private func generateDocumentSummary(_ document: ProcessedDocument) async -> String? {
        print("HALDEBUG-IMPORT: Generating LLM summary for: \(document.filename)")
        
        // Check if Apple Intelligence is available
        guard #available(macOS 26.0, iOS 26.0, *) else {
            return "Document: \(document.filename)"
        }
        
        let systemModel = SystemLanguageModel.default
        guard systemModel.isAvailable else {
            return "Document: \(document.filename)"
        }
        
        do {
            let contentPreview = String(document.content.prefix(500))
            let prompt = """
            Summarize this document in one clear, descriptive sentence (filename: \(document.filename)):
            
            \(contentPreview)
            """
            
            let session = LanguageModelSession()
            let result = try await session.respond(to: Prompt(prompt))
            
            let summary = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
            print("HALDEBUG-IMPORT: Generated summary: \(summary)")
            return summary
            
        } catch {
            print("HALDEBUG-IMPORT: LLM summarization failed for \(document.filename): \(error)")
            return "Document: \(document.filename)"
        }
    }
    
    // Unified Memory Storage using simplified embeddings (SIMPLIFIED - no entities)
    private func storeDocumentsInMemory(_ documents: [ProcessedDocument]) async {
        print("HALDEBUG-IMPORT: Storing \(documents.count) documents in unified memory")
        
        for document in documents {
            // Store source information
            let sourceId = UUID().uuidString
            let timestamp = Date()
            
            // Store each chunk as unified content using simplified embedding system (no entities)
            for (index, chunk) in document.chunks.enumerated() {
                let contentId = memoryStore.storeUnifiedContent(
                    content: chunk,
                    sourceType: .document,
                    sourceId: sourceId,
                    position: index,
                    timestamp: timestamp
                )
                
                if !contentId.isEmpty {
                    print("HALDEBUG-IMPORT: Stored chunk \(index + 1)/\(document.chunks.count) for \(document.filename)")
                }
            }
        }
        
        print("HALDEBUG-IMPORT: Document storage completed")
    }
    
    // Conversation Message Generation
    private func generateImportMessages(documentSummaries: [String],
                                      totalProcessed: Int,
                                      chatViewModel: ChatViewModel) async {
        print("HALDEBUG-IMPORT: Generating import conversation messages")
        
        // Create user auto-message
        let userMessage: String
        if documentSummaries.count == 1 {
            userMessage = "Hal, here's a document for you: \(documentSummaries[0])"
        } else {
            let numberedList = documentSummaries.enumerated().map { (index, summary) in
                "\(index + 1)) \(summary)"
            }.joined(separator: ", ")
            userMessage = "Hal, here are \(documentSummaries.count) documents for you: \(numberedList)"
        }
        
        // Add user message to conversation
        let userChatMessage = ChatMessage(content: userMessage, isFromUser: true)
        chatViewModel.messages.append(userChatMessage)
        
        // Generate HAL's response
        let halResponse: String
        if documentSummaries.count == 1 {
            halResponse = "Thanks for sharing that document! I've read through it and I'm ready to discuss any questions you have about the content."
        } else {
            halResponse = "Thanks for those \(documentSummaries.count) documents! I've read through all of them and I'm ready to discuss any aspect of the material you'd like to explore."
        }
        
        // Add HAL's response
        let halChatMessage = ChatMessage(content: halResponse, isFromUser: false)
        chatViewModel.messages.append(halChatMessage)
        
        // Store the conversation turn in memory
        let currentTurnNumber = chatViewModel.messages.filter { $0.isFromUser }.count
        memoryStore.storeTurn(
            conversationId: chatViewModel.conversationId,
            userMessage: userMessage,
            assistantMessage: halResponse,
            systemPrompt: chatViewModel.systemPrompt,
            turnNumber: currentTurnNumber
        )
        
        print("HALDEBUG-IMPORT: Generated import conversation messages")
    }
}

// MARK: - Supporting Data Models (SIMPLIFIED - no entities)
struct ProcessedDocument {
    let url: URL
    let filename: String
    let content: String
    let chunks: [String]
    // let entities: [NamedEntity] // COMMENTED OUT - no entity extraction
    let fileExtension: String
}

struct DocumentImportSummary {
    let totalFiles: Int
    let processedFiles: Int
    let skippedFiles: Int
    let documentSummaries: [String]
    let processingTime: TimeInterval
}

// ========== BLOCK 10: DOCUMENT IMPORT MANAGER IMPLEMENTATION - END ==========
