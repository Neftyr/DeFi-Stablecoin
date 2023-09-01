Where 2 contracts inherit the same interface and implement the same functions and have the same source layout, although they are both tested fully, forge coverage fails to recognise hits on one of the contracts.
In this case it would fail to recognise hits on SecondContract as FirstContract comes first alphabetically.

In this project case N (NeftyrStableCoin) is after M (MockFailedMintNFR) aplhabetically, which means only Mock will be shown in coverage.

This is foundry bug reported here: https://github.com/foundry-rs/foundry/issues/5729
