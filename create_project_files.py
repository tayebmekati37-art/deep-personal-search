import os
import sys
from pathlib import Path

BASE = Path(__file__).parent

def write_file(rel_path, content):
    full = BASE / rel_path
    full.parent.mkdir(parents=True, exist_ok=True)
    with open(full, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"Created: {rel_path}")

# ----------------------------------------------------------------------
# backend/config.py
# ----------------------------------------------------------------------
config_content = '''import os
from pathlib import Path

BASE_DIR = Path(__file__).parent.parent
DATA_DIR = BASE_DIR / "data"
DOCUMENTS_DIR = DATA_DIR / "documents"
INDEX_DIR = DATA_DIR / "index"
DB_PATH = DATA_DIR / "search_history.db"

for d in [DOCUMENTS_DIR, INDEX_DIR]:
    d.mkdir(parents=True, exist_ok=True)

EMBEDDING_MODEL = "sentence-transformers/all-MiniLM-L6-v2"
EMBEDDING_DIM = 384

FAISS_INDEX_PATH = INDEX_DIR / "faiss.index"
DOC_METADATA_PATH = INDEX_DIR / "doc_metadata.json"

TOP_K_RESULTS = 20
FINAL_RESULTS = 10
BM25_WEIGHT = 0.3
VECTOR_WEIGHT = 0.7
QUALITY_WEIGHT = 0.2
PERSONALIZATION_WEIGHT = 0.3

OLLAMA_MODEL = "phi:2.7b"
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", None)
'''

# backend/models.py
models_content = '''import sqlite3
import json
from datetime import datetime
from contextlib import contextmanager
from config import DB_PATH

@contextmanager
def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()

def init_db():
    with get_db() as conn:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS searches (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                query TEXT NOT NULL,
                timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
            );
            CREATE TABLE IF NOT EXISTS clicks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                search_id INTEGER NOT NULL,
                chunk_id INTEGER NOT NULL,
                rank INTEGER,
                timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY(search_id) REFERENCES searches(id)
            );
            CREATE TABLE IF NOT EXISTS documents (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT UNIQUE NOT NULL,
                title TEXT,
                domain TEXT,
                word_count INTEGER,
                indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP
            );
            CREATE TABLE IF NOT EXISTS chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                doc_id INTEGER NOT NULL,
                chunk_index INTEGER NOT NULL,
                text TEXT NOT NULL,
                faiss_id INTEGER UNIQUE,
                FOREIGN KEY(doc_id) REFERENCES documents(id)
            );
        """)
        conn.commit()

def log_search(query):
    with get_db() as conn:
        cur = conn.execute("INSERT INTO searches (query) VALUES (?)", (query,))
        return cur.lastrowid

def log_click(search_id, chunk_id, rank):
    with get_db() as conn:
        conn.execute(
            "INSERT INTO clicks (search_id, chunk_id, rank) VALUES (?, ?, ?)",
            (search_id, chunk_id, rank)
        )
        conn.commit()

def get_user_profile(limit=50):
    from collections import Counter
    with get_db() as conn:
        rows = conn.execute("""
            SELECT c.chunk_id, d.domain, d.title
            FROM clicks c
            JOIN chunks ch ON c.chunk_id = ch.faiss_id
            JOIN documents d ON ch.doc_id = d.id
            ORDER BY c.timestamp DESC
            LIMIT ?
        """, (limit,)).fetchall()

    domains = Counter()
    keywords = Counter()
    for r in rows:
        domains[r['domain']] += 1
        if r['title']:
            words = r['title'].lower().split()
            keywords.update(words)
    return {'domains': domains, 'keywords': keywords}
'''

