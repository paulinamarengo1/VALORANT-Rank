# backfill_mmr.py
# Retries the MMR endpoint for every player currently stored as 'Unknown'
# rank_tier in the players table. Runs slower than the main crawler on
# purpose (3 second sleep) to avoid rate limits, since this is the only
# endpoint being called and we can afford to be patient.
#
# Safe to run multiple times — skips anyone who already has a real rank.
# Safe to run alongside collect_data_v2.py — only touches rank_tier/mmr_rr.

import requests
import pyodbc
import time

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
    time.sleep(3)   # slightly longer than main script to be safe
    if response.status_code == 200:
        return response.json()
    if response.status_code == 429:
        print("  Rate limited — sleeping 60s")
        time.sleep(60)
        return get(url)
    return None

def get_mmr(puuid):
    url = f"https://api.henrikdev.xyz/valorant/v2/by-puuid/mmr/{REGION}/{puuid}"
    data = get(url)
    if data and data.get("data"):
        d = data["data"]
        tier = d.get("current_data", {}).get("currenttierpatched", None)
        rr   = d.get("current_data", {}).get("ranking_in_tier", 0)
        if tier:
            return tier, rr
    return None, 0

def run():
    # Fetch all puuids still sitting at Unknown
    cursor.execute("""
        SELECT puuid, game_name, tag_line
        FROM players
        WHERE rank_tier = 'Unknown'
        ORDER BY puuid
    """)
    unknown_players = cursor.fetchall()
    total = len(unknown_players)
    print(f"Found {total} players with Unknown rank — starting backfill")
    print("=" * 50)

    updated   = 0
    still_unknown = 0

    for i, (puuid, name, tag) in enumerate(unknown_players, 1):
        tier, rr = get_mmr(puuid)

        if tier:
            cursor.execute("""
                UPDATE players
                SET rank_tier = ?, mmr_rr = ?
                WHERE puuid = ?
            """, tier, rr, puuid)
            conn.commit()
            updated += 1
            print(f"[{i}/{total}] {name}#{tag} → {tier} ({rr} RR)")
        else:
            still_unknown += 1
            print(f"[{i}/{total}] {name}#{tag} → still no data (leaving as Unknown)")

        # Progress checkpoint every 100 players
        if i % 100 == 0:
            print(f"\n── Checkpoint: {updated} updated, {still_unknown} still unknown ──\n")

    print("=" * 50)
    print(f"Backfill complete.")
    print(f"  Updated:       {updated}")
    print(f"  Still unknown: {still_unknown}")
    print(f"  Total retried: {total}")

run()