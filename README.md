# solana next leader slot

## description
this script checks the upcoming leader slots for a specified solana validator and calculates the time until the next leader slot. it's useful for determining safe periods to perform maintenance activities like restarting the validator without missing important leader slots.

the script fetches performance samples from the solana network to calculate the average slot duration. this information is crucial in estimating the time accurately until the next leader slot.

**notice**: the calculated time until the next leader slot and the average slot duration may have a slight variance in accuracy. this is due to the dynamic nature of the solana network, where slot times can fluctuate based on network conditions. the script provides an estimate based on the most recent data, but minor discrepancies are possible due to these variations

## usage

```bash
chmod + status.sh
```
to use the script, you need to pass the validator identity as an argument.

```bash
./status.sh -i <validator_identity>
```

## packages
install the required packages: bc and jq

```bash
apt install bc jq -y
```

## example output
```
./status.sh -i 1KXvrkPXwkGF6NK1zyzVuJqbXfpenPVPP6hoiK9bsK3
your next leader slot is at slot 233200236 (in approximately 0 hours, 25 minutes, 5.2 seconds, and 200.0 milliseconds).
```

## changelog

- fetch performance samples from api - 2023/12/03