# backend/indexer.py
indexer_content = '''import os
import json
import numpy as np
from pathlib import Path
from sentence_transformers import SentenceTransformer
import faiss
from tqdm import tqdm
from config import *
import models

_model = None
def get_embedder():
    global _model
    if _model is None:
        _model = SentenceTransformer(EMBEDDING_MODEL)
    return _model

def chunk_text(text, chunk_size=500, overlap=50):
    words = text.split()
    chunks = []
    for i in range(0, len(words), chunk_size - overlap):
        chunk = ' '.join(words[i:i+chunk_size])
        if chunk:
            chunks.append(chunk)
    return chunks

def index_documents():
    embedder = get_embedder()
    if FAISS_INDEX_PATH.exists():
        index = faiss.read_index(str(FAISS_INDEX_PATH))
        with open(DOC_METADATA_PATH, 'r') as f:
            metadata = json.load(f)
        next_id = len(metadata)
    else:
        index = faiss.IndexFlatIP(EMBEDDING_DIM)
        metadata = []
        next_id = 0

    models.init_db()
    with models.get_db() as conn:
        indexed_files = set(row['path'] for row in conn.execute("SELECT path FROM documents").fetchall())

    new_files = []
    for f in DOCUMENTS_DIR.glob("*.txt"):
        if str(f) not in indexed_files:
            new_files.append(f)

    if not new_files:
        print("No new documents to index.")
        return

    all_chunks = []
    all_embeddings = []

    for file_path in tqdm(new_files, desc="Indexing documents"):
        with open(file_path, 'r', encoding='utf-8') as f:
            text = f.read()
        lines = text.splitlines()
        title = lines[0].strip() if lines else file_path.stem
        domain = file_path.stem

        with models.get_db() as conn:
            cur = conn.execute(
                "INSERT INTO documents (path, title, domain, word_count) VALUES (?, ?, ?, ?)",
                (str(file_path), title, domain, len(text.split()))
            )
            doc_id = cur.lastrowid
            conn.commit()

        chunks = chunk_text(text)
        for idx, chunk_text in enumerate(chunks):
            all_chunks.append((doc_id, idx, chunk_text))

    if all_chunks:
        texts = [c[2] for c in all_chunks]
        embeddings = embedder.encode(texts, normalize_embeddings=True)
        index.add(embeddings.astype(np.float32))
        start_id = next_id
        for i, (doc_id, chunk_idx, text) in enumerate(all_chunks):
            faiss_id = start_id + i
            metadata.append({
                'faiss_id': faiss_id,
                'doc_id': doc_id,
                'chunk_index': chunk_idx,
                'text': text[:200] + "..."
            })
            with models.get_db() as conn:
                conn.execute(
                    "INSERT INTO chunks (doc_id, chunk_index, text, faiss_id) VALUES (?, ?, ?, ?)",
                    (doc_id, chunk_idx, text, faiss_id)
                )
                conn.commit()

        faiss.write_index(index, str(FAISS_INDEX_PATH))
        with open(DOC_METADATA_PATH, 'w') as f:
            json.dump(metadata, f)
        print(f"Indexed {len(all_chunks)} new chunks. Total chunks: {len(metadata)}")
    else:
        print("No new chunks.")
'''

