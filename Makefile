.PHONY: build build-pool build-router test clean

build:
	forge build

build-pool:
	FOUNDRY_PROFILE=pool-deploy forge build

build-router:
	FOUNDRY_PROFILE=router-deploy forge build

test:
	forge test

test-v:
	forge test -vvv

clean:
	forge clean
