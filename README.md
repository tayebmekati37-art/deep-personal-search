@"
# Deep Personal Search with Knowledge Graph

A privacy-focused, personalized search engine that learns from your behavior, filters SEO spam, synthesizes answers, and now includes a **knowledge graph** that extracts entities and relationships from your documents for visual exploration and enhanced search relevance.

## Features

### Core Search
- **Hybrid search** – combines semantic vector search (FAISS) with BM25 for robust retrieval.
- **Personalization** – tracks clicks and builds an interest profile to boost relevant results.
- **Quality scoring** – filters SEO spam based on domain authority, content length, and commercial density.
- **Answer synthesis** – when you ask a question (query ends with `?`), the top results are fed to a local LLM (Ollama + Phi-2) or OpenAI to generate a coherent answer with citations.
- **Offline-first** – once models are downloaded, the system works without internet (except optional OpenAI fallback).

### Knowledge Graph
- **Entity extraction** – uses spaCy to extract persons, organizations, locations, and key concepts from your documents during indexing.
- **Relationship extraction** – captures subject‑verb‑object triples and co‑occurrence relationships.
- **Persistent storage** – entities and relationships are stored in SQLite tables.
- **Graph‑enhanced search** – query entities are used to boost results containing related entities.
- **Interactive visual explorer** – a D3.js force‑directed graph (at `/graph`) lets you:
  - See nodes colored by entity type (PERSON, ORG, GPE, CONCEPT).
  - Drag nodes to explore connections.
  - Click a node to view details (type, source documents).
  - Filter by entity type and search by name.
- **Memory dashboard** – visit `/history` to see past searches and click statistics.

## Technology Stack

- **Backend**: Python 3.11, FastAPI, SQLite, FAISS, sentence‑transformers, spaCy, NetworkX
- **Frontend**: HTML, Tailwind CSS, D3.js
- **LLM integration**: Ollama (local) or OpenAI API (optional)

## Installation

### Prerequisites
- Python 3.11 (binary installer available at [python.org](https://www.python.org/downloads/release/python-3119/))
- Git (optional, for cloning)
- Windows (the instructions are tailored for Windows; Linux/macOS users can adapt)

### Setup

1. **Clone or download this repository**
   ```bash
   git clone https://github.com/tayebmekati37-art/deep-personal-search.git
   cd deep-personal-search
