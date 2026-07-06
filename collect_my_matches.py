# collect_my_matches.py
# Pulls up to 100 competitive matches specifically for Disciple bolita#poli.
# Henrik's API returns max 20 matches per call, so we page through 5 calls.
# All 10 players per match are saved (same schema as the main crawler).
# Safe to run multiple times — IF NOT EXISTS guards prevent duplicates.

import requests
import pyodbc
import json
import time

from config import HENRIK_API_KEY

HEADERS = {"Authorization": HENRIK_API_KEY}
REGION  = "na"
MY_NAME = "Disciple bolita"
MY_TAG  = "poli"

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

def get_puuid(name, tag):
    url  = f"https://api.henrikdev.xyz/valorant/v1/account/{name}/{tag}"
    data = get(url)
    if data and data.get("data"):
        return data["data"].get("puuid")
    return None

def get_match_ids_paged(puuid, total=100):
    """Henrik returns max 20 per call — page through to get up to 100."""
    all_ids = []
    page    = 1
    per_page = 20
    seen = set()

    while len(all_ids) < total:
        url  = (f"https://api.henrikdev.xyz/valorant/v3/by-puuid/matches/{REGION}/{puuid}"
                f"?mode=competitive&size={per_page}&page={page}&platform=pc")
        data = get(url)
        if not data or not data.get("data"):
            break
        batch = [
            m.get("metadata", {}).get("matchid")
            for m in data["data"]
            if m and (m.get("metadata") or {}).get("matchid")
        ]
        if not batch:
            break
        new = [mid for mid in batch if mid not in seen]
        if not new:
            break   # API stopped returning new matches
        for mid in new:
            seen.add(mid)
            all_ids.append(mid)
        print(f"  Page {page}: got {len(new)} new match IDs (total so far: {len(all_ids)})")
        page += 1

    return all_ids[:total]

def get_match_by_id(match_id):
    url  = f"https://api.henrikdev.xyz/valorant/v2/match/{match_id}"
    data = get(url)
    if data and data.get("data"):
        return data["data"]
    return None

def save_player(puuid, name, tag, tier="Unknown", rr=0):
    cursor.execute("""
        IF NOT EXISTS (SELECT 1 FROM players WHERE puuid = ?)
        INSERT INTO players (puuid, game_name, tag_line, rank_tier, mmr_rr)
        VALUES (?, ?, ?, ?, ?)
    """, puuid, puuid, name, tag, tier, rr)
    conn.commit()

def save_match_all_players(match):
    if not match:
        return 0
    meta     = match.get("metadata", {})
    match_id = meta.get("matchid", "")
    if not match_id:
        return 0

    cursor.execute("""
        IF NOT EXISTS (SELECT 1 FROM match_raw WHERE match_id = ?)
        INSERT INTO match_raw (match_id, raw_json) VALUES (?, ?)
    """, match_id, match_id, json.dumps(match))

    all_players = match.get("players", {}).get("all_players", [])
    teams       = match.get("teams", {})
    game_length = meta.get("game_length", 0)
    surrendered = game_length < 1320000

    saved = 0
    for player in all_players:
        puuid = player.get("puuid")
        if not puuid:
            continue
        stats = player.get("stats", {})
        team  = player.get("team", "").lower()
        won   = teams.get(team, {}).get("has_won", False)

        save_player(puuid, player.get("name", ""), player.get("tag", ""))

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
        saved += 1

    conn.commit()
    return saved

def run():
    print("=" * 50)
    print(f"Pulling up to 100 matches for {MY_NAME}#{MY_TAG}")
    print("=" * 50)

    puuid = get_puuid(MY_NAME, MY_TAG)
    if not puuid:
        print("Could not resolve account — check name/tag")
        return
    print(f"Resolved puuid: {puuid[:16]}...")

    match_ids = get_match_ids_paged(puuid, total=100)
    print(f"\nFound {len(match_ids)} match IDs — fetching full match data...\n")

    # Check which ones are already in the DB so we skip API calls for them
    already_saved = set()
    cursor.execute("SELECT match_id FROM match_raw")
    for row in cursor.fetchall():
        already_saved.add(row[0])

    new_count  = 0
    skip_count = 0

    for i, mid in enumerate(match_ids, 1):
        if mid in already_saved:
            skip_count += 1
            print(f"[{i}/{len(match_ids)}] {mid[:8]}... already in DB — skipping")
            continue

        match  = get_match_by_id(mid)
        saved  = save_match_all_players(match)
        new_count += 1
        print(f"[{i}/{len(match_ids)}] {mid[:8]}... saved {saved} player rows")

    print("\n" + "=" * 50)
    print(f"Done. {new_count} new matches saved, {skip_count} already existed.")
    print("=" * 50)

run()
