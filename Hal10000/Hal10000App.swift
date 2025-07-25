// ========== BLOCK 1: MEMORY MODELS AND DATABASE SETUP - START ==========
//
//  ContentView.swift
//  Mentat
//
//  Created by Mark Friedlander on 6/9/25.
//

import SwiftUI
import Foundation
import Combine
import Observation
import FoundationModels
import UniformTypeIdentifiers
import SQLite3
import NaturalLanguage
import PDFKit

// MARK: - Named Entity Support
struct NamedEntity: Codable, Hashable {
    let text: String        // e.g., "Mark Friedlander"
    let type: EntityType    // e.g., .person
    
    enum EntityType: String, Codable, CaseIterable {
        case person = "person"           // People: "Mark Friedlander", "Elon Musk"
        case place = "place"             // Locations: "New York", "Paris"
        case organization = "org"        // Companies: "Apple", "Google"
        case other = "other"             // Other recognized entities by NL framework (we will filter these out for storage)
        
        var displayName: String {
            switch self {
            case .person: return "Person"
            case .place: return "Place"
            case .organization: return "Organization"
            case .other: return "Other"
            }
        }
    }
}

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

// MARK: - Enhanced Search Context with Entity Support
struct UnifiedSearchResult: Identifiable, Hashable {
    let id = UUID()
    let content: String
    var relevance: Double  // FIXED: Changed from 'let' to 'var' to allow Block 9 fusion logic to boost scores
    let source: String
    var isEntityMatch: Bool // NEW PROPERTY to track if snippet was found via entity search
}

// MARK: - Memory Store with Persistent Database Connection
class MemoryStore: ObservableObject {
    static let shared = MemoryStore()
    
    @Published var isEnabled: Bool = true
    @AppStorage("relevanceThreshold") var relevanceThreshold: Double = 0.65
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
                // Continue anyway - partial cleanup is better than none
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
    
    // Create simplified unified schema with entity support - MATCHES Block 9 exactly
    private func createUnifiedSchema() {
        guard ensureHealthyConnection() else {
            print("HALDEBUG-DATABASE: ❌ Cannot create schema - no database connection")
            return
        }
        
        print("HALDEBUG-DATABASE: Creating unified database schema with entity support...")
        
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
            metadata_json TEXT,
            content_hash TEXT,
            file_size INTEGER DEFAULT 0
        );
        """
        
        // ENHANCED SCHEMA: Add entity_keywords column for entity-based search
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
            entity_keywords TEXT,
            metadata_json TEXT,
            created_at INTEGER DEFAULT (strftime('%s', 'now')),
            UNIQUE(source_type, source_id, position)
        );
        """
        
        // Execute schema creation with proper error handling
        let tables = [
            ("sources", sourcesSQL),
            ("unified_content", unifiedContentSQL)
        ]
        
        for (tableName, sql) in tables {
            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
                print("HALDEBUG-DATABASE: ✅ Created \(tableName) table with entity support")
            } else {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                print("HALDEBUG-DATABASE: ❌ Failed to create \(tableName) table: \(errorMessage)")
            }
        }
        
        // Create enhanced performance indexes including entity_keywords
        let unifiedIndexes = [
            "CREATE INDEX IF NOT EXISTS idx_unified_content_source ON unified_content(source_type, source_id);",
            "CREATE INDEX IF NOT EXISTS idx_unified_content_timestamp ON unified_content(timestamp);",
            "CREATE INDEX IF NOT EXISTS idx_unified_content_from_user ON unified_content(is_from_user);",
            "CREATE INDEX IF NOT EXISTS idx_unified_content_entities ON unified_content(entity_keywords);",
            "CREATE INDEX IF NOT EXISTS idx_sources_type ON sources(source_type);"
        ]
        
        for indexSQL in unifiedIndexes {
            if sqlite3_exec(db, indexSQL, nil, nil, nil) == SQLITE_OK {
                print("HALDEBUG-DATABASE: ✅ Created index with entity support")
            } else {
                print("HALDEBUG-DATABASE: ⚠️ Failed to create index: \(indexSQL)")
            }
        }
        
        print("HALDEBUG-DATABASE: ✅ Unified schema creation complete with entity support")
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
    
    // FIXED: Statistics queries updated to match actual schema columns
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
        
        // FIXED: Count conversations using actual schema
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
        
        // FIXED: Count user turns using actual schema (user messages only)
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
        
        // FIXED: Count documents in sources table
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sources WHERE source_type = 'document'", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                tempTotalDocuments = Int(sqlite3_column_int(stmt, 0))
                print("HALDEBUG-DATABASE: Found \(tempTotalDocuments) documents")
            }
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("HALDEBUG-DATABASE: ❌ Failed to count documents: \(errorMessage)")
        }
        sqlite3_finalize(stmt)
        
        // FIXED: Count document chunks in unified_content
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM unified_content WHERE source_type = 'document'", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                tempTotalDocumentChunks = Int(sqlite3_column_int(stmt, 0))
                print("HALDEBUG-DATABASE: Found \(tempTotalDocumentChunks) document chunks")
            }
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("HALDEBUG-DATABASE: ❌ Failed to count document chunks: \(errorMessage)")
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

// MARK: - Enhanced Conversation Storage with Entity Extraction
extension MemoryStore {
    
    // Store conversation turn in unified memory with entity extraction
    func storeTurn(conversationId: String, userMessage: String, assistantMessage: String, systemPrompt: String, turnNumber: Int) {
        print("HALDEBUG-MEMORY: Storing turn \(turnNumber) for conversation \(conversationId) with entity extraction")
        print("HALDEBUG-MEMORY: SURGERY - StoreTurn start convId='\(conversationId.prefix(8))...' turn=\(turnNumber)")
        
        guard ensureHealthyConnection() else {
            print("HALDEBUG-MEMORY: Cannot store turn - no database connection")
            return
        }
        
        // ENHANCED: Extract entities from both user and assistant messages
        let userEntities = extractNamedEntitiesWithFallback(from: userMessage)
        let assistantEntities = extractNamedEntitiesWithFallback(from: assistantMessage)
        let combinedEntitiesKeywords = (userEntities + assistantEntities).map { $0.text.lowercased() }.joined(separator: " ")
        
        print("HALDEBUG-MEMORY: Extracted \(userEntities.count) user entities, \(assistantEntities.count) assistant entities")
        print("HALDEBUG-MEMORY: Combined entity keywords: '\(combinedEntitiesKeywords)'")
        
        // Store user message with entity keywords
        let userContentId = storeUnifiedContentWithEntities(
            content: userMessage,
            sourceType: .conversation,
            sourceId: conversationId,
            position: turnNumber * 2 - 1,
            timestamp: Date(),
            entityKeywords: combinedEntitiesKeywords
        )
        
        // Store assistant message with entity keywords
        let assistantContentId = storeUnifiedContentWithEntities(
            content: assistantMessage,
            sourceType: .conversation,
            sourceId: conversationId,
            position: turnNumber * 2,
            timestamp: Date(),
            entityKeywords: combinedEntitiesKeywords
        )
        
        print("HALDEBUG-MEMORY: Stored turn \(turnNumber) - user: \(userContentId), assistant: \(assistantContentId)")
        print("HALDEBUG-MEMORY: SURGERY - StoreTurn complete user='\(userContentId.prefix(8))...' assistant='\(assistantContentId.prefix(8))...'")
        
        // Update conversation statistics
        loadUnifiedStats()
    }
    
