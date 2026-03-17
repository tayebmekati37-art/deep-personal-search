let currentData = null;
let svg, simulation, link, node, label;

fetch('/api/graph')
    .then(res => res.json())
    .then(data => {
        currentData = data;
        initGraph(data);
        setupFilters();
    });

function initGraph(data) {
    const width = document.getElementById('graph').clientWidth;
    const height = 600;

    // Clear previous graph
    d3.select("#graph").selectAll("*").remove();

    svg = d3.select("#graph")
        .append("svg")
        .attr("width", width)
        .attr("height", height)
        .call(d3.zoom().on("zoom", (event) => {
            svg.attr("transform", event.transform);
        }))
        .append("g");

    simulation = d3.forceSimulation(data.nodes)
        .force("link", d3.forceLink(data.links).id(d => d.id).distance(150))
        .force("charge", d3.forceManyBody().strength(-400))
        .force("center", d3.forceCenter(width / 2, height / 2))
        .force("collide", d3.forceCollide().radius(d => Math.sqrt(d.size) * 5 + 10));

    link = svg.append("g")
        .selectAll("line")
        .data(data.links)
        .enter().append("line")
        .attr("stroke", "#999")
        .attr("stroke-opacity", 0.6)
        .attr("stroke-width", d => Math.sqrt(d.weight));

    node = svg.append("g")
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

    label = svg.append("g")
        .selectAll("text")
        .data(data.nodes)
        .enter().append("text")
        .text(d => d.name)
        .attr("font-size", 10)
        .attr("dx", 12)
        .attr("dy", 4)
        .attr("fill", "#333");

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

        label
            .attr("x", d => d.x)
            .attr("y", d => d.y);
    });
}

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

function setupFilters() {
    // Populate type filter dropdown
    const types = [...new Set(currentData.nodes.map(n => n.type))];
    const typeFilter = document.getElementById('typeFilter');
    types.forEach(t => {
        const option = document.createElement('option');
        option.value = t;
        option.text = t;
        typeFilter.appendChild(option);
    });

    document.getElementById('typeFilter').addEventListener('change', applyFilters);
    document.getElementById('searchNode').addEventListener('input', applyFilters);
}

function applyFilters() {
    const selectedType = document.getElementById('typeFilter').value;
    const searchTerm = document.getElementById('searchNode').value.toLowerCase();

    const filteredNodes = currentData.nodes.filter(n => {
        const typeMatch = selectedType === 'all' || n.type === selectedType;
        const nameMatch = n.name.toLowerCase().includes(searchTerm);
        return typeMatch && nameMatch;
    });

    const filteredNodeIds = new Set(filteredNodes.map(n => n.id));
    const filteredLinks = currentData.links.filter(l => 
        filteredNodeIds.has(l.source) && filteredNodeIds.has(l.target)
    );

    // Reinitialize graph with filtered data
    initGraph({ nodes: filteredNodes, links: filteredLinks });
}

