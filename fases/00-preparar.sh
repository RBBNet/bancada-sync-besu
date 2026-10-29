#!/usr/bin/env bash
# Fase 00: registra o ambiente, baixa o start-network no commit fixado, constrói a imagem do rbb-cli
# e instala as dependências. Não altera nenhuma rede.

fase "Fase 00: preparação do ambiente"

passo "Ambiente de execução"
fato ambiente.executor "$([ "$NO_GITHUB" = true ] && echo "GitHub Actions (${RUNNER_NAME:-?}, ${RUNNER_OS:-?})" || echo "máquina local")"
fato ambiente.sistema "$(uname -s) $(uname -r)"
fato ambiente.arquitetura "$(uname -m)"
fato ambiente.cpus "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '?')"
for f in docker git jq curl node npm python3; do command -v "$f" >/dev/null || abortar "ferramenta ausente: $f"; done
fato ambiente.docker "$(docker version --format '{{.Server.Version}}')"
fato ambiente.docker_compose "$(docker compose version --short)"
fato ambiente.node "$(node --version)"
node -e "process.exit(parseInt(process.versions.node) >= ${NODE_VERSAO_MINIMA} ? 0 : 1)" \
  || abortar "Node.js ${NODE_VERSAO_MINIMA}+ necessário"
fato bancada.commit "$(git -C "$RAIZ" rev-parse HEAD 2>/dev/null || echo desconhecido)"
if [ -n "$(git -C "$RAIZ" status --porcelain 2>/dev/null)" ]; then
  fato bancada.alteracoes_locais "SIM (código com alterações não versionadas; execução não reproduzível a partir do commit)"
else
  fato bancada.alteracoes_locais "não"
fi

passo "Parâmetros do experimento"
fato experimento.besu "$BESU"
fato experimento.formato "$FORMATO"
fato experimento.esperas_min "$ESPERAS_MIN"
fato experimento.limite_orfa_s "$LIMITE_ORFA"
fato experimento.intervalo_carga_s "$INTERVALO_CARGA"
fato experimento.alvos "$ALVOS"

passo "start-network no commit fixado (versoes.env)"
mkdir -p "$SN"
git -C "$SN" init -q
git -C "$SN" fetch -q --depth 1 "$START_NETWORK_REPO" "$START_NETWORK_COMMIT" || abortar "falha ao baixar o start-network"
git -C "$SN" checkout -q FETCH_HEAD
fato repositorio.start-network "$START_NETWORK_REPO @ $(git -C "$SN" rev-parse HEAD)"

passo "Imagem do rbb-cli construída a partir do start-network"
desvio "a imagem bndes/rbb:latest do Docker Hub é de 2023 e anterior ao start-network atual; construímos a imagem localmente (start-network/build.sh faz o mesmo, sem fixar a versão do Besu)"
RBB_IMAGE="bancada/rbb-cli:${START_NETWORK_COMMIT:0:7}"
export RBB_IMAGE
em "$SN" executar "construir imagem do rbb-cli" \
    docker build --build-arg "BESU_IMAGE=${BESU_IMAGEM_RBB_CLI}" --build-arg NODE_VERSION=22 --tag "$RBB_IMAGE" .
fato imagem.rbb_cli "$RBB_IMAGE"
executar "baixar imagem do Besu dos nós" docker pull -q "$BESU_IMAGEM"
fato imagem.besu "$BESU_IMAGEM"

passo "Dependências Node.js da carga de transações"
em "$RAIZ/ferramentas" executar "ferramentas da bancada: npm ci" npm ci --no-audit --no-fund