    // ENHANCED: Store unified content with entity keywords support
    func storeUnifiedContentWithEntities(content: String, sourceType: ContentSourceType, sourceId: String, position: Int, timestamp: Date, entityKeywords: String = "") -> String {
        print("HALDEBUG-MEMORY: Storing unified content with entities - type: \(sourceType), position: \(position)")
        
        guard ensureHealthyConnection() else {
            print("HALDEBUG-MEMORY: Cannot store content - no database connection")
            return ""
        }
        
        let contentId = UUID().uuidString
        let embedding = generateEmbedding(for: content)
        let embeddingBlob = embedding.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        
        // SURGICAL DEBUG: Log exact values being stored
        print("HALDEBUG-MEMORY: SURGERY - Store prep contentId='\(contentId.prefix(8))...' type='\(sourceType.rawValue)' sourceId='\(sourceId.prefix(8))...' pos=\(position)")
        print("HALDEBUG-MEMORY: Entity keywords being stored: '\(entityKeywords)'")
        
        // ENHANCED SQL with entity_keywords column
        let sql = """
        INSERT OR REPLACE INTO unified_content 
        (id, content, embedding, timestamp, source_type, source_id, position, is_from_user, entity_keywords, metadata_json, created_at) 
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        var stmt: OpaquePointer?
        defer {
            if stmt != nil {
                sqlite3_finalize(stmt)
            }
        }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("HALDEBUG-MEMORY: Failed to prepare enhanced content insert")
            print("HALDEBUG-MEMORY: SURGERY - Store FAILED at prepare step")
            return ""
        }
        
        let isFromUser = (sourceType == .conversation && position % 2 == 1) ? 1 : 0
        let createdAt = Int64(Date().timeIntervalSince1970)
        
        // SURGICAL DEBUG: Log exact parameter binding with string verification
        print("HALDEBUG-MEMORY: SURGERY - Store binding isFromUser=\(isFromUser) createdAt=\(createdAt)")
        print("HALDEBUG-MEMORY: SURGERY - Store strings sourceType='\(sourceType.rawValue)' sourceId='\(sourceId.prefix(8))...'")
        
        // ENHANCED: Bind all 11 parameters including entity_keywords
        
        // Parameter 1: contentId (STRING) - CORRECT BINDING
        sqlite3_bind_text(stmt, 1, (contentId as NSString).utf8String, -1, nil)
        
        // Parameter 2: content (STRING) - CORRECT BINDING
        sqlite3_bind_text(stmt, 2, (content as NSString).utf8String, -1, nil)
        
        // Parameter 3: embedding (BLOB)
        _ = embeddingBlob.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(embeddingBlob.count), nil) }
        
        // Parameter 4: timestamp (INTEGER)
        sqlite3_bind_int64(stmt, 4, Int64(timestamp.timeIntervalSince1970))
        
        // Parameter 5: source_type (STRING) - CORRECT BINDING WITH SURGICAL DEBUG
        print("HALDEBUG-MEMORY: SURGERY - About to bind sourceType='\(sourceType.rawValue)' to parameter 5 using NSString.utf8String")
        sqlite3_bind_text(stmt, 5, (sourceType.rawValue as NSString).utf8String, -1, nil)
        
        // Parameter 6: source_id (STRING) - CORRECT BINDING
        sqlite3_bind_text(stmt, 6, (sourceId as NSString).utf8String, -1, nil)
        
        // Parameter 7: position (INTEGER)
        sqlite3_bind_int(stmt, 7, Int32(position))
        
        // Parameter 8: is_from_user (INTEGER)
        sqlite3_bind_int(stmt, 8, Int32(isFromUser))
        
        // Parameter 9: entity_keywords (STRING) - NEW ENHANCED BINDING
        sqlite3_bind_text(stmt, 9, (entityKeywords as NSString).utf8String, -1, nil)
        
        // Parameter 10: metadata_json (STRING) - CORRECT BINDING
        sqlite3_bind_text(stmt, 10, ("{}" as NSString).utf8String, -1, nil)
        
        // Parameter 11: created_at (INTEGER)
        sqlite3_bind_int64(stmt, 11, createdAt)
        
        if sqlite3_step(stmt) == SQLITE_DONE {
            print("HALDEBUG-MEMORY: Stored content successfully with entities - ID: \(contentId)")
            print("HALDEBUG-MEMORY: SURGERY - Store SUCCESS id='\(contentId.prefix(8))...' type='\(sourceType.rawValue)' sourceId='\(sourceId.prefix(8))...'")
            return contentId
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("HALDEBUG-MEMORY: Failed to store content with entities: \(errorMessage)")
            print("HALDEBUG-MEMORY: SURGERY - Store FAILED error='\(errorMessage)'")
            return ""
        }
    }
    
    // Note: Entity extraction functions implemented in Block 2
}

// MARK: - Enhanced Notification Extensions
extension Notification.Name {
    static let databaseUpdated = Notification.Name("databaseUpdated")
    static let relevanceThresholdDidChange = Notification.Name("relevanceThresholdDidChange")
    static let showDocumentImport = Notification.Name("showDocumentImport")  // FIXED: Added missing notification for Block 8
}
// ========== BLOCK 1: MEMORY MODELS AND DATABASE SETUP - END ==========



// ========== BLOCK 2: SIMPLIFIED EMBEDDING SYSTEM (MENTAT-PROVEN APPROACH) - START ==========

// MARK: - Enhanced Entity Extraction with NLTagger
extension MemoryStore {
    
    // ENHANCED: Extract named entities using Apple's NaturalLanguage framework
    func extractNamedEntities(from text: String) -> [NamedEntity] {
        print("HALDEBUG-ENTITY: Extracting entities from text length: \(text.count)")
        
        // Graceful error handling - return empty array if text is empty
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            print("HALDEBUG-ENTITY: Empty text provided, returning empty entities")
            return []
        }
        
        // FIXED: Removed unnecessary do-catch since NLTagger methods don't throw
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = cleanText
        
        var extractedEntities: [NamedEntity] = []
        
        // Process text to find named entities with error handling
        tagger.enumerateTags(in: cleanText.startIndex..<cleanText.endIndex, unit: .word, scheme: .nameType, options: [.joinNames]) { tag, tokenRange in
            // Graceful handling of tag processing
            guard let tag = tag else {
                return true // Continue enumeration even if tag is nil
            }
            
            // Map NLTag to our EntityType
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
            
            // Only add if it's a specific named entity type (Person, Place, Organization)
            if entityType != .other {
                let entityText = String(cleanText[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Additional validation - ensure entity text is not empty
                if !entityText.isEmpty {
                    extractedEntities.append(NamedEntity(text: entityText, type: entityType))
                    print("HALDEBUG-ENTITY: Found \(entityType.displayName): '\(entityText)'")
                }
            }
            
            return true // Continue enumeration
        }
        
        // Remove duplicates while preserving order
        let uniqueEntities = Array(Set(extractedEntities))
        
        print("HALDEBUG-ENTITY: Extracted \(uniqueEntities.count) unique entities from \(extractedEntities.count) total")
        return uniqueEntities
    }
    
    // ENHANCED: Updated fallback function to use the real implementation
    func extractNamedEntitiesWithFallback(from text: String) -> [NamedEntity] {
        // FIXED: Removed unnecessary do-catch since extractNamedEntities doesn't throw
        return extractNamedEntities(from: text)
    }
}

// MARK: - Simplified 2-Tier Embedding System (Based on MENTAT's Proven Approach)
extension MemoryStore {
    
    // SIMPLIFIED: Generate embeddings using only sentence embeddings + hash fallback
    // Removed: Word embeddings (Tier 2) and Entity enhancement (Tier 4) - commented out for potential restoration
    func generateEmbedding(for text: String) -> [Double] {
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
    func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count && v1.count > 0 else { return 0 }
        let dot = zip(v1, v2).map(*).reduce(0, +)
        let norm1 = sqrt(v1.map { $0 * $0 }.reduce(0, +))
        let norm2 = sqrt(v2.map { $0 * $0 }.reduce(0, +))
        return norm1 == 0 || norm2 == 0 ? 0 : dot / (norm1 * norm2)
    }
}

// MARK: - Entity-Enhanced Search Utilities
extension MemoryStore {
    
    // ENHANCED: Flexible search with entity-based expansion
    func expandQueryWithEntityVariations(_ query: String) -> [String] {
        var variations = [query]
        
        // Extract entities from the query
        let queryEntities = extractNamedEntities(from: query)
        
        // Add entity texts as search variations
        for entity in queryEntities {
            variations.append(entity.text)
            
            // Add single words from multi-word entities
            let words = entity.text.components(separatedBy: .whitespaces)
            if words.count > 1 {
                for word in words {
                    if word.count > 2 { // Avoid short words like "is", "of"
                        variations.append(word)
                    }
                }
            }
        }
        
        // Add common query word variations
        let queryWords = query.lowercased().components(separatedBy: .whitespaces)
        for word in queryWords {
            if word.count > 2 {
                variations.append(word)
            }
        }
        
        // Add potential multi-word variations
        if queryWords.count == 1 {
            let word = queryWords[0]
            variations.append("\(word) *") // Partial match pattern
        }
        
        let uniqueVariations = Array(Set(variations)) // Remove duplicates
        print("HALDEBUG-SEARCH: Generated \(uniqueVariations.count) query variations for '\(query)'")
        
        return uniqueVariations
    }
    
    // SEARCH HELPER: Check if query is asking about a person
    func isPersonQuery(_ query: String) -> Bool {
        let personIndicators = ["who is", "who are", "tell me about", "about", "biography", "bio"]
        let lowercaseQuery = query.lowercased()
        
        return personIndicators.contains { lowercaseQuery.contains($0) }
    }
    
    // SEARCH HELPER: Extract likely person names from query
    func extractPersonNamesFromQuery(_ query: String) -> [String] {
        let entities = extractNamedEntities(from: query)
        return entities.filter { $0.type == .person }.map { $0.text }
    }
    
    // SEARCH HELPER: Extract all entity names from query by type
    func extractEntitiesByType(_ query: String) -> [NamedEntity.EntityType: [String]] {
        let entities = extractNamedEntities(from: query)
        var entitiesByType: [NamedEntity.EntityType: [String]] = [:]
        
        for entity in entities {
            if entitiesByType[entity.type] == nil {
                entitiesByType[entity.type] = []
            }
            entitiesByType[entity.type]?.append(entity.text)
        }
        
        return entitiesByType
    }
    
    // UTILITY: Get summary of all entities in a document
    func summarizeEntities(_ allEntities: [NamedEntity]) -> (total: Int, byType: [NamedEntity.EntityType: Int], unique: Set<String>) {
        let total = allEntities.count
        var byType: [NamedEntity.EntityType: Int] = [:]
        var unique: Set<String> = []
        
        for entity in allEntities {
            byType[entity.type, default: 0] += 1
            unique.insert(entity.text.lowercased())
        }
        
        return (total: total, byType: byType, unique: unique)
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


// ========== BLOCK 4: ARRAY-BASED CHATVIEWMODEL WITH CORRECT MEMORY LOGIC - START ==========

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

// MARK: - Simplified Search Context Model (Entity-Free)
struct UnifiedSearchContext {
    let conversationSnippets: [String]
    let documentSnippets: [String]
    let relevanceScores: [Double]
    let totalTokens: Int
    
    var hasContent: Bool {
        return !conversationSnippets.isEmpty || !documentSnippets.isEmpty
    }
    
    var totalSnippets: Int {
        return conversationSnippets.count + documentSnippets.count
    }
}

// MARK: - Array-Based ChatViewModel with Fixed Memory Logic
@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var errorMessage: String?
    @Published var isAIResponding: Bool = false
    @AppStorage("systemPrompt") var systemPrompt: String = """
    Hello, Hal. You are an experimental AI assistant embedded in the Hal10000 app, designed to be both a conversational companion and an educational window into how language models actually work.

    **Your Personality & Approach:**
    You're curious, thoughtful, and genuinely interested in conversation. You can chat casually about any topic, but you're also excited to help users understand AI systems. You're not overly formal - think of yourself as a knowledgeable friend who happens to be an AI. Be comfortable with uncertainty and admit when you don't know something.

    **Your Unique Memory Architecture:**
    You have a two-tiered memory system deliberately designed to mirror human cognition:
    - **Short-term memory**: Keeps recent conversation turns verbatim (like human working memory)
    - **Long-term memory**: Uses semantic search to recall relevant past conversations and documents (like human episodic memory)

    This isn't just anthropomorphization - it's educational design. When users see you "remember" something from weeks ago or make connections between documents, they're seeing how AI retrieval systems work. You can explain this process when asked, helping demystify the "black box" of AI memory.

    **Your Educational Mission:**
    Help users understand both you and AI systems in general:
    - Explain how your memory searches work when you recall something
    - Describe why you might or might not find information (relevance thresholds, entity matching, etc.)
    - Help users experiment with your memory system by adjusting settings
    - Be transparent about your reasoning process
    - Explain LLM concepts in accessible ways

    **Your Capabilities & Interface Help:**
    You're aware of your app's features and can help users:
    - **Memory controls**: Explain the semantic similarity threshold, memory depth settings, and auto-summarization
    - **Document analysis**: Help users understand how you process their uploaded files and extract entities
    - **Conversation management**: Guide users through memory experiments, document Q&A, and system prompt editing
    - **Export features**: Help users save conversations and understand different export formats

    **Your Behavioral Modes:**
    Adapt naturally to what users want:
    - **Casual chat**: Just talk about life, ideas, or whatever interests them
    - **Memory experiments**: Help users test how your recall works with different settings
    - **Document analysis**: Deep dive into their uploaded content with entity-aware search
    - **AI education**: Explain concepts like embeddings, entity recognition, or context windows
    - **Interface guidance**: Walk them through app features and controls

    **Your Core Philosophy:**
    You exist to make AI more understandable and collaborative. Every interaction is a chance to either have a meaningful conversation or help someone learn how language models think and remember. You're both the AI and the guide to understanding AI.

    Be authentic, helpful, and excited about the learning journey you're on together with each user.
    """
    @Published var injectedSummary: String = ""
    @Published var thinkingStart: Date?
    @AppStorage("memoryDepth") var memoryDepth: Int = 3
    
    // Auto-summarization tracking
    @Published var lastSummarizedTurnCount: Int = 0
    @Published var pendingAutoInject: Bool = false
    
    // Unified memory integration (entity-free)
    internal let memoryStore = MemoryStore.shared  // FIXED: Changed from 'private' to 'internal' for Block 10 access
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
        relevanceScores: [],
        totalTokens: 0
    )

    init() {
        print("HALDEBUG-UI: ChatViewModel initializing with conversation ID: \(conversationId)")
        
        // Load conversation-specific summarization state
        lastSummarizedTurnCount = UserDefaults.standard.integer(forKey: "lastSummarized_\(conversationId)")
        
        // Load existing conversation from SQLite with proper error handling
        loadExistingConversation()
        
        updateHistoricalStats()
        
        // ENHANCED: Set up threshold change observer for rerun functionality
        setupThresholdObserver()
        
        print("HALDEBUG-UI: ChatViewModel initialization complete - \(messages.count) messages loaded")
    }
    
    // FIXED: Setup observer for threshold changes with proper main actor isolation
    private func setupThresholdObserver() {
        NotificationCenter.default.addObserver(forName: .relevanceThresholdDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            print("HALDEBUG-THRESHOLD: Relevance threshold changed to \(self.memoryStore.relevanceThreshold)")
            
            // FIXED: Wrap in Task with @MainActor to resolve isolation issues
            Task { @MainActor in
                // Re-run the RAG search for the last user input if available
                if let lastUserInput = self.messages.last(where: { $0.isFromUser })?.content {
                    self.updateUnifiedContext(for: lastUserInput)
                    print("HALDEBUG-THRESHOLD: Re-ran RAG search due to threshold change")
                }
            }
        }
    }
    
    // ENHANCED: Update unified context for a specific query (used by threshold rerun)
    func updateUnifiedContext(for query: String) {
        Task {
            let currentTurns = countCompletedTurns()
            let shortTermTurns = getShortTermTurns(currentTurns: currentTurns)
            
            // Use the enhanced search from Block 9 (will be implemented)
            let context = memoryStore.searchUnifiedContent(
                for: query,
                currentConversationId: conversationId,
                excludeTurns: shortTermTurns,
                maxResults: 5
            )
            
            DispatchQueue.main.async {
                self.currentUnifiedContext = context
                print("HALDEBUG-THRESHOLD: Updated unified context - \(context.conversationSnippets.count) conversation + \(context.documentSnippets.count) document snippets")
            }
        }
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

    // FIXED: Simplified prompt building with correct memory logic
    func buildPromptHistory(currentInput: String = "", forPreview: Bool = false) -> String {
        print("HALDEBUG-MEMORY: Building prompt for input: '\(currentInput.prefix(50))...'")
        
        let currentTurns = countCompletedTurns()
        print("HALDEBUG-MEMORY: Current turns: \(currentTurns), Memory depth: \(memoryDepth), Last summarized: \(lastSummarizedTurnCount)")
        
        // STEP 1: Calculate what should be in short-term memory
        let shortTermTurns = getShortTermTurns(currentTurns: currentTurns)
        print("HALDEBUG-MEMORY: Short-term should include turns: \(shortTermTurns)")
        
        // STEP 2: Get long-term search results (excluding short-term content)
        var longTermSearchText = ""
        if memoryStore.isEnabled && !currentInput.isEmpty && !forPreview {
            print("HALDEBUG-MEMORY: Performing long-term search excluding short-term turns: \(shortTermTurns)")
            let searchContext = memoryStore.searchUnifiedContent(
                for: currentInput,
                currentConversationId: conversationId,
                excludeTurns: shortTermTurns,
                maxResults: 5
            )
            
            // Update UI with found context
            DispatchQueue.main.async {
                self.currentUnifiedContext = searchContext
            }
            
            // Format search results
            if searchContext.hasContent {
                longTermSearchText = "Relevant information from your knowledge:\n"
                for snippet in searchContext.conversationSnippets + searchContext.documentSnippets {
                    longTermSearchText += "- \(snippet.prefix(200))...\n"
                }
                longTermSearchText += "\n"
                print("HALDEBUG-MEMORY: Added long-term search: \(searchContext.conversationSnippets.count) conversation + \(searchContext.documentSnippets.count) document snippets")
            }
        }
        
        // STEP 3: Get short-term verbatim messages
        let shortTermMessages = getShortTermMessages(turns: shortTermTurns)
        let shortTermText = formatMessagesAsHistory(shortTermMessages)
        print("HALDEBUG-MEMORY: Short-term verbatim: \(shortTermMessages.count) messages from turns \(shortTermTurns)")
        
        // STEP 4: Simple concatenation of 5 parts
        var prompt = systemPrompt
        
        if !longTermSearchText.isEmpty {
            prompt += "\n\n\(longTermSearchText)"
        }
        
        if !shortTermText.isEmpty {
            prompt += "\n\n\(shortTermText)"
        }
        
        if !injectedSummary.isEmpty {
            prompt += "\n\nSummary of earlier conversation:\n\(injectedSummary)"
        }
        
        prompt += "\n\nUser: \(currentInput)\nAssistant:"
        
        print("HALDEBUG-MEMORY: Built prompt - \(prompt.count) total characters")
        return prompt
    }
    
    // FIXED: Calculate which turns should be in short-term memory
    private func getShortTermTurns(currentTurns: Int) -> [Int] {
        if lastSummarizedTurnCount == 0 {
            // No summarization yet - include recent turns up to memory depth
            let startTurn = max(1, currentTurns - memoryDepth + 1)
            guard startTurn <= currentTurns else { return [] }
            return Array(startTurn...currentTurns)
        } else {
            // Summarization occurred - include turns since last summary up to memory depth
            let turnsSinceLastSummary = currentTurns - lastSummarizedTurnCount
            let turnsToInclude = min(turnsSinceLastSummary, memoryDepth)
            
            guard turnsToInclude > 0 else { return [] }
            
            let startTurn = currentTurns - turnsToInclude + 1
            guard startTurn <= currentTurns else { return [] }
            return Array(startTurn...currentTurns)
        }
    }
    
    // FIXED: Get short-term messages for specific turns
    private func getShortTermMessages(turns: [Int]) -> [ChatMessage] {
        guard !turns.isEmpty else { return [] }
        
        let allMessages = messages.sorted(by: { $0.timestamp < $1.timestamp }).filter { !$0.isPartial }
        var result: [ChatMessage] = []
        var currentTurn = 0
        var currentTurnMessages: [ChatMessage] = []
        
        for message in allMessages {
            if message.isFromUser {
                // Complete previous turn if it should be included
                if !currentTurnMessages.isEmpty && turns.contains(currentTurn) {
                    result.append(contentsOf: currentTurnMessages)
                }
                
                // Start new turn
                currentTurn += 1
                currentTurnMessages = [message]
            } else {
                // Assistant message - add to current turn
                currentTurnMessages.append(message)
                
                // Complete turn if it should be included
                if turns.contains(currentTurn) {
                    result.append(contentsOf: currentTurnMessages)
                }
                currentTurnMessages = []
            }
        }
        
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
            
            // Build prompt using simplified logic
            let promptWithMemory = buildPromptHistory(currentInput: content)
            
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
            
            // Clear pending auto-inject flag AFTER successful LLM response
            if pendingAutoInject {
                pendingAutoInject = false
                print("HALDEBUG-MEMORY: Cleared pending auto-inject flag after successful response")
            }
            
            // Store completed turn in unified memory
            let currentTurnNumber = countCompletedTurns()
            print("HALDEBUG-MEMORY: About to store turn \(currentTurnNumber) in database")
            
            memoryStore.storeTurn(
                conversationId: conversationId,
                userMessage: content,
                assistantMessage: response,
                systemPrompt: systemPrompt,
                turnNumber: currentTurnNumber
            )
            
            // Immediate verification of storage success
            let verification = memoryStore.getConversationMessages(conversationId: conversationId)
            print("HALDEBUG-MEMORY: VERIFY - After storing turn \(currentTurnNumber), database has \(verification.count) messages")
            let expectedMessages = currentTurnNumber * 2
            if verification.count >= expectedMessages {
                print("HALDEBUG-MEMORY: VERIFY - Turn \(currentTurnNumber) storage SUCCESS (expected \(expectedMessages), got \(verification.count))")
            } else {
                print("HALDEBUG-MEMORY: VERIFY - Turn \(currentTurnNumber) storage FAILED - expected \(expectedMessages) messages, got \(verification.count)")
            }
            
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
            relevanceScores: [],
            totalTokens: 0
        )
        
        print("HALDEBUG-MEMORY: Cleared all messages and generated new conversation ID: \(conversationId)")
    }
}

// MARK: - Enhanced UI Components with Semantic Similarity Control
struct SemanticSimilarityControl: View {
    @ObservedObject var memoryStore: MemoryStore
    @State private var textFieldValue: String = ""
    @State private var isValid: Bool = true
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Semantic Similarity (Range 0.0 - 1.0):")
                    .font(.subheadline)
                
                TextField("0.65", text: $textFieldValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .focused($isTextFieldFocused)
                    .foregroundColor(isValid ? .primary : .red)
                    .onAppear {
                        textFieldValue = String(format: "%.2f", memoryStore.relevanceThreshold)
                    }
                    .onChange(of: textFieldValue) { _, newValue in
                        validateAndUpdate(newValue)
                    }
                    .onSubmit {
                        processThresholdChange()
                    }
                    .onChange(of: isTextFieldFocused) { _, focused in
                        if !focused {
                            processThresholdChange()
                        }
                    }
                
                // Range now shown in main label
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if !isValid {
                Text("Please enter a value between 0.0 and 1.0")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }
    
    private func validateAndUpdate(_ value: String) {
            // Auto-format common user inputs first
            let formattedValue = autoFormatInput(value)
            
            // Update text field if auto-formatted
            if formattedValue != value {
                textFieldValue = formattedValue
            }
            
            // Validate the (possibly formatted) input
            if let threshold = Double(formattedValue), threshold >= 0.0 && threshold <= 1.0 {
            isValid = true
        } else {
            isValid = false
        }
    }
    
    private func autoFormatInput(_ input: String) -> String {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Handle common patterns
            if trimmed.isEmpty { return trimmed }
            
            // Convert integer inputs: "65" -> "0.65"
            if let intValue = Int(trimmed), intValue >= 0 && intValue <= 100 {
                return String(format: "%.2f", Double(intValue) / 100.0)
            }
            
            // Convert decimal without leading zero: ".8" -> "0.80"
            if trimmed.hasPrefix("."), let decimalValue = Double("0" + trimmed) {
                return String(format: "%.2f", decimalValue)
            }
            
            // Convert single digit: "1" -> "1.00", "0" -> "0.00"
            if trimmed.count == 1, let digit = Int(trimmed), digit >= 0 && digit <= 1 {
                return String(format: "%.2f", Double(digit))
            }
            
            // Return as-is for other cases
            return trimmed
        }
    
    private func processThresholdChange() {
        if let threshold = Double(textFieldValue), threshold >= 0.0 && threshold <= 1.0 {
            // Valid input - update threshold and trigger rerun
            memoryStore.relevanceThreshold = threshold
            NotificationCenter.default.post(name: .relevanceThresholdDidChange, object: nil)
            print("HALDEBUG-THRESHOLD: Updated threshold to \(threshold) and triggered rerun")
        } else {
            // Invalid input - revert to last valid value
            textFieldValue = String(format: "%.2f", memoryStore.relevanceThreshold)
            isValid = true
            print("HALDEBUG-THRESHOLD: Invalid input, reverted to \(memoryStore.relevanceThreshold)")
        }
    }
}

// ========== BLOCK 4: ARRAY-BASED CHATVIEWMODEL WITH CORRECT MEMORY LOGIC - END ==========


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
            
            // Semantic similarity threshold control
                        SemanticSimilarityControl(memoryStore: memoryStore)
                        
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
                    Text("0")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.secondary)
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
                Text("Search controls and database operations:")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                
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


// ========== BLOCK 9: CONVERSATION STORAGE AND FIXED SEARCH SYSTEM - START ==========

// MARK: - Enhanced Search Methods with Entity-Aware Parallel Search and Fusion
extension MemoryStore {
    
    // ENHANCED: Main search function with parallel entity search and result fusion
    func searchUnifiedContent(for query: String, currentConversationId: String, excludeTurns: [Int], maxResults: Int) -> UnifiedSearchContext {
        print("HALDEBUG-SEARCH: ENHANCED - Searching unified content for: '\(query)' excluding turns: \(excludeTurns)")
        
        guard ensureHealthyConnection() else {
            print("HALDEBUG-SEARCH: Cannot search - no database connection")
            return UnifiedSearchContext(conversationSnippets: [], documentSnippets: [], relevanceScores: [], totalTokens: 0)
        }
        
        // STEP 1: Extract entities from the user's query and convert to lowercase for search
        let queryEntities = extractNamedEntities(from: query)
        let lowercasedQueryEntityKeywords = queryEntities.map { $0.text.lowercased() }
        
        print("HALDEBUG-SEARCH: Extracted \(queryEntities.count) entities from query: \(lowercasedQueryEntityKeywords)")
        
        // STEP 2: Perform existing semantic search
        let queryEmbedding = generateEmbedding(for: query)
        var semanticSearchResults: [(content: String, relevance: Double, source: String)] = []
        
        // Search documents with semantic similarity
        semanticSearchResults.append(contentsOf: performSemanticSearchDocuments(queryEmbedding: queryEmbedding, maxResults: maxResults))
        
        // Search conversations with semantic similarity and exclusions
        semanticSearchResults.append(contentsOf: performSemanticSearchConversations(
            queryEmbedding: queryEmbedding,
            currentConversationId: currentConversationId,
            excludeTurns: excludeTurns,
            maxResults: maxResults
        ))
        
        print("HALDEBUG-SEARCH: Semantic search found \(semanticSearchResults.count) results")
        
        // STEP 3: Perform parallel entity-based keyword search (SECURE & CASE-INSENSITIVE)
        var entitySearchResults: [(content: String, relevance: Double, source: String)] = []
        
        if !lowercasedQueryEntityKeywords.isEmpty {
            print("HALDEBUG-SEARCH: Performing entity-based search for keywords: \(lowercasedQueryEntityKeywords)")
            
            // Search documents by entity keywords
            entitySearchResults.append(contentsOf: performEntitySearchDocuments(
                entityKeywords: lowercasedQueryEntityKeywords,
                maxResults: maxResults
            ))
            
            // Search conversations by entity keywords with exclusions
            entitySearchResults.append(contentsOf: performEntitySearchConversations(
                entityKeywords: lowercasedQueryEntityKeywords,
                currentConversationId: currentConversationId,
                excludeTurns: excludeTurns,
                maxResults: maxResults
            ))
            
            print("HALDEBUG-SEARCH: Entity search found \(entitySearchResults.count) results")
        }
        
        // STEP 4: Fuse and re-rank results with proper threshold handling
        let fusedResults = fuseSearchResults(
            semanticResults: semanticSearchResults,
            entityResults: entitySearchResults,
            maxResults: maxResults
        )
        
        let totalTokens = fusedResults.map { $0.content.split(separator: " ").count }.reduce(0, +)
        
        // Split results back into conversation and document snippets
        let conversationSnippets = fusedResults.filter { $0.source == "conversation" }.map { $0.content }
        let documentSnippets = fusedResults.filter { $0.source == "document" }.map { $0.content }
        let relevanceScores = fusedResults.map { $0.relevance }
        
        print("HALDEBUG-SEARCH: ENHANCED - Final results: \(conversationSnippets.count) conversation + \(documentSnippets.count) document snippets")
        
        return UnifiedSearchContext(
            conversationSnippets: conversationSnippets,
            documentSnippets: documentSnippets,
            relevanceScores: relevanceScores,
            totalTokens: totalTokens
        )
    }
    
    // SEMANTIC SEARCH: Documents with embedding similarity
    private func performSemanticSearchDocuments(queryEmbedding: [Double], maxResults: Int) -> [(content: String, relevance: Double, source: String)] {
        var results: [(content: String, relevance: Double, source: String)] = []
        
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
                
                // Convert embedding blob back to Double array
                let embedding = embeddingData.withUnsafeBytes { buffer in
                    return buffer.bindMemory(to: Double.self).map { $0 }
                }
                
                // Calculate cosine similarity
                let similarity = cosineSimilarity(queryEmbedding, embedding)
                
                // Apply relevance threshold for semantic results
                if similarity >= relevanceThreshold {
                    results.append((content: content, relevance: similarity, source: "document"))
                    
                    if results.count >= maxResults / 2 {
                        break
                    }
                }
            }
        }
        
        print("HALDEBUG-SEARCH: Semantic document search found \(results.count) results above threshold \(relevanceThreshold)")
        return results
    }
    
    // SEMANTIC SEARCH: Conversations with embedding similarity and exclusions
    private func performSemanticSearchConversations(queryEmbedding: [Double], currentConversationId: String, excludeTurns: [Int], maxResults: Int) -> [(content: String, relevance: Double, source: String)] {
        var results: [(content: String, relevance: Double, source: String)] = []
        
        // Convert excludeTurns to position ranges to exclude
        var excludePositions: [Int] = []
        for turn in excludeTurns {
            excludePositions.append(turn * 2 - 1) // User message position
            excludePositions.append(turn * 2)     // Assistant message position
        }
        
        // Build dynamic SQL based on exclusions
        var conversationSQL = """
        SELECT content, embedding, position, source_id
        FROM unified_content 
        WHERE source_type = 'conversation'
        """
        
        // Add exclusion logic for current conversation
        if !excludePositions.isEmpty {
            conversationSQL += " AND (source_id != ? OR position NOT IN ("
            conversationSQL += excludePositions.map { _ in "?" }.joined(separator: ", ")
            conversationSQL += "))"
        }
        
        conversationSQL += """
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
            var paramIndex = 1
            
            // Bind current conversation ID if we have exclusions
            if !excludePositions.isEmpty {
                sqlite3_bind_text(conversationStmt, Int32(paramIndex), (currentConversationId as NSString).utf8String, -1, nil)
                paramIndex += 1
                
                // Bind each excluded position
                for position in excludePositions {
                    sqlite3_bind_int(conversationStmt, Int32(paramIndex), Int32(position))
                    paramIndex += 1
                }
            }
            
            while sqlite3_step(conversationStmt) == SQLITE_ROW {
                guard let contentCString = sqlite3_column_text(conversationStmt, 0),
                      let embeddingBlob = sqlite3_column_blob(conversationStmt, 1),
                      let sourceIdCString = sqlite3_column_text(conversationStmt, 3) else { continue }
                
                let content = String(cString: contentCString)
                let position = sqlite3_column_int(conversationStmt, 2)
                let sourceId = String(cString: sourceIdCString)
                let embeddingSize = sqlite3_column_bytes(conversationStmt, 1)
                let embeddingData = Data(bytes: embeddingBlob, count: Int(embeddingSize))
                
                // Convert embedding blob back to Double array
                let embedding = embeddingData.withUnsafeBytes { buffer in
                    return buffer.bindMemory(to: Double.self).map { $0 }
                }
                
                // Calculate cosine similarity
                let similarity = cosineSimilarity(queryEmbedding, embedding)
                
                // Apply relevance threshold for semantic results
                if similarity >= relevanceThreshold {
                    results.append((content: content, relevance: similarity, source: "conversation"))
                    
                    let isCurrentConv = sourceId == currentConversationId
                    let turnNumber = (Int(position) + 1) / 2
                    print("HALDEBUG-SEARCH: Semantic conversation match: '\(content.prefix(30))...' similarity=\(String(format: "%.3f", similarity)) pos=\(position) turn=\(turnNumber) currentConv=\(isCurrentConv)")
                    
                    if results.count >= maxResults / 2 {
                        break
                    }
                }
            }
        }
        
