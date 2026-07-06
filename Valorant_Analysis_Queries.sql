
-- VALORANT: HIGH ELO vs LOW ELO ANALYSIS QUERIES

-- ELO TIER DEFINITION:
--   Low Elo  = Iron, Bronze, Silver, Gold, Platinum
--   High Elo = Diamond, Ascendant, Immortal, Radiant
--
-- queries use a shared CTE (elo_tagged) that joins
-- match_metadata to players and buckets rank into two tiers.
-- Swap in your own puuid where marked for personal comparisons.


-- 1. DATASET OVERVIEW
SELECT
    COUNT(DISTINCT mm.match_id)                          AS total_matches,
    COUNT(DISTINCT mm.puuid)                             AS total_players,
    COUNT(*)                                             AS total_player_match_rows,
    SUM(CASE WHEN p.rank_tier LIKE 'Iron%'
              OR p.rank_tier LIKE 'Bronze%'
              OR p.rank_tier LIKE 'Silver%'
              OR p.rank_tier LIKE 'Gold%'
              OR p.rank_tier LIKE 'Platinum%'
             THEN 1 ELSE 0 END)                         AS low_elo_rows,
    SUM(CASE WHEN p.rank_tier LIKE 'Diamond%'
              OR p.rank_tier LIKE 'Ascendant%'
              OR p.rank_tier LIKE 'Immortal%'
              OR p.rank_tier LIKE 'Radiant%'
             THEN 1 ELSE 0 END)                         AS high_elo_rows,
    SUM(CASE WHEN p.rank_tier = 'Unknown' -- private profiles
              OR p.rank_tier IS NULL
             THEN 1 ELSE 0 END)                         AS unknown_rank_rows
FROM match_metadata mm
LEFT JOIN players p ON mm.puuid = p.puuid;


-- 2. RANK TIER DISTRIBUTION
--    How many players do we have at each rank sub-tier?

SELECT
    COALESCE(p.rank_tier, 'Unknown')    AS rank_tier,
    COUNT(DISTINCT mm.puuid)            AS unique_players,
    COUNT(*)                            AS total_match_rows
FROM match_metadata mm
LEFT JOIN players p ON mm.puuid = p.puuid
GROUP BY p.rank_tier
ORDER BY
    CASE
        WHEN p.rank_tier LIKE 'Iron%'       THEN 1
        WHEN p.rank_tier LIKE 'Bronze%'     THEN 2
        WHEN p.rank_tier LIKE 'Silver%'     THEN 3
        WHEN p.rank_tier LIKE 'Gold%'       THEN 4
        WHEN p.rank_tier LIKE 'Platinum%'   THEN 5
        WHEN p.rank_tier LIKE 'Diamond%'    THEN 6
        WHEN p.rank_tier LIKE 'Ascendant%'  THEN 7
        WHEN p.rank_tier LIKE 'Immortal%'   THEN 8
        WHEN p.rank_tier LIKE 'Radiant%'    THEN 9
        ELSE 10
    END;


-- 3. AGENT PICK RATES BY ELO TIER
--    Which agents are most popular in low vs high elo?
--    Includes pick rate % within each tier so you can compare
--    even if the sample sizes are different.
WITH elo_tagged AS (
    SELECT
        mm.agent_name,
        CASE
            WHEN p.rank_tier LIKE 'Diamond%'
              OR p.rank_tier LIKE 'Ascendant%'
              OR p.rank_tier LIKE 'Immortal%'
              OR p.rank_tier LIKE 'Radiant%'
            THEN 'High Elo'
            ELSE 'Low Elo'
        END AS elo_tier
    FROM match_metadata mm
    JOIN players p ON mm.puuid = p.puuid
    WHERE p.rank_tier IS NOT NULL
      AND p.rank_tier != 'Unknown'
      AND p.rank_tier != 'Unrated'
      AND mm.agent_name IS NOT NULL
      AND mm.agent_name != ''
),
tier_totals AS (
    SELECT elo_tier, COUNT(*) AS tier_total
    FROM elo_tagged
    GROUP BY elo_tier
),
ranked AS (
    SELECT
        e.agent_name,
        e.elo_tier,
        COUNT(*)                                            AS picks,
        ROUND(COUNT(*) * 100.0 / t.tier_total, 2)          AS pick_rate_pct,
        RANK() OVER (
            PARTITION BY e.elo_tier
            ORDER BY COUNT(*) DESC
        )                                                   AS rank_within_tier
    FROM elo_tagged e
    JOIN tier_totals t ON e.elo_tier = t.elo_tier
    GROUP BY e.agent_name, e.elo_tier, t.tier_total
)
SELECT
    rank_within_tier    AS rank,
    agent_name,
    elo_tier,
    picks,
    pick_rate_pct
