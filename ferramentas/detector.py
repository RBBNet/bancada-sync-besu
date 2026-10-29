"""Resume o laço do full sync de um nó Besu a partir do besu_bancada.log (DEBUG, com logger e thread).

Uso: detector.py <arquivo-de-log> <desde-epoch> <agora-epoch> <limite-orfa-s>

Uma tentativa de sync é a linha "Found common ancestor". Ela é órfã quando nenhuma linha
"Starting download pipeline" vem depois dela (antes da próxima tentativa) e já passou o limite.
É a assinatura do travamento: o laço morre entre as duas linhas, sem WARN nem ERROR.

Saída (JSON, uma linha):
  tentativas, pipelines, orfas, pendentes  contados a partir de <desde>
  ultimo_laco, silencio_s                  última linha do laço (de todo o arquivo lido) e há quanto tempo
  bft_paradas, bft_partidas                paradas e partidas do coordenador BFT a partir de <desde>
"""
import json
import os
import re
import sys
from datetime import datetime

LINHA = re.compile(r'^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d{4}) ')
EVENTOS = [
    ('ancestral', 'Found common ancestor with peer'),
    ('pipeline', 'Starting download pipeline'),
    ('espera', 'Waiting for peer matching filter'),
    ('par', 'Found peer matching filter'),
    ('em_dia', 'Caught up to best peer'),
    ('melhor_par', 'Best peer:'),
    ('bft_para', 'Stopping BFT mining coordinator'),
    ('bft_volta', 'Starting BFT mining coordinator'),
]
LACO = {'ancestral', 'pipeline', 'espera', 'par', 'em_dia', 'melhor_par'}
LEITURA_MAX = 64 * 1024 * 1024  # só o fim do arquivo; o laço registra algo a cada 5 s


def iso(t):
    return datetime.fromtimestamp(t).astimezone().isoformat(timespec='milliseconds')


def ler_eventos(arquivo):
    eventos = []
    if not os.path.exists(arquivo):
        return eventos
    with open(arquivo, 'rb') as f:
        f.seek(0, os.SEEK_END)
        f.seek(max(0, f.tell() - LEITURA_MAX))
        for bruta in f:
            linha = bruta.decode('utf-8', 'replace')
            m = LINHA.match(linha)
            if not m:
                continue
            for tipo, texto in EVENTOS:
                if texto in linha:
                    t = datetime.strptime(m.group(1), '%Y-%m-%dT%H:%M:%S.%f%z').timestamp()
                    eventos.append((t, tipo))
                    break
    return eventos


def main():
    arquivo, desde, agora, limite = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
    eventos = ler_eventos(arquivo)
    recentes = [e for e in eventos if e[0] >= desde]
    ancestrais = [t for t, tipo in recentes if tipo == 'ancestral']
    pipelines = [t for t, tipo in recentes if tipo == 'pipeline']
    orfas, pendentes = [], []
    for i, t in enumerate(ancestrais):
        proxima = ancestrais[i + 1] if i + 1 < len(ancestrais) else float('inf')
        if any(t <= p < proxima for p in pipelines):
            continue
        (orfas if agora - t > limite else pendentes).append(iso(t))
    laco = [t for t, tipo in eventos if tipo in LACO]
    print(json.dumps({
        'tentativas': len(ancestrais),
        'pipelines': len(pipelines),
        'orfas': orfas,
        'pendentes': pendentes,
        'ultimo_laco': iso(laco[-1]) if laco else None,
        'silencio_s': round(agora - laco[-1]) if laco else None,
        'bft_paradas': sum(1 for _, tipo in recentes if tipo == 'bft_para'),
        'bft_partidas': sum(1 for _, tipo in recentes if tipo == 'bft_volta'),
    }))


if __name__ == '__main__':
    main()