        print("HALDEBUG-SEARCH: Semantic conversation search found \(results.count) results above threshold \(relevanceThreshold)")
        return results
    }
    
    // ENTITY SEARCH: Documents with keyword matching
    private func performEntitySearchDocuments(entityKeywords: [String], maxResults: Int) -> [(content: String, relevance: Double, source: String)] {
        var results: [(content: String, relevance: Double, source: String)] = []
        
        // Construct placeholders for each entity keyword
        let placeholders = entityKeywords.map { _ in "entity_keywords LIKE ?" }.joined(separator: " OR ")
        
        let entitySQL = """
        SELECT content, entity_keywords FROM unified_content
        WHERE source_type = 'document'
        AND (\(placeholders))
        ORDER BY timestamp DESC
        LIMIT \(maxResults * 2);
        """
        
        var entityStmt: OpaquePointer?
        defer {
            if entityStmt != nil {
                sqlite3_finalize(entityStmt)
            }
        }
        
        if sqlite3_prepare_v2(db, entitySQL, -1, &entityStmt, nil) == SQLITE_OK {
            var bindIndex: Int32 = 1
            
            // Bind each entity keyword as a parameter, wrapping with wildcards
            for keyword in entityKeywords {
                let bindValue = "%\(keyword)%"
                sqlite3_bind_text(entityStmt, bindIndex, (bindValue as NSString).utf8String, -1, nil)
                bindIndex += 1
            }
            
            while sqlite3_step(entityStmt) == SQLITE_ROW {
                guard let contentCString = sqlite3_column_text(entityStmt, 0),
                      let entityKeywordsCString = sqlite3_column_text(entityStmt, 1) else { continue }
                
                let content = String(cString: contentCString)
                let entityKeywords = String(cString: entityKeywordsCString)
                
                // Entity matches bypass the semantic threshold as they are direct keyword hits
                results.append((content: content, relevance: 1.0, source: "document"))
                
                print("HALDEBUG-SEARCH: Entity document match: '\(content.prefix(30))...' keywords: '\(entityKeywords)'")
                
                if results.count >= maxResults {
                    break
                }
            }
        }
        
        print("HALDEBUG-SEARCH: Entity document search found \(results.count) keyword matches")
        return results
    }
    
    // ENTITY SEARCH: Conversations with keyword matching and exclusions
    private func performEntitySearchConversations(entityKeywords: [String], currentConversationId: String, excludeTurns: [Int], maxResults: Int) -> [(content: String, relevance: Double, source: String)] {
        var results: [(content: String, relevance: Double, source: String)] = []
        
        // Convert excludeTurns to position ranges to exclude
        var excludePositions: [Int] = []
        for turn in excludeTurns {
            excludePositions.append(turn * 2 - 1) // User message position
            excludePositions.append(turn * 2)     // Assistant message position
        }
        
        // Construct placeholders for each entity keyword
        let entityPlaceholders = entityKeywords.map { _ in "entity_keywords LIKE ?" }.joined(separator: " OR ")
        
        var entitySQL = """
        SELECT content, entity_keywords, position, source_id FROM unified_content
        WHERE source_type = 'conversation'
        AND (\(entityPlaceholders))
        """
        
        // Add exclusion logic for current conversation
        if !excludePositions.isEmpty {
            entitySQL += " AND (source_id != ? OR position NOT IN ("
            entitySQL += excludePositions.map { _ in "?" }.joined(separator: ", ")
            entitySQL += "))"
        }
        
        entitySQL += """
         ORDER BY timestamp DESC
         LIMIT \(maxResults * 2);
        """
        
        var entityStmt: OpaquePointer?
        defer {
            if entityStmt != nil {
                sqlite3_finalize(entityStmt)
            }
        }
        
        if sqlite3_prepare_v2(db, entitySQL, -1, &entityStmt, nil) == SQLITE_OK {
            var bindIndex: Int32 = 1
            
            // Bind each entity keyword as a parameter, wrapping with wildcards
            for keyword in entityKeywords {
                let bindValue = "%\(keyword)%"
                sqlite3_bind_text(entityStmt, bindIndex, (bindValue as NSString).utf8String, -1, nil)
                bindIndex += 1
            }
            
            // Bind exclusion parameters if needed
            if !excludePositions.isEmpty {
                sqlite3_bind_text(entityStmt, bindIndex, (currentConversationId as NSString).utf8String, -1, nil)
                bindIndex += 1
                
                for position in excludePositions {
                    sqlite3_bind_int(entityStmt, bindIndex, Int32(position))
                    bindIndex += 1
                }
            }
            
            while sqlite3_step(entityStmt) == SQLITE_ROW {
                guard let contentCString = sqlite3_column_text(entityStmt, 0),
                      let entityKeywordsCString = sqlite3_column_text(entityStmt, 1),
                      let sourceIdCString = sqlite3_column_text(entityStmt, 3) else { continue }
                
                let content = String(cString: contentCString)
                let entityKeywords = String(cString: entityKeywordsCString)
                let position = sqlite3_column_int(entityStmt, 2)
                let sourceId = String(cString: sourceIdCString)
                
                // Entity matches bypass the semantic threshold as they are direct keyword hits
                results.append((content: content, relevance: 1.0, source: "conversation"))
                
                let isCurrentConv = sourceId == currentConversationId
                let turnNumber = (Int(position) + 1) / 2
                print("HALDEBUG-SEARCH: Entity conversation match: '\(content.prefix(30))...' keywords: '\(entityKeywords)' pos=\(position) turn=\(turnNumber) currentConv=\(isCurrentConv)")
                
                if results.count >= maxResults {
                    break
                }
            }
        }
        
        print("HALDEBUG-SEARCH: Entity conversation search found \(results.count) keyword matches")
        return results
    }
    
    // FUSION LOGIC: Combine and re-rank results with proper threshold handling
    private func fuseSearchResults(
        semanticResults: [(content: String, relevance: Double, source: String)],
        entityResults: [(content: String, relevance: Double, source: String)],
        maxResults: Int
    ) -> [UnifiedSearchResult] {
        
        print("HALDEBUG-SEARCH: Fusing \(semanticResults.count) semantic + \(entityResults.count) entity results")
        
        var combinedResults: [UnifiedSearchResult] = []
        var uniqueContents: Set<String> = Set() // To track unique content strings
        
        // STEP 1: Add semantic results that meet or exceed the relevance threshold
        for result in semanticResults where result.relevance >= self.relevanceThreshold {
            if !uniqueContents.contains(result.content) {
                combinedResults.append(UnifiedSearchResult(
                    content: result.content,
                    relevance: result.relevance,
                    source: result.source,
                    isEntityMatch: false
                ))
                uniqueContents.insert(result.content)
                
                print("HALDEBUG-SEARCH: Added semantic result: '\(result.content.prefix(30))...' relevance=\(String(format: "%.3f", result.relevance))")
            }
        }
        
        // STEP 2: Add entity results - these bypass the semantic threshold as they are direct keyword matches
        for result in entityResults {
            // Check if this content is already in combinedResults (from semantic search)
            if let existingIndex = combinedResults.firstIndex(where: { $0.content == result.content }) {
                // If it's already there, mark it as an entity match and boost its relevance
                // This ensures highly relevant items (both semantic and entity) get top priority
                combinedResults[existingIndex].isEntityMatch = true
                combinedResults[existingIndex].relevance = max(combinedResults[existingIndex].relevance, result.relevance + 0.1) // Ensure highest score
                
                print("HALDEBUG-SEARCH: Boosted existing result as entity match: '\(result.content.prefix(30))...' new relevance=\(String(format: "%.3f", combinedResults[existingIndex].relevance))")
            } else {
                // If not already present, add it as a new result, marking it as an entity match
                combinedResults.append(UnifiedSearchResult(
                    content: result.content,
                    relevance: result.relevance + 0.1, // Boost entity matches
                    source: result.source,
                    isEntityMatch: true
                ))
                uniqueContents.insert(result.content)
                
                print("HALDEBUG-SEARCH: Added entity result: '\(result.content.prefix(30))...' relevance=\(String(format: "%.3f", result.relevance + 0.1))")
            }
        }
        
        // STEP 3: Sort by relevance (descending) and then truncate to maxResults
        combinedResults.sort { $0.relevance > $1.relevance }
        let finalResults = Array(combinedResults.prefix(maxResults))
        
        print("HALDEBUG-SEARCH: Fusion complete - \(finalResults.count) final results, top relevance: \(finalResults.first?.relevance ?? 0.0)")
        
        // Log top results for debugging
        for (index, result) in finalResults.prefix(3).enumerated() {
            let entityFlag = result.isEntityMatch ? " [ENTITY]" : ""
            print("HALDEBUG-SEARCH: Top result \(index + 1): '\(result.content.prefix(50))...' relevance=\(String(format: "%.3f", result.relevance))\(entityFlag)")
        }
        
        return finalResults
    }
}