FROM ranked
ORDER BY elo_tier, rank_within_tier;


-- 4. ONE-TRICKING: DO PLAYERS SPAM THE SAME AGENT?
--    For each player, what % of their matches use their
--    most-played agent? High % = one-trick tendency.
--    Grouped by elo tier to compare habits.

WITH player_agent_counts AS (
    SELECT
        mm.puuid,
        mm.agent_name,
        COUNT(*)    AS agent_matches
    FROM match_metadata mm
    WHERE mm.agent_name IS NOT NULL AND mm.agent_name != ''
    GROUP BY mm.puuid, mm.agent_name
),
player_totals AS (
    SELECT puuid, SUM(agent_matches) AS total_matches
    FROM player_agent_counts
    GROUP BY puuid
),
player_top_agent AS (
    SELECT
        pac.puuid,
        pac.agent_name                                                  AS top_agent,
        pac.agent_matches,
        pt.total_matches,
        ROUND(pac.agent_matches * 100.0 / pt.total_matches, 1)         AS top_agent_pct,
        RANK() OVER (PARTITION BY pac.puuid ORDER BY pac.agent_matches DESC) AS rnk
    FROM player_agent_counts pac
    JOIN player_totals pt ON pac.puuid = pt.puuid
)
SELECT
    CASE
        WHEN p.rank_tier LIKE 'Diamond%'
          OR p.rank_tier LIKE 'Ascendant%'
          OR p.rank_tier LIKE 'Immortal%'
          OR p.rank_tier LIKE 'Radiant%'
        THEN 'High Elo'
        ELSE 'Low Elo'
    END                                     AS elo_tier,
    ROUND(AVG(pta.top_agent_pct), 1)        AS avg_top_agent_pct,   -- higher = more one-tricky
    ROUND(MIN(pta.top_agent_pct), 1)        AS min_top_agent_pct,
    ROUND(MAX(pta.top_agent_pct), 1)        AS max_top_agent_pct,
    COUNT(DISTINCT pta.puuid)               AS player_count
FROM player_top_agent pta
JOIN players p ON pta.puuid = p.puuid
WHERE pta.rnk = 1
  AND p.rank_tier IS NOT NULL
  AND p.rank_tier != 'Unknown'
GROUP BY
    CASE
        WHEN p.rank_tier LIKE 'Diamond%'
          OR p.rank_tier LIKE 'Ascendant%'
          OR p.rank_tier LIKE 'Immortal%'
          OR p.rank_tier LIKE 'Radiant%'
        THEN 'High Elo'
        ELSE 'Low Elo'
    END;


