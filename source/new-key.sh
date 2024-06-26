#/bin/bash -e
passphrase=$1

echo -e 'y' | ssh-keygen -t rsa -b 4096 -f scratch -N "$passphrase" 

privateKey=$(cat scratch)
publicKey=$(cat 'scratch.pub')

json="{\"keyinfo\":{\"privateKey\":\"$privateKey\",\"publicKey\":\"$publicKey\"}}"

echo "$json" > $AZ_SCRIPTS_OUTPUT_PATH