# backend/search.py
search_content = '''import json
import numpy as np
from rank_bm25 import BM25Okapi
import faiss
from sentence_transformers import SentenceTransformer
from config import *
from quality_scorer import score_chunk
from personalization import personalize_results

_index = None
_metadata = None
_embedder = None
_bm25_corpus = None
_bm25_model = None
_chunk_texts = None

def load_index():
    global _index, _metadata, _embedder, _bm25_model, _chunk_texts
    if _index is None:
        _index = faiss.read_index(str(FAISS_INDEX_PATH))
        with open(DOC_METADATA_PATH, 'r') as f:
            _metadata = json.load(f)
        _embedder = SentenceTransformer(EMBEDDING_MODEL)
        import models
        with models.get_db() as conn:
            rows = conn.execute("SELECT text FROM chunks ORDER BY faiss_id").fetchall()
        _chunk_texts = [r['text'] for r in rows]
        tokenized_corpus = [doc.split() for doc in _chunk_texts]
        _bm25_model = BM25Okapi(tokenized_corpus)
    return _index, _metadata, _embedder, _bm25_model, _chunk_texts

def hybrid_search(query, top_k=TOP_K_RESULTS):
    index, metadata, embedder, bm25, texts = load_index()
    query_emb = embedder.encode([query], normalize_embeddings=True)
    scores_vec, indices = index.search(query_emb.astype(np.float32), top_k)
    vec_results = {idx: score for idx, score in zip(indices[0], scores_vec[0]) if idx != -1}

    tokenized_query = query.split()
    bm25_scores = bm25.get_scores(tokenized_query)
    bm25_indices = np.argsort(bm25_scores)[::-1][:top_k]
    bm25_results = {idx: bm25_scores[idx] for idx in bm25_indices}

    all_ids = set(vec_results.keys()) | set(bm25_results.keys())
    combined = []
    for idx in all_ids:
        vec_score = vec_results.get(idx, 0)
        bm25_score = bm25_results.get(idx, 0) / max(bm25_scores) if max(bm25_scores) > 0 else 0
        total = VECTOR_WEIGHT * vec_score + BM25_WEIGHT * bm25_score
        combined.append((idx, total))

    combined.sort(key=lambda x: x[1], reverse=True)
    meta_mapping = metadata  # list indexed by faiss_id

    detailed = []
    for idx, score in combined[:top_k]:
        meta = meta_mapping[idx]
        full_text = _chunk_texts[idx]
        import models
        with models.get_db() as conn:
            doc = conn.execute("SELECT * FROM documents WHERE id=?", (meta['doc_id'],)).fetchone()
        detailed.append({
            'faiss_id': idx,
            'score': score,
            'text': full_text,
            'doc_id': meta['doc_id'],
            'title': doc['title'],
            'domain': doc['domain'],
            'word_count': doc['word_count']
        })
    return detailed

def search(query):
    candidates = hybrid_search(query)
    for c in candidates:
        c['quality_score'] = score_chunk(c['text'], c['domain'])
    candidates = personalize_results(query, candidates)
    for c in candidates:
        final_score = (1 - QUALITY_WEIGHT - PERSONALIZATION_WEIGHT) * c['score'] \
                      + QUALITY_WEIGHT * c['quality_score'] \
                      + PERSONALIZATION_WEIGHT * c.get('personalization_boost', 0)
        c['final_score'] = final_score
    candidates.sort(key=lambda x: x['final_score'], reverse=True)
    return candidates[:FINAL_RESULTS]
'''

# backend/quality_scorer.py
quality_content = '''import re
from collections import Counter

def score_chunk(text, domain):
    score = 0.5
    high_authority = {'wikipedia.org', 'nytimes.com', 'bbc.com', 'nature.com'}
    low_authority = {'buzzfeed.com', 'medium.com', 'quora.com'}
    if domain in high_authority:
        score += 0.2
    elif domain in low_authority:
        score -= 0.1

    words = text.split()
    word_count = len(words)
    if word_count < 50:
        score -= 0.1
    elif word_count > 300:
        score += 0.05

    money_words = {'price', 'buy', 'cheap', 'discount', 'offer', 'deal', 'sale', 'cost'}
    money_count = sum(1 for w in words if w.lower() in money_words)
    money_density = money_count / max(1, word_count)
    if money_density > 0.05:
        score -= 0.1

    word_freq = Counter(w.lower() for w in words)
    repeated = sum(1 for f in word_freq.values() if f > 3)
    if repeated > 5:
        score -= 0.1

    return max(0.0, min(1.0, score))
'''

