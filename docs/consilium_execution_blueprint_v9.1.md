# CONSILIUM EXECUTION BLUEPRINT v9.2 (MVP)
**Target:** Bittensor optimization-style subnet (netuid TBD; QUBO-like contract)  
**Reality check (Feb 2026):** Bittensor **SN4 (netuid=4)** is **Targon** (Confidential AI Cloud) and does **not** provide QUBO tasks. See Appendix F.
**MVP Deadline:** 28 Feb 2026  
**Status:** Engineering Specification (for implementation by 2-person team + AI)  
**Confidentiality:** Internal / do not distribute

---

## 0. Executive Summary

This document is an implementation-focused translation of the “E8 + Topology + Quantum Scout” approach for a **Bittensor optimization-style subnet** with a QUBO-like contract.

Core idea (what to build):
- Target subnet provides **Dense QUBO** instances `Q` (or an equivalent cost structure we can map into QUBO) under a strict time window.
- We extract fast **topological signals** from the task’s interaction structure (“holes/loops” → invariants like `β₁`) using an IBM/Qiskit **Quantum Scout** with strict timeouts and hard fallbacks.
- We construct a deterministic **8D topological latent space** and a projection matrix `W ∈ R^(8×N)` (“topological principal components”).
- We **quantize** the latent space against the **E8 root system** (240 roots = vertices of the Gosset polytope `4_21`) either by:
  - **Beam-of-roots (8D):** pick the best roots by reduced energy, or
  - **Adjoint spectrum (248D features):** compute a “Moon/Sun” root energy spectrum and synthesize a target direction from many roots (Section 6.6).
- We **lift** the chosen target direction back to an `N`-bit seed via `W⁺`, then run a short **Lift & Repair** local search on the original `Q` to produce a valid submission.

MVP goal:
- Implement the full miner loop on **testnet** and demonstrate non-random positive incentive/score under strict latency constraints.

What is intentionally *not* explained here:
- Philosophical / “why E8” motivation. The spec focuses on I/O and determinism so an AI can implement it.

---

## 1. MVP Definition (Scope)

### 1.1 Goal
Achieve stable positive incentive/score on the target subnet **testnet** by running a single miner instance continuously and submitting valid solutions.

### 1.2 Success Metrics (KPIs)
Define these numbers before Week 2 and keep them stable for the month:
- **Median incentive/score ≥ `S_target`** over a continuous run of `T_eval` hours.
- **p95 end-to-end latency ≤ `T_p95`** seconds (job received → tx submitted).
- **Acceptance rate ≥ `R_accept`** (valid solutions / total attempts).
- **Stability:** `≥ 24h` continuous operation without crash.

Recommended initial targets (edit after first baseline run):
- `S_target = 0.001`
- `T_p95 = 45s`
- `R_accept = 80%`
- `T_eval = 24h`

### 1.3 Non-Goals (MVP)
- No GUI/front-end (CLI only).
- No autoscaling / multi-node cluster management.
- No mainnet risk in February (testnet only).
- No “enterprise” observability; keep only minimal structured logs.

### 1.4 Strategic Context (Sniper Doctrine)
The target subnet is treated as a **time-windowed optimization market**. The intended niche is:
- Dense / high-connectivity QUBOs where naive GPU heuristics struggle with state update costs.
- We ignore low-complexity instances and focus on tasks where the E8+topology pipeline gives asymmetric advantage.

---

## 2. The Interface: Subnet Contract (Must-Be-True)

> **Important:** v9.0 contained placeholder method names. For v9.2, treat subnet I/O as **contract-first**: verify the real Synapse schema and submission behavior in the actual subnet codebase before coding.  
> **Reality check:** SN4 (netuid=4) is Targon; its on-wire contract is not QUBO (Appendix F).

### 2.1 Task Source
Miner receives tasks from validators via a Bittensor Synapse (or an HTTP axon contract, depending on subnet).

MVP deliverable:
- A single function that converts “Raw Synapse” → `(Q, meta)` where:
  - `Q`: dense matrix (`N×N`, `float32` preferred)
  - `meta`: includes at minimum `job_id`, `deadline_ts` or `timeout_s`, and any validator-provided scoring hints.

### 2.2 Task Data Model (Schema to confirm)
Minimum fields we assume exist (or can be derived):
- `N` (int): number of variables (expected 2000–5000).
- `Q` (matrix): QUBO weights, typically in `[-1, 1]` (confirm).
- `domain` (enum): variables are either `{0,1}` or `{-1,1}` (confirm; implement conversion).
- `time_window_s` (float): hard deadline for response (confirm).

### 2.3 Solution Output Model
Miner must output:
- `solution`: list/array of length `N` (binary/spins per subnet contract)
- optional `energy` (float) if accepted by protocol (confirm)
- signature / wallet metadata as required by Bittensor

### 2.4 Scoring Objective (MVP assumption)
Assume validators reward:
- Lower energy `H(s)` is better
- Latency is a multiplier/penalty
- Invalid format or deadline miss → zero or negative

Define energy in a single canonical form internally, and convert at boundaries:
- Spin form: `s ∈ {-1, +1}^N`, `H(s) = sᵀ Q s`
- Binary form: `x ∈ {0, 1}^N`, `H(x) = xᵀ Q x`

---

## 3. System Architecture (Single-Node MVP)

### 3.1 Components
All components run on one host (laptop or server), with external calls to IBM/Qiskit and an optional solver service.

