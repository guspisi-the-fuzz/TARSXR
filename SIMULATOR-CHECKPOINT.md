# Checkpoint de integração — 25/09/2026

Compatível com Core commit `60b671d` em `../TARS-RC3/tars-core`.
[Registro completo](../TARS-RC3/tars-core/docs/software-integration/XCODE-CHECKPOINT.md).

## Validação

Xcode 27.0 (27A266a), iPhone 18 Pro Simulator iOS 27.0:
- Debug e Release: BUILD SUCCEEDED, sem assinatura/publicação.
- Runner no app real via HTTP: 10 PASS (movimento temporizado, STOP, E-STOP,
  bloqueios, confirmação da geração e recovery sem retomada de movimento).
- Interface: E-STOP bloqueou Mover; recuperação confirmou movimento parado.
- Desconexão: OFFLINE/UNKNOWN, sensores N/A. Reinício do Core: reconexão e
  pairing automáticos, sem reabrir app.
- Regressão Core: 271 PASS. Checks de pronúncia presentes na árvore: 22 PASS.

## Executar

Na raiz do Core:
```sh
PYTHONPATH=src .venv/bin/python -m tars.dev_server --without-ai --port 8770
```
Abrir TARSXR.xcodeproj e rodar scheme TARSXR em Simulator. O scheme compartilhado
configura TARS_CORE_URL=http://127.0.0.1:8770. Os botões Mover 250 ms, Parar,
E-STOP e Confirmar recuperação ficam no botão Painel de Testes, visível abaixo da Cognitive Interface.

Para checks automáticos, habilitar TARS_SIMULATOR_CHECKS=1 no scheme Run →
Arguments → Environment Variables. É opt-in porque envia comandos ao simulador.
O relatório fica em Documents/safety-checks.json do container do app.
Controles e runner são exclusivos de DEBUG + Simulator; não compilam no app físico.
Não há target XCTest. Estes checks são executados pelo app no Simulator.

## Estado preservado e limites

Antes desta tarefa havia alterações locais em MyApp/AudioTestPronunciation.swift
e Tests/AudioTestPronunciationChecks.swift. Foram preservadas e testadas, mas
não incluídas no commit de safety/integração. O build foi feito com essas mudanças
presentes. Áudio ao vivo, IA e gates de visão não foram testados nesta entrega.

Nenhum CAD alterado. Sem push. Não comprova execução no iPhone XR físico:
deployment target continua iOS 27. Avisos existentes de depreciação de áudio e
metadados AppIntents permanecem. Persistência de E-STOP após reinício, cache
limitado e hardware real continuam pendentes no Core.


## Incremento Painel de Testes — 26/09/2026

Base anterior: `55a3a1e`. Painel dedicado com conexão, movimento informado pelo
Core, segurança, último resultado e confirmação explícita de recuperação.
Comandos disponíveis apenas em Debug Simulator e com ESP32 virtual confirmado.
Mover fica indisponível com bloqueio ou comando de movimento/recuperação pendente;
Parar e E-STOP continuam acessíveis durante essas requisições.

Validação: builds Debug/Release aprovados; Play do Xcode abriu a versão nova.
Na UI, recuperação deixou Liberado/Parado; Mover 250 ms registrou EXECUTED;
E-STOP mostrou Bloqueado/Parado e desabilitou Mover. Encerrado com E-STOP ativo.
A consulta de aproximadamente 0,5 s pode não observar um pulso de 250 ms;
o painel explica essa limitação e não simula animação ou contagem regressiva.
Os testes anteriores do Core não foram repetidos neste incremento de interface.

Rollback: reverter somente o commit deste painel com `git revert`, preservando
alterações locais. Não usar reset --hard. Um patch reversível dos dois arquivos
Swift e instruções também estão guardados no workspace TARS HW&SW em
software/rollback/. A verificação inversa do patch passou sem desfazer alterações.
Manter este padrão nos próximos incrementos: preservar funcionalidades validadas,
isolar alterações, validar e registrar um mecanismo de rollback antes da entrega.

## RECOVERY-2 — conexão e diagnóstico

Core correspondente: c0069f9. Reconexão automática com intervalos progressivos
1/2/4/8/15/30 s, teto de 30 s e reset após sucesso. 401 de sessão permite novo
pairing; rejeição de pairing 401/403 pausa tentativas e mostra botão de nova
conexão. Nenhum comando de movimento é repetido automaticamente.
HUD/painel distinguem falha transitória do supervisor, falha persistente e falta
de atualização. Conectar não equivale a liberar bloqueio de segurança.

