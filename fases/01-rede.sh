#!/usr/bin/env bash
# Fase 01: cria chaves, gênesis e configuração dos nós com o rbb-cli do start-network (roteiro de rede
# de teste da RBB, seções 1 a 3) e sobe a rede inteira: 4 validadores, boot e writer. Confere o
# procedimento de thread dump e liga a carga de transações. Resultado: estado E0.

fase "Fase 01: rede QBFT com 4 validadores, boot e writer (estado E0)"
ESTADO_ATUAL="montagem→E0"
rbbcli() { em "$SN" executar "rbb-cli $*" ./rbb-cli "$@"; }

passo "Roteiro 1.3: chaves dos nós"
rbbcli node create "${NOS// /,}"
for n in $NOS; do fato "no.$n.chave_publica" "$(cat "$SN/.env.configs/nodes/$n/key.pub")"; done
desvio "4 validadores em vez de 1: com 4, a rede continua produzindo blocos (quórum de 3) enquanto um validador está congelado, como na rede real"

passo "Roteiro 1.3: portas RPC no host"
for n in $NOS; do rbbcli config set "nodes.$n.ports+=[\"$(porta "$n"):8545\"]"; done
desvio "portas RPC $PORTA_VALIDATOR a $PORTA_VALIDATOR4 em vez de 10001 em diante, para não colidir com outras redes na mesma máquina"

passo "Roteiro 2.1: genesis.json com os 4 validadores no extraData"
rbbcli genesis create --validators validator,validator2,validator3,validator4
G="$SN/.env.configs/genesis.json"
verificar G-01 "chainId do gênesis" "648629" "$(jq -r .config.chainId "$G")"
verificar G-02 "período de bloco e timeout de rodada do QBFT (s)" "4 8" \
  "$(jq -r '"\(.config.qbft.blockperiodseconds) \(.config.qbft.requesttimeoutseconds)"' "$G")"
cp "$G" "$EXEC_DIR/genesis.json"

passo "Roteiro 2.2: discovery desligado fora do boot; static-nodes"
for n in $NOS; do [ "$n" = boot ] || rbbcli config set "nodes.$n.environment.BESU_DISCOVERY_ENABLED=false"; done
desvio "static-nodes em malha completa (cada nó aponta para todos os outros), e não só para o boot: o nó da rede real tinha vários pares, e o laço de sync escolhe o melhor par entre eles"
for n in $NOS; do
  for m in $NOS; do
    [ "$m" = "$n" ] || echo "enode://$(sed 's/^0x//' "$SN/.env.configs/nodes/$m/key.pub")@$m:30303"
  done | jq -R . | jq -s . > "$SN/volumes/$n/static-nodes.json"
done

passo "Ajustes deliberados em relação ao roteiro"
if [ "$FORMATO" = FOREST ]; then
  desvio "BESU_DATA_STORAGE_FORMAT=FOREST em todos os nós (controle; o padrão do Besu é Bonsai)"
  for n in $NOS; do rbbcli config set "nodes.$n.environment.BESU_DATA_STORAGE_FORMAT=\"FOREST\""; done
fi
desvio "log.xml: console e besu_info.log passam a incluir WARN (o original só grava INFO e ERROR), e o novo besu_bancada.log reúne INFO e acima de todos os loggers com DEBUG do sync, do EthPeers e do coordenador BFT, com logger e thread. É dele que o detector lê o laço do full sync"
python3 - "$SN/.env.configs/log.xml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('<Console name="infoConsole" target="SYSTEM_OUT">\n            <LevelRangeFilter minLevel="INFO" maxLevel="INFO"',
              '<Console name="infoConsole" target="SYSTEM_OUT">\n            <LevelRangeFilter minLevel="WARN" maxLevel="INFO"')
s = s.replace('_info/app-%d{MM-dd-yyyy}-%i.log">\n            <LevelRangeFilter minLevel="INFO" maxLevel="INFO"',
              '_info/app-%d{MM-dd-yyyy}-%i.log">\n            <LevelRangeFilter minLevel="WARN" maxLevel="INFO"')
s = s.replace('\n    </Appenders>', '''
        <RollingFile name="bancadaLog" fileName="${LOG_BASE_PATH}/besu_bancada.log" filePattern="${LOG_BASE_PATH}/bancada/app-%d{MM-dd-yyyy}-%i.log">
            <LevelRangeFilter minLevel="ERROR" maxLevel="DEBUG" onMatch="ACCEPT" onMismatch="DENY" />
            <PatternLayout pattern="%d{yyyy-MM-dd'T'HH:mm:ss.SSSZ} %-5p [%t] %c{1} - %m%n" />
            <Policies><SizeBasedTriggeringPolicy size="100 MB" /></Policies>
            <DefaultRolloverStrategy max="20" />
        </RollingFile>

    </Appenders>''', 1)
todos = ''.join(f'\n            <AppenderRef ref="{a}" />' for a in
                ['infoConsole', 'errorConsole', 'infoLog', 'errorLog', 'debugLog', 'bancadaLog'])
loggers = ''.join(f'''        <Logger name="{nome}" level="debug" additivity="false">{todos}
        </Logger>
''' for nome in ['org.hyperledger.besu.ethereum.eth.sync',
                 'org.hyperledger.besu.ethereum.eth.manager.EthPeers',
                 'org.hyperledger.besu.consensus.common.bft.blockcreation'])
s = s.replace('            <AppenderRef ref="debugLog" />\n        </Root>',
              '            <AppenderRef ref="debugLog" />\n            <AppenderRef ref="bancadaLog" level="info" />\n        </Root>\n' + loggers.rstrip('\n'), 1)
