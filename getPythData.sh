#!/bin/bash

stockFeedId="$(jq -r .$1 pythPriceFeedIds.json)"
usdcFeedId="$(jq -r .USDC pythPriceFeedIds.json)"
curl -s "https://hermes.pyth.network/v2/updates/price/latest?ids[]=$stockFeedId&ids[]=$usdcFeedId" | jq -r '.binary.data[0]'

