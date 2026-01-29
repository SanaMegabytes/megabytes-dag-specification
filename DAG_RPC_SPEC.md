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

```bash  
megabytes-cli getdagstats
```

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

## getdagmeta (block-level)

Returns detailed DAG metadata for a specific block, combining **persisted (DB)** and **runtime** views of the DAG state.

### Arguments

Name | Type | Required | Description
------|------|----------|------------
`blockhash` | string | yes | Target block hash to inspect

### Description

`getdagmeta` is a **low-level diagnostic command** designed to inspect how a specific block is positioned inside the DAG.

It exposes both:
- **Persisted metadata** stored in the DAG database (consensus-critical)
- **Runtime-computed metadata** reconstructed from the current DAG view (debug / verification)

This command is essential for:
- DAG correctness verification
- Finality debugging
- Reorg analysis
- GhostDAG parameter tuning
- Detecting DB vs runtime divergence

### What this command reveals

**Structural DAG data**
- Selected Parent (SP)
- Merge-set size
- Past depth
- Anticone size
- Local and tip width

**GhostDAG consensus metrics**
- Blue score
- Blue steps
- Blue / Red block counts
- Effective K value (runtime)

**Finality & integrity checks**
- BLUE_READY status
- Metadata completeness
- DB ↔ runtime consistency validation

### Returned fields (summary)

Field | Description
------|-------------
`hash` | Block hash queried
`height` | Block height
`has_meta` | Indicates whether DAG metadata exists for this block
`meta_db` | Persisted DAG metadata loaded from the DAG database
`meta_runtime` | DAG metadata recomputed at runtime
`sp_match` | Whether DB and runtime selected parent hashes match
`blue_score_match` | Whether DB and runtime blue scores match
`blue_steps_match` | Whether DB and runtime blue steps match

### meta_db fields

Field | Description
------|-------------
`sp_hash` | Selected parent hash
`blue_score` | Monotonic GhostDAG blue score
`blue_steps` | Distance (in blue steps) from selected parent
`blue_count` | Number of blue blocks in merge-set
`red_count` | Number of red blocks in merge-set
`mergeset_size` | Total merge-set size
`past_depth` | Depth of the past cone
`future_children` | Number of known children (non-consensus metric)
`width_tip` | DAG width at tip level
`width_local` | Local DAG width around this block
`tip_anticone` | Size of the anticone relative to the current tip
`k_runtime` | Effective GhostDAG K value
`flags` | Bitmask of DAG state flags
`flags_decoded` | Human-readable decoded flags

### Example

```bash
megabytes-cli getdagmeta <blockhash>
```

Typical use cases

- Verifying GhostDAG convergence after a reorg
- Ensuring blue-score monotonicity
- Auditing DAG DB persistence correctness
- Debugging Finality V2 veto decisions
- Diagnosing unexpected DAG divergence


