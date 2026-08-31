#!/usr/bin/env bash
# Deploy Morpho-blue lending core + supporting tokens + IRM + MetaMorpho factory
# to localnet (chain 31337). Picks up from current on-chain nonce.
#
# Strategy A: skip oversized Liquid proxy (30,893B > EIP-170 24KB),
# wire Morpho-blue (~15.5KB) + AdaptiveCurveIrm (~2.3KB) + MetaMorphoFactory (~23.8KB)
# directly. WLUX already at 0x413e4A820635702Ec199bC5B62dCbCa1749851bf.
#
# Pre-req: the lux dependency repos must be built (forge build) so artifacts exist:
#   - lib/vault-v2/lib/morpho-blue/out/Morpho.sol/Morpho.json
#   - lib/vault-v2/lib/morpho-blue-irm/out/AdaptiveCurveIrm.sol/AdaptiveCurveIrm.json
#   - lib/vault-v2/lib/metamorpho/out/MetaMorphoFactory.sol/MetaMorphoFactory.json
#
# Pre-req: the localnet must be producing blocks. Solo-validator luxd with
# `local-txs-enabled=false` and `enable-automining=false` may stall after the
# first deploy; restart with --enable-automining=true if the chain idles.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

RPC=http://127.0.0.1:9650/v1/chain/C/rpc
GAS_PRICE=${GAS_PRICE:-500000000000}  # 500 gwei (overcome stuck pending txs)
M=$(security find-generic-password -a LUX_MNEMONIC -w)
PRIVATE_KEY=$(cast wallet derive-private-key "$M" 0 | tail -1 | awk '{print $NF}')
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")

LIQUID_ROOT=/Users/z/work/lux/liquid
MB=$LIQUID_ROOT/lib/vault-v2/lib/morpho-blue
IRM=$LIQUID_ROOT/lib/vault-v2/lib/morpho-blue-irm
MM=$LIQUID_ROOT/lib/vault-v2/lib/metamorpho

# Pre-deployed
WLUX=0x413e4A820635702Ec199bC5B62dCbCa1749851bf

OUT=$LIQUID_ROOT/deployments/localnet.env
mkdir -p $LIQUID_ROOT/deployments
: > "$OUT"
echo "WLUX=$WLUX" | tee -a "$OUT"

# Common flags: legacy tx (chain quirk), explicit gas price, broadcast
COMMON=(--legacy --gas-price "$GAS_PRICE" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast)

# Wait for the previous nonce to land before submitting the next.
wait_nonce() {
  local target=$1 tries=60
  while [ $tries -gt 0 ]; do
    local n
    n=$(cast nonce $DEPLOYER --rpc-url "$RPC")
    if [ "$n" -ge "$target" ]; then return 0; fi
    sleep 2
    tries=$((tries-1))
  done
  echo "WAIT TIMEOUT: nonce stuck below $target (current: $n). chain may not be mining." >&2
  return 1
}

deploy() {
  local label=$1 art=$2 args=${3:-}
  local cur
  cur=$(cast nonce $DEPLOYER --rpc-url "$RPC")
  echo ">>> deploying $label from $art (nonce $cur)"
  local out
  if [ -n "$args" ]; then
    # shellcheck disable=SC2086
    out=$(forge create "${COMMON[@]}" "$art" --constructor-args $args 2>&1)
  else
    out=$(forge create "${COMMON[@]}" "$art" 2>&1)
  fi
  local addr
  addr=$(echo "$out" | grep -E "Deployed to:" | awk '{print $NF}')
  if [ -z "$addr" ]; then
    echo "FAIL: $label"
    echo "$out" | tail -10
    exit 1
  fi
  echo "$label=$addr" | tee -a "$OUT"
  wait_nonce "$((cur + 1))"
  echo "$addr"
}

echo "=== Deployer: $DEPLOYER ==="
echo "=== Chain ID: $(cast chain-id --rpc-url $RPC) ==="
echo "=== Nonce:    $(cast nonce $DEPLOYER --rpc-url $RPC) ==="
echo "=== Balance:  $(cast balance $DEPLOYER --rpc-url $RPC) ==="

# 1) Tokens (DevToken from script/DeployLocal.s.sol — already built in main project)
cd "$LIQUID_ROOT"
LUSD=$(deploy LUSD "script/DeployLocal.s.sol:DevToken" "\"Lux USD\" LUSD 1000000000000000000000000")
IBIT=$(deploy IBIT "script/DeployLocal.s.sol:DevToken" "\"iShares Bitcoin ETF\" IBIT 100000000000000000000000")

# 2) Morpho-blue core
cd "$MB"
MORPHO=$(deploy MORPHO "src/Morpho.sol:Morpho" "$DEPLOYER")

# 3) AdaptiveCurveIrm (binds to Morpho)
cd "$IRM"
ADAPTIVE_IRM=$(deploy ADAPTIVE_IRM "src/adaptive-curve-irm/AdaptiveCurveIrm.sol:AdaptiveCurveIrm" "$MORPHO")

# 4) MetaMorphoFactory (vault factory binds to Morpho)
cd "$MM"
META_FACTORY=$(deploy META_FACTORY "src/MetaMorphoFactory.sol:MetaMorphoFactory" "$MORPHO")

# 5) Wire Morpho: enable IRM + standard LLTVs
cd "$LIQUID_ROOT"
echo ">>> enabling IRM on Morpho"
cur=$(cast nonce $DEPLOYER --rpc-url "$RPC")
cast send "$MORPHO" "enableIrm(address)" "$ADAPTIVE_IRM" "${COMMON[@]}" >/dev/null
wait_nonce "$((cur + 1))"
echo "IRM enabled: $ADAPTIVE_IRM"

# LLTVs in WAD (1e18). 86% / 91.5% / 94.5% — standard Morpho preset
for lltv in 860000000000000000 915000000000000000 945000000000000000; do
  cur=$(cast nonce $DEPLOYER --rpc-url "$RPC")
  echo ">>> enabling LLTV $lltv (nonce $cur)"
  cast send "$MORPHO" "enableLltv(uint256)" "$lltv" "${COMMON[@]}" >/dev/null
  wait_nonce "$((cur + 1))"
done

echo "DEPLOYER=$DEPLOYER" >> "$OUT"
echo "CHAIN_ID=31337" >> "$OUT"
echo ""
echo "=== Done. Addresses written to $OUT ==="
cat "$OUT"
