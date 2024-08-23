# solana next leader slot

## description
this script checks the upcoming leader slots for a specified solana validator and calculates the time until the next leader slot. it's useful for determining safe periods to perform maintenance activities like restarting the validator without missing important leader slots.

the script fetches performance samples from the solana network to calculate the average slot duration. this information is crucial in estimating the time accurately until the next leader slot.

**notice**: the calculated time until the next leader slot and the average slot duration may have a slight variance in accuracy. this is due to the dynamic nature of the solana network, where slot times can fluctuate based on network conditions. the script provides an estimate based on the most recent data, but minor discrepancies are possible due to these variations

## usage

```bash
bash show-my-next-leader-slot.sh
```
to use the script, you need to modify the three variables at top of the script:
```
VALIDATOR_IDENTITY
TIME_ZONE
RPC_URL
```
## packages
install the required packages: bc and jq

```bash
apt install bc jq -y
```

## example output
```
bash show-my-next-leader-slot.sh

```
Upcoming Leader Slots
Lead  285365600-285365603  4 slots       2024-08-23 15:06:46 UTC | 2024-08-23 10:06:46 America/Chicago (1.76 secs)
      285365604-285368927  3324 slots    2024-08-23 15:06:47 UTC | 2024-08-23 10:06:47 America/Chicago (24 mins 26.47 secs)
Lead  285368928-285368931  4 slots       2024-08-23 15:31:14 UTC | 2024-08-23 10:31:14 America/Chicago (1.76 secs)
      285368932-285373683  4752 slots    2024-08-23 15:31:16 UTC | 2024-08-23 10:31:16 America/Chicago (34 mins 56.47 secs)
Lead  285373684-285373687  4 slots       2024-08-23 16:06:12 UTC | 2024-08-23 11:06:12 America/Chicago (1.76 secs)
      285373688-285388187  14500 slots   2024-08-23 16:06:14 UTC | 2024-08-23 11:06:14 America/Chicago (1 hr 46 mins 37.05 secs)
Lead  285388188-285388191  4 slots       2024-08-23 17:52:51 UTC | 2024-08-23 12:52:51 America/Chicago (1.76 secs)


Epoch: 660
Time to end of epoch: 22 hrs 52 mins 48.00 secs
Epoch end time (UTC): 2024-08-24 13:57:35 ***** Epoch end time (America/Chicago): 2024-08-24 08:57:35

Current slot: 285365298
Current time (UTC): 2024-08-23 15:04:33 UTC ***** Current time (America/Chicago): 2024-08-23 10:04:33 CDT
Average slot duration: .441176 seconds (441.176000 milliseconds)

Your next leader slot is at slot 285365600 for VALIDATOR_IDENTITY = <your-identity-pubkey>
Time of next leader slot (UTC): 2024-08-23 15:07:00 UTC ***** Time of next leader slot (America/Chicago): 2024-08-23 10:07:00 CDT
***** in approximately 0 hours, 2 minutes, 13 seconds *****
```

## changelog
2024-08-23
- added a table at the top of the output to show next 4 leaderslots
- added variables TIME_ZONE and RPC_URL
- Updated the sumamry output
```