- **Ingest**: Synapse → dense `Q`, `meta`
- **Quantum Scout**: `(Q, meta)` → topological features `F` (with strict timeout + fallback)
- **W Builder**: `(Q, F)` → `W ∈ R^(8×N)` + cache key
- **E8 Quantizer**: `W, Q` → candidate roots `r_i` and/or best `r*`
- **Lift & Repair**: `(W, r*, Q)` → valid `N`-bit solution `s`
- **Submit**: `s` → on-chain/testnet submission
- **Logger**: writes one JSON line per attempt (minimal observability)

### 3.2 Degraded Modes (Required for MVP)
The pipeline must always produce *some* output before deadline:
- **Degraded-Q**: Quantum Scout timed out → use cached `F_cache`
- **Degraded-W**: W build failed → use cached `W_cache` or deterministic default `W_default`
- **Degraded-S**: Repair cannot finish → return best-so-far seed solution

### 3.3 Hardware Roles (Conceptual)
- **Orchestrator (Local host):** parsing, caching, building `W`, lift & repair, submission.
- **Scout (IBM Quantum / Qiskit Runtime):** topological feature estimation under strict timeout.
- **Hammer (optional external solver):** if configured, solves/warms-starts candidate solutions within a time slice.

---

## 4. The “Sniper Loop” Pipeline (Deterministic, Deadline-Aware)

### 4.1 Hard Time Budget (initial)
This is a starting point; tune after first testnet run.

- Step 1 Ingest: `0.5s`
- Step 2 Quantum Scout: `3.0s` (hard timeout)
- Step 3 Build W: `5.0s`
- Step 4 E8 Quantize: `0.2s`
- Step 5 Lift & Repair: `≤ (deadline - elapsed - submit_budget)` (target `2–20s`)
- Step 6 Submit: `1.0s`

### 4.2 Filtering (Sniper Scope)
We intentionally ignore tasks that do not match the dense/high-connectivity niche.

Define **effective density**:
```
density_eps(Q, eps) = count(|Q_ij| > eps) / (N*N)
```

Initial policy:
- If `N < 2000`: DROP (optional; tune)
- If `density_eps(Q, eps=1e-3) < 0.3`: DROP (tune)

### 4.3 End-to-End Steps
1) **Ingest**
- Parse synapse, validate shapes/types, convert to internal canonical domain (spin or binary).
- Compute cheap stats: `N`, `density_eps`, min/max weight, symmetric check.

2) **Quantum Scout (timeout hard)**
- Compute topological features `F`:
  - must include at least `beta1_estimate` (even if approximate)
  - may include additional scalars: `components_estimate`, `spectral_near_zero`, etc.
- If timeout/error: load `F_cache` keyed by `(subnet_version, N_bucket, density_bucket)` or last-good.

3) **Build W**
- Build `W ∈ R^(8×N)` deterministically from `(Q, F)` (Section 6).
- Cache `W` for reuse across tasks:
  - **Exact reuse:** if `job_id/task_id` repeats or `Q_fingerprint` matches, reuse `W`/`W⁺` and skip eigenvectors.
  - **Bucket reuse:** otherwise reuse by coarse key (`N_bucket` + `beta1_bucket`) if enabled.
- Precompute `W⁺` (pseudo-inverse) when W changes.

4) **E8 Quantize**
- Generate E8 roots (240 vectors in `R^8`) deterministically (Appendix A).
- Compute reduced matrix `Q8 = W Q Wᵀ` (8×8).
- If `E8_MODE=beam8`:
  - Select root candidates `r` by minimizing reduced energy `E8(r) = rᵀ Q8 r`.
  - Keep top `B` candidates (beam width; MVP start `B=8`).
- If `E8_MODE=adjoint248`:
  - Compute the full root energy spectrum `E8(r_i)` for all 240 roots.
  - Build 1–2 target directions `u` (Moon-only; Moon+Sun) as weighted mixtures of roots (Section 6.6).
  - Optionally keep top `B` single roots as a safety fallback.

5) **Lift & Repair (anytime)**
For each candidate target direction `u ∈ R^8` (either a root `r` or a mixture direction) in order:
- Lift: `s_seed = W⁺ u` (vector in `R^N`)
- Binarize/spinize: `s0 = binarize(s_seed)` (Section 6)
- Repair: run greedy local search on original `Q` under a strict time slice.
- Track best `(energy, solution)` and stop when remaining time is low.

6) **Submit**
- Submit best solution found.
- No artificial delays: submit as soon as ready.

---

## 5. Mathematical & Data Definitions

### 5.1 QUBO Canonicalization
Pick one internal representation for MVP (recommended: **spin** `{-1,+1}`):
- If subnet uses `{0,1}`, convert to spin or implement both energy functions and repair deltas.

### 5.2 E8 Root System (Gosset Polytope `4_21`)
We use the E8 root system as a fixed codebook of 240 vectors in `R^8`:
- All roots have equal norm (`||r||² = 2`)
- Two families:
  - Type A: permutations of `(±1, ±1, 0, 0, 0, 0, 0, 0)` → 112 roots
  - Type B: `(±1/2, …, ±1/2)` with an even number of minus signs → 128 roots

Engineering note:
- In MVP we do **not** need to implement Weyl-group actions explicitly; we only need the deterministic root codebook and snapping.

### 5.3 Projection Matrix `W`
Corrected definition (v9.2):
- `W ∈ R^(8×N)` maps `N`-dimensional states into an 8D latent space.
- `v = W s`, where `v ∈ R^8`, `s ∈ R^N` (a candidate state/seed).
- `W` is derived from topological structure (Section 6), not hand-tuned.

### 5.4 Snapping / Quantization
Given `v ∈ R^8`, snap to nearest E8 root:
```
r* = argmin_{r in Roots_E8} ||v - r||_2
```
Since all roots share a constant norm, this is equivalent to maximizing dot product:
```
r* = argmax_{r in Roots_E8} <v, r>
```

