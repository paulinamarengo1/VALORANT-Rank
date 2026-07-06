# What Does High Elo Actually Do Differently?
### A data-driven analysis of 2,000+ VALORANT competitive matches across the entire rank ladder

I'm a Gold 1 Skye main. Instead of watching another "how to rank up" video, I built a data pipeline to answer the question analytically: **what are Immortal and Radiant players measurably doing that Iron-to-Gold players aren't?**

This project crawls VALORANT match data via the [HenrikDev API](https://docs.henrikdev.xyz/), stores it in SQL Server, and analyzes the differences between skill tiers.

---

## Dataset

| Metric | Value |
|---|---|
| Matches collected | 2,084 |
| Unique players | 11,074 |
| Player-match rows | 19,642 |
| Rank coverage | Iron 1 → Radiant |
| Region / platform | NA / PC competitive only |

Players are grouped into **Low Elo** (Iron–Platinum, primarily Iron/Bronze) and **High Elo** (Diamond–Radiant, primarily Immortal/Radiant), with my own Gold 1 account analyzed separately as an individual comparison point.

---

## Key Findings

### 1. Headshot % is the clearest mechanical gradient in the game

| Rank | HS% |
|---|---|
| Iron | 13.2% |
| Bronze | 16.4% |
| Silver | 20.0% |
| Gold | 23.3% |
| Ascendant | 31.7% |
| Immortal | 31.0% |
| Radiant | 29.6% |

High elo players land headshots **nearly twice as often** as low elo players (30.4% vs 17.3%). Interestingly, low elo players aren't missing more, they're hitting body instead of head. The gap is crosshair placement, not raw accuracy. HS% also slightly *declines* from Ascendant to Radiant, suggesting that at the very top, aim stops being the differentiator, everyone has it, and game sense takes over.

### 2. High elo players adapt agent picks to the map. Low elo players don't.

Sova appears in the high elo top 3 on every long-sightline map (Ascent, Breeze, Haven) — and is completely absent from low elo's top 3 on every map. Low elo's top picks are nearly identical on every single map: Reyna, Jett, Sage, regardless of what the map rewards.

### 3. High-skill-ceiling agents only work at high elo

| Agent | High Elo WR | Low Elo WR | Gap |
|---|---|---|---|
| Omen | 53.3% | 35.2% | **-18.1** |
| Raze | 61.0% | 45.2% | -15.8 |
| Phoenix | 55.3% | 44.8% | -10.5 |

Agents requiring lineups, map knowledge, or mechanical mastery collapse at low elo. Meanwhile simple-kit agents (Sage, Iso) perform nearly identically across both tiers. Reyna and Jett, equally popular at both tiers, actually post *losing* records in low elo (48.3% / 48.5%), despite the community perception that they're low elo stompers.

### 4. Agent flexibility is a high elo phenomenon

**18% of high elo players play 7+ different agents. Only 1.6% of low elo players do.** More than half of low elo players work with a pool of 3 or fewer agents. One-tricking *rates* are similar between tiers (~42-47% of games on a main). The difference is pool depth.

### 5. KDA barely differs between tiers — and predicts wins identically

High elo: 1.06 KD. Low elo: 0.96 KD. Nearly identical. Winners at both tiers post ~1.2 KD and losers ~0.85 — the relationship between individual performance and winning is constant across the entire ladder. What differs is *how* kills happen (headshots), not how many.

### Where I sit (Gold 1, Skye main)

| Stat | Me | Low Elo Avg | High Elo Avg |
|---|---|---|---|
| HS% | 19.9% | 17.7% | 30.4% |
| Avg kills | 11.8 | 14.7 | 16.9 |
| Avg assists | **7.9** | 5.3 | 5.3 |

My HS% sits exactly where the gradient predicts for Gold. My assists run 50% above both tier averages (Skye main things). The data's verdict: my path to climbing isn't playing more aggressively, it's closing the headshot gap.

### What the data can't measure

Positioning, crosshair placement habits, utility timing, and communication are invisible to match-level APIs — yet the headshot gradient is downstream of exactly those skills. This analysis can measure the *outcomes* of game sense, but not game sense itself. Knowing where the data ends is part of the analysis.

---

## Architecture

```
HenrikDev API ──> Python BFS crawler ──> SQL Server ──> Power BI
                  (snowball sampling)     (3 tables)     dashboard
```

**Data collection** uses breadth-first snowball sampling: seed accounts → pull recent competitive matches → extract all 10 players per match → queue unseen players → repeat. Because competitive matchmaking is MMR-banded, rank-diverse data requires rank-diverse seeds — the high elo crawl seeds from the official leaderboard, while the low elo crawl seeds from accounts in specific rank neighborhoods.

**Storage** is three tables: `players` (puuid, name, rank snapshot), `match_metadata` (per-player per-match stats, PK on match_id + puuid), and `match_raw` (full JSON payloads — so re-parsing never requires re-calling the API).

**Pipeline features:**
- Three-layer deduplication (in-memory sets + `IF NOT EXISTS` SQL guards)
- Rate limit handling with automatic backoff (Henrik free tier: 30 req/min)
- Platform filtering (PC-only, excludes console crossplay data)
- MMR backfill script for players whose rank lookup initially failed
- Null-safe API response parsing

## Repository structure

```
├── collect_data.py           # v1: leaderboard-seeded, single-player-per-match
├── collect_data_gold.py      # v2: BFS snowball crawler, configurable seeds
├── collect_data_highelo.py   # leaderboard-seeded high elo crawler
├── collect_my_matches.py     # paged pull of my own match history
├── backfill_mmr.py           # retries rank lookup for Unknown players
├── Valorant_Analysis_Queries.sql             # analysis queries
├── config.example.py         # API key template (copy to config.py)
└── README.md
```


## Tech stack

**Python** (requests, pyodbc) · **SQL Server** (window functions, CTEs, PERCENTILE_CONT) · **Power BI** (DAX, conditional formatting) · **HenrikDev API**

## Limitations & honest caveats

- **Sampling bias:** snowball sampling captures connected player neighborhoods, not a random population sample. Agent preferences may partially reflect cluster effects.
- **Sample sizes:** 311 high elo / 291 low elo ranked players. Aggregate stats (HS%, pick rates) are built on tens of thousands of rows and are stable; per-agent-per-map win rates run thin (15-30 picks) and are treated as directional.
- **The middle is missing:** the ladder's middle (Gold-Diamond) is underrepresented — the comparison is deliberately top-vs-bottom.
- **Private profiles** can't be rank-resolved and are excluded from tier analysis.
