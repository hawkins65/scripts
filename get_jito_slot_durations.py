#!/usr/bin/env python3
"""
Retrieve Jito validator slot duration data from Trillium API and export to CSV.
"""

import sys
import csv
import requests

def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <epoch>")
        sys.exit(1)

    try:
        epoch = int(sys.argv[1])
    except ValueError:
        print("Error: epoch must be an integer")
        sys.exit(1)

    url = f"https://api.trillium.so/validator_rewards/{epoch}"
    print(f"Fetching data from {url}...")

    response = requests.get(url)
    response.raise_for_status()
    data = response.json()

    # Filter validators with JITO in stake_pools and stake_pools.JITO > 1
    jito_validators = []
    for v in data:
        stake_pools = v.get('stake_pools', {})
        if stake_pools and 'JITO' in stake_pools and stake_pools['JITO'] > 1:
            jito_validators.append(v)

    # Sort by slot_duration_mean descending
    jito_validators.sort(key=lambda x: x.get('slot_duration_mean') or 0, reverse=True)

    # Define output fields
    fields = [
        'epoch', 'identity_pubkey', 'vote_account_pubkey', 'name',
        'jito_overall_rank', 'jito_stake', 'slot_duration_mean', 'slot_duration_median',
        'mev_earned', 'total_compound_mev_apy', 'activated_stake',
        'jito_passing_eligibility_criteria', 'jito_start_epoch'
    ]

    output_file = f"epoch_{epoch}_jito_slot_durations.csv"

    with open(output_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction='ignore', quoting=csv.QUOTE_ALL)
        writer.writeheader()
        for v in jito_validators:
            row = {field: v.get(field) for field in fields}
            row['jito_stake'] = v.get('stake_pools', {}).get('JITO')
            writer.writerow(row)

    print(f"Wrote {len(jito_validators)} validators to {output_file}")

if __name__ == "__main__":
    main()