### 5.5 Pseudo-Inverse
Given `W` has full row rank, compute:
```
W⁺ = Wᵀ (W Wᵀ)^(-1)     # dimensions: (N×8)
```
Compute and cache `W⁺` whenever `W` changes.

Practical MVP note (numerical stability):
- Use a ridge-stabilized pseudo-inverse by default:
  ```
  W⁺_λ = Wᵀ (W Wᵀ + λ I)^(-1)
  ```
- Start with `λ = 1e-3` and tune if needed.

---

## 6. E8 Regularizer (Engineering Specification)

### 6.1 Inputs / Outputs
Inputs:
- `Q`: dense `N×N` float32
- `F`: topological feature vector (at minimum `beta1_estimate`)

Outputs:
- `W`: `8×N` float32
- `W_plus`: `N×8` float32
- `Roots_E8`: list of 240 vectors in `R^8` (cached global constant)

### 6.2 Building `W` (MVP-Implementable)
We need 8 stable “topological principal components” for the task graph.

MVP method (deterministic, fast, reproducible):
1) Build a **skeleton graph** `G_skel` from `Q`:
   - For each node `i`, keep the `k` strongest interactions by `|Q_ij|`.
   - Symmetrize the edge set.
   - Set `k = clamp(k_min, k_max, f(beta1_estimate, N))`.
2) Build sparse adjacency `A` and graph Laplacian `L0 = D - A`.
3) Compute 8 eigenvectors associated with the smallest non-trivial eigenvalues of `L0`:
   - Stack them as rows of `W` (after normalization / orthonormalization).

Caching policy (explicit; do not “wing it”):
- Define a `Q_fingerprint`:
  - Preferred: stable `task_id`/`job_id` from `meta` if the subnet guarantees identical `Q` per id.
  - Otherwise: hash of the raw `float32` bytes (e.g., `xxh3_64(Q.tobytes())`) or a cheaper signature (top-|Q_ij| edges + weights).
- Cache entries store: `W`, `W⁺_λ`, and optionally `Q8` and the 240-root energy spectrum `E_i`.
- If `Q_fingerprint` matches, **reuse** and skip eigenvectors (this can save seconds per round).
- Use an LRU cap (e.g., 8–32 entries) to bound memory.

Recommended MVP defaults:
- `k_min = 32`, `k_max = 256`
- `f(beta1, N) = round(16 + 2*min(beta1, 64))` (tune)

Notes:
- This matches the “topological components” intent and keeps runtime feasible at `N≈5000`.
- The Quantum Scout controls `beta1_estimate`, which controls skeletonization and stability of `W`.

### 6.3 Reduced Energy Selection in E8 Space
Compute reduced matrix:
```
Q8 = W Q Wᵀ     # 8×8
```
For each root `r`:
```
E8(r) = rᵀ Q8 r
```
Select beam `B` roots with the lowest `E8(r)`.

### 6.4 Lift & Repair
For each candidate target direction `u ∈ R^8` (root or mixture):
1) Lift:
```
s_seed = W⁺ u      # N-dimensional real vector
```
2) Binarize/spinize:
- If internal domain is spins: `s0_i = +1 if s_seed_i >= 0 else -1`
- If internal domain is binary: `x0_i = 1 if s_seed_i >= 0 else 0`
3) Repair (greedy local search on original `Q`):
- Run until time slice exhausted or no improving flips.
- Always maintain best-so-far solution.

Repair must be **anytime**:
- If time remains: continue improving
- If close to deadline: stop and return current best

Implementation detail for speed:
- Maintain `g = Q s` (or `Q x`) and update `g` after each flip so each flip is `O(N)`, not `O(N²)`.
(See Appendix B.)

### 6.5 Why this can work (engineering framing)
The E8 root codebook provides a compact set of highly symmetric directions in 8D. The hypothesis is:
- The 8D embedding concentrates “energy landscape shape” into a small space.
- Snapping to E8 roots yields seeds that are closer to good minima than random initialization.

This is an empirical claim for MVP:
- We validate only by testnet score and golden-set energy distributions.

### 6.6 Adjoint-248 Mode (“Moon/Sun” Root Spectrum)
This mode keeps the same `W ∈ R^(8×N)` and `Roots_E8 ⊂ R^8`, but changes how we choose the target direction `u ∈ R^8`.

Engineering framing:
- **8D beam mode** picks *one* root at a time (`u = r_i`).
- **Adjoint-248 mode** treats the 240 roots as a “dictionary” and computes a **root energy spectrum** to synthesize `u` as a mixture of roots.
- We call it “Adjoint-248” because we operate with **248 coefficients** conceptually:
  - 8 Cartan coordinates (the 8D latent vector)
  - 240 root coefficients (one per E8 root; split into 112+128 “Moon/Sun” families)

#### 6.6.1 Root Energy Spectrum
Compute:
```
Q8 = W Q Wᵀ
E_i = r_iᵀ Q8 r_i     for i=1..240
```
Split roots into:
- **Moon = Type A (112 roots)**: permutations of `(±1, ±1, 0, 0, 0, 0, 0, 0)`
- **Sun = Type B (128 roots)**: `(±1/2, …, ±1/2)` with an even number of minus signs

#### 6.6.2 Softmin Weights (Top-k)
Convert energies to weights separately per family:
```
w_i = exp(-β_A * (E_i - min(E_Moon)))   for i in Moon
z_i = exp(-β_B * (E_i - min(E_Sun)))    for i in Sun
```
Then:
- Keep only the top-`kA` Moon weights and renormalize.
- Keep only the top-`kB` Sun weights and renormalize.

