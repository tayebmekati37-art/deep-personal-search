# Deep Personal Search

A privacy-focused, personalized search engine that learns from your behavior, filters SEO spam, and synthesizes answers from multiple sources. Designed to run on low-resource hardware (i3, 4GB RAM).

## Features

- **Personalization** – tracks your clicks and builds an interest profile to boost relevant results.
- **Spam filtering** – quality scoring based on domain authority, content length, and commercial density.
- **Answer synthesis** – when you ask a question, the top results are fed to a local LLM (Ollama + Phi-2) to generate a coherent answer with citations.
- **Hybrid search** – combines semantic vector search (FAISS) with BM25 for robust retrieval.
- **Offline-first** – once models are downloaded, the system works without internet (except optional OpenAI fallback).
- **Lightweight** – uses `all-MiniLM-L6-v2` (80MB) and can run on CPU with 4GB RAM.

## Installation

1. Clone this repository.
2. Run the setup script:
   ```bash
   chmod +x setup.sh
   ./setup.sh