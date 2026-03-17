# setup_knowledge_graph.ps1
Write-Host "=== Knowledge Graph Extension Setup ===" -ForegroundColor Green

# Activate virtual environment if exists
if (Test-Path "venv\Scripts\Activate.ps1") {
    & .\venv\Scripts\Activate.ps1
} else {
    Write-Host "Virtual environment not found. Please run setup.sh first." -ForegroundColor Red
    exit 1
}

# Install new packages
Write-Host "Installing spaCy and networkx..." -ForegroundColor Cyan
pip install spacy==3.7.2 networkx==3.2.1

# Download spaCy model
Write-Host "Downloading spaCy English model..." -ForegroundColor Cyan
python -m spacy download en_core_web_sm

# Create necessary directories
New-Item -ItemType Directory -Force -Path frontend\static\js | Out-Null

# Create new backend files

# entity_extractor.py
@"
import spacy
from collections import Counter

_nlp = None

def get_nlp():
    global _nlp
    if _nlp is None:
        _nlp = spacy.load("en_core_web_sm")
    return _nlp

def extract_entities(text):
    nlp = get_nlp()
    doc = nlp(text)
    entities = []
    for ent in doc.ents:
        name = ent.text.strip().lower()
        entities.append((name, ent.label_))
    for chunk in doc.noun_chunks:
        if chunk.root.pos_ == "NOUN" and len(chunk.text.split()) <= 3:
            name = chunk.text.lower().strip()
            entities.append((name, "CONCEPT"))
    return entities

def extract_relationships(text):
    nlp = get_nlp()
    doc = nlp(text)
    relations = []
    for sent in doc.sents:
        for token in sent:
            if token.dep_ in ("nsubj", "nsubjpass") and token.head.pos_ == "VERB":
                subject = token.text.lower()
                verb = token.head.lemma_.lower()
                for child in token.head.children:
                    if child.dep_ in ("dobj", "iobj", "attr"):
                        obj = child.text.lower()
                        relations.append((subject, verb, obj))
                        break
    return relations
"@ | Set-Content -Path backend\entity_extractor.py -Encoding utf8

# graph_builder.py
@"
import networkx as nx
import json
import models

def build_graph(limit_nodes=500):
    G = nx.Graph()
    with models.get_db() as conn:
        entities = conn.execute(
            "SELECT id, name, type, frequency FROM entities ORDER BY frequency DESC LIMIT ?",
            (limit_nodes,)
        ).fetchall()
        entity_ids = [e['id'] for e in entities]
        for e in entities:
            G.add_node(e['id'], name=e['name'], type=e['type'], size=e['frequency'])
        if entity_ids:
            placeholders = ','.join('?' for _ in entity_ids)
            relationships = conn.execute(f"""
                SELECT source_entity_id, target_entity_id, relation_type, strength
                FROM relationships
                WHERE source_entity_id IN ({placeholders}) AND target_entity_id IN ({placeholders})
            """, entity_ids + entity_ids).fetchall()
            for r in relationships:
                G.add_edge(r['source_entity_id'], r['target_entity_id'],
                           type=r['relation_type'], weight=r['strength'])
    return G

def graph_to_json(G):
    nodes = []
    for n, data in G.nodes(data=True):
        nodes.append({
            "id": n,
            "name": data.get('name', ''),
            "type": data.get('type', ''),
            "size": data.get('size', 1)
        })
    links = []
    for u, v, data in G.edges(data=True):
        links.append({
            "source": u,
            "target": v,
            "type": data.get('type', ''),
            "weight": data.get('weight', 1)
        })
    return {"nodes": nodes, "links": links}

def get_related_entities(entity_id, max_depth=2):
    G = build_graph()
    if entity_id not in G:
        return []
    related = {}
    visited = set()
    queue = [(entity_id, 0)]
    while queue:
        node, depth = queue.pop(0)
        if node in visited or depth > max_depth:
            continue
        visited.add(node)
        if node != entity_id:
            related[node] = G.nodes[node]
        for neighbor in G.neighbors(node):
            if neighbor not in visited:
                queue.append((neighbor, depth+1))
    return related
"@ | Set-Content -Path backend\graph_builder.py -Encoding utf8

