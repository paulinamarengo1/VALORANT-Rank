# collect_data_highelo.py
# High elo snowball crawler — seeds from leaderboard (Radiant/Immortal)
# and BFS-expands through competitive matches only.
# Fixes applied vs original: None-safe get_match_ids, 60s rate limit sleep.

import requests
import pyodbc
import json
import time
import argparse
from collections import deque

from config import HENRIK_API_KEY

HEADERS = {"Authorization": HENRIK_API_KEY}
REGION = "na"

conn = pyodbc.connect(
    'DRIVER={SQL Server};'
    'SERVER=POLI_PC\\SQLEXPRESS;'
    'DATABASE=valorant_churn;'
    'Trusted_Connection=yes;'
)
cursor = conn.cursor()

def get(url):
    response = requests.get(url, headers=HEADERS)
    time.sleep(2)
    if response.status_code == 200:
        return response.json()
    if response.status_code == 429:
        print("  Rate limited — sleeping 60s")
        time.sleep(60)
        return get(url)
    print(f"  Error {response.status_code}: {url}")
    return None

def get_leaderboard_seeds(size=20):
    url = f"https://api.henrikdev.xyz/valorant/v1/leaderboard/{REGION}"
    data = get(url)
    seeds = []
    if data and data.get("data"):
        for p in data["data"][:size]:
            if p.get("puuid"):
                seeds.append((p["puuid"], p.get("gameName", ""), p.get("tagLine", "")))
    print(f"Seeded {len(seeds)} players from leaderboard")
    return seeds

def get_mmr(puuid):
    url = f"https://api.henrikdev.xyz/valorant/v2/by-puuid/mmr/{REGION}/{puuid}"
    data = get(url)
    if data and data.get("data"):
        d = data["data"]
        tier = d.get("current_data", {}).get("currenttierpatched", "Unknown")
        rr   = d.get("current_data", {}).get("ranking_in_tier", 0)
        return tier, rr
    return "Unknown", 0

def get_match_ids(puuid, mode="competitive", count=5):
    url = f"https://api.henrikdev.xyz/valorant/v3/by-puuid/matches/{REGION}/{puuid}?mode={mode}&size={count}&platform=pc"
    data = get(url)
    if data and data.get("data"):
        return [m.get("metadata", {}).get("matchid") for m in data["data"]
                if m and (m.get("metadata") or {}).get("matchid")]
    return []

def get_match_by_id(match_id):
    url = f"https://api.henrikdev.xyz/valorant/v2/match/{match_id}"
    data = get(url)
    if data and data.get("data"):
        return data["data"]
    return None

def save_player(puuid, name, tag, tier, rr):
    cursor.execute("""
        IF NOT EXISTS (SELECT 1 FROM players WHERE puuid = ?)
        INSERT INTO players (puuid, game_name, tag_line, rank_tier, mmr_rr)
        VALUES (?, ?, ?, ?, ?)
        ELSE
        UPDATE players SET rank_tier = ?, mmr_rr = ? WHERE puuid = ?
    """, puuid, puuid, name, tag, tier, rr, tier, rr, puuid)
    conn.commit()

def save_match_all_players(match):
    if not match:
        return []
    meta = match.get("metadata", {})
    match_id = meta.get("matchid", "")
    if not match_id:
        return []

    cursor.execute("""
        IF NOT EXISTS (SELECT 1 FROM match_raw WHERE match_id = ?)
        INSERT INTO match_raw (match_id, raw_json) VALUES (?, ?)
    """, match_id, match_id, json.dumps(match))

    all_players = match.get("players", {}).get("all_players", [])
    teams = match.get("teams", {})
    game_length = meta.get("game_length", 0)
    surrendered = game_length < 1320000

    new_puuids = []
    for player in all_players:
        puuid = player.get("puuid")
        if not puuid:
            continue
        stats = player.get("stats", {})
        team  = player.get("team", "").lower()
        won   = teams.get(team, {}).get("has_won", False)

        cursor.execute("""
            IF NOT EXISTS (SELECT 1 FROM match_metadata WHERE match_id = ? AND puuid = ?)
            INSERT INTO match_metadata (
                match_id, puuid, game_start, game_length_ms,
                queue_id, map_name, agent_name,
                kills, deaths, assists,
                headshots, bodyshots, legshots,
                won, surrendered
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
            match_id, puuid,
            match_id, puuid,
            meta.get("game_start", 0),
            game_length,
            meta.get("mode", ""),
            meta.get("map", ""),
            player.get("character", ""),
            stats.get("kills", 0),
            stats.get("deaths", 0),
            stats.get("assists", 0),
            stats.get("headshots", 0),
            stats.get("bodyshots", 0),
            stats.get("legshots", 0),
            1 if won else 0,
            1 if surrendered else 0
        )
        new_puuids.append((puuid, player.get("name", ""), player.get("tag", "")))

    conn.commit()
    return new_puuids

def run(target_matches=10000, max_seed=20, hop_match_limit=5, target_players=500):
    print("=" * 50)
    print(f"VALORANT High Elo Crawl — target {target_players} players")
    print("=" * 50)

    seeds = get_leaderboard_seeds(size=max_seed)
    visited_players = set()
    visited_matches = set()
    queue = deque(seeds)
    saved_matches = 0

    while queue and saved_matches < target_matches:
        if target_players and len(visited_players) >= target_players:
            break
        puuid, name, tag = queue.popleft()
        if puuid in visited_players:
            continue
        visited_players.add(puuid)

        tier, rr = get_mmr(puuid)
        save_player(puuid, name, tag, tier, rr)
        print(f"\n[{len(visited_players)} players visited | {saved_matches} matches saved] "
              f"{name}#{tag} — {tier} ({rr} RR)")

        match_ids = get_match_ids(puuid, mode="competitive", count=hop_match_limit)
        for mid in match_ids:
            if mid in visited_matches or saved_matches >= target_matches:
                continue
            visited_matches.add(mid)

            match = get_match_by_id(mid)
            new_players = save_match_all_players(match)
            if new_players:
                saved_matches += 1
                print(f"  + match {mid[:8]}... -> {len(new_players)} players saved")
                for np in new_players:
                    if np[0] not in visited_players:
                        queue.append(np)

    print("\n" + "=" * 50)
    print(f"Crawl complete. {saved_matches} matches, {len(visited_players)} unique players.")
    print("=" * 50)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", type=int, default=10000)
    parser.add_argument("--seeds", type=int, default=20)
    parser.add_argument("--hop-matches", type=int, default=5)
    parser.add_argument("--target-players", type=int, default=500)
    args = parser.parse_args()

    run(target_matches=args.target,
        max_seed=args.seeds,
        hop_match_limit=args.hop_matches,
        target_players=args.target_players)