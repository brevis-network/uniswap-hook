#!/bin/bash
echo "reqid:" $REQUEST_ID
/home/ubuntu/.cargo/bin/forge script script/deployHook.sol --rpc-url "$1" --keystore $2 --password-file "$2.pwd" --broadcast \
    --verify --verifier oklink --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/xlayer --api-key 5dd22fb5-ab0c-4abd-b0a3-bd4e6d54a5b3 \
    --delay 10 --retries 10