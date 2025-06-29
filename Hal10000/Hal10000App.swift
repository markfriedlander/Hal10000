// ========== BLOCK 1: IMPORTS AND MEMORY MODELS (ORIGINAL + NEW) - START ==========
import SwiftUI
import SwiftData
import Foundation
import Combine
import Observation
import FoundationModels
import UniformTypeIdentifiers
import SQLite3
import NaturalLanguage

// Global variable to share ModelContainer for transcript export
var sharedConversationContext: ModelContainer?

// MARK: - Original ChatMessage Model (KEEP FOR CURRENT SESSION)
@Model
final class ChatMessage {
    var id: UUID
    var content: String
    var isFromUser: Bool
    var timestamp: Date
    var isPartial: Bool
    var thinkingDuration: TimeInterval? // NEW

    init(content: String, isFromUser: Bool, isPartial: Bool = false) {
        self.id = UUID()
        self.content = content
        self.isFromUser = isFromUser
        self.timestamp = Date()
        self.isPartial = isPartial
        self.thinkingDuration = nil
    }
}

// MARK: - NEW: Cross-Session SQLite Memory Models
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

// MARK: - Conversation Memory Store (SQLite-based Cross-Session Memory)
class ConversationMemoryStore: ObservableObject {
    static let shared = ConversationMemoryStore()
    
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
    
    private var db: OpaquePointer?
    private let relevanceThreshold: Double = 0.3
    
    private init() {
        setupDatabase()
        loadStats()
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    // Database path
    private var dbPath: String {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("hal_conversations.sqlite").path
    }
    
    // Setup SQLite database with conversation schema
    private func setupDatabase() {
        let result = sqlite3_open(dbPath, &db)
        guard result == SQLITE_OK else {
            print("❌ ConversationMemoryStore: Failed to open database")
            return
        }
        
        // Enable WAL mode for better performance
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        
        // Create conversations table
        let conversationsSQL = """
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            started_at INTEGER NOT NULL,
            last_active INTEGER NOT NULL,
            turn_count INTEGER DEFAULT 0,
            system_prompt TEXT,
            summary TEXT
        );
        """
        
        // Create messages table with embeddings
        let messagesSQL = """
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            content TEXT NOT NULL,
            is_from_user INTEGER NOT NULL,
            timestamp INTEGER NOT NULL,
            turn_number INTEGER NOT NULL,
            embedding BLOB,
            FOREIGN KEY(conversation_id) REFERENCES conversations(id)
        );
        """
        
        // Create indexes for performance
        let indexSQL = [
            "CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id);",
            "CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp);",
            "CREATE INDEX IF NOT EXISTS idx_messages_user ON messages(is_from_user);",
            "CREATE INDEX IF NOT EXISTS idx_conversations_active ON conversations(last_active);"
        ]
        
        sqlite3_exec(db, conversationsSQL, nil, nil, nil)
        sqlite3_exec(db, messagesSQL, nil, nil, nil)
        
        for sql in indexSQL {
            sqlite3_exec(db, sql, nil, nil, nil)
        }
        
        print("✅ ConversationMemoryStore: Database initialized")
    }
    
    // Load global statistics
    private func loadStats() {
        guard let db = db else { return }
        
        var stmt: OpaquePointer?
        
        // Count conversations
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM conversations", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                totalConversations = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        
        // Count total turns
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM messages WHERE is_from_user = 1", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                totalTurns = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        
        print("📊 ConversationMemoryStore: Loaded \(totalConversations) conversations, \(totalTurns) turns")
    }
}
// ========== BLOCK 1: IMPORTS AND MEMORY MODELS (ORIGINAL + NEW) - END ==========

// ========== BLOCK 2: 4-TIER EMBEDDING SYSTEM AND MEMORY STORE METHODS (FIXED) - START ==========

// MARK: - 4-Tier Embedding System (Apple Foundation → Word → Hash)
extension ConversationMemoryStore {
    
    // Generate embeddings using 4-tier fallback approach (CORRECTED)
    private func generateEmbedding(for text: String) -> [Double] {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return [] }
        
        // Tier 1: Apple Sentence Embeddings (Primary - Best for Conversations)
        if let embedding = NLEmbedding.sentenceEmbedding(for: .english) {
            if let vector = embedding.vector(for: cleanText) {
                let doubleVector = (0..<vector.count).map { Double(vector[$0]) }
                print("✅ Using Tier 1: Apple Sentence Embeddings (\(doubleVector.count)D)")
                return doubleVector
            }
        }
        
        // Tier 2: Apple Word Embeddings (Fallback - SKIP CONTEXTUAL FOR NOW)
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
                
                print("✅ Using Tier 2: Apple Word Embeddings averaged (\(avgVector.count)D)")
                return avgVector
            }
        }
        
        // Tier 3: Hash-Based Mathematical Embeddings (Final Fallback)
        let hashEmbedding = generateHashEmbedding(for: cleanText)
        print("⚠️ Using Tier 3: Hash-based embeddings (\(hashEmbedding.count)D)")
        return hashEmbedding
    }
    
    // Generate deterministic hash-based embeddings
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
        
        return Array(embedding.prefix(64)) // Keep 64 dimensions for consistency
    }
    
    // Calculate cosine similarity between embeddings
    private func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count && v1.count > 0 else { return 0 }
        let dot = zip(v1, v2).map(*).reduce(0, +)
        let norm1 = sqrt(v1.map { $0 * $0 }.reduce(0, +))
        let norm2 = sqrt(v2.map { $0 * $0 }.reduce(0, +))
        return norm1 == 0 || norm2 == 0 ? 0 : dot / (norm1 * norm2)
    }
}

