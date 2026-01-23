echo "reqid:" $REQUEST_ID
forge script script/deployHook.sol --rpc-url "$1" --keystore $2 --password-file "$2.pwd" --broadcast