-- 5. AGENT DIVERSITY: HOW MANY UNIQUE AGENTS PER PLAYER?
WITH agent_pools AS (
    SELECT
        mm.puuid,
        COUNT(DISTINCT mm.agent_name) AS unique_agents_played
    FROM match_metadata mm
    WHERE mm.agent_name IS NOT NULL AND mm.agent_name != ''
    GROUP BY mm.puuid
),
elo_tagged AS (
    SELECT
        ap.puuid,
        ap.unique_agents_played,
        CASE
            WHEN p.rank_tier LIKE 'Diamond%'
              OR p.rank_tier LIKE 'Ascendant%'
              OR p.rank_tier LIKE 'Immortal%'
              OR p.rank_tier LIKE 'Radiant%'
            THEN 'High Elo'
            ELSE 'Low Elo'
        END AS elo_tier
    FROM agent_pools ap
    JOIN players p ON ap.puuid = p.puuid
    WHERE p.rank_tier IS NOT NULL
      AND p.rank_tier != 'Unknown'
      AND p.rank_tier != 'Unrated'
),
percentiles AS (
    SELECT DISTINCT
        elo_tier,
        PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY unique_agents_played)
            OVER (PARTITION BY elo_tier) AS median_pool_size,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY unique_agents_played)
            OVER (PARTITION BY elo_tier) AS p25_pool_size,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY unique_agents_played)
            OVER (PARTITION BY elo_tier) AS p75_pool_size
    FROM elo_tagged
)
SELECT
    e.elo_tier,
    COUNT(DISTINCT e.puuid)                                         AS player_count,
    ROUND(AVG(CAST(e.unique_agents_played AS FLOAT)), 2)            AS avg_pool_size,
    pr.median_pool_size,
    pr.p25_pool_size,
    pr.p75_pool_size,
    ROUND(SUM(CASE WHEN e.unique_agents_played = 1 THEN 1.0 ELSE 0 END)
        / COUNT(DISTINCT e.puuid) * 100, 1)                         AS pct_only_1_agent,
    ROUND(SUM(CASE WHEN e.unique_agents_played BETWEEN 2 AND 3 THEN 1.0 ELSE 0 END)
        / COUNT(DISTINCT e.puuid) * 100, 1)                         AS pct_agents_2_to_3,
    ROUND(SUM(CASE WHEN e.unique_agents_played BETWEEN 4 AND 6 THEN 1.0 ELSE 0 END)
        / COUNT(DISTINCT e.puuid) * 100, 1)                         AS pct_agents_4_to_6,
    ROUND(SUM(CASE WHEN e.unique_agents_played >= 7 THEN 1.0 ELSE 0 END)
        / COUNT(DISTINCT e.puuid) * 100, 1)                         AS pct_agents_7_plus
FROM elo_tagged e
JOIN percentiles pr ON e.elo_tier = pr.elo_tier
GROUP BY e.elo_tier, pr.median_pool_size, pr.p25_pool_size, pr.p75_pool_size;



-- 6. HEADSHOT / BODYSHOT / LEGSHOT % BY ELO TIER
--    Core mechanical skill signal. High elo should show
--    higher HS%, lower leg%.
--    Note: shots = headshots + bodyshots + legshots (total).

SELECT
    CASE
        WHEN p.rank_tier LIKE 'Diamond%'
          OR p.rank_tier LIKE 'Ascendant%'
          OR p.rank_tier LIKE 'Immortal%'
          OR p.rank_tier LIKE 'Radiant%'
        THEN 'High Elo'
        ELSE 'Low Elo'
    END                                                         AS elo_tier,
    SUM(mm.headshots)                                           AS total_headshots,
    SUM(mm.bodyshots)                                           AS total_bodyshots,
    SUM(mm.legshots)                                            AS total_legshots,
    SUM(mm.headshots + mm.bodyshots + mm.legshots)              AS total_shots,
    ROUND(
        SUM(mm.headshots) * 100.0
        / NULLIF(SUM(mm.headshots + mm.bodyshots + mm.legshots), 0),
    2)                                                          AS hs_pct,
    ROUND(
        SUM(mm.bodyshots) * 100.0
        / NULLIF(SUM(mm.headshots + mm.bodyshots + mm.legshots), 0),
    2)                                                          AS body_pct,
    ROUND(
        SUM(mm.legshots) * 100.0
        / NULLIF(SUM(mm.headshots + mm.bodyshots + mm.legshots), 0),
    2)                                                          AS leg_pct,
    COUNT(DISTINCT mm.puuid)                                    AS player_count