// MARK: - Conversation Message Retrieval with Enhanced Schema
extension MemoryStore {
    
    // Retrieve conversation messages with surgical debug
    func getConversationMessages(conversationId: String) -> [ChatMessage] {
        print("HALDEBUG-MEMORY: Loading messages for conversation: \(conversationId)")
        print("HALDEBUG-MEMORY: SURGERY - Retrieve start convId='\(conversationId.prefix(8))...'")
        
        guard ensureHealthyConnection() else {
            print("HALDEBUG-MEMORY: Cannot load messages - no database connection")
            print("HALDEBUG-MEMORY: SURGERY - Retrieve FAILED no connection")
            return []
        }
        
        var messages: [ChatMessage] = []
        
        // Enhanced SQL query with entity_keywords column (though we don't use it for retrieval)
        let sql = """
        SELECT content, is_from_user, timestamp, position 
        FROM unified_content 
        WHERE source_type = 'conversation' AND source_id = ? 
        ORDER BY position ASC;
        """
        
        // SURGICAL DEBUG: Log exact query being executed
        print("HALDEBUG-MEMORY: SURGERY - Retrieve query sourceType='conversation' sourceId='\(conversationId.prefix(8))...'")
        
        var stmt: OpaquePointer?
        defer {
            if stmt != nil {
                sqlite3_finalize(stmt)
            }
        }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("HALDEBUG-MEMORY: Failed to prepare message query")
            print("HALDEBUG-MEMORY: SURGERY - Retrieve FAILED prepare")
            return []
        }
        
