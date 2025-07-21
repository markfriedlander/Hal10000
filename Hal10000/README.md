# Hal10000

**Hal10000** is a macOS-native AI assistant built with SwiftUI and Apple’s Foundation models. It explores local memory, vector search, and conversational persistence in a privacy-preserving package designed for experimentation, customization, and developer insight.

## Features

* 🔊 **On-device chat** with Apple’s Foundation `SystemLanguageModel`
* 🧠 **Configurable short-term memory** depth per conversation
* 🔄 **Auto-summarization** of past turns (when memory limit exceeded)
* 📂 **Long-term memory** via vector embeddings and SQLite persistence
* 📁 **Document import** (.pdf, .docx, .html, .md, etc.) with chunking
* 🔍 **Unified memory search** across past chats and documents
* 🗋 **Export formats**: `.txt` (transcript), `.thread` (JSON), `.llmdna` (persona DNA)
* ✨ **Live token estimation** for memory window debugging

## Installation

Requires macOS 15+ with Xcode 16 and Apple silicon.

```bash
# Clone the repo
$ git clone https://github.com/yourname/Hal10000.git

# Open in Xcode
$ open Hal10000/Hal10000.xcodeproj
```

No external dependencies. Built entirely with Swift + SwiftUI.

## Philosophy

Hal10000 is not a chatbot clone. It's a testbed for understanding:

* How memory affects LLM behavior
* What context really means in practice
* How local AI assistants might evolve outside the cloud

The design prioritizes transparency: token counts, visual indicators, and direct access to underlying structures.

## Memory Architecture

* **Short-Term**: Last N user/assistant turns, user-defined
* **Summarization**: Automatically summarizes earlier turns when limit exceeded
* **Long-Term**: Stores all messages and imported documents as vectorized entries in SQLite
* **Embedding**: Uses Apple’s `NLEmbedding` (sentence-level) with hash fallback
* **Search**: Cosine similarity relevance lookup + optional debug output

## UI Highlights

* Split sidebar with behavior, memory, and context sections
* Live summary injection preview
* Token usage meter with color-coded feedback
* Document import UI with support for folders and multiple formats

## Export Options

Choose from `.txt`, `.thread`, or `.llmdna`:

* `.txt` — plain conversation transcript
* `.thread` — JSON export with messages + settings
* `.llmdna` — encapsulated system prompt and assistant traits

Exports are available via menu or button, and can be previewed before saving.

## Development Notes

* Built using SwiftUI, Combine, SQLite3, and NaturalLanguage
* All memory storage is local; no cloud dependencies
* Code is modular, comment-rich, and designed for experimentation

## License

MIT. See `LICENSE` file.

---

This project is a sandbox. It may mutate, fork itself, or get rewritten entirely. But if you're curious about memory, context, and AI interfaces — welcome.

