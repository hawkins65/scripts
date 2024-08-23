#!/bin/bash

# check if an identity argument is provided
if [[ $# -eq 0 ]] ; then
    echo "usage: $0 -i <validatorIdentity>"
    exit 1
fi

# parse command line argument for validator identity
while getopts ":i:" opt; do
  case $opt in
    i)
      VALIDATOR_IDENTITY=$OPTARG
      ;;
    \?)
      echo "invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

# check if validator identity is provided
if [ -z "$VALIDATOR_IDENTITY" ]; then
    echo "validator identity is required."
    exit 1
fi

# fetch performance samples to calculate slot duration
performance_samples=$(curl -s http://api.mainnet-beta.solana.com -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getRecentPerformanceSamples","params":[1]}')
num_slots=$(echo "$performance_samples" | jq -r '.result[0].numSlots')
sample_period_secs=$(echo "$performance_samples" | jq -r '.result[0].samplePeriodSecs')
SLOT_DURATION=$(echo "scale=4; $sample_period_secs / $num_slots" | bc -l)

# get the current slot
current_slot=$(solana slot)

# get your validator's upcoming slots
upcoming_slots=$(solana leader-schedule | grep "$VALIDATOR_IDENTITY")

# check if you have slots in the near future
closest_slot=$(echo "$upcoming_slots" | awk '{print $1}' | sort -n | awk -v current_slot="$current_slot" '$1 > current_slot {print $1; exit}')

if [ -n "$closest_slot" ]; then
    slots_difference=$(($closest_slot - $current_slot))
    time_until_next_slot=$(echo "$slots_difference * $SLOT_DURATION" | bc -l)

    # convert time to hours, minutes, seconds, and milliseconds
    hours=$(echo "$time_until_next_slot/3600" | bc)
    minutes=$(echo "($time_until_next_slot%3600)/60" | bc)
    seconds=$(echo "$time_until_next_slot%60" | bc)
    milliseconds=$(echo "($time_until_next_slot*1000)%1000" | bc)

    echo "your next leader slot is at slot $closest_slot (in approximately $hours hours, $minutes minutes, $seconds seconds, and $milliseconds milliseconds)."
    echo "avg. slot duration: $SLOT_DURATION"
else
    echo "no upcoming leader slots found in the schedule."
fi