FROM match_metadata mm
JOIN players p ON mm.puuid = p.puuid
WHERE p.rank_tier IS NOT NULL
  AND p.rank_tier != 'Unknown'
  AND (mm.headshots + mm.bodyshots + mm.legshots) > 0
GROUP BY
    CASE
        WHEN p.rank_tier LIKE 'Diamond%'
          OR p.rank_tier LIKE 'Ascendant%'
          OR p.rank_tier LIKE 'Immortal%'
          OR p.rank_tier LIKE 'Radiant%'
        THEN 'High Elo'
        ELSE 'Low Elo'
    END;


-- 7. HS% BROKEN DOWN BY INDIVIDUAL RANK TIER
--    More granular than query 6 — shows the full gradient.
SELECT
    CASE
        WHEN p.rank_tier LIKE 'Iron%'       THEN 'Iron'
        WHEN p.rank_tier LIKE 'Bronze%'     THEN 'Bronze'
        WHEN p.rank_tier LIKE 'Silver%'     THEN 'Silver'
        WHEN p.rank_tier LIKE 'Gold%'       THEN 'Gold'
        WHEN p.rank_tier LIKE 'Platinum%'   THEN 'Platinum'
        WHEN p.rank_tier LIKE 'Diamond%'    THEN 'Diamond'
        WHEN p.rank_tier LIKE 'Ascendant%'  THEN 'Ascendant'
        WHEN p.rank_tier LIKE 'Immortal%'   THEN 'Immortal'
        WHEN p.rank_tier LIKE 'Radiant%'    THEN 'Radiant'
    END                                     AS rank_group,
    ROUND(
        SUM(mm.headshots) * 100.0
        / NULLIF(SUM(mm.headshots + mm.bodyshots + mm.legshots), 0),
    2)                                      AS hs_pct,
    ROUND(
        SUM(mm.legshots) * 100.0
        / NULLIF(SUM(mm.headshots + mm.bodyshots + mm.legshots), 0),
    2)                                      AS leg_pct,
    COUNT(DISTINCT mm.puuid)                AS player_count,
    COUNT(*)                                AS match_rows
FROM match_metadata mm
JOIN players p ON mm.puuid = p.puuid
WHERE p.rank_tier IS NOT NULL
  AND p.rank_tier != 'Unknown'
  AND p.rank_tier != 'Unrated'
  AND (mm.headshots + mm.bodyshots + mm.legshots) > 0
GROUP BY
    CASE
        WHEN p.rank_tier LIKE 'Iron%'       THEN 'Iron'
        WHEN p.rank_tier LIKE 'Bronze%'     THEN 'Bronze'
        WHEN p.rank_tier LIKE 'Silver%'     THEN 'Silver'
        WHEN p.rank_tier LIKE 'Gold%'       THEN 'Gold'
        WHEN p.rank_tier LIKE 'Platinum%'   THEN 'Platinum'
        WHEN p.rank_tier LIKE 'Diamond%'    THEN 'Diamond'
        WHEN p.rank_tier LIKE 'Ascendant%'  THEN 'Ascendant'
        WHEN p.rank_tier LIKE 'Immortal%'   THEN 'Immortal'
        WHEN p.rank_tier LIKE 'Radiant%'    THEN 'Radiant'
    END
HAVING COUNT(DISTINCT mm.puuid) >= 10
ORDER BY
    CASE
        WHEN MAX(p.rank_tier) LIKE 'Iron%'       THEN 1
        WHEN MAX(p.rank_tier) LIKE 'Bronze%'     THEN 2
        WHEN MAX(p.rank_tier) LIKE 'Silver%'     THEN 3
        WHEN MAX(p.rank_tier) LIKE 'Gold%'       THEN 4
        WHEN MAX(p.rank_tier) LIKE 'Platinum%'   THEN 5
        WHEN MAX(p.rank_tier) LIKE 'Diamond%'    THEN 6
        WHEN MAX(p.rank_tier) LIKE 'Ascendant%'  THEN 7
        WHEN MAX(p.rank_tier) LIKE 'Immortal%'   THEN 8
        WHEN MAX(p.rank_tier) LIKE 'Radiant%'    THEN 9
    END;


