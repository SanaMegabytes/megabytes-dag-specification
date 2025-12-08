# megabytes-dag-specification
Comprehensive specification and documentation of the Megabytes BlockDAG, including GhostDAG scoring, DAG parents, MHIS, finality rules, and DAG-oriented RPC interfaces.

```mermaid
flowchart LR
%% === HEIGHT 19 ===
subgraph H19["Height 19 (width = 3)"]
    B19a[B19a]:::blue
    B19b[B19b]:::red
    B19c[B19c]:::red
end

%% === HEIGHT 20 ===
subgraph H20["Height 20 (width = 2)"]
    B20a[B20a]:::blue
    B20b[B20b]:::red
end

%% === HEIGHT 21 ===
subgraph H21["Height 21 (width = 1)"]
    B21[B21]:::blue
end

%% === GHOSTDAG COMPUTE NODES (VIOLET) ===
GD19["GhostDAG scoring at height 19:<br/>• Evaluate B19 a/b/c<br/>• Pick blue vs red<br/>• Define best parents for next layer"]:::step

GD20["GhostDAG convergence at height 20:<br/>• Evaluate B20 a/b<br/>• Choose final tip<br/>→ Converges to single head (B21)"]:::step


%% === CONNECTIONS ===


%% All width-3 blocks go through GhostDAG scoring
B19a --> GD19
B19b --> GD19
B19c --> GD19

%% GhostDAG scoring outputs the next-layer blocks (width 2)
GD19 --> B20a
GD19 --> B20b

%% Width-2 blocks go through convergence scoring
B20a --> GD20
B20b --> GD20

%% Final convergence to a single blue head
GD20 --> B21


%% === STYLES ===
classDef blue fill:#6db7ff,stroke:#004a99,stroke-width:2px,color:#000;
classDef red fill:#ff9c9c,stroke:#cc0000,stroke-width:2px,color:#000;
classDef step fill:#e9e4ff,stroke:#6d5fa3,stroke-width:1px,color:#000;

class B18,B19a,B20a,B21 blue;
class B19b,B19c,B20b red;

%% Remove any background/border on height groups

style H19 fill:transparent,stroke-width:0px,stroke:transparent;
style H20 fill:transparent,stroke-width:0px,stroke:transparent;
style H21 fill:transparent,stroke-width:0px,stroke:transparent;
```
---

## DAG Glossary (Key Terms)

### Blue Block
A block selected by GhostDAG as part of the honest, well-connected chain.  
Blue blocks have small anticone sets and strong DAG connectivity.

### Red Block
A valid block that is not chosen for the blue set.  
Red blocks typically have weaker connectivity, a larger anticone, or arrive too late.  
They remain part of the DAG but do not represent the canonical structure.

### Width
The number of blocks produced at the same height.

- `width = 1` → fully converged  
- `width = 2` or `3` → normal short-term concurrency  
- `width >= 4` → possible attack or poor network connectivity  

Width is useful to detect abnormal or suspicious behavior.

### Parent
A block listed inside `dag_parents`.  
A block may have multiple parents:
- one **blue parent** (best, well-connected parent)  
- additional **DAG parents** to maintain global connectivity  

This multi-parent model reduces orphaning and improves DAG robustness.

### Children
Blocks that reference the current block as one of their parents.  
Children are useful to visualize forward connectivity and detect divergence near the tip.

### Anticone
The set of blocks that are neither ancestors nor descendants of a given block.  
A large anticone usually indicates a block that is less well integrated into the DAG and is often classified as red.

### Mergeset
All blocks that must be considered when integrating a new block into the DAG.  
GhostDAG uses mergeset properties to decide block color (blue or red) and to evaluate chain quality.

### Tip
A block with no children.  
Multiple tips indicate parallel mining or temporary forks (width > 1 near the head).

### Isolated DAG (Megabytes-specific)
A branch with extremely weak connectivity to the honest DAG.  
Such branches exhibit very low DAC quality and are subject to Finality V2 isolation veto.

### Algorithm Divergence (R_algo)
Measures how a branch’s PoW algorithm distribution deviates from the honest chain.  
Strong mono-algo bias or unrealistic proportions are treated as suspicious behavior in the security model.

---


