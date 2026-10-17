# Fluidez da bancada espacial — 17/10/2026

## Evidência física recebida

O operador observou uma primeira tentativa parada em RELOCALIZING, seguida de TRACKING ao fechar e iniciar novamente. O trajeto era desenhado, mas abrir 4B e digitar Origem ficaram lentos; a interface acabou respondendo. Parar e iniciar novo mapa voltaram a funcionar. Origem e Destino já tinham sido confirmados pelo operador em um teste anterior; não devem ser tratados como cadastro inexistente.

O log do Xcode recebido contém 456 linhas `HTTP load failed` e tentativas repetidas de abrir a sessão do serviço de corpo indisponível. Registra lançamento dos processos WebKit GPU (~6,99 s), WebContent (~7,05 s), Networking (~10,46 s) e uma ocorrência de `processDidBecomeUnresponsive`. Não contém diagnóstico ARKit de relocalização nem série térmica. Isso identifica trabalho e atrasos evitáveis; não demonstra uma causa única da lentidão ou do RELOCALIZING. O log completo e dados pessoais não fazem parte deste commit.

## Alterações

- Quadros espaciais entram em AsyncStream com capacidade de um quadro pendente, substituído pelo mais recente. Um consumidor substitui a criação de uma Task de interface por quadro. Publicação limitada a 2 Hz; isso não reduz a frequência interna do ARKit.
- Snapshot, trajeto e métricas publicam em um objeto observado apenas pelas pequenas regiões de telemetria/mapa. O Form editável não observa esses quadros. Confirmação de cadastro não é apagada pelo próximo quadro normal. Canvas permite desenho assíncrono.
- Novo mapa usa uma ARSession nova com resetTracking/removeExistingAnchors, sem mapa inicial. O delegate só permite tentativa de relocalização após interrupção quando um mapa salvo foi solicitado. Isso não garante que ARKit nunca informe RELOCALIZING em um mapa novo.
- Prazos explícitos: sem primeiro quadro 12 s, primeiro tracking em mapa novo 25 s, referência salva 45 s, recuperação após perda/limitação 20 s. Quadro antigo invalida localização/percurso. Um timeout encerra a sessão com motivo e libera a câmera; mantém os lugares históricos e não inventa uma referência válida nem apaga o arquivo salvo.
- HUD nativo admite uma observação de corpo por vez. Falhas usam intervalos de 1, 2, 4, 8, 15 e 30 s. Sucesso permite nova consulta após 0,5 s; cache limitado a 0,75 s, descartado em falha, cancelamento, resposta lenta e comando/recuperação. Respostas anteriores a comando não repovoam o cache.
- STOP/ESTOP, comandos explícitos e recuperação não passam pelo espaçamento de observação. NativeBodyCore e suas condições de segurança não foram alterados. A IA nativa continua independente do corpo.
- WKWebView deixa de ser criado no init do player. Inicialização ociosa, pausa em background, título vazio, encerramento e cancelamento sem player não criam WebKit. A reprodução real ainda cria o player quando necessário.
- Diagnóstico espacial exportado inclui contagem de quadros aceitos e último/pior atraso de entrega. O atraso mede timestamp do quadro até admissão no MainActor; não é uma medida completa de latência do toque/renderização.

Não muda firmware, GPIO, sensores, motores, autoridade de movimento, memória pessoal, modelos pagos, aquisição visual ou bloqueio térmico. O corpo permanece indisponível para navegação física. Classificação automática de cômodos, mapa integral do apartamento e navegação autônoma continuam pendentes.

## Verificação

Veja PORTABLE_RESULTS.txt para resultados e limitações. O instalador executa a validação completa do aplicativo no Mac: standalone, Debug/Release e ciclo simulado. Ele não instala no XR, não faz flash, não envia comandos físicos, não publica commits e não altera banco pessoal. A aceitação física está em ACEITACAO_XR.md.