Recommended MVP defaults:
- `β_A = 1.0`, `β_B = 1.0` (tune)
- `kA = 16`, `kB = 16`

Temperature tuning (make it deterministic):
- If `β` is too large → weights collapse to ~one root (degenerates back to beam mode).
- If `β` is too small → weights become uniform (seed becomes “blurred”).
- Recommended auto-β rule per family:
  - Sort energies `E_(1) ≤ … ≤ E_(k)` for the chosen `k` (Moon: `kA`, Sun: `kB`).
  - Pick a target ratio `R` between best and kth weight (start `R=16`):
    ```
    β = ln(R) / max(E_(k) - E_(1), 1e-6)
    ```
  - Clamp: `β ∈ [0.1, 50]`.
- Log entropy of weights and tune offline (Appendix C already includes fields to extend).

#### 6.6.3 Build Target Directions (Moon-only, then Moon+Sun)
Compute:
```
u_moon = normalize( Σ_{i∈Moon} w_i * r_i )
u_sun  = normalize( Σ_{i∈Sun}  z_i * r_i )
u_mix  = normalize( (1-γ) * u_moon + γ * u_sun )
```
Defaults:
- `γ = 0.25` (start conservative; “Sun” is enabled only after gating)

Candidates to try in order:
1) `u = u_moon` (fast “Moon-only” attempt)
2) If gating triggers: `u = u_mix` (Moon+Sun attempt)
3) Optional safety: top `B` single roots (beam) if both mixtures underperform

#### 6.6.4 Gating Policy (Minimal, Deterministic)
We want a cheap rule to decide whether to “turn on Sun”.

MVP gating rule:
- Run Repair for `t_gate` seconds from the Moon seed.
- If improvement vs the initial seed energy is less than `Δ_gate`, enable Sun and try `u_mix`.

Defaults:
- `t_gate = 1.0s`
- `Δ_gate = 0.002 * |H(seed)|` (scale-free; tune per subnet)

#### 6.6.5 Lift With Ridge Pseudo-Inverse
Use ridge-stabilized `W⁺_λ`:
```
s_seed = W⁺_λ u
```
Then binarize/spinize and run Repair.

#### 6.6.6 Implementation Notes (Keep It Simple)
- You do **not** need to build any “true 248×N” matrix to implement this mode.
- Treat “Adjoint-248” as **a better target selector** that uses the full 240-root spectrum.
- For logging/debugging, record:
  - `min(E_Moon)`, `min(E_Sun)`
  - entropies of `w` and `z` (measure concentration)
  - gating decision (`sun_enabled`)

---

## 7. Quantum Scout (Engineering Specification)

### 7.1 Purpose
Return a **topological feature vector `F` fast**, under strict timeouts, robust to IBM API issues.

Minimum required output for MVP:
- `beta1_estimate` (float or int)
- `confidence` (0..1) or `source` (`quantum` | `cache` | `fallback`)

MVP default strategy (selected from Feb 2026 contract+latency check):
- **Online critical path:** classical Scout (graph cycle rank + cheap spectral stats) + cache.
- **Quantum/QPU:** optional/offline calibration only; online path is cache-first with strict timeout.

### 7.2 I/O Contract
Input:
- `Q` (dense `N×N`)
Output:
- `F = { beta1_estimate, ... }`

### 7.3 Algorithm Sketch (LGZ-like Rank/Laplacian Estimation)
We estimate `β₁` via the kernel dimension of the combinatorial 1-Laplacian `L1`:
- Construct a simplicial representation from `Q` (MVP: use skeleton graph and optional 2-simplices by threshold).
- Build boundary operators and `L1`.
- Encode `L1` as a Hermitian operator / Hamiltonian.
- Use Qiskit Runtime primitives to estimate spectral weight near zero.

Heat-trace estimator (conceptual):
```
beta1 ≈ Tr(exp(-τ L1))    for large τ
```

**MVP reality requirement:**
- The runtime program must return within `T_quantum=3s` or we fall back.
- If quantum execution cannot meet this, run the same estimator on a smaller sampled subcomplex (document the sampling).

MVP fallback (must be implemented regardless):
- If quantum is unavailable, estimate a graph-level cycle count on the skeleton:
  - For a graph (1-complex), `beta1_graph = m - n + c` (edges - nodes + connected components).
  - Use this only as a degraded signal for choosing `k` and stabilizing `W`.

### 7.4 Timeouts, Budgets, Fail-Safes
- Hard timeout: `T_quantum = 3.0s` (configurable).
- Budget: `≤ Q_calls_per_hour` (initial 10/h).
- Fail-safe: on timeout or non-2xx response:
  - Use cached `F_cache`
  - Mark attempt as `degraded_quantum=true`
  - If HTTP `429` / throttling: exponential backoff with jitter, but **never** past the deadline (race timeout wins).

### 7.5 Cache Keys
Cache `F` by coarse buckets:
- `N_bucket = round(N / 250) * 250`
- `density_bucket = round(density_eps / 0.05) * 0.05`
- `weight_stats_bucket` (optional)

---

## 8. External Solver (Optional Accelerator)

MVP allows one of these:
- **A)** No external solver: use only Lift & Repair (Section 6.4).
- **B)** External solver service (DA / cloud GPU) that accepts a QUBO and returns a candidate solution.

If using an external solver, define a stable interface:

### 8.1 API Contract (example)
Request:
```json
{
  "job_id": "string",
  "domain": "spin|binary",
  "Q": "packed matrix or URL",
  "time_limit_s": 20.0,
  "warm_start": "optional seed solution"
}
```

Response:
```json
{
  "solution": [0,1,0,...],
  "energy": -123.45,
  "solver_time_s": 18.7,
  "status": "ok|timeout|error"
}
```