-- 10. KDA STATS BY ELO TIER
--     Average kills, deaths, assists, and KDA ratio.
--     Also avg KD (kills/deaths) since assists are less reliable.

SELECT
    CASE
        WHEN p.rank_tier LIKE 'Diamond%'
          OR p.rank_tier LIKE 'Ascendant%'
          OR p.rank_tier LIKE 'Immortal%'
          OR p.rank_tier LIKE 'Radiant%'
        THEN 'High Elo'
        ELSE 'Low Elo'
    END                                                                 AS elo_tier,
    ROUND(AVG(CAST(mm.kills AS FLOAT)), 2)                             AS avg_kills,
    ROUND(AVG(CAST(mm.deaths AS FLOAT)), 2)                            AS avg_deaths,
    ROUND(AVG(CAST(mm.assists AS FLOAT)), 2)                           AS avg_assists,
    ROUND(
        AVG(CAST(mm.kills AS FLOAT))
        / NULLIF(AVG(CAST(mm.deaths AS FLOAT)), 0),
    2)                                                                  AS avg_kd_ratio,
    ROUND(
        AVG(
            (mm.kills + mm.assists * 0.5) 
            / NULLIF(CAST(mm.deaths AS FLOAT), 0)  -- fixed: NULLIF 0 not 0.5
        ),
    2)                                                                  AS avg_kda_ratio,
    COUNT(DISTINCT mm.puuid)                                            AS player_count
FROM match_metadata mm
JOIN players p ON mm.puuid = p.puuid
WHERE p.rank_tier IS NOT NULL
  AND p.rank_tier != 'Unknown'
  AND p.rank_tier != 'Unrated'
  AND mm.deaths > 0  -- also just exclude 0-death rows entirely, they're edge cases
GROUP BY
    CASE
        WHEN p.rank_tier LIKE 'Diamond%'
          OR p.rank_tier LIKE 'Ascendant%'
          OR p.rank_tier LIKE 'Immortal%'
          OR p.rank_tier LIKE 'Radiant%'
        THEN 'High Elo'
        ELSE 'Low Elo'
    END;

-- ============================================================
-- 11. DOES KDA ACTUALLY CORRELATE WITH WINNING?
--     Does the K/D/A -> win relationship differ by elo tier?
--     Splits won vs lost matches and compares avg stats.
-- ============================================================
SELECT
    CASE
        WHEN p.rank_tier LIKE 'Diamond%'
          OR p.rank_tier LIKE 'Ascendant%'
          OR p.rank_tier LIKE 'Immortal%'
          OR p.rank_tier LIKE 'Radiant%'
        THEN 'High Elo'
        ELSE 'Low Elo'
    END                                             AS elo_tier,
    mm.won,
    ROUND(AVG(CAST(mm.kills AS FLOAT)), 2)          AS avg_kills,
    ROUND(AVG(CAST(mm.deaths AS FLOAT)), 2)         AS avg_deaths,
    ROUND(AVG(CAST(mm.assists AS FLOAT)), 2)        AS avg_assists,
    ROUND(
        AVG(CAST(mm.kills AS FLOAT))
        / NULLIF(AVG(CAST(mm.deaths AS FLOAT)), 0),
    2)                                              AS avg_kd_ratio,
    COUNT(*)                                        AS match_count
FROM match_metadata mm
JOIN players p ON mm.puuid = p.puuid
WHERE p.rank_tier IS NOT NULL
  AND p.rank_tier != 'Unknown'
