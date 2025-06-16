// ========== BLOCK 1: IMPORTS AND APP ENTRY POINT - START ==========
import SwiftUI
import SwiftData
import Foundation
import Combine
import Observation
import FoundationModels
// ========== BLOCK 1: IMPORTS AND APP ENTRY POINT - END ==========

// ========== BLOCK 2: CHAT MESSAGE MODEL - START ==========
@Model
final class ChatMessage {
    var id: UUID
    var content: String
    var isFromUser: Bool
    var timestamp: Date
    var isPartial: Bool

    init(content: String, isFromUser: Bool, isPartial: Bool = false) {
        self.id = UUID()
        self.content = content
        self.isFromUser = isFromUser
        self.timestamp = Date()
        self.isPartial = isPartial
    }
}
// ========== BLOCK 2: CHAT MESSAGE MODEL - END ==========

// ========== BLOCK 3: CHAT VIEW MODEL - START ==========
@MainActor
class ChatViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var isAIResponding: Bool = false
    @Published var systemPrompt: String = "You are a helpful assistant."
    @Published var injectedSummary: String = ""
    private var modelContext: ModelContext?
    var memoryDepth: Int = 6

    init() {
        // No ModelContext in init - will be set by the view
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    private func buildPromptHistory(currentInput: String) -> String {
        guard let modelContext = modelContext else { return currentInput }
        
        let sortedMessages = (try? modelContext.fetch(FetchDescriptor<ChatMessage>()))?
            .sorted(by: { $0.timestamp < $1.timestamp }) ?? []

        var history: [String] = []
        var pairsAdded = 0

        for message in sortedMessages.reversed() {
            guard pairsAdded < memoryDepth else { break }
            if message.isFromUser {
                if let response = sortedMessages.first(where: {
                    !$0.isFromUser && $0.timestamp > message.timestamp
                }) {
                    history.insert("User: \(message.content)\nAssistant: \(response.content)", at: 0)
                    pairsAdded += 1
                }
            }
        }

        let joinedHistory = history.joined(separator: "\n\n")
        return "\(systemPrompt)\n\nSummary of earlier conversation:\n\(injectedSummary)\n\n\(joinedHistory)\n\nUser: \(currentInput)\nAssistant:"
    }

    func sendMessage(_ content: String, using context: ModelContext) async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        print("DEBUG: Starting sendMessage with content: \(content)")
        self.isAIResponding = true
        
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
            
            let promptWithMemory = buildPromptHistory(currentInput: content)
            print("DEBUG: Built prompt: \(promptWithMemory.prefix(100))...")
            
            let prompt = Prompt(promptWithMemory)
            let session = LanguageModelSession()
            print("DEBUG: Created session, about to call respond")
            
            // For basic text, use respond(to:) not streamResponse
            let response = try await session.respond(to: prompt)
            print("DEBUG: Got response: \(response.content.prefix(100))...")
            
            aiMessage.content = response.content
            aiMessage.isPartial = false
            try context.save()
            print("DEBUG: Saved AI response")
            
            self.isAIResponding = false
        } catch {
            print("DEBUG: Error occurred: \(error)")
            aiMessage.isPartial = false
            aiMessage.content = "Error: \(error.localizedDescription)"
            self.errorMessage = error.localizedDescription
            self.isAIResponding = false
            try? context.save()
        }
    }
}
// ========== BLOCK 3: CHAT VIEW MODEL - END ==========

// ========== BLOCK 4: CHAT BUBBLE VIEW - START ==========
struct ChatBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isFromUser {
                Spacer()
                Text(message.content)
                    .padding()
                    .background(Color.accentColor.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(12)
            } else {
                Text(message.content)
                    .padding()
                    .background(Color.gray.opacity(0.3))
                    .foregroundColor(.primary)
                    .cornerRadius(12)
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .opacity(message.isPartial ? 0.85 : 1.0)
        .scaleEffect(message.isPartial ? 0.98 : 1.0)
        .animation(.smooth(duration: 0.3), value: message.isPartial)
    }
}
// ========== BLOCK 4: CHAT BUBBLE VIEW - END ==========