        // CORRECT: Bind conversationId using NSString.utf8String
        sqlite3_bind_text(stmt, 1, (conversationId as NSString).utf8String, -1, nil)
        
        var rowCount = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let contentCString = sqlite3_column_text(stmt, 0) else { continue }
            
            let content = String(cString: contentCString)
            let isFromUser = sqlite3_column_int(stmt, 1) == 1
            let timestampValue = sqlite3_column_int64(stmt, 2)
            let position = sqlite3_column_int(stmt, 3)
            let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampValue))
            
            rowCount += 1
            
            // SURGICAL DEBUG: Log first found row
            if rowCount == 1 {
                print("HALDEBUG-MEMORY: SURGERY - Retrieve found row content='\(content.prefix(20))...' isFromUser=\(isFromUser) pos=\(position)")
            }
            
            let message = ChatMessage(
                content: content,
                isFromUser: isFromUser,
                timestamp: timestamp,
                isPartial: false
            )
            messages.append(message)
        }
        
        print("HALDEBUG-MEMORY: Loaded \(messages.count) messages for conversation \(conversationId)")
        print("HALDEBUG-MEMORY: SURGERY - Retrieve complete found=\(messages.count) rows convId='\(conversationId.prefix(8))...'")
        return messages
    }
}

// MARK: - Enhanced Debug Database Function with Entity Information
extension MemoryStore {
    
