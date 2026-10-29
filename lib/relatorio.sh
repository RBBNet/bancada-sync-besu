#!/usr/bin/env bash
# Gera o relatório (Markdown) de uma execução a partir de fatos.jsonl, verificacoes.jsonl e tentativas.jsonl.
# Uso: relatorio.sh <diretório-da-execução>
D="$1"
F="$D/fatos.jsonl"; V="$D/verificacoes.jsonl"; T="$D/tentativas.jsonl"
fatov() { jq -r --arg k "$1" 'select(.tipo=="fato" and .chave==$k) | .valor' "$F" | tail -1; }
md() { sed 's/|/\\|/g'; }  # escapa barras verticais para células de tabela

total=$(jq -s '[.[] | select(.observacao != true)] | length' "$V")
ok=$(jq -s '[.[] | select(.observacao != true and .ok)] | length' "$V")
abortos=$(jq -r 'select(.tipo=="aborto") | .motivo' "$F")
reproduzido=$(fatov resultado.reproduzido)
nao_reproduzido=$(fatov resultado.nao_reproduzido)

echo "# Bancada do travamento do full sync do Besu: execução $(basename "$D")"
echo
echo "Besu \`$(fatov experimento.besu)\`, armazenamento \`$(fatov experimento.formato)\`, esperas em regime de \`$(fatov experimento.esperas_min)\` min."
echo
if [ -n "$reproduzido" ]; then
  echo "**🐞 Travamento reproduzido** $reproduzido. Thread dumps em \`dumps/\`."
elif [ -n "$nao_reproduzido" ]; then
  echo "**Travamento não reproduzido** $nao_reproduzido."
fi
echo
if [ -n "$abortos" ]; then
  echo "**❌ EXECUÇÃO ABORTADA:** $abortos"
elif [ "$ok" = "$total" ]; then
  echo "**✅ Todas as $total verificações passaram.**"
else
  echo "**❌ $((total - ok)) de $total verificações falharam.**"
fi
echo
echo "## Tentativas de sync"
echo
echo "| Tentativa | Regime antes (min) | Nó | Resultado | Provocação (blocos/segundos congelados[nós]) | Tentativas / pipelines | Paradas / partidas do BFT |"
echo "|---|---|---|---|---|---|---|"
jq -r '"| \(.rotulo) | \(.espera_min) | \(.no) | \(if .resultado == "ORFA" then "🐞 ÓRFÃ" elif .resultado == "OK" then "ok" else "sem tentativa" end) | \(.provocacao) | \(.laco.tentativas) / \(.laco.pipelines) | \(.laco.bft_paradas) / \(.laco.bft_partidas) |"' "$T" 2>/dev/null
echo
echo "ÓRFÃ = \"Found common ancestor\" sem \"Starting download pipeline\" depois, em $(fatov experimento.limite_orfa_s) s: a assinatura do travamento."
echo
echo "## Ambiente"
echo
echo "| Item | Valor |"
echo "|---|---|"
for k in bancada.commit bancada.alteracoes_locais ambiente.executor ambiente.sistema ambiente.arquitetura ambiente.cpus ambiente.docker ambiente.docker_compose ambiente.node imagem.besu imagem.rbb_cli repositorio.start-network; do
  v=$(fatov "$k"); [ -n "$v" ] && echo "| $k | \`$(echo "$v" | md)\` |"
done
echo
echo "## Estados da rede"
echo
echo "| Estado | Desde o bloco | Descrição |"
echo "|---|---|---|"
jq -r 'select(.tipo=="estado") | "| **\(.estado)** | \(.bloco) | \(.descricao) |"' "$F"
echo
echo "## Verificações"
echo
echo "| | ID | Estado | Verificação | Esperado | Obtido |"
echo "|---|---|---|---|---|---|"
jq -r 'def c: tostring | gsub("\\|"; "¦"); "| \(if .observacao then "🔎" elif (.defeito // "") != "" and .ok then "🐞" elif .ok then "✅" else "❌" end) | \(.id) | \(.estado) | \(.descricao|c) | \(.esperado|c) | \(.obtido|c) |"' "$V"
echo
echo "🐞 = defeito reproduzido (o esperado é o comportamento defeituoso)."
echo "🔎 = resultado do experimento registrado sem contar como falha da execução."
echo
echo "## Desvios deliberados em relação ao roteiro oficial da RBB"
echo
jq -r 'select(.tipo=="desvio") | "- \(.descricao)"' "$F"
echo
echo "## Fatos registrados"
echo
echo "| Chave | Valor |"
echo "|---|---|"
jq -r 'select(.tipo=="fato") | "| \(.chave) | `\(.valor)` |"' "$F" | grep -v -E '\| (ambiente|imagem|repositorio|bancada)\.'
echo
echo "## Arquivos desta execução"
echo
echo "- \`tentativas.jsonl\`: cada tentativa com o resumo do laço de sync de cada nó"
echo "- \`dumps/\`: thread dumps (o teste inicial do procedimento e, se houve travamento, os do nó travado e do boot)"
echo "- \`verificacoes.jsonl\`, \`fatos.jsonl\`: verificações e fatos, com horário (UTC)"
echo "- \`carga.jsonl\`: transações enviadas pela carga de fundo"
echo "- \`comandos/\`: saída completa de cada comando executado"
echo "- \`nos/\`: logs dos nós Besu (console e arquivos, incluindo \`besu_bancada.log\` com o DEBUG do sync)"
echo "- \`genesis.json\`, \`infra.json\`, \`docker-compose.yml\`, \`log.xml\`"
