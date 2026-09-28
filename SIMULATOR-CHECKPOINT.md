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