Validação: ReconnectionPolicyChecks e ClientReconnectionChecks aprovados; Debug
mais Release Simulator aprovados. O Core passou 371 testes, incluindo HTTP local.
Ainda não feita aceitação visual deste incremento nem teste em XR físico.

Para repetir os checks Swift na raiz do app:
```
xcrun swiftc MyApp/ReconnectionPolicy.swift Tests/ReconnectionPolicyChecks.swift -o /tmp/tars-reconnection-checks
/tmp/tars-reconnection-checks
xcrun swiftc MyApp/TARSClient.swift Tests/ClientReconnectionChecks.swift -o /tmp/tars-client-checks
/tmp/tars-client-checks
```
O cliente de teste usa URLProtocol simulado, sem enviar credenciais à rede.

Alterações de áudio e project.pbxproj presentes na árvore foram preservadas e
excluídas deste commit. Rollback: reverter somente o commit RECOVERY-2 do app;
patch reversível verificado no workspace. Não usar reset --hard ou descartar as
alterações locais. Para rollback do Core, consultar RECOVERY-2.md naquele repo.

## UI-3 — controles manuais fora do fluxo normal

A tela normal não apresenta Painel de Testes, Falar, Testar voz, Concluir,
Cancelar ou alternância de IA. As ferramentas existentes ficam preservadas
somente em Debug Simulator com TARS_MANUAL_DIAGNOSTICS=1. Não foi ativada
captura automática: a interface informa que voz automática está em desenvolvimento.
O retry de autorização continua disponível quando necessário.

Validação: suíte atual do Core c0069f9, 371 testes aprovados; compilação Debug
Simulator aprovada. Isso não conclui validade por sensor nem aceitação integrada.
A reclamação sobre botões não foi diagnosticada como falha resolvida; o painel
manual foi retirado do fluxo normal por solicitação do usuário.
Alterações locais de pronúncia e projeto preservadas, fora deste commit.
Rollback: git revert do commit UI-3; patch reversível no workspace em
software/rollback/ui-3.patch. Não remover estado persistente de segurança.

## VOICE-1 — ativação por voz no primeiro plano

Usuário autorizou reutilizar a chave existente. Fluxo normal inicia escuta local
em português: dizer TARS sozinho produz confirmação e abre uma pergunta;
TARS seguido da pergunta envia apenas a pergunta ao serviço de conversa existente.
Falas sem ativação são descartadas. Captura para antes de TTS; retorno à espera
após resposta, silêncio, ou falha com intervalo progressivo limitado a 30 s.
Suspensão cancela tarefas e respostas antigas; interrupções retomam apenas quando
a escuta automática já estava habilitada. Permissão negada ou reconhecimento local
não suportado não inicia tentativas infinitas; diagnóstico permanece visível.
Fonte Apple para a exigência de reconhecimento local:
https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition

Validação: VoiceActivationChecks, ClientReconnectionChecks, 22 checks de pronúncia
PASS; Debug Simulator BUILD SUCCEEDED. Core sem mudanças: 371 testes passaram
na etapa anterior. Sem validação acústica end-to-end, XR físico ou alegação de
melhoria no timbre. Reconhecimento local precisa estar disponível no dispositivo;
não há fallback silencioso para transmitir áudio ambiente. Não captura em background
nem permite interrupção da resposta pela voz. Detector é reconhecimento de palavra,
não um modelo dedicado de wake word. Qualidade/latência continuam por validar.

Rollback: reverter somente VOICE-1, mantendo alterações locais de pronúncia/projeto;
patch reversível no workspace software/rollback/voice-1.patch.

## VOICE-2 — teste multilíngue online limitado

VOICE-1 falhou na aceitação acústica: reconhecimento local pt-BR indisponível no
simulador (kLSRErrorDomain/300). Build aprovado não equivale a escuta funcional.
Usuário autorizou explicitamente um teste online PT/EN após esclarecimento de
cobrança separada e envio de trechos anteriores à ativação. TARS_ONLINE_WAKE=1
seleciona o gravador/transcritor multilíngue existente; padrão continua local.
Detecção da palavra acontece depois da transcrição online, não no dispositivo.
Silêncio sem fala detectada não gera upload. Apenas frases ativadas chegam à
conversa; áudio ambiente com fala pode ser transcrito neste modo consentido.

