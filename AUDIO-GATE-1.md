# Gate 1 — XR Audio

## Status e entrada

EM IMPLEMENTAÇÃO — build e regressão PASS; aceitação de áudio ao vivo PENDENTE.
Implementação inicial em 20/09/2026 no app XR. Checkpoint Git local do app: 2da6b0d. Core sem alterações funcionais.

## Objetivo e escopo

Ouvir fala e reproduzir resposta no XR, com estados verdadeiros no HUD.

## Arquivos previstos, baseados na inspeção

XR: MyApp/TarsHUDViewModel.swift, TarsHUDView.swift, MyApp.swift; TARSXR.xcodeproj/project.pbxproj. Core: src/tars/hud.py, http_api.py, local_service.py; tests/test_hud_rc3.py.
Os caminhos Core são relativos a `/Users/guzzfuzz/TARS-RC3/tars-core`; XR a `/Users/guzzfuzz/Documents/TARSXR`. São candidatos, não autorização para substituir indiscriminadamente arquivos. Novos arquivos/testes serão nomeados e registrados durante o gate; não são apresentados como existentes.

## Implementação planejada

Adicionar captura/permissões, início/fim de fala, transcrição e TTS com resposta controlada offline; definir contrato autenticado de turno antes de adicionar endpoint. Estados IDLE/LISTENING/THINKING/SPEAKING devem refletir eventos reais. Cancelar captura/TTS ao encerrar sessão. Novos serviços Swift de áudio e testes terão nomes definidos na implementação dentro de MyApp, não existem hoje.

## Testes

Executar a suíte completa com `.venv/bin/python -m pytest -q` no Core, preservar os 63 testes originais e acrescentar os casos deste gate. Compilar e executar o app quando houver alteração Swift.
Testar permissão aceita/negada, silêncio, cancelamento, interrupção e retorno de TTS; validar HUD e falha do Core. Registrar limitações de áudio do Simulator; entrada e saída reais ficam também na aceitação do Gate 7.

## Critérios PASS / FAIL

PASS: Uma fala produz uma resposta controlada audível e estados coerentes, sem comando de movimento; negativa de permissão mantém app utilizável. Regressão mínima e testes do gate todos aprovados, evidência e backup identificados.
FAIL: qualquer regressão, crash, estado fictício, desvio de safety ou critério acima não atendido. Teste não executado mantém PENDENTE, nunca PASS. Não avançar gate.

## Rollback

Remover apenas integração de áudio do gate e restaurar fontes/configuração salvas; retornar AUDIO UNAVAILABLE e polling HUD RC3.
Restaurar somente alterações do gate a partir do backup registrado; preservar trabalho alheio e dados. Reexecutar os 63 testes e aceitação do último gate PASS. Não usar reset destrutivo ou apagar a pasta para recuperar.

## Registro de fechamento a preencher

- Data / responsável: PENDENTE
- Backup ou commit recuperável: PENDENTE
- Arquivos efetivamente alterados: PENDENTE
- Ambiente e comandos de teste: PENDENTE
- Resultado de regressão e testes específicos: PENDENTE
- Evidências de aceitação / falhas: PENDENTE
- Rollback verificado: PENDENTE
- Decisão final PASS/FAIL: PENDENTE


## Execução de 20/09/2026

- Novo MyApp/XRAudioController.swift: Speech pt-BR, AVAudioEngine, permissões, transcrição parcial, pausa de 1,6 s, limite de 20 s e silêncio sem frase de 8 s; cancelamento, background e interrupções; TTS de teste.
- MyApp/TarsHUDView.swift: Falar/Concluir/Cancelar/Testar voz, texto reconhecido e status AUDIO local; amplitude RMS de entrada expande o átomo. TTS altera estado SPEAKING, não mede amplitude de saída.
- TARSXR.xcodeproj/project.pbxproj: descrições de uso de microfone/reconhecimento em Debug e Release.
- Nenhum endpoint Core novo: teste local determinístico de áudio, ainda sem IA e sem despacho de ações.
- Build Debug no iPhone 18 Pro Simulator iOS 27.0: PASS. Core: 63 passed in 0.81s.
- UI comprovou LISTENING, retorno após silêncio sem frase, transcrição real e conclusão do ciclo de TTS com retorno a IDLE; pairing/Core/HUD seguem funcionais.
- Apple e microfone autorizados pelo usuário. Reconhecimento pode enviar fala à Apple; transcrições ficam somente em memória no app, sem persistência adicionada.
- Primeira tentativa TTS foi cancelada; tentativa posterior completou o callback e a UI mostrou teste concluído após transcrição real. Confirmação audível pelo usuário ainda PENDENTE. Não marcar PASS antes da confirmação audível e dos testes de cancelamento/repetição/interrupção.
- Permissão negada e reação de amplitude precisam de validação específica; teste físico continua Gate 7. Aviso SDK: installTap legado depreciado em iOS 27 (mantido por compatibilidade; revisar no hardening).
- Gate 2 permanece BLOQUEADO. Rollback do app: reverter o commit de áudio sobre 2da6b0d, compilar e executar a regressão.