GROUP BY
    CASE
        WHEN p.rank_tier LIKE 'Diamond%'
          OR p.rank_tier LIKE 'Ascendant%'
          OR p.rank_tier LIKE 'Immortal%'
          OR p.rank_tier LIKE 'Radiant%'
        THEN 'High Elo'
        ELSE 'Low Elo'
    END,
    mm.won
ORDER BY elo_tier, mm.won DESC;


-- 12. WIN RATE BY AGENT AND ELO TIER
--     Which agents win more often? Does it differ by elo?

WITH agent_winrates AS (
    SELECT
        mm.agent_name,
        CASE
            WHEN p.rank_tier LIKE 'Diamond%'
              OR p.rank_tier LIKE 'Ascendant%'
              OR p.rank_tier LIKE 'Immortal%'
              OR p.rank_tier LIKE 'Radiant%'
            THEN 'High Elo'
            ELSE 'Low Elo'
        END                                                         AS elo_tier,
        COUNT(*)                                                    AS total_picks,
        SUM(CAST(mm.won AS INT))                                    AS wins,
        ROUND(SUM(CAST(mm.won AS INT)) * 100.0 / COUNT(*), 2)      AS win_rate_pct
    FROM match_metadata mm
    JOIN players p ON mm.puuid = p.puuid
    WHERE p.rank_tier IS NOT NULL
      AND p.rank_tier != 'Unknown'
      AND p.rank_tier != 'Unrated'
      AND mm.agent_name IS NOT NULL
      AND mm.agent_name != ''
    GROUP BY
        mm.agent_name,
        CASE
            WHEN p.rank_tier LIKE 'Diamond%'
              OR p.rank_tier LIKE 'Ascendant%'
              OR p.rank_tier LIKE 'Immortal%'
              OR p.rank_tier LIKE 'Radiant%'
            THEN 'High Elo'
            ELSE 'Low Elo'
        END
    HAVING COUNT(*) >= 10
)
SELECT
    RANK() OVER (PARTITION BY elo_tier ORDER BY win_rate_pct DESC) AS rank,
    agent_name,
    elo_tier,
    total_picks,
    wins,
    win_rate_pct
FROM agent_winrates
ORDER BY elo_tier, rank;


-- 13. AGENT PICK RATES PER MAP — does agent selection
--     change based on map? Broken out by elo tier.

WITH map_agent_picks AS (
    SELECT
        mm.map_name,
        mm.agent_name,
        CASE
            WHEN p.rank_tier LIKE 'Diamond%'
              OR p.rank_tier LIKE 'Ascendant%'
              OR p.rank_tier LIKE 'Immortal%'
              OR p.rank_tier LIKE 'Radiant%'
            THEN 'High Elo'
            ELSE 'Low Elo'
        END                                     AS elo_tier,
        COUNT(*)                                AS picks
    FROM match_metadata mm
    JOIN players p ON mm.puuid = p.puuid
    WHERE p.rank_tier IS NOT NULL
      AND p.rank_tier != 'Unknown'
      AND p.rank_tier != 'Unrated'
      AND mm.map_name IS NOT NULL AND mm.map_name != ''
      AND mm.agent_name IS NOT NULL AND mm.agent_name != ''
    GROUP BY
        mm.map_name,
        mm.agent_name,
        CASE
            WHEN p.rank_tier LIKE 'Diamond%'
              OR p.rank_tier LIKE 'Ascendant%'
              OR p.rank_tier LIKE 'Immortal%'
              OR p.rank_tier LIKE 'Radiant%'
            THEN 'High Elo'
            ELSE 'Low Elo'
        END
),
map_tier_totals AS (
    SELECT
        map_name,
        elo_tier,
        SUM(picks) AS tier_map_total
    FROM map_agent_picks
    GROUP BY map_name, elo_tier
),
ranked AS (
    SELECT
        m.map_name,
        m.agent_name,
        m.elo_tier,
        m.picks,
        ROUND(m.picks * 100.0 / t.tier_map_total, 1)   AS pick_rate_pct,
        RANK() OVER (
            PARTITION BY m.map_name, m.elo_tier
            ORDER BY m.picks DESC
        )                                               AS rank
    FROM map_agent_picks m
    JOIN map_tier_totals t 
        ON m.map_name = t.map_name 
        AND m.elo_tier = t.elo_tier
)
SELECT
    rank,
    map_name,
    agent_name,
    elo_tier,
    picks,
    pick_rate_pct
