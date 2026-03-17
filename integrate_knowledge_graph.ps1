# integrate_knowledge_graph.ps1
Write-Host "=== Integrating Knowledge Graph into Deep Personal Search ===" -ForegroundColor Green

$projectRoot = Get-Location
$backendDir = Join-Path $projectRoot "backend"
$frontendDir = Join-Path $projectRoot "frontend"
$staticJsDir = Join-Path $frontendDir "static" "js"

# Create directories if missing
New-Item -ItemType Directory -Force -Path $backendDir | Out-Null
New-Item -ItemType Directory -Force -Path $frontendDir | Out-Null
New-Item -ItemType Directory -Force -Path $staticJsDir | Out-Null

# ----------------------------------------------------------------------
# 1. Create new backend files (if they don't exist)
# ----------------------------------------------------------------------
$entityExtractorPath = Join-Path $backendDir "entity_extractor.py"
if (-not (Test-Path $entityExtractorPath)) {
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
"@ | Set-Content -Path $entityExtractorPath -Encoding utf8
    Write-Host "Created: backend/entity_extractor.py" -ForegroundColor Cyan
} else {
    Write-Host "backend/entity_extractor.py already exists. Skipping." -ForegroundColor Yellow
}

$graphBuilderPath = Join-Path $backendDir "graph_builder.py"
if (-not (Test-Path $graphBuilderPath)) {
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
"@ | Set-Content -Path $graphBuilderPath -Encoding utf8
    Write-Host "Created: backend/graph_builder.py" -ForegroundColor Cyan
} else {
    Write-Host "backend/graph_builder.py already exists. Skipping." -ForegroundColor Yellow
}

# ----------------------------------------------------------------------
# 2. Create frontend files
# ----------------------------------------------------------------------
$graphHtmlPath = Join-Path $frontendDir "graph.html"
if (-not (Test-Path $graphHtmlPath)) {
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
"@ | Set-Content -Path $graphHtmlPath -Encoding utf8
    Write-Host "Created: frontend/graph.html" -ForegroundColor Cyan
} else {
    Write-Host "frontend/graph.html already exists. Skipping." -ForegroundColor Yellow
}

$graphJsPath = Join-Path $staticJsDir "graph.js"
if (-not (Test-Path $graphJsPath)) {
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
"@ | Set-Content -Path $graphJsPath -Encoding utf8
    Write-Host "Created: frontend/static/js/graph.js" -ForegroundColor Cyan
} else {
    Write-Host "frontend/static/js/graph.js already exists. Skipping." -ForegroundColor Yellow
}

# ----------------------------------------------------------------------
# 3. Append code to existing Python files (with markers)
# ----------------------------------------------------------------------
Write-Host "`nAppending code to existing files (with # --- KNOWLEDGE GRAPH ADDITIONS --- markers)..." -ForegroundColor Cyan

# models.py
$modelsPath = Join-Path $backendDir "models.py"
if (Test-Path $modelsPath) {
    $modelsContent = Get-Content $modelsPath -Raw
    if ($modelsContent -notmatch "CREATE TABLE IF NOT EXISTS entities") {
        Add-Content -Path $modelsPath -Value @"

# --- KNOWLEDGE GRAPH ADDITIONS (add inside init_db() and then these functions) ---
# 1. Inside init_db(), add these table definitions:
#    CREATE TABLE IF NOT EXISTS entities ( ... );
#    CREATE TABLE IF NOT EXISTS relationships ( ... );
#    CREATE TABLE IF NOT EXISTS document_entities ( ... );
#
# 2. Add these helper functions (place anywhere after init_db):

def upsert_entity(name, entity_type, embedding=None):
    with get_db() as conn:
        cur = conn.execute(
            "INSERT INTO entities (name, type, frequency, last_seen, embedding) VALUES (?, ?, 1, CURRENT_TIMESTAMP, ?) "
            "ON CONFLICT(name) DO UPDATE SET frequency = frequency + 1, last_seen = CURRENT_TIMESTAMP",
            (name, entity_type, embedding)
        )
        conn.commit()
        return cur.lastrowid

def insert_relationship(source_id, target_id, rel_type, strength=1.0):
    with get_db() as conn:
        conn.execute(
            "INSERT INTO relationships (source_entity_id, target_entity_id, relation_type, strength, last_seen) "
            "VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP) "
            "ON CONFLICT(source_entity_id, target_entity_id, relation_type) "
            "DO UPDATE SET strength = strength + ?, last_seen = CURRENT_TIMESTAMP",
            (source_id, target_id, rel_type, strength, strength)
        )
        conn.commit()

def link_document_entity(doc_id, entity_id, count=1):
    with get_db() as conn:
        conn.execute(
            "INSERT INTO document_entities (doc_id, entity_id, count) VALUES (?, ?, ?) "
            "ON CONFLICT(doc_id, entity_id) DO UPDATE SET count = count + ?",
            (doc_id, entity_id, count, count)
        )
        conn.commit()
"@
        Write-Host "  Appended code to backend/models.py. You MUST move the table definitions into init_db() manually." -ForegroundColor Yellow
    } else {
        Write-Host "  models.py already has knowledge graph code. Skipping." -ForegroundColor Yellow
    }
} else {
    Write-Host "  backend/models.py not found!" -ForegroundColor Red
}

