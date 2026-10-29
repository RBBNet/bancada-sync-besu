#!/usr/bin/env bash
# T-01: tentativas de sync com os nós em regime.
#
# Hipótese (dos logs da rede real): numa tentativa de sync isolada, feita com o nó em regime há algum
# tempo, o laço do full sync morre logo depois de "Found common ancestor", antes de "Starting download
# pipeline", sem WARN nem ERROR. As tentativas logo depois de um restart funcionam.
#
# Para cada espera de ESPERAS_MIN: deixa a rede em regime durante a espera (vigiando tentativas
# espontâneas), provoca um atraso curto nos alvos (docker pause até a rede andar alguns blocos) e
# classifica a tentativa de cada alvo: ok (o download começou), órfã (assinatura do travamento) ou
# sem tentativa. Na primeira órfã, tira thread dumps e demonstra a consequência: com o laço morto, um
# atraso de mais de 30 blocos não se recupera, porque a propagação de blocos só cobre 30.

fase "T-01: tentativas de sync com os nós em regime"
ESTADO_ATUAL="E0"
DEGRAUS=${DEGRAUS:-"2 2 2 5 5 35"}   # blocos de atraso, em escalada, até cada alvo registrar uma tentativa
ORFAS=""                              # alvos com tentativa órfã
REFERENCIA=""                         # instante (epoch) desde o qual as tentativas contam

# registrar_tentativa <rótulo> <espera-min> <nó> <resultado> <laço-json> <provocação>
registrar_tentativa() {
  jq -cn --arg t "$(agora)" --arg r "$1" --argjson e "$2" --arg no "$3" --arg res "$4" --argjson laco "$5" --arg prov "$6" \
    '{instante:$t, rotulo:$r, espera_min:$e, no:$no, resultado:$res, provocacao:$prov, laco:$laco}' >> "$EXEC_DIR/tentativas.jsonl"
}

# vigiar <segundos>: espera em regime, conferindo a cada 30 s se algum alvo teve tentativa órfã espontânea
vigiar() {
  local fim=$((SECONDS + $1)) no
  while (( SECONDS < fim )); do
    sleep $(( fim - SECONDS < 30 ? (fim - SECONDS > 0 ? fim - SECONDS : 1) : 30 ))
    for no in $ALVOS; do
      if [ "$(laco "$no" "$REFERENCIA" | jq '.orfas | length')" -gt 0 ]; then
        info "tentativa espontânea órfã em $no durante a espera"
        return 0
      fi
    done
  done
}

# provocar: escala o atraso até cada alvo registrar uma tentativa nova desde $REFERENCIA. Imprime o resumo.
provocar() {
  local pendentes="$ALVOS" n s no resto resumo=""
  for n in $DEGRAUS; do
    s=$(atrasar "$n" $pendentes)
    resumo="$resumo ${n}b/${s}s[$(echo $pendentes | tr ' ' ',')]"
    sleep 20
    resto=""
    for no in $pendentes; do
      [ "$(laco "$no" "$REFERENCIA" | jq .tentativas)" -gt 0 ] || resto="$resto $no"
    done
    pendentes=$(echo $resto)
    [ -z "$pendentes" ] && break
  done
  echo "${resumo# }"
}

# tentativa <rótulo> <espera-min>: espera em regime, provoca e classifica cada alvo
tentativa() {
  local rotulo="$1" espera="$2" prov r res no
  ULTIMA="$rotulo, após $espera min em regime"
  passo "Tentativa $rotulo: ${espera} min em regime e depois atraso nos alvos ($ALVOS)"
  REFERENCIA=$(date +%s)
  vigiar $((espera * 60))
  prov="(nenhuma: tentativa espontânea)"
  if [ -z "$(for no in $ALVOS; do laco "$no" "$REFERENCIA" | jq -r 'select((.orfas | length) > 0) | "x"'; done)" ]; then
    prov=$(provocar)
    info "provocação (blocos/segundos congelados[nós]): $prov"
  fi
  sleep $((LIMITE_ORFA + 10))
  for no in $ALVOS; do
    r=$(laco "$no" "$REFERENCIA")
    if [ "$(jq '.orfas | length' <<<"$r")" -gt 0 ]; then res="ORFA"; ORFAS="$ORFAS $no"
    elif [ "$(jq .tentativas <<<"$r")" -gt 0 ]; then res="OK"
    else res="SEM_TENTATIVA"; fi
    info "$no: $res $(jq -c '{tentativas, pipelines, orfas, silencio_s, bft_paradas, bft_partidas}' <<<"$r")"
    registrar_tentativa "$rotulo" "$espera" "$no" "$res" "$r" "$prov"
  done
  ORFAS=$(echo $ORFAS)
  # os alvos voltam a acompanhar a rede antes da próxima espera (se o laço estiver vivo)
  [ -n "$ORFAS" ] || esperar_ate "alvos voltarem a acompanhar o boot" 120 acompanha "$PORTA_BOOT" $(for no in $ALVOS; do porta "$no"; done) || true
}