FROM ranked
WHERE rank <= 3
ORDER BY map_name, elo_tier, rank;



-- 14. WIN RATE BY AGENT AND MAP (combined)
--     Best agent to play on each map — does high elo know
--     better map-agent combos than low elo?

WITH agent_map_winrates AS (
    SELECT
        mm.map_name,
        mm.agent_name,
        CASE
            WHEN p.rank_tier LIKE 'Diamond%'
              OR p.rank_tier LIKE 'Ascendant%'
              OR p.rank_tier LIKE 'Immortal%'
              OR p.rank_tier LIKE 'Radiant%'
            THEN 'High Elo'
            ELSE 'Low Elo'
        END                                                         AS elo_tier,
        COUNT(*)                                                    AS total_picks,
        SUM(CAST(mm.won AS INT))                                    AS wins,
        ROUND(SUM(CAST(mm.won AS INT)) * 100.0 / COUNT(*), 2)      AS win_rate_pct
    FROM match_metadata mm
    JOIN players p ON mm.puuid = p.puuid
    WHERE p.rank_tier IS NOT NULL
      AND p.rank_tier != 'Unknown'
      AND p.rank_tier != 'Unrated'
      AND mm.map_name IS NOT NULL AND mm.map_name != ''
      AND mm.agent_name IS NOT NULL AND mm.agent_name != ''
    GROUP BY
        mm.map_name,
        mm.agent_name,
        CASE
            WHEN p.rank_tier LIKE 'Diamond%'
              OR p.rank_tier LIKE 'Ascendant%'
              OR p.rank_tier LIKE 'Immortal%'
              OR p.rank_tier LIKE 'Radiant%'
            THEN 'High Elo'
            ELSE 'Low Elo'
        END
    HAVING COUNT(*) >= 15
),
ranked AS (
    SELECT
        map_name,
        agent_name,
        elo_tier,
        total_picks,
        wins,
        win_rate_pct,
        RANK() OVER (
            PARTITION BY map_name, elo_tier
            ORDER BY win_rate_pct DESC
        )                                                           AS rank
    FROM agent_map_winrates
)
SELECT
    rank,
    map_name,
    agent_name,
    elo_tier,
    total_picks,
    wins,
    win_rate_pct
FROM ranked
WHERE rank <= 3
ORDER BY map_name, elo_tier, rank;



-- ── YOUR PERSONAL STATS (swap puuid for yours) ─────────────
-- To find your puuid: SELECT puuid FROM players WHERE game_name = 'Disciple bolita'
SELECT
    p.game_name,
    p.tag_line,
    p.rank_tier,
    COUNT(*)                                                    AS matches_in_sample,
    ROUND(AVG(CAST(mm.kills AS FLOAT)), 2)                     AS avg_kills,
    ROUND(AVG(CAST(mm.deaths AS FLOAT)), 2)                    AS avg_deaths,
    ROUND(AVG(CAST(mm.assists AS FLOAT)), 2)                   AS avg_assists,
    ROUND(
        SUM(mm.headshots) * 100.0
        / NULLIF(SUM(mm.headshots + mm.bodyshots + mm.legshots), 0),
    2)                                                          AS hs_pct,
    ROUND(SUM(CAST(mm.won AS INT)) * 100.0 / COUNT(*), 2)      AS win_rate_pct
FROM match_metadata mm
JOIN players p ON mm.puuid = p.puuid
WHERE p.game_name = 'Disciple bolita'
GROUP BY p.game_name, p.tag_line, p.rank_tier;