Teste limitado no app a 3 minutos ou 6 uploads, o que ocorrer primeiro. Falhas
consomem a reserva; foreground não renova o limite. Nova execução do processo
reinicia a janela, por isso não deixar flag ativa em lançamento de uso diário.
Não há repetição automática de requisições. Captura para durante respostas.
Falhas locais alternam pt-BR/en-US e interrompem tentativas após seis erros.
TTS escolhe a melhor qualidade instalada no idioma detectado, sem baixar vozes
nem garantia de melhora perceptiva. Acknowledgement curto é bilíngue.

Testes de roteamento PT/EN e limite de tempo/envios aprovados; aceitação real
pendente do teste no simulador. Correção da ativação LOCAL continua pendente.
Rollback: reverter apenas o commit VOICE-2; patch software/rollback/voice-2.patch.

## REGRESSION-1 — revisão antes de novas chamadas pagas

Core 801279b: 377 testes PASS. Quatro executáveis Swift PASS: ativação PT/EN e
limites de teste; reconexão; cliente HTTP com falhas e cancelamento; 22 casos de
pronúncia. Builds Debug e Release Simulator PASS. Nenhuma chamada externa à API.

Corrigidos dois pontos encontrados na revisão: tarefas de áudio validam geração
e cancelamento antes de iniciar trabalho; cliente rejeita cancelamento antes de
pairing/request. Teste comprova zero envios para tarefas previamente canceladas.
Falhas de cota, limite local, configuração ou autorização pausam voz automática
até nova execução do app; limite temporário confirmado mantém política progressiva.
Não repetir requisição paga já enviada. Não retomada automática por foreground
após falhas permanentes. Deadline não sobrescreve o diagnóstico após bloqueio.

Pendências: ativação local indisponível no simulador; aceitação acústica online
bloqueada pela recusa de API; nenhuma prova de melhora perceptiva da voz. Core
não concluído: validade por sensor, supervisão externa e aceitação integrada
prolongada continuam pendentes. XR e firmware permanecem etapas posteriores.
Rollback: reverter apenas REGRESSION-1; patch regression-1.patch no workspace.
Alterações locais de pronúncia/project.pbxproj preservadas e não incluídas.

## SENSORS-1 — diagnóstico de direção

HUD agora apresenta FORWARD/REVERSE com motivo atual fornecido pelo Core,
separado de último resultado de comando. Distâncias vencidas ficam N/A.
Core com validade individual: 404 testes PASS; app Debug BUILD SUCCEEDED.
Sem reinstalar/ativar áudio neste incremento. Rollback: reverter apenas este
commit e o correspondente Core; patch sensors-1-app.patch no workspace.

## VOICE-3 — prazo de captura independente do relógio civil

Captura local e online usam uptime para silêncio e duração, mantendo os limites
2,4 s após fala, 15 s sem fala e 20 s máximos por captura. Ajustes de data/hora não
prolongam a gravação. Janela de captura é renovada por interação, sem aproveitar
fala anterior. Relógio inválido/retrocesso descarta a captura. Política de ativação
PT/EN e orçamento online de 180 s/6 envios permanecem preservados.

Validação: checks de ativação/prazos, cliente HTTP/cancelamento, reconexão e
22 casos de pronúncia PASS. Debug Simulator BUILD SUCCEEDED. Nenhuma chamada de
API, instalação ou ativação de microfone nesta etapa. Qualidade perceptiva do TTS
e wake local indisponível no simulador continuam sem solução comprovada.

Rollback: reverter apenas o commit VOICE-3; patch voice-3-app.patch no workspace.
Mudanças preexistentes de pronúncia/project.pbxproj não incluídas.

## VOICE-4 — integração do controlador com I/O simulado

Diagnóstico exclusivo de Debug Simulator, ativado por TARS_VOICE_CHECKS=1 com
TARS_ONLINE_WAKE=0. Substitui apenas captura e saída de fala; exercita roteamento,
tarefas assíncronas, cancelamento, callbacks e agendamento do XRAudioController.
Durante o diagnóstico, a view não inicia conexão ao Core nem escuta normal.
Resultado gravado em Documents/voice-cycle-checks.txt no container do app.

Executado no iPhone 18 Pro/iOS 27 Simulator: PASS para fala ambiente ignorada,
ativação por nome e pergunta posterior em português, pergunta direta em inglês,
retorno à espera por nova ativação, callback de fala antigo ignorado, resposta
cancelada descartada, nenhum replay e bloqueio após erro permanente de autorização.
Debug Simulator BUILD SUCCEEDED; diagnóstico encerrado após leitura do resultado.
Não usa microfone, reconhecimento Apple, TTS real ou API. Não valida transcrição
online, acústica, qualidade perceptiva ou ativação local real. Estes continuam
pendentes; não confundir esse PASS com aceite de voz de ponta a ponta.