# frontend/graph.html
@"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Knowledge Graph Explorer</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://d3js.org/d3.v7.min.js"></script>
</head>
<body class="bg-gray-100">
    <div class="container mx-auto p-4">
        <a href="/" class="text-blue-600 hover:underline">&larr; Back to Search</a>
        <h1 class="text-3xl font-bold my-4">Your Knowledge Graph</h1>
        <div class="flex flex-wrap gap-4 mb-4">
            <div>
                <label>Filter by type:</label>
                <select id="typeFilter" class="border rounded p-1">
                    <option value="all">All</option>
                </select>
            </div>
            <div>
                <label>Search node:</label>
                <input id="searchNode" class="border rounded p-1" placeholder="Entity name...">
            </div>
        </div>
        <div id="graph" class="bg-white rounded-lg shadow-lg" style="height: 600px;"></div>
        <div id="details" class="mt-4 p-4 bg-white rounded-lg shadow hidden">
            <h2 class="text-xl font-bold" id="detailName"></h2>
            <p id="detailType"></p>
            <p id="detailDocs"></p>
        </div>
    </div>
    <script src="/static/js/graph.js"></script>
</body>
</html>
"@ | Set-Content -Path frontend\graph.html -Encoding utf8

# frontend/static/js/graph.js
@"
fetch('/api/graph')
    .then(res => res.json())
    .then(data => {
        const width = document.getElementById('graph').clientWidth;
        const height = 600;

        const svg = d3.select("#graph")
            .append("svg")
            .attr("width", width)
            .attr("height", height)
            .call(d3.zoom().on("zoom", (event) => {
                svg.attr("transform", event.transform);
            }))
            .append("g");

        const simulation = d3.forceSimulation(data.nodes)
            .force("link", d3.forceLink(data.links).id(d => d.id).distance(100))
            .force("charge", d3.forceManyBody().strength(-300))
            .force("center", d3.forceCenter(width / 2, height / 2));

        const link = svg.append("g")
            .selectAll("line")
            .data(data.links)
            .enter().append("line")
            .attr("stroke", "#999")
            .attr("stroke-opacity", 0.6)
            .attr("stroke-width", d => Math.sqrt(d.weight));

        const node = svg.append("g")
            .selectAll("circle")
            .data(data.nodes)
            .enter().append("circle")
            .attr("r", d => Math.sqrt(d.size) * 3)
            .attr("fill", d => {
                switch(d.type) {
                    case "PERSON": return "#ff7f0e";
                    case "ORG": return "#1f77b4";
                    case "GPE": return "#2ca02c";
                    default: return "#d62728";
                }
            })
            .call(d3.drag()
                .on("start", dragstarted)
                .on("drag", dragged)
                .on("end", dragended))
            .on("click", (event, d) => showDetails(d));

        node.append("title").text(d => d.name);

        simulation.on("tick", () => {
            link
                .attr("x1", d => d.source.x)
                .attr("y1", d => d.source.y)
                .attr("x2", d => d.target.x)
                .attr("y2", d => d.target.y);

            node
                .attr("cx", d => d.x)
                .attr("cy", d => d.y);
        });

        function dragstarted(event) {
            if (!event.active) simulation.alphaTarget(0.3).restart();
            event.subject.fx = event.subject.x;
            event.subject.fy = event.subject.y;
        }

        function dragged(event) {
            event.subject.fx = event.x;
            event.subject.fy = event.y;
        }

        function dragended(event) {
            if (!event.active) simulation.alphaTarget(0);
            event.subject.fx = null;
            event.subject.fy = null;
        }

        function showDetails(d) {
            fetch(`/api/entity/${d.id}`)
                .then(res => res.json())
                .then(data => {
                    document.getElementById('details').classList.remove('hidden');
                    document.getElementById('detailName').textContent = data.entity.name;
                    document.getElementById('detailType').textContent = `Type: ${data.entity.type}`;
                    const docs = data.documents.map(doc => doc.title).join(', ');
                    document.getElementById('detailDocs').textContent = `Appears in: ${docs}`;
                });
        }
    });
"@ | Set-Content -Path frontend\static\js\graph.js -Encoding utf8

# Update requirements.txt (append new packages)
Add-Content -Path backend\requirements.txt -Value "`n# Knowledge Graph`nspacy==3.7.2`nnetworkx==3.2.1"

# Update setup.sh to include spacy download (if not already)
$setupContent = Get-Content setup.sh -Raw
if ($setupContent -notmatch "spacy download") {
    Add-Content -Path setup.sh -Value @"

# Install spaCy model for knowledge graph
echo "Downloading spaCy model..."
python -m spacy download en_core_web_sm
"@
}

Write-Host "==================================================" -ForegroundColor Green
Write-Host "Knowledge Graph extension files created." -ForegroundColor Green
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "1. Manually update your existing Python files with the code snippets provided in the instructions."
Write-Host "   (models.py, indexer.py, search.py, personalization.py, app.py)"
Write-Host "2. After updating, re-index your documents to populate the graph:"
Write-Host "   Invoke-RestMethod -Method Post -Uri http://localhost:8000/reindex"
Write-Host "3. Visit http://localhost:8000/graph to explore your knowledge graph."
Write-Host ""
Write-Host "See the previous message for the exact code to add to each file." -ForegroundColor Cyan