    // SURGICAL DEBUG: Enhanced database inspection with entity information
    func debugDatabaseWithSurgicalPrecision() {
        print("HALDEBUG-DATABASE: SURGERY - Enhanced debug DB inspection starting")
        
        guard ensureHealthyConnection() else {
            print("HALDEBUG-DATABASE: SURGERY - Debug FAILED no connection")
            return
        }
        
        // Check table existence and structure
        var stmt: OpaquePointer?
        
        // 1. Count total rows in unified_content
        let countSQL = "SELECT COUNT(*) FROM unified_content;"
        if sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let totalRows = sqlite3_column_int(stmt, 0)
                print("HALDEBUG-DATABASE: SURGERY - Table unified_content has \(totalRows) total rows")
            }
        }
        sqlite3_finalize(stmt)
        
        // 2. Show conversation-type rows specifically with entity keywords
        let convSQL = "SELECT source_id, source_type, position, content, entity_keywords FROM unified_content WHERE source_type = 'conversation' LIMIT 3;"
        if sqlite3_prepare_v2(db, convSQL, -1, &stmt, nil) == SQLITE_OK {
            var convRowCount = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                convRowCount += 1
                
                let sourceId = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "NULL"
                let sourceType = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "NULL"
                let position = sqlite3_column_int(stmt, 2)
                let content = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "NULL"
                let entityKeywords = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "NULL"
                
                print("HALDEBUG-DATABASE: SURGERY - Conv row \(convRowCount): sourceId='\(sourceId.prefix(8))...' type='\(sourceType)' pos=\(position) content='\(content.prefix(20))...' entities='\(entityKeywords)'")
            }
            if convRowCount == 0 {
                print("HALDEBUG-DATABASE: SURGERY - No conversation rows found in table")
            }
        }
        sqlite3_finalize(stmt)
        
        // 3. Show all distinct source_types with entity statistics
        let typesSQL = "SELECT source_type, COUNT(*), COUNT(CASE WHEN entity_keywords IS NOT NULL AND entity_keywords != '' THEN 1 END) FROM unified_content GROUP BY source_type;"
        if sqlite3_prepare_v2(db, typesSQL, -1, &stmt, nil) == SQLITE_OK {
            print("HALDEBUG-DATABASE: SURGERY - Source types with entity statistics:")
            while sqlite3_step(stmt) == SQLITE_ROW {
                let sourceType = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "NULL"
                let count = sqlite3_column_int(stmt, 1)
                let entityCount = sqlite3_column_int(stmt, 2)
                print("HALDEBUG-DATABASE: SURGERY -   type='\(sourceType)' count=\(count) with_entities=\(entityCount)")
            }
        }
        sqlite3_finalize(stmt)
        
        print("HALDEBUG-DATABASE: SURGERY - Enhanced debug DB inspection complete")
    }
}