Rollback: reverter apenas VOICE-4; patch voice-4-app.patch no workspace.
Arquivos locais de pronúncia e project.pbxproj preservados fora do commit.
Release Simulator BUILD SUCCEEDED: hooks de captura/saída simuladas excluídos.

## VOICE-5 — diagnóstico real do reconhecimento local

Debug Simulator: TARS_LOCAL_VOICE_PROBE=1, TARS_ONLINE_WAKE=0. Prova com captura
local de até dez segundos após autorização por idioma, sem Core/API. Registra
somente capacidades e erros, não conteúdo reconhecido. Saída em
Documents/local-voice-probe.txt. Diagnóstico encerrado ao concluir.

Resultado real em 28/09/2026, iPhone 18 Pro, runtime iOS 27.0 (24A434):
pt-BR e en-US anunciam available=true e onDevice=true; ambos falham ao iniciar
com kLSRErrorDomain/300. Debug Simulator BUILD SUCCEEDED. Portanto a ativação
local NÃO está validada; capabilities sozinhas não comprovam funcionamento.
Apple documenta 300 como falha de inicialização, sem identificar uma única causa:
https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/error
Não concluir que falta permissão, modelo ou saldo da API apenas por esse código.

Só há iOS 27.0 instalado. Nenhum runtime baixado, simulador apagado ou fallback
online ativado. Próxima validação acústica local depende de corrigir a inicialização
ou testar outro runtime; XR físico permanece após software conforme ordem definida.
O ciclo do controlador com I/O simulado passou em VOICE-4, mas não resolve esta falha.
Rollback: reverter apenas VOICE-5; patch voice-5-app.patch no workspace.

## VOICE-6 — tornar o silêncio do app diagnosticável

Após teste online sem resposta relatado pelo usuário, tela foi inspecionada:
TRIAL FINISHED. Não havia evidência suficiente para distinguir falha na captura,
transcrição sem a palavra TARS ou reprodução. Não atribuir causa sem dados.

UI normal agora mostra última transcrição (até 300 caracteres, somente em memória)
e etapa/motivo: transcrevendo, palavra de ativação ausente, aguardando IA, saída de
voz, falha. Encerramento mostra uploads usados. Nenhum botão adicionado; mantém
limites de 180 s/6 uploads e não libera movimento. Build Debug PASS.
Ciclo do controlador reexecutado no simulador: PASS, incluindo transcrição ignorada
preservada com motivo legível. Teste offline, sem API. Aceitação acústica segue
pendente de nova fala do usuário com o diagnóstico visível.
Rollback: reverter VOICE-6; patch voice-6-app.patch no workspace.

## VOICE-8 — continuidade após resposta

Causa observada na UI: transcrição correta ignorada por ausência de TARS; teste
encerrou em 6/6 uploads. Fluxo anterior exigia nova ativação a cada pergunta.

Após conclusão real do TTS, abre janela de 30 s para uma próxima frase sem TARS.
Consumir a frase fecha a janela; próxima resposta concluída abre outra. Wake-only
continua aguardando pergunta. Silêncio sem fala, falha ou suspensão resetam a
política. Não amplia o orçamento de 180 s/6 uploads nem permite atuação física.
Na transcrição online, elegibilidade usa término da captura, não latência da API.

Checks Swift de janela/expiração/relógio/falha/suspensão PASS. Debug build PASS.
Aceitação com fala real permanece para o teste do usuário após implantação.
Controlador reexecutado no iOS Simulator, resultado novo às 00:56:36: PASS,
incluindo pergunta subsequente sem wake, callback antigo e resposta cancelada.
Rollback: reverter VOICE-8; patch voice-8-app.patch no workspace.

## VOICE-9 — voz natural e alternativa local

App integrado ao endpoint autenticado /v1/speech do Core: MP3 com Cedar,
instrução de ritmo calmo e português brasileiro, mesmas palavras da resposta.
Identificação de voz gerada por IA na tela. Chave permanece somente no Core.
Se geração/inicialização falha, usa voz local pelo restante da sessão, sem repetir
chamadas pagas; falha durante reprodução encerra turno e usa local no próximo
caso de erro de decodificação. Cancelamento invalida áudio atrasado; callback de
conclusão mantém janela de conversa. Limite de reprodução 90 s.