assert s.count('minLevel="WARN" maxLevel="INFO"') == 2 and s.count('ref="bancadaLog"') == 4, "log.xml com formato inesperado"
open(p, 'w').write(s)
PY
cp "$SN/.env.configs/log.xml" "$EXEC_DIR/log.xml"
desvio "imagem do Besu fixada por digest (${BESU_IMAGEM}); o compose usa hyperledger/besu sem versão, o que traria a mais recente"
cat > "$SN/.env" <<EOF
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
IMAGE_BESU=${BESU_IMAGEM}
CPUS_LIMIT_BESU_CONTAINER=2
MEMORY_LIMIT_BESU_CONTAINER=2G
EOF
cp "$SN/infra.json" "$EXEC_DIR/infra.json"

passo "Roteiro 3: renderizar templates e subir a rede"
rbbcli config render-templates
cp "$SN/docker-compose.yml" "$EXEC_DIR/docker-compose.yml"
em "$SN" executar "subir todos os nós" docker compose up -d $NOS
for n in $NOS; do esperar_ate "RPC de $n responder" 180 responde "$(porta "$n")" || abortar "$n não respondeu"; done

CONSOLE=$(cd "$SN" && docker compose logs validator 2>/dev/null)
verificar E0-01 "versão do Besu no validator" "besu/v${BESU}" \
  "$(rpc "$PORTA_VALIDATOR" web3_clientVersion | jq -r .result | cut -d/ -f1-2)"
verificar E0-02 "formato de armazenamento do validator" "$(echo "$FORMATO" | tr 'A-Z' 'a-z')" \
  "$(grep -o 'Data storage: [A-Za-z]*' <<<"$CONSOLE" | head -1 | cut -d' ' -f3 | tr 'A-Z' 'a-z')"
verificar E0-03 "modo de sincronização do validator (padrão quando há arquivo de gênesis)" "full" \
  "$(grep -o 'Sync mode: [A-Za-z_]*' <<<"$CONSOLE" | head -1 | cut -d' ' -f3 | tr 'A-Z' 'a-z')"
malha_completa() { local n; for n in $NOS; do tem_pares "$(porta "$n")" 5 || return 1; done; }
esperar_ate "cada nó conectar aos outros 5" 180 malha_completa
verificar_que E0-04 "malha completa: cada nó com 5 pares" "5 pares em cada nó" \
  "$(for n in $NOS; do printf '%s=%s ' "$n" "$(pares "$(porta "$n")")"; done)" malha_completa
b1=$(bloco_atual "$PORTA_BOOT"); sleep 20; b2=$(bloco_atual "$PORTA_BOOT")
verificar_que E0-05 "rede produz blocos (QBFT, período de 4 s)" "avanço ≥ 4 blocos em 20 s" "$b1 → $b2" \
  test $((b2 - b1)) -ge 4
esperar_ate "todos os nós acompanharem o boot" 60 acompanha "$PORTA_BOOT" $(for n in $NOS; do porta "$n"; done)
fato rede.hash_genesis "$(rpc "$PORTA_BOOT" eth_getBlockByNumber '["0x0",false]' | jq -r .result.hash)"
verificar_que E0-06 "besu_bancada.log do validator registra o laço do full sync" "linha \"Waiting for peer matching filter\" presente" \
  "$(grep -c 'Waiting for peer matching filter' "$SN/volumes/validator/logs/besu_bancada.log" 2>/dev/null || true) linha(s)" \
  grep -q 'Waiting for peer matching filter' "$SN/volumes/validator/logs/besu_bancada.log"

passo "Procedimento de thread dump (o mesmo que se usaria num nó real travado)"
info "docker compose exec <nó> bash -c 'kill -QUIT \"\$(cat /tmp/pid)\"'  e depois  docker compose logs --since <instante> <nó>"
if tirar_dump validator teste-inicial; then d=sim; else d=não; fi
verificar D-01 "o thread dump aparece no log do contêiner" "sim" "$d"
sleep 8
verificar_que D-02 "o validator continua no ar e acompanhando a rede depois do dump" "no máximo 1 bloco atrás do boot" \
  "validator $(bloco_atual "$PORTA_VALIDATOR"), boot $(bloco_atual "$PORTA_BOOT")" acompanha "$PORTA_BOOT" "$PORTA_VALIDATOR"

passo "Carga de transações em segundo plano (1 a cada ${INTERVALO_CARGA} s, enviada ao boot)"
node "$RAIZ/ferramentas/carga.js" "http://localhost:$PORTA_BOOT" "$INTERVALO_CARGA" "$EXEC_DIR/carga.jsonl" &
PID_CARGA=$!
sleep $((INTERVALO_CARGA * 3 + 10))
# txs_recentes: transações nos últimos 6 blocos do boot
txs_recentes() {
  local b i t=0
  b=$(bloco_atual "$PORTA_BOOT")
  for i in 0 1 2 3 4 5; do
    t=$((t + $(rpc "$PORTA_BOOT" eth_getBlockByNumber "[\"$(printf '0x%x' $((b - i)))\",false]" | jq '.result.transactions | length')))
  done
  echo "$t"
}
TXS=$(txs_recentes)
verificar_que E0-07 "transações da carga entram em blocos" "≥ 1 transação nos últimos 6 blocos" \
  "$TXS transação(ões); $(grep -c ENVIADA "$EXEC_DIR/carga.jsonl" 2>/dev/null || true) enviada(s) pela carga" \
  test "$TXS" -ge 1
estado E0 "4 validadores, boot e writer em malha completa; Besu ${BESU}, ${FORMATO}; carga leve de transações"