# indexer.py
$indexerPath = Join-Path $backendDir "indexer.py"
if (Test-Path $indexerPath) {
    $indexerContent = Get-Content $indexerPath -Raw
    if ($indexerContent -notmatch "extract_entities") {
        Add-Content -Path $indexerPath -Value @"

# --- KNOWLEDGE GRAPH ADDITIONS ---
# Add these imports at the top of the file:
# import entity_extractor
# import models
#
# Inside the chunk processing loop (where you have chunk_text and doc_id), add:
#
# # Extract entities and relationships for knowledge graph
# entities = entity_extractor.extract_entities(chunk_text)
# for ent_name, ent_type in set(entities):  # deduplicate per chunk
#     ent_id = models.upsert_entity(ent_name, ent_type)
#     models.link_document_entity(doc_id, ent_id)
#
# relations = entity_extractor.extract_relationships(chunk_text)
# for subj, verb, obj in relations:
#     subj_id = models.upsert_entity(subj, "SUBJECT")
#     obj_id = models.upsert_entity(obj, "OBJECT")
#     models.insert_relationship(subj_id, obj_id, verb)
"@
        Write-Host "  Appended instructions to backend/indexer.py. You must add the imports and code in the correct place." -ForegroundColor Yellow
    } else {
        Write-Host "  indexer.py already has knowledge graph code. Skipping." -ForegroundColor Yellow
    }
} else {
    Write-Host "  backend/indexer.py not found!" -ForegroundColor Red
}

# search.py
$searchPath = Join-Path $backendDir "search.py"
if (Test-Path $searchPath) {
    $searchContent = Get-Content $searchPath -Raw
    if ($searchContent -notmatch "graph_boost") {
        Add-Content -Path $searchPath -Value @"

# --- KNOWLEDGE GRAPH ADDITIONS ---
# Add these helper functions (place after load_index, e.g., at the end of file):

import graph_builder
import models

def get_related_entity_ids(entity_names, max_depth=1):
    related_ids = set()
    with models.get_db() as conn:
        for name in entity_names:
            row = conn.execute("SELECT id FROM entities WHERE name = ?", (name,)).fetchone()
            if row:
                related = conn.execute("""
                    SELECT target_entity_id FROM relationships WHERE source_entity_id = ?
                    UNION
                    SELECT source_entity_id FROM relationships WHERE target_entity_id = ?
                """, (row['id'], row['id'])).fetchall()
                for r in related:
                    related_ids.add(r[0])
    return related_ids

def graph_boost(query, candidates):
    import entity_extractor
    query_entities = [name for name, typ in entity_extractor.extract_entities(query)]
    if not query_entities:
        return candidates
    related_ids = get_related_entity_ids(query_entities)
    if not related_ids:
        return candidates
    for c in candidates:
        with models.get_db() as conn:
            doc_entities = conn.execute(
                "SELECT entity_id FROM document_entities WHERE doc_id = ?",
                (c['doc_id'],)
            ).fetchall()
        doc_entity_ids = {r['entity_id'] for r in doc_entities}
        overlap = doc_entity_ids & related_ids
        if overlap:
            boost = min(len(overlap) * 0.1, 0.5)
            c['score'] += boost
    return candidates

# Then inside the search() function, after personalization but before sorting, add:
# candidates = graph_boost(query, candidates)
"@
        Write-Host "  Appended code to backend/search.py. You must add the function calls inside search()." -ForegroundColor Yellow
    } else {
        Write-Host "  search.py already has knowledge graph code. Skipping." -ForegroundColor Yellow
    }
} else {
    Write-Host "  backend/search.py not found!" -ForegroundColor Red
}

