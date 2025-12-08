## DAG RPC Commands

Megabytes exposes several **RPC methods** to inspect the BlockDAG structure,
including block-level DAG details, per-layer information, and global DAG statistics.

---

## getblockdag "blockhash"

Returns detailed DAG-related information for a specific block.

### Arguments

Name | Type | Description
-----|------|------------
`blockhash` | string (hex) | The hash of the block to inspect

### Description

This command provides a full DAG view of a block:

- its height  
- its blue score  
- the list of DAG parents  
- the list of DAG children  
- PoW algorithm used  
- MHIS value (Merkle-like Historical Integrity Sequence)  

This allows developers, explorers, or researchers to visualize
how a block is positioned within the DAG.

### Example

```bash  
megabytes-cli getblockdag 20c4f6236f8e5061745cfafe6d6e05cdad617ec84460e4bf4e8248ca2b453ac4
```

### Returned fields

Field | Description
------|------------
`hash` | Block hash
`height` | Block height
`has_data` | True if block data is available
`on_active_chain` | True if block is in the active GhostDAG chain
`pow_algo` | Mining algorithm used
`blue_score` | GhostDAG blue score
`dag_parents[]` | List of DAG parents with metadata
`dag_children[]` | List of DAG children with metadata
`mhis` | Anti-reorg integrity sequence

### Use cases

- Visualizing DAG connectivity  
- Debugging consensus / orphaning  
- Multi-parent propagation analysis  
- Block explorer development  

---

## getdaglayer height

Returns all blocks that belong to a given **DAG layer (height)**.

### Arguments

Name | Type | Description
------|------|------------
`height` | integer | Layer height to inspect

### Description

In a BlockDAG, multiple blocks may exist at the same height ("layer").  
This RPC reveals whether:

- the layer contains a single block (width = 1)  
- multiple concurrent blocks appear at the same height (width > 1)  

Useful for detecting DAG concurrency, forks, and network delays.

### Example

```bash  
megabytes-cli getdaglayer 20
```

### Returned fields

Field | Description
------|------------
`height` | Requested layer height
`width` | Number of blocks at this height
`blocks[]` | Array of blocks in the layer (hash, algo, blue_score)

### Use cases

- Detecting concurrency and accidental forks  
- Analyzing network propagation  
- Building DAG visualization tools  

---

## getdagstats (window)

Returns global DAG statistics over a specified recent block window.

### Arguments

Name | Type | Default | Description
------|------|---------|------------
`window` | integer | 200 | Number of blocks to analyze

### Description

Provides high-level metrics describing the structure and health of the DAG:

- **avg_width / max_width** → DAG concurrency  
- **avg_parents / avg_children** → edge density  
- **pct_multi_parents** → % of blocks referencing >1 parent  
- **mhis_unique_ratio** → anti-reorg integrity quality  

This command is invaluable for measuring:

- miner decentralization  
- DAG saturation  
- orphan rate  
- network stability  
- GhostDAG parameter tuning  

### Example

bash  
megabytes-cli getdagstats  

### Returned fields (summary)

Field | Description
------|-------------
`window` | Number of blocks analyzed
`from_height` / `to_height` | Range of blocks
`avg_width` / `max_width` | DAG width metrics
`tip_width` | Width at the current tip
`wide_heights[]` | Heights where width exceeded 1
`avg_parents` / `max_parents` | DAG parent connectivity
`avg_children` / `max_children` | DAG child connectivity
`pct_multi_parents` | Ratio of blocks with multiple DAG parents
`mhis_unique_ratio` | Diversity of MHIS values (anti-reorg strength)

### Use cases

- Monitoring DAG concurrency/load  
- Detecting propagation delays or slow miners  
- Evaluating stability during stress tests  
- Academic research on DAG security

---
