# Search Module

**Owner**: SEARCH Agent
**Status**: ✅ Implementation Complete (FTS5 + Cognitive Memory System)
**Instructions**: See [Search/AGENTS.md](AGENTS.md)

## Overview

Search implementation for Retrace with:
- **Full-Text Search (FTS)**: Fast keyword search using SQLite FTS5
- **Cognitive Memory System (CMS)**: dense vector search (`AcceleratedVectorEngine`,
  Accelerate BLAS + NaturalLanguage embeddings — not llama.cpp), a knowledge graph
  over extracted entities (`EntityMeshManager`), episodic clustering of frames into
  sessions (`CognitiveSessionizer`), a multi-hop reasoner (`CognitiveReasoner`), and
  an OpenRouter-backed semantic indexing pipeline (`Search/OpenRouter/`)

## Implemented Files

```
Search/
├── SearchManager.swift              # ✅ FTS search implementation
├── IngestionManager.swift           # ✅ Search index ingestion pipeline
├── QueryParser/
│   ├── QueryParser.swift           # ✅ Query parsing & validation
│   └── QueryTokenizer.swift        # ✅ Shared tokenization + shell-option classification
├── Ranking/
│   └── ResultRanker.swift          # ✅ Multi-signal ranking
├── VectorSearch/
│   └── AcceleratedVectorEngine.swift # ✅ Dense vector engine: Accelerate BLAS + NaturalLanguage
├── EntityMesh/
│   └── EntityMeshManager.swift     # ✅ Knowledge graph over extracted entities
├── Episodic/
│   └── CognitiveSessionizer.swift  # ✅ Episodic clustering of frames
├── Reasoning/
│   └── CognitiveReasoner.swift     # ✅ Multi-hop reasoning over mesh + episodes
├── OpenRouter/
│   ├── OpenRouterClient.swift               # ✅ OpenRouter API client
│   └── OpenRouterGranularSearchCoordinator.swift # ✅ Semantic indexing pipeline
└── Tests/
    ├── QueryParserTests.swift      # ✅ Query parser tests
    ├── CognitiveMemorySystemTests.swift # ✅ CMS tests
    └── TestLogger.swift
```

See [Search/AGENTS.md](AGENTS.md) for the full directory description and protocol list.

## Query Syntax

### Supported Features
- **Keywords**: `swift programming` (prefix matching)
- **Phrases**: `"exact phrase"` (exact matching)
- **Exclusions**: `-java` or `-"machine learning"`
- **App Filter**: `app:Chrome`
- **Date Filters**: `after:2024-01-01` or `before:yesterday`
- **Combined**: `"syntax error" swift -java app:Xcode after:week`

### Example Queries
```
error message                        # Basic keywords
"compiler error"                     # Exact phrase
swift -java -python                  # With exclusions
bug app:Safari after:week            # With filters
"404 error" -resolved app:Chrome     # Complex query
```

## Usage

### Initialization
```swift
let searchManager = SearchManager(
    database: databaseManager,
    ftsEngine: ftsManager
)
try await searchManager.initialize(config: .default)
```

### Basic Search
```swift
let results = try await searchManager.search(text: "error message", limit: 50)
```

### Advanced Search
```swift
let query = SearchQuery(
    text: "swift \"compiler error\"",
    filters: SearchFilters(
        startDate: Date().addingTimeInterval(-7 * 86400),
        appBundleIDs: ["com.apple.Xcode"]
    ),
    limit: 50
)
let results = try await searchManager.search(query: query)
```

### Indexing
```swift
try await searchManager.index(text: extractedText)
try await searchManager.removeFromIndex(frameID: frameID)
```

## Architecture

### Data Flow
```
Query → Parser → FTS Builder → Database → Ranker → Results
```

### Ranking Formula
```
score = BM25 + (recency × 0.2) + (metadata × 0.1)
```

Signals:
- **BM25**: SQLite FTS5 relevance
- **Recency**: Linear decay over 30 days
- **Metadata**: Matches in title, app, URL

## Cognitive Memory System (CMS)

The CMS is the dense-vector/semantic layer that supplements FTS. It replaced an
earlier, never-shipped design based on `HybridSearchManager` + a local Nomic
Embed v1.5 / llama.cpp embedding pipeline (deleted as dead code; do not resurrect
those names). The real, shipped pieces:

- **`VectorSearch/AcceleratedVectorEngine.swift`** — dense vector indexing/search
  using Apple Accelerate (BLAS) over NaturalLanguage-framework embeddings.
- **`EntityMesh/EntityMeshManager.swift`** — knowledge graph built from entities
  extracted from indexed text.
- **`Episodic/CognitiveSessionizer.swift`** — clusters frames into episodic
  sessions.
- **`Reasoning/CognitiveReasoner.swift`** — multi-hop reasoning over the entity
  mesh and episodic sessions.
- **`OpenRouter/`** — an OpenRouter-backed semantic indexing pipeline
  (`Processing/SemanticIndexer.swift` is the actor that drives it).

Persistence lives in `Database/Queries/CognitiveMemoryQueries.swift` and
`Database/Migrations/V21_CognitiveMemorySystem.swift`; the shared protocols are
in `Shared/Protocols/CognitiveMemoryProtocols.swift`. See
[Search/AGENTS.md](AGENTS.md) for the protocol list and directory tree.

## Implementation Status

### ✅ Completed
- Full query parsing with all syntax
- FTS integration via protocols
- Multi-signal ranking
- Indexing pipeline
- Dense vector search (Accelerate BLAS + NaturalLanguage embeddings)
- Knowledge graph / entity mesh
- Episodic clustering + multi-hop reasoning
- OpenRouter-backed semantic indexing
- Comprehensive tests

### 🚧 Deferred
- Autocomplete (needs FTS vocab table)
- ANN indexing (HNSW, FAISS) for production scale

## Performance

- Query parsing: <1ms
- FTS search: <100ms (Database-dependent)
- Ranking: <10ms per 100 results

## Dependencies

### Required
- Database module (FTSProtocol)
- Shared types (SearchQuery, etc.)

## Protocols Implemented

- ✅ `SearchProtocol`
- ✅ `QueryParserProtocol`

## Known Limitations

### App Filtering in FTS
The `SearchFilters.appBundleIDs` filter is currently parsed but not fully implemented in the FTS query.
The infrastructure is in place but requires a JOIN with the frames table to filter by app bundle ID.
This can be addressed in a future update.

## See Also

- [PROGRESS.md](PROGRESS.md) - Detailed implementation notes
- [CLAUDE-SEARCH.md](../CLAUDE-SEARCH.md) - Agent instructions
- [Shared/Protocols/SearchProtocol.swift](../Shared/Protocols/SearchProtocol.swift) - Interface contracts