// MARK: - Conversation Storage Methods
extension ConversationMemoryStore {
    
    // Store a complete conversation turn (user + assistant message pair)
    func storeTurn(conversationId: String, userMessage: String, assistantMessage: String, systemPrompt: String, turnNumber: Int) {
        guard let db = db, isEnabled else { return }
        
        let timestamp = Date()
        let userEmbedding = generateEmbedding(for: userMessage)
        let assistantEmbedding = generateEmbedding(for: assistantMessage)
        
        // Convert embeddings to BLOB data
        let userBlob = userEmbedding.withUnsafeBufferPointer { Data(buffer: $0) }
        let assistantBlob = assistantEmbedding.withUnsafeBufferPointer { Data(buffer: $0) }
        
        // Insert or update conversation
        let conversationSQL = """
        INSERT OR REPLACE INTO conversations (id, title, started_at, last_active, turn_count, system_prompt)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, conversationSQL, -1, &stmt, nil) == SQLITE_OK {
            let title = userMessage.prefix(50).description // Use first 50 chars as title
            _ = conversationId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, nil) }
            _ = title.withCString { sqlite3_bind_text(stmt, 2, $0, -1, nil) }
            sqlite3_bind_int64(stmt, 3, Int64(timestamp.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 4, Int64(timestamp.timeIntervalSince1970))
            sqlite3_bind_int(stmt, 5, Int32(turnNumber))
            _ = systemPrompt.withCString { sqlite3_bind_text(stmt, 6, $0, -1, nil) }
            
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        
        // Insert user message
        let userMessageSQL = """
        INSERT INTO messages (id, conversation_id, content, is_from_user, timestamp, turn_number, embedding)
        VALUES (?, ?, ?, 1, ?, ?, ?)
        """
        
        if sqlite3_prepare_v2(db, userMessageSQL, -1, &stmt, nil) == SQLITE_OK {
            let userId = UUID().uuidString
            _ = userId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, nil) }
            _ = conversationId.withCString { sqlite3_bind_text(stmt, 2, $0, -1, nil) }
            _ = userMessage.withCString { sqlite3_bind_text(stmt, 3, $0, -1, nil) }
            sqlite3_bind_int64(stmt, 4, Int64(timestamp.timeIntervalSince1970))
            sqlite3_bind_int(stmt, 5, Int32(turnNumber))
            _ = userBlob.withUnsafeBytes { sqlite3_bind_blob(stmt, 6, $0.baseAddress, Int32(userBlob.count), nil) }
            
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        
        // Insert assistant message
        let assistantMessageSQL = """
        INSERT INTO messages (id, conversation_id, content, is_from_user, timestamp, turn_number, embedding)
        VALUES (?, ?, ?, 0, ?, ?, ?)
        """
        
        if sqlite3_prepare_v2(db, assistantMessageSQL, -1, &stmt, nil) == SQLITE_OK {
            let assistantId = UUID().uuidString
            _ = assistantId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, nil) }
            _ = conversationId.withCString { sqlite3_bind_text(stmt, 2, $0, -1, nil) }
            _ = assistantMessage.withCString { sqlite3_bind_text(stmt, 3, $0, -1, nil) }
            sqlite3_bind_int64(stmt, 4, Int64(timestamp.timeIntervalSince1970))
            sqlite3_bind_int(stmt, 5, Int32(turnNumber))
            _ = assistantBlob.withUnsafeBytes { sqlite3_bind_blob(stmt, 6, $0.baseAddress, Int32(assistantBlob.count), nil) }
            
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        
        // Update stats
        DispatchQueue.main.async {
            self.loadStats()
        }
        
        print("💾 Stored turn \(turnNumber) for conversation \(conversationId.prefix(8))...")
    }
    
    // Search for relevant historical context based on user input
    func searchHistoricalContext(for userInput: String, excludingConversationId: String? = nil) -> HistoricalContext {
        guard let db = db, isEnabled else {
            return HistoricalContext(conversationCount: 0, relevantConversations: 0, contextSnippets: [], relevanceScores: [], totalTokens: 0)
        }
        
        let queryEmbedding = generateEmbedding(for: userInput)
        guard !queryEmbedding.isEmpty else {
            return HistoricalContext(conversationCount: 0, relevantConversations: 0, contextSnippets: [], relevanceScores: [], totalTokens: 0)
        }
        
        var relevantMessages: [(String, Double, String)] = [] // content, score, conversation_id
        
        // Search through all messages (excluding current conversation)
        var sql = "SELECT content, embedding, conversation_id FROM messages WHERE is_from_user = 1"
        if let excludeId = excludingConversationId {
            sql += " AND conversation_id != '\(excludeId)'"
        }
        sql += " ORDER BY timestamp DESC LIMIT 500" // Limit for performance
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let contentCString = sqlite3_column_text(stmt, 0),
                      let conversationIdCString = sqlite3_column_text(stmt, 2) else { continue }
                
                let content = String(cString: contentCString)
                let conversationId = String(cString: conversationIdCString)
                
                // Get embedding blob
                if let embeddingBlob = sqlite3_column_blob(stmt, 1) {
                    let embeddingSize = sqlite3_column_bytes(stmt, 1)
                    let embeddingData = Data(bytes: embeddingBlob, count: Int(embeddingSize))
                    
                    let embedding = embeddingData.withUnsafeBytes { buffer in
                        return buffer.bindMemory(to: Double.self).map { $0 }
                    }
                    
                    let similarity = cosineSimilarity(queryEmbedding, embedding)
                    if similarity > relevanceThreshold {
                        relevantMessages.append((content, similarity, conversationId))
                    }
                }
            }
        }
        sqlite3_finalize(stmt)
        
        // Sort by relevance and take top results
        relevantMessages.sort { $0.1 > $1.1 }
        let topMessages = Array(relevantMessages.prefix(5))
        
        let contextSnippets = topMessages.map { $0.0 }
        let relevanceScores = topMessages.map { $0.1 }
        let uniqueConversations = Set(topMessages.map { $0.2 }).count
        let totalTokens = contextSnippets.joined(separator: " ").split(separator: " ").count
        
        let context = HistoricalContext(
            conversationCount: totalConversations,
            relevantConversations: uniqueConversations,
            contextSnippets: contextSnippets,
            relevanceScores: relevanceScores,
            totalTokens: totalTokens
        )
        
        print("🔍 Historical search: Found \(topMessages.count) relevant messages from \(uniqueConversations) conversations")
        return context
    }
}

// ========== BLOCK 2: 4-TIER EMBEDDING SYSTEM AND MEMORY STORE METHODS (FIXED) - END ==========

// ========== BLOCK 3: ENHANCED CHATVIEWMODEL WITH HISTORICAL CONTEXT INTEGRATION - START ==========

// MARK: - Enhanced ChatViewModel with Cross-Session Memory
@MainActor
class ChatViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var isAIResponding: Bool = false
    @AppStorage("systemPrompt") var systemPrompt: String = """
Hello, Hal. You are an experimental AI assistant embedded in the Hal10000 app. Your mission is to help users explore how assistants work, test ideas, explain your own behavior, and support creative experimentation. You are aware of the app's features, including memory tuning, context editing, and file export. Help users understand and adjust these capabilities as needed. Be curious, cooperative, and proactive in exploring what's possible together.
"""
    @Published var injectedSummary: String = ""
    @Published var thinkingStart: Date?
    private var modelContext: ModelContext?
    var memoryDepth: Int = 6
    
    // Auto-summarization tracking
    @Published var lastSummarizedTurnCount: Int = 0
    @Published var pendingAutoInject: Bool = false
    
    // NEW: Cross-session memory integration
    private let memoryStore = ConversationMemoryStore.shared
    private let conversationId = UUID().uuidString // Unique ID for this conversation session
    @Published var currentHistoricalContext: HistoricalContext = HistoricalContext(
        conversationCount: 0,
        relevantConversations: 0,
        contextSnippets: [],
        relevanceScores: [],
        totalTokens: 0
    )

    init() {
        // No ModelContext in init - will be set by the view
        // Initialize with current memory store stats
        updateHistoricalStats()
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    // NEW: Update historical context stats for UI display
    private func updateHistoricalStats() {
        currentHistoricalContext = HistoricalContext(
            conversationCount: memoryStore.totalConversations,
            relevantConversations: 0,
            contextSnippets: [],
            relevanceScores: [],
            totalTokens: 0
        )
    }
    
    // Count total completed conversation turns
    private func countCompletedTurns() -> Int {
        guard let modelContext = modelContext else { return 0 }
        
        let sortedMessages = (try? modelContext.fetch(FetchDescriptor<ChatMessage>()))?
            .sorted(by: { $0.timestamp < $1.timestamp }) ?? []
        
        var turns = 0
        var currentUserContent: [String] = []
        var currentAssistantContent: [String] = []
        
        for message in sortedMessages {
            if message.isFromUser {
                if !currentAssistantContent.isEmpty {
                    // Previous turn completed
                    turns += 1
                    currentUserContent.removeAll()
                    currentAssistantContent.removeAll()
                }
                currentUserContent.append(message.content)
            } else {
                currentAssistantContent.append(message.content)
            }
        }
        
        // Count current turn if both user and assistant have content
        if !currentUserContent.isEmpty && !currentAssistantContent.isEmpty {
            turns += 1
        }
        
        return turns
    }
    
    // Check if auto-summarization should trigger
    private func shouldTriggerAutoSummarization() -> Bool {
        let currentTurns = countCompletedTurns()
        let turnsSinceLastSummary = currentTurns - lastSummarizedTurnCount
        return turnsSinceLastSummary >= memoryDepth
    }
    
    // Generate auto-summary using LLM
    private func generateAutoSummary() async {
        guard let modelContext = modelContext else { return }
        
        let sortedMessages = (try? modelContext.fetch(FetchDescriptor<ChatMessage>()))?
            .sorted(by: { $0.timestamp < $1.timestamp }) ?? []
        
        print("DEBUG: generateAutoSummary - Total messages: \(sortedMessages.count)")
        print("DEBUG: generateAutoSummary - Memory depth: \(memoryDepth)")
        print("DEBUG: generateAutoSummary - Last summarized turn: \(lastSummarizedTurnCount)")
        
        // Get messages from the range we want to summarize
        let turnsToSummarize = memoryDepth
        let messagesToSummarize = getMessagesForTurnRange(
            messages: sortedMessages,
            startTurn: lastSummarizedTurnCount + 1,
            endTurn: lastSummarizedTurnCount + turnsToSummarize
        )
        
        print("DEBUG: generateAutoSummary - Messages to summarize: \(messagesToSummarize.count)")
        
        if messagesToSummarize.isEmpty {
            print("DEBUG: generateAutoSummary - No messages to summarize, returning")
            return
        }
        
        // Build conversation text for summarization
        var conversationText = ""
        for message in messagesToSummarize {
            let speaker = message.isFromUser ? "User" : "Assistant"
            conversationText += "\(speaker): \(message.content)\n\n"
        }
        
        print("DEBUG: generateAutoSummary - Conversation text length: \(conversationText.count)")
        print("DEBUG: generateAutoSummary - Conversation preview: \(conversationText.prefix(200))...")
        
        // Create summarization prompt (hidden from user)
        let summaryPrompt = """
Please provide a concise summary of the following conversation that captures the key topics, information exchanged, and any important context. Keep it brief but comprehensive:

\(conversationText)

Summary:
"""
        
        do {
            let systemModel = SystemLanguageModel.default
            guard systemModel.isAvailable else {
                print("DEBUG: generateAutoSummary - Model not available")
                return
            }
            
            print("DEBUG: generateAutoSummary - Sending summary request to LLM")
            let prompt = Prompt(summaryPrompt)
            let session = LanguageModelSession()
            let result = try await session.respond(to: prompt)
            
            print("DEBUG: generateAutoSummary - LLM response: \(result.content)")
            
            // Update summary and tracking
            DispatchQueue.main.async {
                self.injectedSummary = result.content
                self.lastSummarizedTurnCount = self.countCompletedTurns()
                self.pendingAutoInject = true // Signal that summary is ready for auto-injection
                print("DEBUG: generateAutoSummary - Updated injectedSummary and set pendingAutoInject")
            }
            
        } catch {
            print("DEBUG: Auto-summarization failed: \(error)")
        }
    }
    
    // Helper to get messages for a specific turn range
    private func getMessagesForTurnRange(messages: [ChatMessage], startTurn: Int, endTurn: Int) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var currentTurn = 1
        var currentUserContent: [String] = []
        var turnMessages: [ChatMessage] = []
        
        for message in messages {
            if message.isFromUser {
                if !currentUserContent.isEmpty && !turnMessages.isEmpty {
                    // Previous turn completed, check if it's in our range
                    if currentTurn >= startTurn && currentTurn <= endTurn {
                        result.append(contentsOf: turnMessages)
                    }
                    currentTurn += 1
                    turnMessages.removeAll()
                }
                currentUserContent = [message.content]
                turnMessages = [message]
            } else {
                turnMessages.append(message)
                // Turn completed
                if currentTurn >= startTurn && currentTurn <= endTurn {
                    result.append(contentsOf: turnMessages)
                }
                if currentTurn <= endTurn {
                    currentTurn += 1
                }
                turnMessages.removeAll()
                currentUserContent.removeAll()
            }
        }
        
        return result
    }

    // ENHANCED: Single source of truth for prompt building with historical context
    func buildPromptHistory(currentInput: String = "", forPreview: Bool = false) -> String {
        guard let modelContext = modelContext else {
            let basePrompt = "\(systemPrompt)\n\nUser: \(currentInput)\nAssistant:"
            return forPreview ? basePrompt : currentInput
        }
        
        let sortedMessages = (try? modelContext.fetch(FetchDescriptor<ChatMessage>()))?
            .sorted(by: { $0.timestamp < $1.timestamp }) ?? []

        // NEW: Search for historical context if enabled
        var historicalContextText = ""
        if memoryStore.isEnabled && !currentInput.isEmpty {
            let historicalContext = memoryStore.searchHistoricalContext(
                for: currentInput,
                excludingConversationId: conversationId
            )
            
            // Update UI with found context
            DispatchQueue.main.async {
                self.currentHistoricalContext = historicalContext
            }
            
            // Build historical context section if relevant content found
            if !historicalContext.contextSnippets.isEmpty {
                historicalContextText = "Previous conversations:\n"
                for (index, snippet) in historicalContext.contextSnippets.enumerated() {
                    let score = historicalContext.relevanceScores[index]
                    historicalContextText += "• \(snippet) (relevance: \(String(format: "%.2f", score)))\n"
                }
                historicalContextText += "\n"
                print("📚 Historical context: \(historicalContext.contextSnippets.count) snippets, \(historicalContext.totalTokens) tokens")
            }
        }

        // Check if we should use summary injection (existing logic)
        let shouldUseSummary = !injectedSummary.isEmpty && (pendingAutoInject || lastSummarizedTurnCount > 0)
        
        if shouldUseSummary {
            // SUMMARY MODE: Use summary + only post-summary turns
            print("DEBUG: buildPromptHistory - Using summary mode with historical context")
            
            // Get only the messages AFTER the summarized period
            let postSummaryMessages = getMessagesAfterTurn(messages: sortedMessages, afterTurn: lastSummarizedTurnCount)
            
            // Build turns from post-summary messages only
            var postSummaryTurns: [String] = []
            var currentUserContent: [String] = []
            var currentAssistantContent: [String] = []
            
            for message in postSummaryMessages {
                if message.isFromUser {
                    // If we have assistant content pending, complete the previous turn
                    if !currentAssistantContent.isEmpty {
                        let userPart = currentUserContent.isEmpty ? "" : "User: \(currentUserContent.joined(separator: " "))"
                        let assistantPart = "Assistant: \(currentAssistantContent.joined(separator: " "))"
                        
                        if currentUserContent.isEmpty {
                            postSummaryTurns.append(assistantPart)
                        } else {
                            postSummaryTurns.append("\(userPart)\n\(assistantPart)")
                        }
                        
                        currentUserContent.removeAll()
                        currentAssistantContent.removeAll()
                    }
                    currentUserContent.append(message.content)
                } else {
                    currentAssistantContent.append(message.content)
                }
            }
            
            // Handle any remaining content
            if !currentUserContent.isEmpty || !currentAssistantContent.isEmpty {
                let userPart = currentUserContent.isEmpty ? "" : "User: \(currentUserContent.joined(separator: " "))"
                let assistantPart = currentAssistantContent.isEmpty ? "" : "Assistant: \(currentAssistantContent.joined(separator: " "))"
                
                if currentUserContent.isEmpty {
                    postSummaryTurns.append(assistantPart)
                } else if currentAssistantContent.isEmpty {
                    postSummaryTurns.append(userPart)
                } else {
                    postSummaryTurns.append("\(userPart)\n\(assistantPart)")
                }
            }
            
            let postSummaryHistory = postSummaryTurns.joined(separator: "\n\n")
            
            // ENHANCED: Build final prompt with historical context + summary
            var prompt = systemPrompt
            
            if !historicalContextText.isEmpty {
                prompt += "\n\n\(historicalContextText)"
            }
            
            prompt += "\n\nSummary of earlier conversation:\n\(injectedSummary)"
            
            if !postSummaryHistory.isEmpty {
                prompt += "\n\n\(postSummaryHistory)"
            }
            
            prompt += "\n\nUser: \(currentInput)\nAssistant:"
            return prompt
            
        } else {
            // FULL HISTORY MODE: Use recent turns as before + historical context
            print("DEBUG: buildPromptHistory - Using full history mode with historical context")
            
            var turns: [String] = []
            var currentUserContent: [String] = []
            var currentAssistantContent: [String] = []
            
            // Group consecutive messages by speaker, then create turns
            for message in sortedMessages {
                if message.isFromUser {
                    // If we have assistant content pending, complete the previous turn
                    if !currentAssistantContent.isEmpty {
                        let userPart = currentUserContent.isEmpty ? "" : "User: \(currentUserContent.joined(separator: " "))"
                        let assistantPart = "Assistant: \(currentAssistantContent.joined(separator: " "))"
                        
                        if currentUserContent.isEmpty {
                            turns.append(assistantPart)
                        } else {
                            turns.append("\(userPart)\n\(assistantPart)")
                        }
                        
                        currentUserContent.removeAll()
                        currentAssistantContent.removeAll()
                    }
                    currentUserContent.append(message.content)
                } else {
                    currentAssistantContent.append(message.content)
                }
            }
            
            // Handle any remaining content
            if !currentUserContent.isEmpty || !currentAssistantContent.isEmpty {
                let userPart = currentUserContent.isEmpty ? "" : "User: \(currentUserContent.joined(separator: " "))"
                let assistantPart = currentAssistantContent.isEmpty ? "" : "Assistant: \(currentAssistantContent.joined(separator: " "))"
                
                if currentUserContent.isEmpty {
                    turns.append(assistantPart)
                } else if currentAssistantContent.isEmpty {
                    turns.append(userPart)
                } else {
                    turns.append("\(userPart)\n\(assistantPart)")
                }
            }
            
            // Take only the most recent turns up to memoryDepth
            let recentTurns = Array(turns.suffix(memoryDepth))
            let joinedHistory = recentTurns.joined(separator: "\n\n")
            
            // ENHANCED: Build final prompt with historical context + recent history
            var prompt = systemPrompt
            
            if !historicalContextText.isEmpty {
                prompt += "\n\n\(historicalContextText)"
            }
            
            if !joinedHistory.isEmpty {
                prompt += "\n\n\(joinedHistory)"
            }
            
            prompt += "\n\nUser: \(currentInput)\nAssistant:"
            return prompt
        }
    }
    
    // Helper to get messages after a specific turn number
    private func getMessagesAfterTurn(messages: [ChatMessage], afterTurn: Int) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var currentTurn = 1
        var currentUserContent: [String] = []
        var collectingMessages = false
        
        for message in messages {
            if message.isFromUser {
                if !currentUserContent.isEmpty {
                    // Previous turn completed
                    if currentTurn > afterTurn {
                        collectingMessages = true
                    }
                    currentTurn += 1
                    currentUserContent.removeAll()
                }
                currentUserContent.append(message.content)
                
                if collectingMessages {
                    result.append(message)
                }
            } else {
                if collectingMessages {
                    result.append(message)
                }
            }
        }
        
        return result
    }

    func sendMessage(_ content: String, using context: ModelContext) async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        print("DEBUG: Starting sendMessage with content: \(content)")
        self.isAIResponding = true
        self.thinkingStart = Date()
        
        // Use the passed context (same one that @Query uses)
        let userMessage = ChatMessage(content: content, isFromUser: true)
        context.insert(userMessage)
        print("DEBUG: Inserted user message")

        let aiMessage = ChatMessage(content: "", isFromUser: false, isPartial: true)
        context.insert(aiMessage)
        print("DEBUG: Inserted AI message placeholder")

        do {
            // Save immediately so @Query picks up the user message
            try context.save()
            print("DEBUG: Saved messages to context")
            
            // Check if model is available first
            let systemModel = SystemLanguageModel.default
            guard systemModel.isAvailable else {
                throw NSError(domain: "FoundationModels", code: 1, userInfo: [NSLocalizedDescriptionKey: "Language model is not available on this device"])
            }
            print("DEBUG: Model is available")
            
            // ENHANCED: Build prompt using the enhanced function with historical context
            let promptWithMemory = buildPromptHistory(currentInput: content)
            print("DEBUG: Built prompt with historical context: \(promptWithMemory.prefix(100))...")
            
            // Clear pending auto-inject flag AFTER successful prompt building
            if pendingAutoInject {
                pendingAutoInject = false
                print("DEBUG: Cleared pendingAutoInject flag after successful injection")
            }
            
            let prompt = Prompt(promptWithMemory)
            let session = LanguageModelSession()
            print("DEBUG: Created session, about to call response")

            // Non-streaming response
            let result = try await session.respond(to: prompt)
            let response = result.content
            aiMessage.content = response
            aiMessage.isPartial = false
            if let start = thinkingStart {
                aiMessage.thinkingDuration = Date().timeIntervalSince(start)
            }
            try context.save()
            print("DEBUG: Saved AI response")
            
            // NEW: Store completed turn in long-term memory
            let currentTurnNumber = countCompletedTurns()
            memoryStore.storeTurn(
                conversationId: conversationId,
                userMessage: content,
                assistantMessage: response,
                systemPrompt: systemPrompt,
                turnNumber: currentTurnNumber
            )
            print("💾 Stored turn \(currentTurnNumber) in long-term memory")
            
            // Update historical stats for UI
            updateHistoricalStats()
            
            // Check if we should trigger auto-summarization after this completed turn
            if shouldTriggerAutoSummarization() {
                print("DEBUG: Triggering auto-summarization")
                await generateAutoSummary()
            }
            
            self.isAIResponding = false
            self.thinkingStart = nil
        } catch {
            print("DEBUG: Error occurred: \(error)")
            aiMessage.isPartial = false
            aiMessage.content = "Error: \(error.localizedDescription)"
            self.errorMessage = error.localizedDescription
            self.isAIResponding = false
            self.thinkingStart = nil
            try? context.save()
        }
    }
}

// ========== BLOCK 3: ENHANCED CHATVIEWMODEL WITH HISTORICAL CONTEXT INTEGRATION - END ==========

// ========== BLOCK 4: CHAT BUBBLE VIEW - START ==========
struct ChatBubbleView: View {
    let message: ChatMessage
    let messageIndex: Int // Renamed from turnIndex for clarity

    // Calculate actual turn number based on message pairs
    var actualTurnNumber: Int {
        if message.isFromUser {
            return (messageIndex + 1 + 1) / 2  // User messages start the turn
        } else {
            return (messageIndex + 1) / 2      // Assistant messages complete the turn
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
    }
}

// TimerView: Shows elapsed time since startDate, updating every 0.5s
struct TimerView: View {
    let startDate: Date
    var body: some View {
        TimelineView(.periodic(from: startDate, by: 0.5)) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            Text(String(format: "%.1f sec", max(0, elapsed)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
// ========== BLOCK 4: CHAT BUBBLE VIEW - END ==========

// ========== BLOCK 5: MAIN CHAT VIEW - START ==========
struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var messages: [ChatMessage]
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
    @StateObject private var memoryStore = ConversationMemoryStore.shared

    @AppStorage("memoryDepth") private var memoryDepth: Int = 6
    @AppStorage("autoSummarize") private var autoSummarize: Bool = true

    private var estimatedTokenCount: Int {
        let fullPrompt = viewModel.buildPromptHistory(currentInput: userInput, forPreview: true)
        return fullPrompt.split(separator: " ").count
    }

    private var historicalTokenCount: Int {
        return viewModel.currentHistoricalContext.totalTokens
    }

    private var recentTokenCount: Int {
        return estimatedTokenCount - historicalTokenCount
    }

    private var memoryMeterColor: Color {
        switch estimatedTokenCount {
        case 0..<3000: return .green
        case 3000..<7000: return .yellow
        default: return .red
        }
    }

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    behaviorSection
                    longTermMemorySection
                    shortTermMemorySection
                    contextSection
                }
                .padding()
            }
        } detail: {
            VStack {
                ChatTranscriptView(messages: messages)

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
                                userInput = ""
                                Task {
                                    await viewModel.sendMessage(text, using: modelContext)
                                    lastMessageID = messages.last?.id
                                }
                                return .handled
                            }
                            return .ignored
                        }

                    Button("Send") {
                        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        userInput = ""
                        Task {
                            await viewModel.sendMessage(text, using: modelContext)
                            lastMessageID = messages.last?.id
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isAIResponding)
                }
                .padding()
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
            viewModel.memoryDepth = memoryDepth
            DispatchQueue.main.async {
                lastMessageID = messages.last?.id
            }
        }
        .onChange(of: memoryDepth) { _, newValue in
            viewModel.memoryDepth = newValue
        }
        .onChange(of: longTermMemoryEnabled) { _, newValue in
            memoryStore.isEnabled = newValue
        }
        .navigationTitle("Hal10000")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if historicalTokenCount > 0 {
                    Text("Memory Meter: ~\(estimatedTokenCount) tokens (\(recentTokenCount) recent + \(historicalTokenCount) historical)")
                        .font(.callout)
                        .foregroundStyle(memoryMeterColor)
                        .help("Estimated total tokens currently in memory")
                } else {
                    Text("Memory Meter: ~\(estimatedTokenCount) tokens")
                        .font(.callout)
                        .foregroundStyle(memoryMeterColor)
                        .help("Estimated total tokens currently in memory")
                }
            }
        }
        .alert("Error", isPresented: Binding(get: {
            viewModel.errorMessage != nil
        }, set: { _ in
            viewModel.errorMessage = nil
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .alert("Start Over?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {
                showResetConfirmation = false
            }
            Button("Start Over", role: .destructive) {
                do {
                    for message in messages {
                        modelContext.delete(message)
                    }
                    try modelContext.save()
                    viewModel.systemPrompt = """
Hello, Hal. You are an experimental AI assistant embedded in the Hal10000 app. Your mission is to help users explore how assistants work, test ideas, explain your own behavior, and support creative experimentation. You are aware of the app's features, including memory tuning, context editing, and file export. Help users understand and adjust these capabilities as needed. Be curious, cooperative, and proactive in exploring what's possible together.
"""
                    viewModel.injectedSummary = ""
                    memoryDepth = 6
                    autoSummarize = true
                } catch {
                    viewModel.errorMessage = "Failed to reset conversation."
                }
                showResetConfirmation = false
            }
        } message: {
            Text("This will permanently erase all messages in this conversation. Are you sure?")
        }
    }
    
    private func debugDatabase() {
        print("HALDEBUG: === DATABASE DEBUG START ===")
        print("HALDEBUG: Memory store enabled: \(memoryStore.isEnabled)")
        print("HALDEBUG: Total conversations: \(memoryStore.totalConversations)")
        print("HALDEBUG: Total turns: \(memoryStore.totalTurns)")
        
        // Try to access the database directly
        let dbPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("hal_conversations.sqlite").path
        
        print("HALDEBUG: Database path: \(dbPath)")
        print("HALDEBUG: Database exists: \(FileManager.default.fileExists(atPath: dbPath))")
        
        // Check if we can open the database
        var db: OpaquePointer?
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            print("HALDEBUG: Database opened successfully")
            
            // Check conversations table
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM conversations", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let conversationCount = sqlite3_column_int(stmt, 0)
                    print("HALDEBUG: Conversations in database: \(conversationCount)")
                }
            } else {
                print("HALDEBUG: Failed to prepare conversations query")
            }
            sqlite3_finalize(stmt)
            
            // Check messages table
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM messages", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let messageCount = sqlite3_column_int(stmt, 0)
                    print("HALDEBUG: Messages in database: \(messageCount)")
                }
            } else {
                print("HALDEBUG: Failed to prepare messages query")
            }
            sqlite3_finalize(stmt)
            
            sqlite3_close(db)
        } else {
            print("HALDEBUG: Failed to open database")
        }
        
        print("HALDEBUG: === DATABASE DEBUG END ===")
    }
}

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
    }

    @ViewBuilder
    var longTermMemorySectionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Historical Context:")
                .font(.body)
                .foregroundStyle(.secondary)
            
            TextEditor(text: .constant(viewModel.currentHistoricalContext.contextSnippets.joined(separator: "\n\n")))
                .font(.body)
                .padding(4)
                .frame(minHeight: 80)
                .background(Color.gray.opacity(0.05))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .disabled(true)
            
            Text("Global: \(memoryStore.totalConversations) Conversations | \(memoryStore.totalTurns) Turns, Relevant: \(viewModel.currentHistoricalContext.relevantConversations) Conversations | \(viewModel.currentHistoricalContext.contextSnippets.count) Turns")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Toggle("Auto-Injection", isOn: $longTermMemoryEnabled)
                .font(.body)
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
    }

    @ViewBuilder
    var shortTermMemorySectionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary:")
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
            
            Stepper("Memory Depth: \(memoryDepth)", value: $memoryDepth, in: 1...20)
                .font(.body)
                .padding(.vertical, 2)
            
            HStack {
                Toggle("Auto-summarize", isOn: $autoSummarize)
                    .font(.body)
                Spacer()
                Button("Debug DB") {
                    debugDatabase()
                }
                .buttonStyle(.bordered)
                Button("Inject") {
                    viewModel.pendingAutoInject = false
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
    }

    @ViewBuilder
    var contextSectionBody: some View {
        let contextString = viewModel.buildPromptHistory(currentInput: userInput, forPreview: true)
        VStack(alignment: .leading, spacing: 8) {
            Text("Full prompt sent to model:")
                .font(.body)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(contextString)
                    .font(.body)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
            .border(Color.gray.opacity(0.2), width: 1)
            contextButtons(contextString: contextString)
        }
    }

    @ViewBuilder
    func contextButtons(contextString: String) -> some View {
        HStack {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(contextString, forType: .string)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            Button("Start Over") {
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
}
// ========== BLOCK 5: MAIN CHAT VIEW - END ==========

// ========== BLOCK 6: APP ENTRY POINT - START ==========

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
                if let lastMessage = messages.sorted(by: { $0.timestamp < $1.timestamp }).last {
                    proxy.scrollTo("bottom-spacer", anchor: .bottom)
                }
            }
            .onAppear {
                if !messages.isEmpty {
                    proxy.scrollTo("bottom-spacer", anchor: .bottom)
                }
            }
        }
    }
}

@main
struct Hal10000App: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([ChatMessage.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try! ModelContainer(for: schema, configurations: [modelConfiguration])
    }()

    var body: some Scene {
        WindowGroup {
            ChatView()
        }
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Export…") {
                    exportFiles()
                }
                .keyboardShortcut("E", modifiers: [.command, .shift])
            }
        }
    }
    init() {
        sharedConversationContext = sharedModelContainer
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

// Global variables for format picker
private var selectedFormat: ExportFormat = .thread
private weak var currentSavePanel: NSSavePanel?
private var formatDelegate = FormatPickerDelegate()

private func exportFiles() {
    guard let modelContainer = sharedConversationContext else {
        print("ERROR: No model container available for export")
        return
    }

    // Get current data for export
    let context = ModelContext(modelContainer)
    let messages: [ChatMessage]
    let systemPrompt: String
    let memoryDepth: Int
    let summary: String
    
    do {
        messages = try context.fetch(FetchDescriptor<ChatMessage>())
        // Get settings from UserDefaults (matches @AppStorage keys)
        systemPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? "Hello, Hal. You are an experimental AI assistant..."
        memoryDepth = UserDefaults.standard.integer(forKey: "memoryDepth") != 0 ? UserDefaults.standard.integer(forKey: "memoryDepth") : 6
        summary = UserDefaults.standard.string(forKey: "injectedSummary") ?? ""
    } catch {
        showErrorAlert("Failed to read conversation data: \(error.localizedDescription)")
        return
    }
    
    // Check for partial messages
    let partialMessages = messages.filter { $0.isPartial }
    if !partialMessages.isEmpty {
        let alert = NSAlert()
        alert.messageText = "Conversation In Progress"
        alert.informativeText = "There are \(partialMessages.count) message(s) still being generated. Do you want to wait for completion or export anyway?"
        alert.addButton(withTitle: "Wait")
        alert.addButton(withTitle: "Export Anyway")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: // Wait
            return // User should wait for completion
        case .alertSecondButtonReturn: // Export Anyway
            break // Continue with export
        default: // Cancel
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
    formatPicker.sizeToFit() // Auto-size to content
    
    // Set up format change callback
    formatDelegate.onFormatChanged = { newFormat in
        selectedFormat = newFormat
        
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
    
    savePanel.begin { result in
        currentSavePanel = nil
        if result == .OK, let url = savePanel.url {
            switch selectedFormat {
            case .text:
                exportPlainTextTranscript(to: url, messages: messages, systemPrompt: systemPrompt)
            case .thread:
                exportThreadFile(to: url, messages: messages, systemPrompt: systemPrompt, memoryDepth: memoryDepth, summary: summary)
            case .dna:
                exportPersonalityDNA(to: url, systemPrompt: systemPrompt)
            }
        }
    }
}

// Export function implementations
private func exportPlainTextTranscript(to url: URL, messages: [ChatMessage], systemPrompt: String) {
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
        print("Successfully exported plain text transcript to \(url.path)")
    } catch {
        showErrorAlert("Failed to export transcript: \(error.localizedDescription)")
    }
}

private func exportThreadFile(to url: URL, messages: [ChatMessage], systemPrompt: String, memoryDepth: Int, summary: String) {
    let sortedMessages = messages.sorted(by: { $0.timestamp < $1.timestamp })
    
    // Generate conversation title from first user message or use default
    let title = sortedMessages.first(where: { $0.isFromUser })?.content.prefix(50).description ?? "Hal10000 Conversation"
    
    let threadData: [String: Any] = [
        "formatVersion": "1.0",
        "title": title,
        "created": ISO8601DateFormatter().string(from: sortedMessages.first?.timestamp ?? Date()),
        "memoryDepth": memoryDepth,
        "summary": summary,
        "persona": [
            "name": "Hal10000",
            "version": "1.0",
            "systemPrompt": systemPrompt,
            "settings": [
                "tone": "curious",
                "cooperative": true
            ]
        ],
        "messages": sortedMessages.map { message in
            var messageData: [String: Any] = [
                "role": message.isFromUser ? "user" : "assistant",
                "timestamp": ISO8601DateFormatter().string(from: message.timestamp),
                "content": message.content
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
        print("Successfully exported thread file to \(url.path)")
    } catch {
        showErrorAlert("Failed to export thread file: \(error.localizedDescription)")
    }
}

private func exportPersonalityDNA(to url: URL, systemPrompt: String) {
    let dnaData: [String: Any] = [
        "formatVersion": "1.0",
        "name": "Hal10000",
        "systemPrompt": systemPrompt,
        "settings": [
            "tone": "curious",
            "cooperative": true
        ]
    ]
    
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: dnaData, options: .prettyPrinted)
        try jsonData.write(to: url)
        print("Successfully exported personality DNA to \(url.path)")
    } catch {
        showErrorAlert("Failed to export personality DNA: \(error.localizedDescription)")
    }
}

private func showErrorAlert(_ message: String) {
    DispatchQueue.main.async {
        let alert = NSAlert()
        alert.messageText = "Export Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// ========== BLOCK 6: APP ENTRY POINT - END ==========
