# syntax=docker/dockerfile:1.28.0
# Elara vault-loader — one-shot Vault bootstrap (ETAPA-04 loader).
# setup-vault.sh needs bash + vault + jq + base64. The hashicorp/vault image
# ships none of bash/jq/base64, and Alpine has no vault package, so the vault
# binary (1.16.3 == server 1.16.3, no CLI drift) is copied from the pinned server
# image while bash/jq/base64 (coreutils) come from apk.
FROM hashicorp/vault:1.16.3 AS vault-bin
FROM alpine:3.21.8
COPY --from=vault-bin /bin/vault /usr/local/bin/vault
RUN apk add --no-cache bash jq coreutils \
 && mkdir -p /work/scripts /secrets
WORKDIR /work
ENTRYPOINT ["/bin/bash", "/work/scripts/setup-vault.sh"]