# app.py
$appPath = Join-Path $backendDir "app.py"
if (Test-Path $appPath) {
    $appContent = Get-Content $appPath -Raw
    if ($appContent -notmatch "/graph" -or $appContent -notmatch "/api/graph") {
        Add-Content -Path $appPath -Value @"

# --- KNOWLEDGE GRAPH ADDITIONS ---
# Add these routes at the end of the file (before if __name__ == "__main__":)

import graph_builder
import json

@app.get("/graph", response_class=HTMLResponse)
def graph_page(request: Request):
    return templates.TemplateResponse("graph.html", {"request": request})

@app.get("/api/graph")
def get_graph():
    G = graph_builder.build_graph(limit_nodes=500)
    data = graph_builder.graph_to_json(G)
    return JSONResponse(data)

@app.get("/api/entity/{entity_id}")
def entity_detail(entity_id: int):
    with models.get_db() as conn:
        entity = conn.execute("SELECT * FROM entities WHERE id = ?", (entity_id,)).fetchone()
        if not entity:
            return JSONResponse({"error": "Not found"}, status_code=404)
        docs = conn.execute("""
            SELECT d.id, d.title, de.count FROM documents d
            JOIN document_entities de ON d.id = de.doc_id
            WHERE de.entity_id = ?
            ORDER BY de.count DESC
        """, (entity_id,)).fetchall()
        related = conn.execute("""
            SELECT e.id, e.name, e.type, r.relation_type, r.strength
            FROM relationships r
            JOIN entities e ON (r.target_entity_id = e.id AND r.source_entity_id = ?)
            UNION
            SELECT e.id, e.name, e.type, r.relation_type, r.strength
            FROM relationships r
            JOIN entities e ON (r.source_entity_id = e.id AND r.target_entity_id = ?)
        """, (entity_id, entity_id)).fetchall()
    return JSONResponse({
        "entity": dict(entity),
        "documents": [dict(d) for d in docs],
        "related": [dict(r) for r in related]
    })
"@
        Write-Host "  Appended routes to backend/app.py. You may need to move imports to the top." -ForegroundColor Yellow
    } else {
        Write-Host "  app.py already has graph routes. Skipping." -ForegroundColor Yellow
    }
} else {
    Write-Host "  backend/app.py not found!" -ForegroundColor Red
}

# ----------------------------------------------------------------------
# 4. Update requirements.txt (already done by setup_knowledge_graph.ps1, but ensure)
# ----------------------------------------------------------------------
$reqPath = Join-Path $backendDir "requirements.txt"
if (Test-Path $reqPath) {
    $reqContent = Get-Content $reqPath -Raw
    if ($reqContent -notmatch "spacy" -or $reqContent -notmatch "networkx") {
        Add-Content -Path $reqPath -Value @"

# Knowledge Graph
spacy==3.7.2
networkx==3.2.1
"@
        Write-Host "  Added spacy and networkx to requirements.txt" -ForegroundColor Cyan
    }
}

# ----------------------------------------------------------------------
# Final instructions
# ----------------------------------------------------------------------
Write-Host @"

=============================================================
✅ Knowledge Graph files created and code snippets appended.

❗ NEXT STEPS (MANUAL):
1. Open each backend Python file and move the appended code to the correct locations:
   - models.py: Move the CREATE TABLE statements inside init_db().
   - indexer.py: Add imports at top and entity extraction inside chunk loop.
   - search.py: Add graph_boost function and call it inside search().
   - app.py: Ensure imports are at top; routes are fine at the end.

2. After moving the code, re-index your documents:
   cd C:\Users\Tayeb\Documents\deep-personal-search
   venv311\Scripts\activate
   python -c "from backend.indexer import index_documents; index_documents()"

3. Start the server:
   cd backend
   uvicorn app:app --reload --host 127.0.0.1 --port 8000

4. Open http://127.0.0.1:8000/graph to explore your knowledge graph.

If you need help with any specific file, just ask!
=============================================================
"@ -ForegroundColor Green