# backend/personalization.py
personalization_content = '''import models
from collections import Counter

def personalize_results(query, candidates):
    profile = models.get_user_profile()
    if not profile['domains'] and not profile['keywords']:
        for c in candidates:
            c['personalization_boost'] = 0
        return candidates

    total_domains = sum(profile['domains'].values())
    domain_weights = {d: count/total_domains for d, count in profile['domains'].items()}

    total_keywords = sum(profile['keywords'].values())
    keyword_weights = {k: count/total_keywords for k, count in profile['keywords'].items()}

    for c in candidates:
        boost = 0
        if c['domain'] in domain_weights:
            boost += domain_weights[c['domain']] * 0.5
        title_words = c['title'].lower().split()
        for kw, w in keyword_weights.items():
            if kw in title_words:
                boost += w * 0.5
        c['personalization_boost'] = boost
    return candidates
'''

# backend/synthesizer.py
synthesizer_content = '''import subprocess
import json
import requests
from config import OLLAMA_MODEL, OPENAI_API_KEY

def synthesize_answer(query, chunks):
    if not chunks:
        return "No relevant content found.", []

    context = "\\n\\n---\\n\\n".join([f"Source: {c['title']} ({c['domain']})\\n{c['text']}" for c in chunks[:3]])
    prompt = f"""Based on the following sources, provide a concise and accurate answer to the question.
If the sources do not contain the answer, say that you cannot answer.

Question: {query}

Sources:
{context}

Answer:"""

    if OLLAMA_MODEL:
        try:
            answer = query_ollama(prompt)
            sources = [{'title': c['title'], 'domain': c['domain']} for c in chunks[:3]]
            return answer, sources
        except Exception as e:
            print(f"Ollama failed: {e}")

    if OPENAI_API_KEY:
        try:
            answer = query_openai(prompt)
            sources = [{'title': c['title'], 'domain': c['domain']} for c in chunks[:3]]
            return answer, sources
        except Exception as e:
            print(f"OpenAI failed: {e}")

    return "Answer generation requires Ollama or OpenAI API key.", []

def query_ollama(prompt):
    response = requests.post(
        "http://localhost:11434/api/generate",
        json={"model": OLLAMA_MODEL, "prompt": prompt, "stream": False}
    )
    if response.status_code == 200:
        return response.json()["response"]
    else:
        raise Exception(f"Ollama error: {response.status_code}")

def query_openai(prompt):
    import openai
    openai.api_key = OPENAI_API_KEY
    response = openai.ChatCompletion.create(
        model="gpt-3.5-turbo",
        messages=[{"role": "user", "content": prompt}],
        temperature=0.3
    )
    return response.choices[0].message.content
'''

# backend/app.py
app_content = '''from fastapi import FastAPI, Request, Form, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel
import uvicorn
from typing import Optional
import logging

from config import *
import models
import indexer
import search as search_engine
import synthesizer

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Deep Personal Search")
templates = Jinja2Templates(directory="../frontend")

@app.on_event("startup")
def startup():
    models.init_db()
    logger.info("Database initialized.")

@app.get("/", response_class=HTMLResponse)
def home(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})

@app.post("/search")
def search(query: str = Form(...)):
    search_id = models.log_search(query)
    results = search_engine.search(query)

    is_question = query.strip().endswith("?")
    answer = None
    sources = []
    if is_question and results:
        answer, sources = synthesizer.synthesize_answer(query, results[:3])

    formatted = []
    for r in results:
        formatted.append({
            "faiss_id": r["faiss_id"],
            "title": r["title"],
            "domain": r["domain"],
            "snippet": r["text"][:200] + "...",
            "score": r["final_score"],
            "quality": r["quality_score"]
        })

    return JSONResponse({
        "search_id": search_id,
        "query": query,
        "answer": answer,
        "sources": sources,
        "results": formatted
    })

@app.post("/click")
def click(search_id: int = Form(...), chunk_id: int = Form(...), rank: int = Form(...)):
    models.log_click(search_id, chunk_id, rank)
    return {"status": "ok"}

@app.get("/history", response_class=HTMLResponse)
def history(request: Request):
    with models.get_db() as conn:
        searches = conn.execute("""
            SELECT s.id, s.query, s.timestamp,
                   (SELECT COUNT(*) FROM clicks WHERE search_id = s.id) as click_count
            FROM searches s
            ORDER BY s.timestamp DESC
            LIMIT 20
        """).fetchall()
    return templates.TemplateResponse("history.html", {"request": request, "searches": searches})

@app.post("/reindex")
def reindex():
    try:
        indexer.index_documents()
        return {"status": "ok", "message": "Indexing completed."}
    except Exception as e:
        logger.exception("Reindex failed")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
'''