k=0
for espera in $ESPERAS_MIN; do
  k=$((k + 1))
  tentativa "$k" "$espera"
  [ -n "$ORFAS" ] && break
done
if [ -z "$ORFAS" ]; then
  # Controle: atraso de mais de 30 blocos só no validator. Com o laço vivo, ele se recupera pelo full sync
  # (a propagação não cobre mais de 30 blocos); é também mais uma tentativa em regime.
  DEGRAUS="35" ALVOS="validator" tentativa "controle" 0
fi

passo "Resumo das tentativas"
resultados() { jq -r --arg no "$1" 'select(.no == $no) | .resultado' "$EXEC_DIR/tentativas.jsonl"; }
todos_tentaram() { local no; for no in $ALVOS; do [ -n "$(resultados "$no" | grep -v SEM_TENTATIVA)" ] || return 1; done; }
for no in $ALVOS; do
  fato "tentativas.$no" "$(resultados "$no" | sort | uniq -c | awk '{printf "%s%s=%s", (NR>1?" ":""), $2, $1}')"
done
verificar_que T01-01 "o gatilho exercita o caminho suspeito: cada alvo registrou ao menos uma tentativa de sync" \
  "ao menos uma tentativa OK ou ORFA em cada alvo" \
  "$(for no in $ALVOS; do printf '%s: %s; ' "$no" "$(resultados "$no" | tr '\n' ' ')"; done)" todos_tentaram

if [ -n "$ORFAS" ]; then
  fato resultado.reproduzido "SIM, em: $ORFAS (tentativa $ULTIMA)"
  for no in $ORFAS; do
    passo "Thread dumps de $no (3, com 10 s de intervalo) e do boot, para comparação"
    for i in 1 2 3; do
      if tirar_dump "$no" "travado-$i"; then info "dumps/$no-travado-$i.txt"; else info "dump $i de $no falhou"; fi
      [ "$i" -lt 3 ] && sleep 10
    done
    tirar_dump boot referencia >/dev/null || true
    verificar_que T01-02 "thread dumps de $no gravados" "3 arquivos com \"Full thread dump\"" \
      "$(grep -l 'Full thread dump' "$EXEC_DIR"/dumps/"$no"-travado-*.txt 2>/dev/null | wc -l | tr -d ' ') arquivo(s)" \
      test "$(grep -l 'Full thread dump' "$EXEC_DIR"/dumps/"$no"-travado-*.txt 2>/dev/null | wc -l)" -eq 3
    r=$(laco "$no" "$REFERENCIA")
    reproduzir_defeito "travamento do full sync após Found common ancestor" T01-03 \
      "$no: o laço do full sync morre depois de \"Found common ancestor\", sem \"Starting download pipeline\"" \
      "tentativa órfã e laço em silêncio" \
      "$([ "$(jq '.orfas | length' <<<"$r")" -gt 0 ] && echo "tentativa órfã" || echo "sem órfã") e $([ "$(jq '.silencio_s // 0' <<<"$r")" -ge "$LIMITE_ORFA" ] && echo "laço em silêncio" || echo "laço ativo")" \
      "$(jq -c . <<<"$r")"

    passo "Consequência em $no: atraso de mais de 30 blocos com o laço morto"
    s=$(atrasar 35 "$no")
    info "$no congelado por ${s}s enquanto a rede andou 35 blocos"
    sleep 120
    atraso=$(( $(bloco_atual "$PORTA_BOOT") - $(bloco_atual "$(porta "$no")") ))
    reproduzir_defeito_que "travamento do full sync após Found common ancestor" T01-04 \
      "$no: com o laço morto, o nó atrasado mais de 30 blocos não volta a acompanhar a rede" \
      "mais de 30 blocos atrás 120 s depois" "$atraso blocos atrás" test "$atraso" -gt 30
    tirar_dump "$no" "apos-atraso-longo" >/dev/null || true
  done
  estado E1 "laço do full sync morto em: $ORFAS"
else
  fato resultado.nao_reproduzido "em $k tentativa(s) e no controle (esperas: $ESPERAS_MIN min)"
  observar T01-03 "travamento do full sync após Found common ancestor" "reproduzido" "não reproduzido"
  if acompanha "$PORTA_BOOT" "$PORTA_VALIDATOR"; then rec=sim; else rec=não; fi
  verificar T01-04 "com o laço vivo, o validator atrasado 35 blocos volta a acompanhar a rede pelo full sync" "sim" "$rec" \
    "$(jq -c 'select(.rotulo == "controle") | .laco' "$EXEC_DIR/tentativas.jsonl")"
fi