Core: 430 PASS. Cliente Swift (formato/cancelamento/reconexão) PASS.
Controlador real no simulador com WAV silencioso: conclusão, cancelamento,
alternativa sem reenvio e regressão de conversa PASS às 01:06:18.
Debug BUILD SUCCEEDED. Amostra real portuguesa gerada com uma chamada paga,
8,4 s, MP3 24 kHz. Qualidade perceptiva ainda sem aprovação do usuário.
O teste online conserva 180 s/6 uploads; Core aceita seis gerações de voz por
processo. Reinício reseta a cota de desenvolvimento; não é teto de gastos mensal.
Rollback voice-9-app.patch e voice-9-core.patch no workspace. Não incluídos os
arquivos preexistentes de pronúncia e project.pbxproj.
Release Simulator BUILD SUCCEEDED.

## VOICE-14: bounded extended conversation

Opt-in `scripts/conversation-session.sh` launches an installed build with online
capture for 15 minutes or 30 uploads. It sends speech to OpenAI, including speech
before the wake word, and incurs API use. It is not launched by the build or by
normal icon startup. Background/foreground transitions do not renew the allowance.
The default short trial remains 3 minutes / 6 uploads. Restarting the process creates
a new session. This is a development safeguard, not a persistent financial budget.
Core speech allows 60 requests per process (30 wake acknowledgements plus 30 answers).
Other provider errors can still trigger the existing local fallback. Restart the
Core with the corresponding version before the extended session. Local simulator
recognition remains unavailable; no claim of an offline wake-word fix.
Validation: 1,000 alternating PT/EN policy turns, upload/time boundaries, no refill,
and 60 fake speech calls preserve Onyx; no paid calls. Real long-duration audio and
interruption/reconnection integration remain to be validated separately.

## VOICE-15: first latency reduction
Endpoint silence reduced from 2.4 to 1.4 seconds; 20-second capture ceiling and
15-second no-speech discard unchanged. New boundary checks verify that resumed
speech resets the silence window. Pauses longer than 1.4 seconds can end a turn;
real Portuguese/English phrase completion needs user validation.
Debug simulator overwrites Documents/voice-latency.json with the last successful
transcription, response and voice-to-playback durations. No text or audio stored.
API stages remain sequential, not streaming; this change removes one second of
endpoint waiting but does not establish a measured end-to-end latency improvement.

## VOICE-16: optional buffered streaming

`TARS_STREAM_VOICE=1 ./scripts/conversation-session.sh` selects streaming; the
launcher without this variable preserves full MP3 playback. Both use the approved
Onyx direction and one generation request per utterance. No sentence splitting.
Core `/v1/speech/stream` sends authenticated NDJSON containing PCM 24 kHz mono
16-bit little-endian audio and requires an explicit done record. The client rejects
truncated/oversized streams and cancels the connection when leaving the iterator.
The audio engine queues 0.8 seconds before starting. If the queue drains before EOF,
it pauses and buffers 1.6 seconds before resuming; a completed short tail can drain
immediately. This cannot guarantee gap-free audio when the network stalls.
Cancellation stops queued sound and drops late callbacks. A failure after playback
starts never replays the answer automatically; failure before playback can use the
existing local voice fallback. Requests remain bounded and share the Core's budget.
Debug tests use silent PCM, so they verify playback lifecycle, not voice quality or
real network latency. Live comparison with full MP3 remains required before making
streaming the default. No microphone or paid API call is used by the diagnostic.

## VOICE-17: optional first-sentence response

`TARS_EARLY_RESPONSE=1 TARS_STREAM_VOICE=1 ./scripts/conversation-session.sh`
selects early conversation audio after transcription. Default remains the existing
complete-response path. One model request yields a complete first sentence then
remaining text. Up to two sequential Onyx generation requests feed one buffered
PCM player; the first can overlap generation of the remaining text. Voice identity
and instructions are unchanged, but cadence across the sentence boundary needs
real listening validation. Each generation counts toward the unchanged budget.
No automatic retry; incomplete output is not committed to conversation history.
Failure does not read the user's question aloud or repeat partially played audio.
Numeric diagnostic first_audio_after_transcription_seconds measures from model
request start to playback; do not add a separate answer duration to that field.
TARS_PAUSE_VOICE=1 keeps the UI/Core connection open without starting capture.
Offline checks do not establish live latency, quality or uninterrupted prosody.