# backend/requirements.txt
requirements_content = '''fastapi==0.104.1
uvicorn==0.24.0
sentence-transformers==2.2.2
faiss-cpu==1.7.4
rank-bm25==0.2.2
numpy==1.24.3
scikit-learn==1.3.0
requests==2.31.0
jinja2==3.1.2
python-multipart==0.0.6
openai==0.28.0
textstat==0.7.3
'''

# frontend/index.html
index_html = '''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Deep Personal Search</title>
    <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-100 flex items-center justify-center min-h-screen">
    <div class="max-w-2xl w-full p-6 bg-white rounded-lg shadow-lg">
        <h1 class="text-3xl font-bold text-center text-gray-800 mb-6">Deep Personal Search</h1>
        <form action="/search" method="post" class="space-y-4">
            <input type="text" name="query" placeholder="Ask anything..." required
                   class="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500">
            <button type="submit"
                    class="w-full bg-blue-600 text-white font-semibold py-2 px-4 rounded-lg hover:bg-blue-700 transition">
                Search
            </button>
        </form>
        <p class="text-sm text-gray-500 mt-4 text-center">
            Your personal search engine that learns from you, blocks spam, and synthesizes answers.
        </p>
    </div>
</body>
</html>
'''

# frontend/results.html
results_html = '''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Search Results - Deep Personal Search</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script>
        function logClick(searchId, chunkId, rank) {
            fetch('/click', {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: new URLSearchParams({ search_id: searchId, chunk_id: chunkId, rank: rank })
            });
        }
    </script>
</head>
<body class="bg-gray-100">
    <div class="max-w-4xl mx-auto p-6">
        <a href="/" class="text-blue-600 hover:underline mb-4 inline-block">&larr; New Search</a>
        <div id="results" class="space-y-6"></div>
    </div>

    <script>
        const data = JSON.parse(sessionStorage.getItem('searchResults'));
        const container = document.getElementById('results');

        if (!data) {
            container.innerHTML = '<p class="text-red-500">No results found. Please go back and search again.</p>';
        } else {
            const queryDiv = document.createElement('div');
            queryDiv.className = 'bg-white p-4 rounded-lg shadow';
            queryDiv.innerHTML = `<h2 class="text-xl font-semibold">Results for "${data.query}"</h2>`;
            container.appendChild(queryDiv);

            if (data.answer) {
                const answerDiv = document.createElement('div');
                answerDiv.className = 'bg-green-50 border-l-4 border-green-500 p-4 rounded-lg shadow';
                answerDiv.innerHTML = `
                    <h3 class="font-bold text-lg mb-2">AI Answer</h3>
                    <p class="text-gray-800">${data.answer.replace(/\\n/g, '<br>')}</p>
                    ${data.sources.length ? '<p class="text-sm text-gray-500 mt-2">Sources: ' + data.sources.map(s => s.title).join(', ') + '</p>' : ''}
                `;
                container.appendChild(answerDiv);
            }

            const resultsDiv = document.createElement('div');
            resultsDiv.className = 'space-y-4';
            data.results.forEach((res, idx) => {
                const item = document.createElement('div');
                item.className = 'bg-white p-4 rounded-lg shadow hover:shadow-md transition';
                item.innerHTML = `
                    <a href="#" onclick="logClick(${data.search_id}, ${res.faiss_id}, ${idx+1}); return true;" class="block">
                        <h3 class="text-xl font-semibold text-blue-600 hover:underline">${res.title}</h3>
                        <p class="text-sm text-gray-600">${res.domain} · Quality: ${(res.quality*100).toFixed(0)}%</p>
                        <p class="text-gray-700 mt-2">${res.snippet}</p>
                        <div class="flex items-center mt-2 text-xs text-gray-400">
                            <span class="bg-blue-100 text-blue-800 px-2 py-1 rounded">Score: ${res.score.toFixed(2)}</span>
                            <span class="ml-2 cursor-help" title="Personalized based on your history">🎯</span>
                        </div>
                    </a>
                `;
                resultsDiv.appendChild(item);
            });
            container.appendChild(resultsDiv);
        }
    </script>
</body>
</html>
'''

