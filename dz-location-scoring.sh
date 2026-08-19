#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# DoubleZero Location Scoring
#
# RANKING NOTE:
#   • Devices are sorted by:
#       (A) Good vs Bad group: "Good" = activated AND max_users>0. Everything else is "Bad".
#       (B) Within the "Bad" group: rows with max_users<=0 are placed at the very bottom.
#       (C) Continent bucket (Good rows first, then Bad nonzero-max rows): 
#           1 = Asia/South America/Africa, 2 = North America, 3 = Europe, 4 = Other/Unknown
#       (D) Utilization: users/max_users (lower is better; max_users<=0 never considered here because those are already last)
#       (E) Users: lower is better (tie-break)
#   • Final "Rank" is assigned sequentially from 1..N after sorting.
#
# Output columns (console and CSV are identical in order):
#   Rank, continent, utilization, location, users, max_users, exchange, region,
#   contributor, status, device_type, public_ip, dz_prefixes, mgmt_vrf, owner, account, code
# ------------------------------------------------------------------------------

cmd_output="$(doublezero device list --env mainnet-beta)"

# -------- Build sortable rows with helper keys using AWK --------
sortable="$(printf '%s\n' "$cmd_output" | tail -n +2 | awk -v FS='|' -v OFS='|' '
function trim(s){ gsub(/^ *| *$/, "", s); return s }
function map_exchange(ex,   region,cont,bucket) {
  region="Unknown"; cont="Other"; bucket=4
  # Rank bucket 1 (Asia / South America / Africa)
  if      (ex=="hkg") {region="Hong Kong";         cont="Asia";            bucket=1}
  else if (ex=="sin") {region="Singapore";         cont="Asia";            bucket=1}
  else if (ex=="tyo") {region="Tokyo JP";          cont="Asia";            bucket=1}
  else if (ex=="bom") {region="Mumbai IN";         cont="Asia";            bucket=1}
  else if (ex=="sao") {region="Sao Paulo BR";      cont="South America";   bucket=1}
  # (Add Africa sites here → bucket=1)

  # Rank bucket 2 (North America)
  else if (ex=="chi") {region="Chicago US";        cont="North America";   bucket=2}
  else if (ex=="dfw") {region="Dallas US";         cont="North America";   bucket=2}
  else if (ex=="lax") {region="Los Angeles US";    cont="North America";   bucket=2}
  else if (ex=="nyc") {region="New York US";       cont="North America";   bucket=2}
  else if (ex=="slc") {region="Salt Lake City US"; cont="North America";   bucket=2}
  else if (ex=="sjc") {region="San Jose US";       cont="North America";   bucket=2}
  else if (ex=="sea") {region="Seattle US";        cont="North America";   bucket=2}
  else if (ex=="was") {region="Washington DC US";  cont="North America";   bucket=2}
  else if (ex=="ymq") {region="Montreal CA";       cont="North America";   bucket=2}
  else if (ex=="yto") {region="Toronto CA";        cont="North America";   bucket=2}

  # Rank bucket 3 (Europe)
  else if (ex=="ams") {region="Amsterdam NL";      cont="Europe";          bucket=3}
  else if (ex=="dub") {region="Dublin IE";         cont="Europe";          bucket=3}
  else if (ex=="fra") {region="Frankfurt DE";      cont="Europe";          bucket=3}
  else if (ex=="lon") {region="London UK";         cont="Europe";          bucket=3}
  else if (ex=="mad") {region="Madrid ES";         cont="Europe";          bucket=3}
  else if (ex=="mrs") {region="Marseille FR";      cont="Europe";          bucket=3}
  else if (ex=="sxb") {region="Strasbourg FR";     cont="Europe";          bucket=3}
  else if (ex=="waw") {region="Warsaw PL";         cont="Europe";          bucket=3}
  else if (ex=="sqq") {region="Siauliai LT";       cont="Europe";          bucket=3}

  return region "|" cont "|" bucket
}
{
  for (i=1;i<=NF;i++) $i=trim($i)

  ex=tolower($5)
  users=$9+0
  max=$10+0
  status_lc=tolower($11)
  zero_max = (max<=0 ? 1 : 0)
  util=(max>0 ? users/max : 0)   # value ignored when zero_max=1; they’ll be sorted last anyway

  split(map_exchange(ex), m, "|")
  region=m[1]; continent=m[2]; cont_bucket=m[3]+0

  inactive = (status_lc == "activated" ? 0 : 1)
  bad = (inactive || zero_max)  # 0 = good (activated & max>0), 1 = bad

  # Helper sort keys FIRST:
  # bad | zero_max | cont_bucket | util | users
  # Then payload fields in the exact order we’ll emit to CSV later.
  printf "%d|%d|%d|%0.6f|%010d|%s|%s|%0.6f|%s|%d|%d|%s|%s|%s|%s|%s|%s|%s|%s|%s\n",
    bad, zero_max, cont_bucket, util, users,
    continent, region, util, $4, users, max, $5, $3, $11, $6, $7, $8, $12, $13, $1, $2
}
')"

# Sort by: good/bad, then ensure max_users=0 are bottom, then continent, util, users
sorted="$(printf '%s\n' "$sortable" | sort -t'|' -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n)"

# ---------- Create CSV with final ranks 1..N ----------
csv_out="dz_scored.csv"
{
  echo "Rank,continent,utilization,location,users,max_users,exchange,region,contributor,status,device_type,public_ip,dz_prefixes,mgmt_vrf,owner,account,code"
  rank=0
  printf '%s\n' "$sorted" | awk -v FS='|' -v OFS=',' '
    function safe(s){ gsub(/,/, " ", s); return s }
    {
      rank++
      # helper keys: $1..$5
      continent=$6; region=$7; util=$8; location=$9; users=$10+0; maxu=$11+0
      exchange=$12; contributor=$13; status=$14; device_type=$15
      public_ip=$16; dz_prefixes=$17; mgmt_vrf=$18; owner=$19; account=$20; code=$21

      printf "%d,%s,%.6f,%s,%d,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
        rank, safe(continent), util+0.0, safe(location), users, maxu,
        safe(exchange), safe(region), safe(contributor), safe(status),
        safe(device_type), safe(public_ip), safe(dz_prefixes),
        safe(mgmt_vrf), safe(owner), safe(account), safe(code)
    }
  '
} > "$csv_out"

# ---------- Console output ----------
cat <<'NOTE'
RANKING NOTE
• Devices are sorted by:
  (A) Good vs Bad: "Good" = activated AND max_users>0. All others are "Bad".
  (B) Within "Bad": max_users<=0 entries are placed at the very bottom.
  (C) Continent bucket: 1 = Asia/South America/Africa, 2 = North America, 3 = Europe, 4 = Other/Unknown.
  (D) Utilization (users/max_users): lower is better.
  (E) Users: lower is better (tie-break).
• Final "Rank" is assigned sequentially from 1..N after sorting.
NOTE

if command -v column >/dev/null 2>&1; then
  column -s',' -t "$csv_out"
else
  cat "$csv_out"
fi

echo
echo "Saved: $csv_out"
