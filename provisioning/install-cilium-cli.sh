#!/bin/bash
set -e
echo ">>> Scaricamento versione stabile Cilium CLI..."
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
echo ">>> Versione rilevata: $CILIUM_CLI_VERSION"
curl -L --fail --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz"
sudo tar -xzvf cilium-linux-amd64.tar.gz -C /usr/local/bin
rm cilium-linux-amd64.tar.gz
echo ">>> Installazione completata!"
cilium version