### 8.2 Failure Policy
- If external solver fails/slow: immediately continue with local Lift & Repair using `s_seed`.

---

## 9. Testing & Validation (MVP, Minimal)

### 9.1 Golden Dataset (local)
Save ~20 real tasks from testnet to `tests/data/` as JSON (synapse snapshots).

Required local command:
- `run_pipeline --input tests/data/golden_01.json --deadline 45s`

Acceptance (local):
- Produces a correctly shaped solution.
- Computes energy without NaN/overflow.
- Runs under the deadline budget.

### 9.2 Testnet Run (the real proof)
Run miner on the target subnet testnet for `≥ 2h` (then `24h`).
Log and track:
- latency per stage
- final energy
- accepted vs rejected submissions
- score/incentive if available

---

## 10. Implementation Roadmap (Feb 2026)

### Week 1 — Skeleton
- Implement Ingest + Submit to testnet.
- Implement logging.
- Dummy solver produces valid-shaped random solutions (for protocol verification).

### Week 2 — Brain (Quantum + E8 core)
- Implement E8 roots generator + snapping.
- Implement W builder (skeleton graph + spectral embedding).
- Implement Quantum Scout call + strict timeout + cache.

### Week 3 — Lift & Repair
- Implement W⁺ + lifting + binarize/spinize.
- Implement greedy repair with `O(N)` flip deltas.
- Golden dataset pipeline.

### Week 4 — Tuning & Proving
- Tune time budgets, beam width `B`, skeleton `k`, thresholds.
- 24h testnet run and KPI evaluation.

---

## 11. Risks & Mitigations (MVP)

1) **IBM latency / quota** → strict timeout + cached features + degraded mode.
2) **Subnet protocol changes** → isolate synapse parsing and submission behind interfaces.
3) **Dense matrix performance** → enforce float32 + BLAS + memory budget checks.
4) **Projection error (W bad)** → beam width >1 + repair randomized restarts.
5) **Correlation gap (E8 reduced energy ≠ real energy)** → evaluate top-B roots + pick best after repair.

---

## 12. Reference Implementation Outline (Minimal, AI-Friendly)

Recommended Python module boundaries (names are suggestions; keep interfaces stable):
- `miner/ingest.py`: synapse parsing → `(Q, meta)`
- `miner/quantum_scout.py`: `Q` → `F` with timeout + cache + fallback
- `miner/w_builder.py`: `(Q, F)` → `W, W_plus`
- `miner/e8.py`: root generator + snapping + reduced energy ranking
- `miner/lift_repair.py`: lift, binarize/spinize, greedy repair, energy
- `miner/submit.py`: submit to subnet
- `miner/main.py`: sniper loop + budgets + logging

Minimal CLI commands for MVP:
- `miner run --subnet 4 --network testnet --wallet <name>`
- `miner replay --input tests/data/golden_01.json --deadline 45s`

---

## 13. Configuration (MVP)

### 13.1 Environment Variables
- `IBM_TOKEN` (if using Qiskit Runtime)
- `SOLVER_API_KEY` / `SOLVER_URL` (if using an external solver)
- `BT_WALLET_NAME` / `BT_WALLET_HOTKEY` (per Bittensor conventions; confirm)

### 13.2 Runtime Parameters (config file or CLI)
- Timeouts: `T_ingest`, `T_quantum`, `T_W`, `T_repair`, `T_submit`
- Beam width: `B`
- Skeletonization: `k_min`, `k_max`, `eps_density`
- Determinism: `RNG_SEED` (for repair restarts; default fixed)
- Caching:
  - `W_CACHE_MAX_ENTRIES` (LRU cap)
  - `CACHE_KEY_MODE = task_id | q_hash | signature`
- E8 quantization mode:
  - `E8_MODE = beam8 | adjoint248`
  - If `E8_MODE=adjoint248`: `BETA_A`, `BETA_B`, `K_MOON`, `K_SUN`, `GAMMA_SUN`, `T_GATE_S`, `DELTA_GATE`
  - Optional auto-beta: `AUTO_BETA=true|false`, `BETA_RATIO_R`, `BETA_MIN`, `BETA_MAX`
- Pseudo-inverse ridge: `RIDGE_LAMBDA`

---

## Appendix A — Deterministic Generator for 240 E8 Roots

**Type A (112 roots):**
- Choose 2 positions out of 8 for non-zero entries.
- Assign each of the two entries a sign `±1`.
- All permutations of positions and sign choices.

**Type B (128 roots):**
- All 8-tuples of `±1/2` with an even number of negative signs.

Implementation note:
- Return a stable ordering (lexicographic) for reproducibility.

---

## Appendix B — Greedy Repair: Fast ΔE Updates (Spin Form)

For spins `s ∈ {-1,+1}^N`, energy:
```
H = sᵀ Q s
```

Maintain `g = Q s` (vector length `N`).

Flipping spin `i` (`s_i := -s_i`) changes energy by:
```
ΔH_i = -4 * s_i * g_i + 4 * Q_ii
```
(Derive/confirm based on the exact diagonal convention used by the target subnet’s tasks; adjust once the dataset is verified.)

After flipping `i`, update:
```
g := g + (-2*s_i_old) * Q[:, i]
```
This makes each flip `O(N)`.

---

## Appendix C — Minimal Structured Log Schema (JSONL)

One line per **event** (JSONL). Events are “enveloped” so we can replay/debug without schema drift.

