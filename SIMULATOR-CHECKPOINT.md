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