# frontend/history.html
history_html = '''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Search History - Deep Personal Search</title>
    <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-100">
    <div class="max-w-4xl mx-auto p-6">
        <a href="/" class="text-blue-600 hover:underline mb-4 inline-block">&larr; New Search</a>
        <h1 class="text-3xl font-bold mb-6">Your Search History</h1>
        <div class="bg-white shadow rounded-lg overflow-hidden">
            <ul class="divide-y divide-gray-200">
                {% for s in searches %}
                <li class="p-4 hover:bg-gray-50">
                    <div class="flex justify-between">
                        <span class="font-medium">{{ s.query }}</span>
                        <span class="text-sm text-gray-500">{{ s.timestamp }}</span>
                    </div>
                    <div class="text-sm text-gray-600 mt-1">Clicks: {{ s.click_count }}</div>
                </li>
                {% endfor %}
            </ul>
        </div>
    </div>
</body>
</html>
'''

# setup.sh
setup_sh = '''#!/bin/bash
set -e

echo "=== Deep Personal Search Setup ==="

if [ ! -d "venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv venv
fi

source venv/bin/activate

pip install --upgrade pip

echo "Installing Python packages..."
pip install -r backend/requirements.txt

mkdir -p data/documents data/index

echo "Initializing database..."
python3 -c "
import sqlite3
from backend.config import DB_PATH
from backend.models import init_db
init_db()
print('Database created at', DB_PATH)
"

echo "Downloading embedding model (first time may take a moment)..."
python3 -c "
from sentence_transformers import SentenceTransformer
from backend.config import EMBEDDING_MODEL
SentenceTransformer(EMBEDDING_MODEL)
print('Model downloaded.')
"

read -p "Install Ollama and pull Phi-2 for local answer generation? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if ! command -v ollama &> /dev/null; then
        echo "Installing Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
    else
        echo "Ollama already installed."
    fi
    echo "Pulling Phi-2 model (approx 1.6GB)..."
    ollama pull phi:2.7b
fi

echo "=== Setup complete! ==="
echo "To start the server:"
echo "  cd backend"
echo "  uvicorn app:app --reload"
echo "Then open http://localhost:8000 in your browser."
'''

# ----------------------------------------------------------------------
# Write all files (excluding README.md)
# ----------------------------------------------------------------------
write_file("backend/config.py", config_content)
write_file("backend/models.py", models_content)
write_file("backend/indexer.py", indexer_content)
write_file("backend/search.py", search_content)
write_file("backend/quality_scorer.py", quality_content)
write_file("backend/personalization.py", personalization_content)
write_file("backend/synthesizer.py", synthesizer_content)
write_file("backend/app.py", app_content)
write_file("backend/requirements.txt", requirements_content)
write_file("frontend/index.html", index_html)
write_file("frontend/results.html", results_html)
write_file("frontend/history.html", history_html)
write_file("setup.sh", setup_sh)

print("\nAll files created successfully! (README.md not included)")
print("Next steps:")
print("1. Create README.md manually (content provided below)")
print("2. Open Git Bash (or WSL) in the project folder: cd /c/Users/Tayeb/Documents/deep-personal-search")
print("3. Run: bash setup.sh")
print("4. After setup, start the server: cd backend && uvicorn app:app --reload")
print("5. Open http://localhost:8000 in your browser")