### C.1 Envelope (always present)
- `ts_ms` (number)
- `level` (`debug|info|warn|error`)
- `event` (stable key; no free text)
- `attempt_id`
- `task_id` (use `"unknown"` if not known yet)
- `span_id` (trace span; MVP can reuse `attempt_id`)
- `op` (current operation: `ingest|solve|validate_solution|submit|run_once|...`)
- `subnet` (`sn83|sn43|...`)
- optional: `version`, `service`, `host`
- `payload` (all non-standard fields live here; JSON-safe only, no NaN/Infinity)

Example event record:
```json
{
  "ts_ms": 1738800000123,
  "level": "info",
  "event": "attempt",
  "attempt_id": "8d2b7c5b-8f7e-4b5c-9a42-3b6e0b2a4b7a",
  "task_id": "task_123",
  "span_id": "8d2b7c5b-8f7e-4b5c-9a42-3b6e0b2a4b7a",
  "op": "run_once",
  "subnet": "sn83",
  "version": "0.1.0",
  "service": "e8miner",
  "host": "xmg",
  "payload": {
    "q_fingerprint": "sha256:...",
    "w_cache_hit": true,
    "N": 5000,
    "density_eps": 0.92,
    "degraded_quantum": false,
    "beta1": 37.0,
    "e8_mode": "beam8|moon_sun_softmin",
    "sun_enabled": false,
    "beta_A": 1.0,
    "beta_B": 1.0,
    "energy": -123.45,
    "timings_ms": { "ingest": 200.0, "solve": 2900.0, "repair": 23100.0, "submit": 1000.0, "total": 31200.0 },
    "submit_status": "ok|rejected|timeout|error"
  }
}
```

### C.2 Minimal event set (MVP)
- `attempt_started` (envelope + empty payload)
- `attempt` (attempt summary: timings, quality, solver mode, optional energy)
- `attempt_finished` (status)

---

## Appendix D — MUST-CHECK Items (Do Before Coding)

- Confirm the target subnet synapse schema and actual submission behavior in the current subnet repository.
- Confirm variable domain and diagonal conventions in energy computation.
- Confirm whether the validator expects energy or only a solution vector.
- Confirm IBM/Qiskit runtime latency and select an executable strategy that fits `T_quantum`.

---

## Appendix E — Viable Options in the Next 72 Hours (Minimal Spend)

Goal of this appendix: quickly falsify/confirm where the **E8 + (classical) topology + Lift&Repair** stack has leverage, without building a big platform yet.

### E.1 “Contract + Deadline” First (for any candidate subnet)
Before writing any solver integrations, do a 1-hour paper/grep check in the target subnet repo:
- What is the **hard timeout** (seconds)? Where is it enforced (validator vs synapse)?
- What is the task format (dense `Q`, sparse graph, route list, etc.) and the **scoring function**?
- Is there a published **benchmark/baseline** the validator uses?

Kill criteria (stop immediately):
- If the subnet rewards are dominated by **LLM/GPU inference** rather than optimization quality, skip.
- If deadlines are `≤ 2s` and tasks are large, skip (unless you have a deterministic constant-time trick).

### E.2 Option 1 — Bittensor “Optimization” Subnets (Primary target)
What to do in 1–2 days:
- Pick one optimization-style subnet (example from earlier research: Graphite-like VRP/TSP/QUBO tasks; confirm current number/version).
- Capture a small golden set of real tasks (`~20`) and run local replays.
- Compare four solvers under the subnet’s real timeout:
  1) greedy-from-random (baseline)
  2) beam-of-roots (`E8_MODE=beam8`)
  3) Moon/Sun spectrum (`E8_MODE=adjoint248`)
  4) best-effort external “hammer” (if available)
- If (2) or (3) beats baseline reliably *and* meets deadline, integrate as the miner’s solver backend.

Minimal code needed:
- `replay.py` (task JSON → solve → metrics JSONL)
- `solver.py` (your pipeline: build W → E8 → lift&repair)

#### E.2a Fastest “Incentive > 0” candidate today: SN43 Graphite (TSP / graph optimization)
Reality check (Feb 2026): Graphite (netuid=43) is one of the few clearly-described “pure optimization” markets with a public repo + validator scoring by solution quality.

Graphite is **not QUBO**, but we can still reuse the *core* idea (Laplacian eigenmaps + E8 directions) as a route-seeding heuristic:
- Build node embedding `Y ∈ R^(8×n)` via Laplacian eigenmaps on the task graph (same spirit as `W`).
- Choose an E8 direction `u ∈ R^8`:
  - `beam8`: evaluate all 240 roots against a reduced `Q8 = Y D Yᵀ` (with `D` = distance/cost matrix) and take best roots, or
  - `adjoint248`: Moon/Sun spectrum over roots, synthesize `u_moon` / `u_mix`.
- Convert `u` → a tour seed by sorting nodes by scalar projection `score_i = uᵀ Y[:, i]` (ties broken deterministically).
- Repair using cheap local TSP moves (2-opt / Or-opt) under the synapse timeout (Graphite schema default shows `timeout=12s`).

This gives a minimal, very “E8-flavored” MVP that can be validated against real validator scoring without needing QUBO at all.

#### E.2b QUBO-native optimization subnet to target next: SN83 CliqueAI (Maximum Clique)
CliqueAI (netuid=83) is an explicit combinatorial optimization market:
- Problem: maximum clique on a graph (NP-hard).
- Miner output: a set/list of vertices representing a clique.
- Validator scoring: emphasizes clique size (optimality) and also rewards diversity (non-identical solutions).

Why it is a great fit for your original E8/QUBO blueprint:
- Maximum clique has a standard QUBO formulation → we can reuse the full “E8 + Lift&Repair” pipeline almost 1:1.
- No need to “reinterpret” routing as QUBO; the objective is already a graph energy landscape.

