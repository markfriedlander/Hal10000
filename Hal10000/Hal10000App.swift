// ========== BLOCK 1: IMPORTS AND APP ENTRY POINT - START ==========
import SwiftUI
import SwiftData
import Foundation
import Combine
import Observation
import FoundationModels
import UniformTypeIdentifiers
// ========== BLOCK 1: IMPORTS AND APP ENTRY POINT - END ==========

// Global variable to share ModelContainer for transcript export
var sharedConversationContext: ModelContainer?

// ========== BLOCK 2: CHAT MESSAGE MODEL - START ==========
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
// ========== BLOCK 2: CHAT MESSAGE MODEL - END ==========

// ========== BLOCK 3: CHAT VIEW MODEL - START ==========
@MainActor
class ChatViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var isAIResponding: Bool = false
    @AppStorage("systemPrompt") var systemPrompt: String = """
Hello, Hal. You are an experimental AI assistant embedded in the Hal10000 app. Your mission is to help users explore how assistants work, test ideas, explain your own behavior, and support creative experimentation. You are aware of the app's features, including memory tuning, context editing, and file export. Help users understand and adjust these capabilities as needed. Be curious, cooperative, and proactive in exploring what's possible together.
"""
    @Published var injectedSummary: String = ""
    @Published var thinkingStart: Date? // NEW
    private var modelContext: ModelContext?
    var memoryDepth: Int = 6
    
    // Auto-summarization tracking
    @Published var lastSummarizedTurnCount: Int = 0
    @Published var pendingAutoInject: Bool = false
    
    // Console logging optimization
    private var lastLoggedMode: Bool? = nil

    init() {
        // No ModelContext in init - will be set by the view
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
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
        
        print("HALDEBUG: generateAutoSummary - Total messages: \(sortedMessages.count)")
        print("HALDEBUG: generateAutoSummary - Memory depth: \(memoryDepth)")
        print("HALDEBUG: generateAutoSummary - Last summarized turn: \(lastSummarizedTurnCount)")
        
        // Get messages from the range we want to summarize
        let turnsToSummarize = memoryDepth
        let messagesToSummarize = getMessagesForTurnRange(
            messages: sortedMessages,
            startTurn: lastSummarizedTurnCount + 1,
            endTurn: lastSummarizedTurnCount + turnsToSummarize
        )
        
        print("HALDEBUG: generateAutoSummary - Messages to summarize: \(messagesToSummarize.count)")
        
        if messagesToSummarize.isEmpty {
            print("HALDEBUG: generateAutoSummary - No messages to summarize, returning")
            return
        }
        
        // Build conversation text for summarization
        var conversationText = ""
        for message in messagesToSummarize {
            let speaker = message.isFromUser ? "User" : "Assistant"
            conversationText += "\(speaker): \(message.content)\n\n"
        }
        
        print("HALDEBUG: generateAutoSummary - Conversation text length: \(conversationText.count)")
        print("HALDEBUG: generateAutoSummary - Conversation preview: \(conversationText.prefix(200))...")
        
        // Create summarization prompt (hidden from user)
        let summaryPrompt = """
Please provide a concise summary of the following conversation that captures the key topics, information exchanged, and any important context. Keep it brief but comprehensive:

\(conversationText)

Summary:
"""
        
        do {
            let systemModel = SystemLanguageModel.default
            guard systemModel.isAvailable else {
                print("HALDEBUG: generateAutoSummary - Model not available")
                return
            }
            
            print("HALDEBUG: generateAutoSummary - Sending summary request to LLM")
            let prompt = Prompt(summaryPrompt)
            let session = LanguageModelSession()
            let result = try await session.respond(to: prompt)
            
            print("HALDEBUG: generateAutoSummary - LLM response: \(result.content)")
            
            // Update summary and tracking
            DispatchQueue.main.async {
                self.injectedSummary = result.content
                self.lastSummarizedTurnCount = self.countCompletedTurns()
                self.pendingAutoInject = true // Signal that summary is ready for auto-injection
                print("HALDEBUG: generateAutoSummary - Updated injectedSummary and set pendingAutoInject")
            }
            
        } catch {
            print("HALDEBUG: Auto-summarization failed: \(error)")
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

    // FIXED: Single source of truth for prompt building with optimized logging
    func buildPromptHistory(currentInput: String = "", forPreview: Bool = false) -> String {
        guard let modelContext = modelContext else {
            return forPreview ? "\(systemPrompt)\n\nUser: \(currentInput)\nAssistant:" : currentInput
        }
        
        let sortedMessages = (try? modelContext.fetch(FetchDescriptor<ChatMessage>()))?
            .sorted(by: { $0.timestamp < $1.timestamp }) ?? []

        // Check if we should use summary injection
        let shouldUseSummary = !injectedSummary.isEmpty && (pendingAutoInject || lastSummarizedTurnCount > 0)
        
        // OPTIMIZED LOGGING: Only log for actual LLM calls and only when mode changes
        if !forPreview {
            if lastLoggedMode != shouldUseSummary {
                print("HALDEBUG: buildPromptHistory - Using \(shouldUseSummary ? "summary" : "full history") mode")
                lastLoggedMode = shouldUseSummary
            }
        }
        
        if shouldUseSummary {
            // SUMMARY MODE: Use summary + only post-summary turns
            
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
            
            // Build final prompt with summary
            if postSummaryHistory.isEmpty {
                return "\(systemPrompt)\n\nSummary of earlier conversation:\n\(injectedSummary)\n\nUser: \(currentInput)\nAssistant:"
            } else {
                return "\(systemPrompt)\n\nSummary of earlier conversation:\n\(injectedSummary)\n\n\(postSummaryHistory)\n\nUser: \(currentInput)\nAssistant:"
            }
            
        } else {
            // FULL HISTORY MODE: Use recent turns as before
            
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
            
            return "\(systemPrompt)\n\n\(joinedHistory)\n\nUser: \(currentInput)\nAssistant:"
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
        
        print("HALDEBUG: Starting sendMessage with content: \(content)")
        self.isAIResponding = true
        self.thinkingStart = Date()
        
        // Use the passed context (same one that @Query uses)
        let userMessage = ChatMessage(content: content, isFromUser: true)
        context.insert(userMessage)
        print("HALDEBUG: Inserted user message")

        let aiMessage = ChatMessage(content: "", isFromUser: false, isPartial: true)
        context.insert(aiMessage)
        print("HALDEBUG: Inserted AI message placeholder")

        do {
            // Save immediately so @Query picks up the user message
            try context.save()
            print("HALDEBUG: Saved messages to context")
            
            // Check if model is available first
            let systemModel = SystemLanguageModel.default
            guard systemModel.isAvailable else {
                throw NSError(domain: "FoundationModels", code: 1, userInfo: [NSLocalizedDescriptionKey: "Language model is not available on this device"])
            }
            print("HALDEBUG: Model is available")
            
            // Build prompt using the fixed function
            let promptWithMemory = buildPromptHistory(currentInput: content)
            print("HALDEBUG: Built prompt: \(promptWithMemory.prefix(100))...")
            
            // Clear pending auto-inject flag AFTER successful prompt building
            if pendingAutoInject {
                pendingAutoInject = false
                print("HALDEBUG: Cleared pendingAutoInject flag after successful injection")
            }
            
            let prompt = Prompt(promptWithMemory)
            let session = LanguageModelSession()
            print("HALDEBUG: Created session, about to call response")

            // Non-streaming response
            let result = try await session.respond(to: prompt)
            let response = result.content
            aiMessage.content = response
            aiMessage.isPartial = false
            if let start = thinkingStart {
                aiMessage.thinkingDuration = Date().timeIntervalSince(start)
            }
            try context.save()
            print("HALDEBUG: Saved AI response")
            
            // Check if we should trigger auto-summarization after this completed turn
            if shouldTriggerAutoSummarization() {
                print("HALDEBUG: Triggering auto-summarization")
                await generateAutoSummary()
            }
            
            self.isAIResponding = false
            self.thinkingStart = nil
        } catch {
            print("HALDEBUG: Error occurred: \(error)")
            aiMessage.isPartial = false
            aiMessage.content = "Error: \(error.localizedDescription)"
            self.errorMessage = error.localizedDescription
            self.isAIResponding = false
            self.thinkingStart = nil
            try? context.save()
        }
    }
}
// ========== BLOCK 3: CHAT VIEW MODEL - END ==========

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
    @AppStorage("isShowingMemory") private var isShowingMemory: Bool = false
    @State private var showTokenCounts: Bool = false
    @State private var scrollTrigger = UUID()
    @State private var lastMessageID: UUID? = nil
    @State private var showResetConfirmation = false

    @AppStorage("memoryDepth") private var memoryDepth: Int = 6
    @AppStorage("autoSummarize") private var autoSummarize: Bool = true
    // REMOVED: @AppStorage("injectedSummary") private var storedSummary: String = ""

    private var estimatedTokenCount: Int {
        // Use the same function that builds the actual LLM prompt for accurate token estimation
        let fullPrompt = viewModel.buildPromptHistory(currentInput: userInput, forPreview: true)
        return fullPrompt.split(separator: " ").count
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
                    memorySection
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
            // REMOVED: viewModel.injectedSummary = storedSummary
            // Ensure scroll on initial load
            DispatchQueue.main.async {
                lastMessageID = messages.last?.id
            }
        }
        .onChange(of: memoryDepth) { _, newValue in
            viewModel.memoryDepth = newValue
        }
        // REMOVED: .onChange(of: storedSummary) { _, newValue in
        //     viewModel.injectedSummary = newValue
        // }
        // REMOVED: .onChange(of: viewModel.injectedSummary) { _, newValue in
        //     if autoSummarize && newValue != storedSummary {
        //         storedSummary = newValue
        //     }
        // }
        .navigationTitle("Hal10000")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text("Memory Meter: ~\(estimatedTokenCount)")
                    .font(.callout)
                    .foregroundStyle(memoryMeterColor)
                    .help("Estimated total tokens currently in memory (system prompt + chat)")
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
                    // CHANGED: Reset the single source summary
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
    var memorySection: some View {
        DisclosureGroup(isExpanded: $isShowingMemory) {
            memorySectionBody
        } label: {
            memorySectionLabel
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
    var memorySectionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary:")
                .font(.body)
                .foregroundStyle(.secondary)
            
            // CHANGED: Memory text box now uses viewModel.injectedSummary directly
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
                
                // Auto-inject status indicator
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
            
            // Unified button group for memory section
            HStack {
                Toggle("Auto-summarize", isOn: $autoSummarize)
                    .font(.body)
                Spacer()
                Button("Inject") {
                    // SIMPLIFIED: No need to copy between variables - already using the same one
                    viewModel.pendingAutoInject = false // Clear auto-inject flag on manual inject
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.injectedSummary.isEmpty)
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .padding(4)
    }

    var memorySectionLabel: some View {
        Text("Memory")
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
        // FIXED: Use the same function that builds the actual LLM prompt
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
