# Bancada do travamento do full sync do Besu

Reprodução automatizada, verificável por terceiros, de um travamento do **full sync** do
[Hyperledger Besu](https://github.com/besu-eth/besu) numa rede QBFT montada no padrão da Rede
Blockchain Brasil (RBB).

## O defeito investigado

Num nó Besu 25.5.0 (QBFT, full sync, Bonsai), o laço de sincronização morre em silêncio:

1. O laço procura um par à frente a cada 5 s (`Waiting for peer matching filter`, em DEBUG).
2. Quando encontra, determina o ancestral comum e registra `Found common ancestor with peer ... at block N`.
3. O passo seguinte deveria registrar `Starting download pipeline for sync target ...`. Essa linha
   nunca aparece. Não há WARN nem ERROR, e o laço não volta a rodar até o nó ser reiniciado.

Enquanto o atraso for pequeno, o nó continua acompanhando a rede pela propagação de blocos, que só
cobre anúncios até 30 blocos à frente. Por isso o defeito passa despercebido. Quando o nó atrasa
mais de 30 blocos (uma queda de rede de alguns minutos, por exemplo), ele para de vez. Num
validador, isso o tira do consenso.

Nos logs observados, toda tentativa de sync **isolada**, feita com o nó em regime havia horas ou
dias, travou. As tentativas feitas em sequência logo depois de um restart funcionaram. O ponto
exato da trava só se descobre com um thread dump do nó travado, e é isso que esta bancada busca.

## Como a bancada funciona

1. **Monta a rede** com o [start-network](https://github.com/RBBNet/start-network) da RBB num commit
   fixado: 4 validadores, boot e writer, Besu fixado por digest, gênesis e chaves sintéticos.
2. **Liga uma carga leve de transações** (uma a cada 8 s), de contas aleatórias novas.
3. **Faz tentativas de sync com os nós em regime.** Para cada espera de `ESPERAS_MIN` (padrão
   2, 5, 15, 30, 60 e 120 min), deixa a rede quieta durante a espera e depois congela os nós-alvo
   (`docker pause`) até a rede andar alguns blocos. Ao voltar, cada alvo faz uma tentativa de sync.
   Os alvos são o `validator` e, como comparação, o `writer`, que não é validador.
4. **Classifica cada tentativa** lendo o log DEBUG do nó: `ok` (o download começou), `órfã` (a
   assinatura do travamento) ou `sem tentativa` (o atraso foi coberto pela propagação).
5. **Na primeira órfã, tira 3 thread dumps** do nó travado, com 10 s de intervalo, e um do boot
   para comparação. Depois atrasa o nó travado em 35 blocos e confirma que ele não se recupera.
6. **Se nada travar**, faz um controle: atrasa o validador em 35 blocos e confirma que, com o laço
   vivo, ele se recupera.

### Thread dump sem derrubar o nó

O sinal tem que ir para o processo Java, cujo PID o Besu grava em `/tmp/pid`:

```bash
docker compose exec <nó> bash -c 'kill -QUIT "$(cat /tmp/pid)"'
docker compose logs --since <instante-de-antes> <nó> > dump.txt
```

`docker kill -s QUIT <contêiner>` **não serve**: quando o contêiner roda como root, o PID 1 é o
`su` do `besu-entry.sh` da imagem, que converte o SIGQUIT em SIGTERM e derruba o nó. A bancada
testa o procedimento no início de toda execução (verificações D-01 e D-02).

## Regra de dados: somente dados sintéticos

Este repositório é público. Por isso:

- **Usamos apenas dados sintéticos e descartáveis:** chaves de nós geradas a cada execução e contas
  aleatórias criadas na hora para a carga de transações.
- **É proibido incluir qualquer informação da mainnet ou da testnet da RBB:** enodes, IPs, portas,
  contas, arquivos de gênesis reais e listas de nós ou de participantes. Isso vale também para
  trechos de logs desses nós.
- **É proibido copiar ou referenciar conteúdo de repositórios privados.**
- **Nenhum segredo real.**

O histórico do Git é permanente: apagar um arquivo não o remove do histórico. Na dúvida, não faça
o commit. O repositório tem varredura automática de segredos (gitleaks) a cada push.

## Como executar

**Na sua máquina:** requer Docker (com Compose), Node.js 20+, git, jq, curl e python3.

```bash
./executar.sh                          # Besu 25.5.0, Bonsai, esperas de 2 a 120 min (cerca de 4 h)
ESPERAS_MIN="1 3" ./executar.sh        # rodada curta, para desenvolvimento
BESU=25.12.0 ./executar.sh             # versão recente, para saber se o defeito persiste
FORMATO=FOREST ./executar.sh           # controle com Forest
MANTER_REDE=1 ./executar.sh            # mantém a rede de pé ao final (RPC nas portas 20101 a 20106)
```

Cada execução gera `execucoes/<data-hora>/`, com o relatório `resumo.md` e todas as evidências.
O código de saída é 0 se todas as verificações passarem, com ou sem reprodução do defeito; o
resultado do experimento aparece no topo do relatório.

**No GitHub:** aba *Actions* → *Bancada* → *Run workflow*, escolhendo a versão do Besu, o formato de
armazenamento e as esperas. A página da execução mostra o log de cada passo e o resumo; as
evidências ficam anexadas como artefato.

## Verificações

| ID | O que confere |
|---|---|
| G-01, G-02 | chainId e parâmetros do QBFT do gênesis gerado pelo start-network |
| E0-01 a E0-03 | versão do Besu, formato de armazenamento e modo de sincronização (full) |
| E0-04, E0-05 | malha completa (5 pares por nó) e produção de blocos |
| E0-06 | o log da bancada registra o laço do full sync (sem isso o detector não enxerga nada) |
| E0-07 | as transações da carga entram em blocos |
| D-01, D-02 | o procedimento de thread dump funciona e não derruba o nó |
| T01-01 | o gatilho exercita o caminho suspeito: cada alvo fez ao menos uma tentativa de sync |
| T01-02 a T01-04 | se travou: dumps gravados, assinatura confirmada e nó que não se recupera de um atraso de 35 blocos. Se não travou: controle em que o validador se recupera |

Toda diferença deliberada em relação ao roteiro oficial da RBB é impressa na execução como
"DESVIO DO ROTEIRO" e listada no relatório.

## Estado

Em construção. A primeira meta é reproduzir o travamento no Besu 25.5.0 e obter o thread dump.
Depois: rodar na 25.12.0 e, com o dump em mãos, abrir a issue no repositório do Besu.

## Licença

[GPL-3.0](LICENSE), a mesma da bancada-plugin-permissionamento.