MVP action:
- Clone and run their miner/validator locally, capture real synapses, then plug in the E8 solver backend.
- Use the subnet’s own time limit as `deadline` and keep the same JSONL logging schema.

### E.3 Option 2 — MVP “No Quantum QPU” (Recommended default)
Replace Quantum Scout with deterministic classical signals:
- `beta1_graph = m - n + c` on the skeleton graph
- optional: small spectral stats (e.g., near-zero Laplacian eigenvalues on the skeleton)

Why it’s good for fast validation:
- Zero external dependencies, no queue risk, fully reproducible.

### E.4 Option 3 — Digital Annealer / Quantum-inspired SaaS as the “Hammer”
Where DA fits in the pipeline:
- Best fit: **between** “Ingest” and “Lift&Repair” as an optional external candidate generator:
  - Send the same `Q` plus an optional warm start (`s_seed`).
  - Take the first decent solution returned, then locally Repair and submit.

How to validate quickly (minimal spend):
- Check the pricing model: **cost per solve** vs expected solves/day.
- Measure real wall-clock solve time (including queue/HTTP), not only solver-reported time.
- Set a hard cost cap for tests (e.g., `$20/day`) and stop if it can’t beat local + E8 within deadline.

### E.5 Option 4 — Fixstars Amplify Basic / SQBM+ (Free token) as a test harness
Use it as a cheap sanity check for the math:
- Feed small/medium QUBOs (downsampled `N` or block-decomposed).
- Compare their solution energies vs your Lift&Repair seeds.

Important:
- Treat it as **validation tooling**, not necessarily the final mining backend (rate/limits may be tight).

### E.6 Option 5 — D‑Wave Leap / other annealing trials (only if integration is fast)
If you can get a trial with enough credits:
- Use the hybrid solvers as an external hammer.
- Always keep local Repair as a fallback.

Cost/latency warning:
- The only number that matters for mining is **(energy improvement) / (wall-clock time)** under deadline.

### E.7 “Multi-cloud quantum race” (Defer)
Sending the same job to IBM/AWS/Google and taking the first answer is conceptually valid, but for MVP it’s usually the wrong trade:
- high integration effort
- quota complexity
- unpredictable queueing

If you still try it, implement as:
- fire-and-cancel race with strict global timeout
- cache-first policy
- no deadline overruns, ever

---

## Appendix F — Contract Reality Check (Feb 2026)

### F.1 SN4 (netuid=4) = Targon (Not QUBO)
SN4/Targon is a “Confidential Decentralized AI Cloud” subnet. The miner/validator contract is not QUBO-based:
- Miner exposes an HTTP axon endpoint `GET /cvm` that returns a JSON list of CVM nodes (`[{ "ip": "...", "price": 123 }, ...]`) and requires Epistula-signed headers.
- Validator queries that endpoint to discover nodes, then performs additional checks via attestation endpoints (e.g., `POST http://{cvm_ip}:8080/api/v1/evidence` with Epistula headers).
- Miner “submission” to chain is serving its axon via the `ServeAxon` extrinsic (HTTP protocol + configured port).

Implication:
- This blueprint’s QUBO pipeline (E8 quantization + Lift&Repair) does **not** apply to SN4/Targon without a different problem definition.

### F.2 Example Optimization Subnet (Graphite)
Graphite-style optimization subnets typically:
- Define a `bt.Synapse` with fields like `problem` and `solution`.
- Expect **solution only**; validator computes cost/score itself.
- Enforce a hard query timeout (example: schema default `timeout=12.0s` in `schema_v4.json`).

Implication:
- Before coding “E8/QUBO”, choose a subnet whose problem contract is actually QUBO (or straightforwardly reducible to QUBO under the deadline). Otherwise the energy/diagonal assumptions in Appendix B are not testable.

### F.3 SN25 (netuid=25) = Mainframe (formerly Protein Folding) (Not QUBO)
SN25/Mainframe is a decentralized science compute subnet. Its miner/validator contract is **not** “solve an optimization instance and return a vector”.

What the protocol actually looks like (from repo `macrocosm-os/folding`):
- `PingSynapse`: “can you serve + how much compute?” style handshake.
- `JobSubmissionSynapse`: validator sends a `pdb_id`, `job_id`, `presigned_url`; miner returns **molecular dynamics outputs** (`md_output`) + `miner_seed`/state.
- `IntermediateSubmissionSynapse`: submit intermediate checkpoints (checkpoint numbers → returned files).
- `OrganicSynapse`: additional param-set requests (for organic scoring).

Implication for E8/TDA solver:
- There is no QUBO matrix `Q` nor a binary solution vector to optimize for reward.
- The dominant axis is **throughput + correctness of scientific compute** (OpenMM MD / docking pipelines, file handling, reliability), not “one-shot global minimum”.
- So SN25 is not a good target for “E8 magic beats everyone on a laptop” as an MVP. Treat it as a different product (compute provider) that likely needs heavier compute and ops discipline.

Evidence:
- `E8miner/external/sn25_folding/folding/protocol.py`
- `E8miner/external/sn25_folding/README.md` (Mainframe description: OpenMM MD + DiffDock docking)

---

## Appendix G — Liquidity & Off‑Ramp Snapshot (Feb 2026)

**As-of:** 2026-02-06. These numbers move; re-check before relying on them.

### G.1 On-chain alpha↔TAO swap liquidity (GeckoTerminal “bittensor” network)
This is the most relevant “cashout” liquidity signal for subnet mining: it reflects how much depth exists to swap your earned subnet alpha into TAO.

