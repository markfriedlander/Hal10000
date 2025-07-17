Hal 10,000

A local, private, entity-aware memory system for interacting with language models like you interact with yourself.

⸻

🧠 What is Hal?

Hal 10,000 is an offline-first, privacy-respecting macOS app that lets you interact with a local LLM and persist memory across conversations and documents — not as a black box, but as a transparent, editable system.

It’s part AI assistant, part cognitive mirror. A tool for thinking. A lab for exploring. A new kind of relationship with machine intelligence.

⸻

✨ Core Capabilities

Feature	Description
🧠 Memory-Enabled AI	Hal remembers your conversations across sessions using structured storage and summarization.
🔍 Semantic Document Search	Upload documents (PDF, .txt, .md), and Hal will chunk, tag, and embed them for future retrieval.
🏷️ Entity-Aware Memory	Named entities (people, places, orgs) are extracted at ingestion and searchable later.
💬 Conversational Framing	Every memory turn is stored as part of a dialogue — Hal can recall and reflect with you.
🔐 Private & Local	All data and models run on-device. Nothing is sent to the cloud.
🧪 LLM as Interface	Uses Apple’s Foundation Models for conversation, summarization and understanding.


⸻

📦 Key Components

✅ MemoryStore
	•	Uses SQLite3 + WAL for structured persistence
	•	Supports:
	•	conversations, documents, emails, webpages
	•	Full-text + vector search with entity tagging
	•	Manual nuclear reset function for full wipe

✅ Named Entity Engine
	•	Tags and classifies entities using Apple’s NaturalLanguage
	•	Supports:
	•	Person, Place, Organization
	•	Custom relevance boosts in search
	•	Entities are embedded in storage and prompt contexts

✅ Document Importer
	•	Supports:
	•	.pdf, .txt, .md (and more via textutil)
	•	Each doc is:
	•	Parsed
	•	Chunked (400-char segments, 50 overlap)
	•	Entity-tagged
	•	Summarized with LLM (macOS 26)

✅ Unified Schema
	•	sources and unified_content tables
	•	Indexed by type, time, speaker, and entity keywords
	•	Supports real-time stats and visual diagnostics

⸻

🔍 Example Use Cases
	•	“What did I say last month about OpenAI?”
	•	“Summarize all documents related to the Atlanta project.”
	•	“Remind me what I’ve said about X company across chats and files.”

⸻

🚀 Getting Started

Requirements
	•	macOS 26
	•	Xcode
	•	SwiftData, FoundationModels, and SQLite3 (included)

Installation
	1.	Clone the repo:
git clone https://github.com/yourname/hal10000.git
cd hal10000
	2.	Open in Xcode
	3.	Build and run the Hal10000App.swift target

⚠️ No external model downloads required. Everything runs locally.

⸻

📊 Developer Features
	•	MemoryStore.shared.getDatabaseStatus() — Inspect live DB health and table schema
	•	loadUnifiedStats() — Get memory counts (conversations, turns, docs, chunks)
	•	performNuclearReset() — Wipe memory clean

⸻

🧠 Philosophy

Hal isn’t just a chatbot. It’s a sketch of a new kind of partner:
	•	One that remembers what matters
	•	Forgets what doesn’t
	•	And can tell you why it knows what it knows

We’re not building HAL 9000. We’re building the HAL we always wanted:
Transparent, conversational, and yours.

⸻

📅 Roadmap
	•	Cross-device sync (optional + encrypted)
	•	Memory UI visualization (what Hal remembers and why)
	•	User-driven memory annotation and starring
	•	Custom model support (e.g., Mistral, LLaMA.cpp)

⸻

📜 License

MIT License. You own your memories. We just help you talk to them.