// ========== BLOCK 5: MAIN CHAT VIEW - START ==========
struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var messages: [ChatMessage]
    @State private var userInput: String = ""
    @StateObject private var viewModel = ChatViewModel()
    @State private var isShowingPromptEditor: Bool = true
    @State private var isShowingDebugger: Bool = false
    @State private var showTokenCounts: Bool = false

    @AppStorage("memoryDepth") private var memoryDepth: Int = 6
    @AppStorage("autoSummarize") private var autoSummarize: Bool = true
    @AppStorage("injectedSummary") private var storedSummary: String = ""

    private var estimatedTokenCount: Int {
        let systemText = viewModel.systemPrompt
        let recentMessages = messages
            .sorted(by: { $0.timestamp < $1.timestamp })
            .suffix(viewModel.memoryDepth * 2)
        let messagesText = recentMessages.map { $0.content }.joined(separator: " ")
        let fullText = systemText + " " + messagesText + " " + userInput
        return fullText.split(separator: " ").count
    }

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show System Prompt", isOn: $isShowingPromptEditor)
                        .font(.caption)

                    if isShowingPromptEditor {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("System Prompt:")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextEditor(text: $viewModel.systemPrompt)
                                .frame(minHeight: 60)
                                .border(Color.gray.opacity(0.3), width: 1)

                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Stepper("Memory Depth: \(memoryDepth)", value: $memoryDepth, in: 1...20)
                                        .font(.caption2)

                                    Toggle("Auto-summarize", isOn: $autoSummarize)
                                        .font(.caption2)
                                }
                            }

                            Text("Summary injected:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            TextEditor(text: $storedSummary)
                                .frame(minHeight: 40)
                                .border(Color.gray.opacity(0.3), width: 1)
                        }
                    }

                    DisclosureGroup("Context Debugger", isExpanded: $isShowingDebugger) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Show token count per message", isOn: $showTokenCounts)
                                .font(.caption2)

                            Text("Estimated tokens: \(estimatedTokenCount)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Text("Full prompt sent to model:")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ScrollView {
                                Text(buildFullPromptPreview())
                                    .font(.caption2)
                                    .padding(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 120)
                            .background(Color.gray.opacity(0.05))
                            .cornerRadius(8)
                            .border(Color.gray.opacity(0.2), width: 1)
                        }
                    }
                    
                    Button("Start Over", role: .destructive) {
                        do {
                            for message in messages {
                                modelContext.delete(message)
                            }
                            try modelContext.save()
                            viewModel.systemPrompt = "You are a helpful assistant."
                            storedSummary = ""
                            memoryDepth = 6
                            autoSummarize = true
                        } catch {
                            viewModel.errorMessage = "Failed to reset conversation."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 16)
                }
                .padding()
            }
        } detail: {
            VStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(messages.sorted(by: { $0.timestamp < $1.timestamp })) { message in
                                ChatBubbleView(message: message)
                                    .id(message.id)
                            }
                            
                            if viewModel.isAIResponding {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Hal is thinking...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal)
                            }
                        }
                        .onChange(of: messages.count) { _, _ in
                            if let last = messages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                HStack {
                    TextField("Type a message...", text: $userInput, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)

                    Button("Send") {
                        print("DEBUG: Send button tapped")
                        let text = userInput
                        userInput = ""
                        print("DEBUG: About to call sendMessage with text: '\(text)'")
                        Task {
                            print("DEBUG: Inside Task, calling sendMessage")
                            await viewModel.sendMessage(text, using: modelContext)
                            print("DEBUG: sendMessage completed")
                        }
                    }
                    .disabled(userInput.isEmpty || viewModel.isAIResponding)
                }
                .padding()
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
            viewModel.memoryDepth = memoryDepth
            viewModel.injectedSummary = storedSummary
        }
        .onChange(of: memoryDepth) { _, newValue in
            viewModel.memoryDepth = newValue
        }
        .onChange(of: storedSummary) { _, newValue in
            viewModel.injectedSummary = newValue
        }
        .navigationTitle("Hal10000")
        .alert("Error", isPresented: Binding(get: {
            viewModel.errorMessage != nil
        }, set: { _ in
            viewModel.errorMessage = nil
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }

    private func buildFullPromptPreview() -> String {
        let sortedMessages = messages.sorted(by: { $0.timestamp < $1.timestamp })
        let recentMessages = Array(sortedMessages.suffix(viewModel.memoryDepth * 2))

        var messageStrings: [String] = []
        for message in recentMessages {
            let tokenCount = showTokenCounts ? " [\(message.content.split(separator: " ").count) tokens]" : ""
            let prefix = message.isFromUser ? "User: " : "Assistant: "
            messageStrings.append(prefix + message.content + tokenCount)
        }
        
        let messageText = messageStrings.joined(separator: "\n\n")
        return viewModel.systemPrompt + "\n\n" + messageText + "\n\nUser: \(userInput)\nAssistant:"
    }
}
// ========== BLOCK 5: MAIN CHAT VIEW - END ==========

// ========== BLOCK 6: APP ENTRY POINT - START ==========
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
    }
}
// ========== BLOCK 6: APP ENTRY POINT - END ==========
