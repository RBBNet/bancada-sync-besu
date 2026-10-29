#!/usr/bin/env bash
# Executa a bancada do início ao fim: prepara o ambiente, monta a rede no padrão da RBB e faz as
# tentativas de sync em regime. Ao final, sempre guarda os logs dos nós e gera o relatório em
# execucoes/<id>/resumo.md.
#
# Uso: ./executar.sh
#   BESU=25.12.0 ./executar.sh            versão do Besu dos nós (ver versoes.env; padrão 25.5.0)
#   FORMATO=FOREST ./executar.sh          formato de armazenamento (padrão: BONSAI, o padrão do Besu)
#   ESPERAS_MIN="1 3" ./executar.sh       minutos de regime antes de cada tentativa provocada
#   MANTER_REDE=1 ./executar.sh           mantém a rede de pé ao final (para inspeção manual)
#
# Código de saída: 0 = todas as verificações passaram (com ou sem reprodução do defeito);
# 1 = alguma falhou; 2 = execução abortada.

set -u
RAIZ="$(cd "$(dirname "$0")" && pwd)"
source "$RAIZ/versoes.env"
source "$RAIZ/lib/comum.sh"
source "$RAIZ/lib/sync.sh"

EXEC_ID="$(date -u '+%Y%m%d-%H%M%S')"
EXEC_DIR="$RAIZ/execucoes/$EXEC_ID"
TRAB="$EXEC_DIR/trabalho"        # clone, dados dos nós (não vai para os artefatos)
SN="$TRAB/start-network"
mkdir -p "$TRAB"
: > "$EXEC_DIR/fatos.jsonl"; : > "$EXEC_DIR/verificacoes.jsonl"; : > "$EXEC_DIR/tentativas.jsonl"

export COMPOSE_PROJECT_NAME="bancadasync-$(echo "$EXEC_ID" | tr -d '-')"
PORTA_VALIDATOR=${PORTA_VALIDATOR:-20101}
PORTA_BOOT=${PORTA_BOOT:-20102}
PORTA_WRITER=${PORTA_WRITER:-20103}
PORTA_VALIDATOR2=${PORTA_VALIDATOR2:-20104}
PORTA_VALIDATOR3=${PORTA_VALIDATOR3:-20105}
PORTA_VALIDATOR4=${PORTA_VALIDATOR4:-20106}
NOS="validator validator2 validator3 validator4 boot writer"
ALVOS="validator writer"          # nós em que as tentativas de sync são provocadas e observadas

BESU=${BESU:-${BESU_VERSOES%% *}}
_var="BESU_IMAGEM_${BESU//./_}"
BESU_IMAGEM="${!_var:-}"
FORMATO=${FORMATO:-BONSAI}
ESPERAS_MIN=${ESPERAS_MIN:-"2 5 15 30 60 120"}
LIMITE_ORFA=${LIMITE_ORFA:-60}         # segundos sem "Starting download pipeline" para declarar a tentativa órfã
INTERVALO_CARGA=${INTERVALO_CARGA:-8}  # segundos entre transações da carga de fundo
PID_CARGA=""

finalizar() {
  local rc=$?
  # Saída fora de abortar() antes do fim (ex.: variável não definida com set -u): conta como aborto,
  # para que o relatório não declare sucesso com testes que nem chegaram a rodar.
  if [ "$rc" -ne 2 ] && [ "${CONCLUIDA:-0}" != 1 ]; then
    jq -cn --arg t "$(agora)" --arg d "execução interrompida antes do fim (código de saída $rc)" \
      '{tipo:"aborto", instante:$t, motivo:$d}' >> "$EXEC_DIR/fatos.jsonl"
    rc=2
  fi
  [ "$NO_GITHUB" = "true" ] && echo "::endgroup::"
  echo; echo "── Finalização ────────────────────────────────────────────────────"
  [ -n "$PID_CARGA" ] && kill "$PID_CARGA" 2>/dev/null && echo "  · carga de transações encerrada"
  if [ -f "$SN/docker-compose.yml" ]; then
    mkdir -p "$EXEC_DIR/nos"
    (cd "$SN" && docker compose unpause $NOS >/dev/null 2>&1)
    for n in $NOS; do
      (cd "$SN" && docker compose logs --timestamps "$n" > "$EXEC_DIR/nos/$n-console.log" 2>&1)
      [ -d "$SN/volumes/$n/logs" ] && cp -r "$SN/volumes/$n/logs" "$EXEC_DIR/nos/$n-arquivos"
    done
    echo "  · logs dos nós guardados em execucoes/$EXEC_ID/nos/"
    if [ "${MANTER_REDE:-0}" = "1" ]; then
      echo "  · MANTER_REDE=1: rede mantida de pé (projeto $COMPOSE_PROJECT_NAME, portas $PORTA_VALIDATOR a $PORTA_VALIDATOR4)"
    else
      (cd "$SN" && docker compose down -v >/dev/null 2>&1)
      echo "  · rede derrubada"
      rm -rf "$TRAB" 2>/dev/null && echo "  · pasta de trabalho removida (evidências preservadas)"
    fi
  fi
  bash "$RAIZ/lib/relatorio.sh" "$EXEC_DIR" > "$EXEC_DIR/resumo.md"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$EXEC_DIR/resumo.md" >> "$GITHUB_STEP_SUMMARY"
  local total ok obs reproduzido
  total=$(jq -s '[.[] | select(.observacao != true)] | length' "$EXEC_DIR/verificacoes.jsonl")
  ok=$(jq -s '[.[] | select(.observacao != true and .ok)] | length' "$EXEC_DIR/verificacoes.jsonl")
  obs=$(jq -s '[.[] | select(.observacao == true)] | length' "$EXEC_DIR/verificacoes.jsonl")
  reproduzido=$(jq -r 'select(.tipo=="fato" and .chave=="resultado.reproduzido") | .valor' "$EXEC_DIR/fatos.jsonl" | tail -1)
  echo
  echo "════════════════════════════════════════════════════════════════════"
  if [ "$rc" -eq 2 ]; then
    echo "  EXECUÇÃO ABORTADA: $ok de $total verificações passaram antes da interrupção"
  elif [ "$ok" = "$total" ]; then
    echo "  RESULTADO: todas as $total verificações passaram"
  else
    echo "  RESULTADO: $((total - ok)) de $total verificações FALHARAM"; rc=1
  fi
  [ -n "$reproduzido" ] && echo "  TRAVAMENTO DO SYNC REPRODUZIDO: $reproduzido"
  [ "$obs" -gt 0 ] && echo "  + $obs observação(ões) do experimento (ver relatório; não contam como falha)"
  echo "  relatório: execucoes/$EXEC_ID/resumo.md"
  echo "════════════════════════════════════════════════════════════════════"
  exit "$rc"
}
trap finalizar EXIT

echo "Bancada do travamento do full sync do Besu: execução $EXEC_ID"
[ -n "$BESU_IMAGEM" ] || abortar "BESU=$BESU não está em versoes.env (opções: $BESU_VERSOES)"
case "$FORMATO" in BONSAI|FOREST) ;; *) abortar "FORMATO=$FORMATO inválido (BONSAI ou FOREST)" ;; esac
for f in fases/00-preparar.sh fases/01-rede.sh testes/T01-tentativas-em-regime.sh; do
  source "$RAIZ/$f"
done
CONCLUIDA=1