| Netuid | Subnet | Pool | Reserve (USD) | 24h Volume (USD) | Notes |
|---:|---|---|---:|---:|---|
| 43 | Graphite | SN43 / TAO | 4,642,347.53 | 20,697.96 | Optimization (routing). Good depth for small/medium daily swaps. |
| 83 | CliqueAI | SN83 / TAO | 1,028,113.17 | 25,389.58 | Optimization (maximum clique). Lower depth than SN43; still workable for modest swaps. |
| 25 | Mainframe (formerly folding) | SN25 / TAO | 3,393,345.51 | 37,336.58 | Heavy-domain compute/optimization; contract not QUBO-like. |
| 10 | Swap (LP incentives) | SN10 / TAO | 5,027,739.94 | 1,155,687.70 | Not solver-driven; scoring depends on LP fees + capital. |
| 6 | Infinite Games | SN6 / TAO | 3,442,277.72 | 716,013.41 | Prediction-style contract; different success factors. |
| 8 | Trading (Vanta) | SN8 / TAO | 29,561,693.11 | 5,638,719.49 | Signals/trading contract; different success factors. |

Source: GeckoTerminal API `networks/bittensor/pools/{pool_id}` for `pool_id ∈ {0-43, 0-83, 0-25, 0-10, 0-6, 0-8}`.

### G.2 TAO off‑ramp liquidity proxy (CoinGecko)
If you can swap alpha → TAO on-chain, then TAO → USDT is typically a standard CEX trade.

CoinGecko “simple price” snapshot (2026-02-06):
- TAO price: **$159.35**
- TAO 24h volume: **$258.35M**

Source: CoinGecko API `simple/price?ids=bittensor&vs_currencies=usd&include_24hr_vol=true`.

### G.3 Practical cashout path (minimal ops)
1) Earn subnet alpha rewards on-chain.
2) Swap alpha → TAO using the subnet’s swap pool (monitor slippage; chunk swaps if needed).
3) Transfer TAO to a centralized exchange that supports TAO.
4) Sell TAO → USDT.

### G.4 Engineering implication for MVP
To keep “Incentive → USDT” testable in a week:
- Start with subnets that are **solver-driven** (SN43, SN83).
- Log every swap attempt in JSONL (amount in/out, implied slippage, pool snapshot, tx hash).
- Treat “liquidity” as a constraint: if your daily cashout is a large fraction of pool reserve, you will self-sandbag via slippage.

### G.5 Concrete sizing (what is “small/medium/too big”)
**These are heuristics** to make the MVP operational. Real slippage depends on concentrated liquidity/ticks, so always check the swap quote’s “price impact” and downsize if needed.

Rule of thumb (per swap chunk):
- `chunk_usd ≤ min(0.1% * reserve_usd, 5% * volume_24h_usd)`

Rule of thumb (per day total):
- `daily_usd ≤ 20% * volume_24h_usd` (above this you are a big part of the market; expect worse execution)

With the 2026-02-06 snapshot:
- **SN43 (reserve $4.64M, 24h vol $20.7k)**:
  - `chunk_usd ≤ min($4,642, $1,035) ≈ $1,000`
  - “Small” ≈ `$200–$1,000/day` (≲ 1–5% of daily volume)
  - “Too big” ≈ `>$4,000–$5,000/day` (≈ 20–25% of daily volume) unless volume rises materially
- **SN83 (reserve $1.03M, 24h vol $25.4k)**:
  - `chunk_usd ≤ min($1,028, $1,269) ≈ $1,000`
  - “Small” ≈ `$200–$1,000/day`
  - “Too big” ≈ `>$5,000/day`

Operational tactic:
- Prefer **TWAP-style cashout**: split into `5–20` chunks across the day.
- Log `quoted_out`, `executed_out`, and `price_impact` per chunk; auto-downsize chunks if price impact exceeds a threshold (e.g., `>1%`).

---

## Appendix H — Codebase Structure (Reuse 80% without overengineering)

Goal: a clean MVP where we can run **multiple subnets** with the same “E8 kernel”, and only swap thin adapters.

### H.1 Principle: Functional Core, Imperative Shell
- **Functional core**: pure functions (deterministic) for embedding, E8 root spectrum, quantization, lift, repair, scoring helpers.
- **Imperative shell**: I/O with Bittensor, caches, retries, timeouts, logging, config.

This gives:
- fast unit testing of the solver core (no chain required),
- easy adapter reuse,
- reproducibility (seeded randomness + versioned artifacts).

### H.2 “Ports & Adapters” (DDD‑ish, but lightweight)
Keep the domain vocabulary small and explicit:
- `Problem` (raw synapse payload + parsed canonical form)
- `Solution` (canonical) + `EncodedSolution` (subnet-specific wire format)
- `SolverBackend` interface: `solve(problem, deadline) -> Solution`
- `SubnetAdapter` interface: `ingest() -> Problem`, `submit(solution)`, `decode/encode`, `validate_local(solution)`

### H.3 Suggested repo layout (Python)
- `e8miner/core/` — E8 kernel + math + repair (pure-ish)
- `e8miner/adapters/sn43_graphite/` — ingest/submit + route encoding
- `e8miner/adapters/sn83_cliqueai/` — ingest/submit + clique encoding/QUBO mapping
- `e8miner/infra/` — JSONL logger, caches, retry/backoff, timing budgets
- `e8miner/app/` — runner/scheduler (choose subnet, choose backend, enforce deadlines)

### H.4 Don’t overdo “DDD”
We only need enough abstraction to:
- run SN43 and SN83 side-by-side,
- swap solver backends (local / Amplify / DA) later,
- keep the solver core testable.

Avoid:
- deep class hierarchies,
- “framework” code before incentive is proven,
- premature microservices.
