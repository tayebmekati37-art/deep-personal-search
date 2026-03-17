#!/bin/bash
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

# Install spaCy model for knowledge graph
echo "Downloading spaCy model..."
python -m spacy download en_core_web_sm
