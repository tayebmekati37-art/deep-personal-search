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
            fetch(/api/entity/)
                .then(res => res.json())
                .then(data => {
                    document.getElementById('details').classList.remove('hidden');
                    document.getElementById('detailName').textContent = data.entity.name;
                    document.getElementById('detailType').textContent = Type: ;
                    const docs = data.documents.map(doc => doc.title).join(', ');
                    document.getElementById('detailDocs').textContent = Appears in: ;
                });
        }
    });
