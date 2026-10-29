#!/usr/bin/env bash
# Funções para observar o laço do full sync, provocar atrasos e tirar thread dumps dos nós.

# porta <nó>: porta RPC do nó no host
porta() {
  case "$1" in
    validator) echo "$PORTA_VALIDATOR" ;; boot) echo "$PORTA_BOOT" ;; writer) echo "$PORTA_WRITER" ;;
    validator2) echo "$PORTA_VALIDATOR2" ;; validator3) echo "$PORTA_VALIDATOR3" ;; validator4) echo "$PORTA_VALIDATOR4" ;;
    *) abortar "nó desconhecido: $1" ;;
  esac
}

# laco <nó> <desde-epoch>: resumo JSON do laço de sync do nó a partir do instante (ver ferramentas/detector.py)
laco() {
  python3 "$RAIZ/ferramentas/detector.py" "$SN/volumes/$1/logs/besu_bancada.log" "$2" "$(date +%s)" "$LIMITE_ORFA"
}

# atrasar <blocos> <nó>...: congela os nós (docker pause) até a rede avançar <blocos> blocos, medidos
# no boot, e os descongela. Imprime quantos segundos ficaram congelados.
atrasar() {
  local n="$1"; shift
  local b0 b inicio=$SECONDS
  b0=$(bloco_atual "$PORTA_BOOT")
  (cd "$SN" && docker compose pause "$@") >/dev/null 2>&1
  while :; do
    sleep 1
    b=$(bloco_atual "$PORTA_BOOT")
    [ -n "$b" ] && [ -n "$b0" ] && [ $((b - b0)) -ge "$n" ] && break
    (( SECONDS - inicio >= 900 )) && break   # trava de segurança: a rede deveria seguir sem os nós congelados
  done
  (cd "$SN" && docker compose unpause "$@") >/dev/null 2>&1
  echo $((SECONDS - inicio))
}

# tirar_dump <nó> <rótulo>: thread dump da JVM sem derrubar o nó, gravado em dumps/<nó>-<rótulo>.txt.
# O sinal vai para o PID do Java, que o Besu grava em /tmp/pid, e não para o PID 1 do contêiner:
# quando o contêiner roda como root, o PID 1 é o su do besu-entry.sh, que converte o SIGQUIT em
# SIGTERM e derruba o nó (docker kill -s QUIT faz isso).
tirar_dump() {
  local no="$1" rotulo="$2" arq desde
  mkdir -p "$EXEC_DIR/dumps"
  arq="$EXEC_DIR/dumps/$no-$rotulo.txt"
  desde=$(agora)
  (cd "$SN" && docker compose exec -T "$no" bash -c 'kill -QUIT "$(cat /tmp/pid)"') >/dev/null 2>&1 || return 1
  sleep 3
  (cd "$SN" && docker compose logs --no-log-prefix --since "$desde" "$no") > "$arq" 2>&1
  grep -q 'Full thread dump' "$arq"
}
