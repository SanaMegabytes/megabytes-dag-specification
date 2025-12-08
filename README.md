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

**Full technical specification:**  
See the complete DAG glossary, definitions, and GhostDAG rules in  
[DAG_SPEC.md](./DAG_SPEC.md)




