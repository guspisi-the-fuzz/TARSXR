# Validação no Mac — 17/10/2026

Evidência: saída integral do instalador enviada pelo usuário em Pasted markdown.md. Log informado: /var/folders/h_/rbcsq2qd06nfgswfn_jyvnqm0000gn/T/tars-spatial-validation.0oSqxi.

- PASS Debug antes/depois dos testes e Release iOS.
- PASS 180 verificações espaciais, 32 de protocolo Body V0 e 345 de cinemática das quatro rodas.
- PASS regressões existentes, incluindo memória, conversa, voz, câmera, visão, serviços e mocks HTTP nativos.
- PASS ciclo do app no iPhone Simulator, inclusive estado espacial, referência do mapa, percurso simulado e exclusão de câmera. I/O simulado, sem microphone/TTS/API.
- PASS testes host do firmware e integração virtual com setup/loop reais, 1000 ciclos de recuperação e emissão completa dos quatro encoders.
- PASS build ESP32 no Mac: RAM 23016 bytes; flash 310697 bytes. Imagem criada, não gravada no dispositivo. A medida de flash observada no Linux foi 310537 bytes; não se afirma igualdade binária entre builds.
- Inventário do corpo encontrou 12 fontes candidatas; inventário não equivale a validação física.

Ainda não executados: instalação/aceitação deste incremento no XR físico, precisão/drift/relocalização/temperatura, flash ESP32 e atuação real, transporte direto XR–ESP32 e supervisor físico das quatro rodas/pescoço.

Status enviado pelo usuário mostra alterações dos dois repositórios ainda sem commit/push deste pacote. Arquivo ReferenceCamera.swift.20261015_214945.bak permanece fora do versionamento.