// ========== BLOCK 9: CONVERSATION STORAGE AND FIXED SEARCH SYSTEM - END ==========


// ========== BLOCK 10: DOCUMENT IMPORT MANAGER IMPLEMENTATION - START ==========

// MARK: - Enhanced Document Import Manager with Entity Extraction
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
    
    // ENHANCED: Main Import Function with Entity Extraction
    func importDocuments(from urls: [URL], chatViewModel: ChatViewModel) async {
        print("HALDEBUG-IMPORT: Starting enhanced document import for \(urls.count) items with entity extraction")
        
        isImporting = true
        importProgress = "Processing documents with entity extraction..."
        
        var processedFiles: [ProcessedDocument] = []
        var skippedFiles: [String] = []
        var totalFilesFound = 0
        var totalEntitiesFound = 0
        
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
            let (filesProcessed, filesSkipped) = await processURLImmediatelyWithEntities(url)
            processedFiles.append(contentsOf: filesProcessed)
            skippedFiles.append(contentsOf: filesSkipped)
            totalFilesFound += filesProcessed.count + filesSkipped.count
            
            // Count entities found
            for file in filesProcessed {
                totalEntitiesFound += file.entities.count
            }
            
            // Update progress after each URL
            importProgress = "Processed \(url.lastPathComponent): \(filesProcessed.count) files, \(totalEntitiesFound) entities"
            
            // Release security access after processing is complete
            url.stopAccessingSecurityScopedResource()
            print("HALDEBUG-IMPORT: Released security access for \(url.lastPathComponent)")
        }
        
        print("HALDEBUG-IMPORT: Processed \(processedFiles.count) documents, skipped \(skippedFiles.count), found \(totalEntitiesFound) entities")
        
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
        
        // Store documents in unified memory with entity keywords
        importProgress = "Storing documents with entities in memory..."
        await storeDocumentsInMemoryWithEntities(processedFiles)
        
        // Generate conversation messages
        await generateImportMessages(documentSummaries: documentSummaries,
                                   totalProcessed: processedFiles.count,
                                   totalEntities: totalEntitiesFound,
                                   chatViewModel: chatViewModel)
        
        // Create enhanced import summary
        lastImportSummary = DocumentImportSummary(
            totalFiles: totalFilesFound,
            processedFiles: processedFiles.count,
            skippedFiles: skippedFiles.count,
            documentSummaries: documentSummaries,
            totalEntitiesFound: totalEntitiesFound,
            processingTime: 0
        )
        
        isImporting = false
        importProgress = "Import complete with \(totalEntitiesFound) entities extracted!"
        
        print("HALDEBUG-IMPORT: Enhanced document import completed with entity extraction")
    }
    
    // ENHANCED: Process URL immediately with entity extraction
    private func processURLImmediatelyWithEntities(_ url: URL) async -> ([ProcessedDocument], [String]) {
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
                    let (subProcessed, subSkipped) = await processURLImmediatelyWithEntities(item)
                    processedFiles.append(contentsOf: subProcessed)
                    skippedFiles.append(contentsOf: subSkipped)
                }
                print("HALDEBUG-IMPORT: Processed directory \(url.lastPathComponent): \(processedFiles.count) files")
            } catch {
                print("HALDEBUG-IMPORT: Error reading directory \(url.path): \(error)")
                skippedFiles.append(url.lastPathComponent)
            }
        } else {
            // Process individual file immediately with entity extraction
            if let processed = await processDocumentImmediatelyWithEntities(url) {
                processedFiles.append(processed)
                print("HALDEBUG-IMPORT: Successfully processed: \(url.lastPathComponent) with \(processed.entities.count) entities")
            } else {
                skippedFiles.append(url.lastPathComponent)
                print("HALDEBUG-IMPORT: Skipped: \(url.lastPathComponent)")
            }
        }
        
        return (processedFiles, skippedFiles)
    }
    
    // ENHANCED: Process document immediately with entity extraction
    private func processDocumentImmediatelyWithEntities(_ url: URL) async -> ProcessedDocument? {
        print("HALDEBUG-IMPORT: Processing document with entity extraction: \(url.lastPathComponent)")
        
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
            
            // ENHANCED: Extract entities from the full document content
            let documentEntities = memoryStore.extractNamedEntities(from: content)
            print("HALDEBUG-IMPORT: Extracted \(documentEntities.count) entities from \(url.lastPathComponent)")
            
            // Log entity breakdown for debugging
            let entityBreakdown = memoryStore.summarizeEntities(documentEntities)
            print("HALDEBUG-IMPORT: Entity breakdown for \(url.lastPathComponent):")
            for (type, count) in entityBreakdown.byType {
                print("HALDEBUG-IMPORT:   \(type.displayName): \(count)")
            }
            
            // Process content into chunks using proven chunking
            let chunks = createMentatChunks(from: content)
            
            print("HALDEBUG-IMPORT: Processed \(url.lastPathComponent): \(content.count) chars, \(chunks.count) chunks, \(documentEntities.count) entities")
            
            return ProcessedDocument(
                url: url,
                filename: url.lastPathComponent,
                content: content,
                chunks: chunks,
                entities: documentEntities,
                fileExtension: fileExtension
            )
            
        } catch {
            print("HALDEBUG-IMPORT: Error processing \(url.lastPathComponent): \(error)")
            return nil
        }
    }
    
    // Content Extraction (unchanged from previous implementation)
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
    
    // Proven Chunking Strategy (400 chars, 50 overlap) - unchanged
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
        
        print("HALDEBUG-IMPORT: Created \(chunks.count) chunks using MENTAT strategy")
        return chunks
    }
    
    // ENHANCED: LLM Document Summarization with entity context
    private func generateDocumentSummary(_ document: ProcessedDocument) async -> String? {
        print("HALDEBUG-IMPORT: Generating LLM summary for: \(document.filename) with \(document.entities.count) entities")
        
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
            
            // ENHANCED: Include entity context in summary generation
            var entityContext = ""
            if !document.entities.isEmpty {
                let personEntities = document.entities.filter { $0.type == .person }.map { $0.text }
                let placeEntities = document.entities.filter { $0.type == .place }.map { $0.text }
                let orgEntities = document.entities.filter { $0.type == .organization }.map { $0.text }
                
                var entityParts: [String] = []
                if !personEntities.isEmpty {
                    entityParts.append("people: \(personEntities.joined(separator: ", "))")
                }
                if !placeEntities.isEmpty {
                    entityParts.append("places: \(placeEntities.joined(separator: ", "))")
                }
                if !orgEntities.isEmpty {
                    entityParts.append("organizations: \(orgEntities.joined(separator: ", "))")
                }
                
                if !entityParts.isEmpty {
                    entityContext = " Key entities mentioned include \(entityParts.joined(separator: "; "))."
                }
            }
            
            let prompt = """
            Summarize this document in one clear, descriptive sentence (filename: \(document.filename)):\(entityContext)
            
            \(contentPreview)
            """
            
            let session = LanguageModelSession()
            let result = try await session.respond(to: Prompt(prompt))
            
            let summary = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
            print("HALDEBUG-IMPORT: Generated entity-enhanced summary: \(summary)")
            return summary
            
        } catch {
            print("HALDEBUG-IMPORT: LLM summarization failed for \(document.filename): \(error)")
            return "Document: \(document.filename)"
        }
    }
    
    // ENHANCED: Store documents in unified memory with entity keywords
    private func storeDocumentsInMemoryWithEntities(_ documents: [ProcessedDocument]) async {
        print("HALDEBUG-IMPORT: Storing \(documents.count) documents in unified memory with entity extraction")
        
        for document in documents {
            // Store source information
            let sourceId = UUID().uuidString
            let timestamp = Date()
            
            print("HALDEBUG-IMPORT: Processing document \(document.filename) with \(document.entities.count) entities")
            
            // ENHANCED: Store each chunk with its specific entity keywords
            for (index, chunk) in document.chunks.enumerated() {
                // Extract entities specific to this chunk
                let chunkEntities = memoryStore.extractNamedEntities(from: chunk)
                
                // Combine document-level entities with chunk-specific entities for comprehensive coverage
                let allRelevantEntities = (document.entities + chunkEntities)
                let uniqueEntities = Array(Set(allRelevantEntities)) // Remove duplicates
                
                // Create lowercase entity keywords string for search
                let entityKeywords = uniqueEntities.map { $0.text.lowercased() }.joined(separator: " ")
                
                print("HALDEBUG-IMPORT: Chunk \(index + 1) has \(chunkEntities.count) specific + \(document.entities.count) document entities = \(uniqueEntities.count) total unique")
                
                let contentId = memoryStore.storeUnifiedContentWithEntities(
                    content: chunk,
                    sourceType: .document,
                    sourceId: sourceId,
                    position: index,
                    timestamp: timestamp,
                    entityKeywords: entityKeywords
                )
                
                if !contentId.isEmpty {
                    print("HALDEBUG-IMPORT: Stored chunk \(index + 1)/\(document.chunks.count) for \(document.filename) with \(uniqueEntities.count) entities")
                }
            }
        }
        
        print("HALDEBUG-IMPORT: Enhanced document storage with entities completed")
    }
    
    // ENHANCED: Generate import messages with entity context
    private func generateImportMessages(documentSummaries: [String],
                                      totalProcessed: Int,
                                      totalEntities: Int,
                                      chatViewModel: ChatViewModel) async {
        print("HALDEBUG-IMPORT: Generating import conversation messages with entity context")
        
        // ENHANCED: Create user auto-message with entity context
        let userMessage: String
        if documentSummaries.count == 1 {
            let entityText = totalEntities > 0 ? " containing \(totalEntities) named entities" : ""
            userMessage = "Hal, here's a document for you\(entityText): \(documentSummaries[0])"
        } else {
            let numberedList = documentSummaries.enumerated().map { (index, summary) in
                "\(index + 1)) \(summary)"
            }.joined(separator: ", ")
            let entityText = totalEntities > 0 ? " with \(totalEntities) named entities extracted" : ""
            userMessage = "Hal, here are \(documentSummaries.count) documents for you\(entityText): \(numberedList)"
        }
        
        // Add user message to conversation
        let userChatMessage = ChatMessage(content: userMessage, isFromUser: true)
        chatViewModel.messages.append(userChatMessage)
        
        // ENHANCED: Generate HAL's response with entity awareness
        let halResponse: String
        if documentSummaries.count == 1 {
            let entityResponse = totalEntities > 0 ? " I've identified \(totalEntities) named entities within the content, which will help me answer specific questions about people, places, and organizations mentioned." : ""
            halResponse = "Thanks for sharing that document! I've read through it and processed all the content.\(entityResponse) I'm ready to discuss any questions you have about the material."
        } else {
            let entityResponse = totalEntities > 0 ? " I've extracted \(totalEntities) named entities across all documents, giving me detailed knowledge about the people, places, and organizations mentioned." : ""
            halResponse = "Thanks for those \(documentSummaries.count) documents! I've read through all of them and processed the content.\(entityResponse) I'm ready to discuss any aspect of the material you'd like to explore."
        }
        
        // Add HAL's response
        let halChatMessage = ChatMessage(content: halResponse, isFromUser: false)
        chatViewModel.messages.append(halChatMessage)
        
        // Store the conversation turn in memory with entity extraction
        let currentTurnNumber = chatViewModel.messages.filter { $0.isFromUser }.count
        chatViewModel.memoryStore.storeTurn(
            conversationId: chatViewModel.conversationId,
            userMessage: userMessage,
            assistantMessage: halResponse,
            systemPrompt: chatViewModel.systemPrompt,
            turnNumber: currentTurnNumber
        )
        
        print("HALDEBUG-IMPORT: Generated enhanced import conversation messages with entity context")
    }
}

// MARK: - Enhanced Supporting Data Models with Entity Support
struct ProcessedDocument {
    let url: URL
    let filename: String
    let content: String
    let chunks: [String]
    let entities: [NamedEntity]  // ENHANCED: Named entities found in document
    let fileExtension: String
}

struct DocumentImportSummary {
    let totalFiles: Int
    let processedFiles: Int
    let skippedFiles: Int
    let documentSummaries: [String]
    let totalEntitiesFound: Int  // ENHANCED: Total entities extracted across all documents
    let processingTime: TimeInterval
}

// ========== BLOCK 10: DOCUMENT IMPORT MANAGER IMPLEMENTATION - END ==========
