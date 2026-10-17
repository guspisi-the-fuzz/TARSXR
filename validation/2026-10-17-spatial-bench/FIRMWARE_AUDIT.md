# Auditoria de integração espacial — firmware recebido

Fonte: arquivo TARS_FIRMWARE_AUDITORIA.zip enviado pelo usuário. Repositório identificado no histórico como guspisi-the-fuzz/tars-firmware, branch main. Usuário mostrou árvore limpa main...origin/main; o ZIP não contém metadados Git, portanto esta auditoria identifica a fonte por hash, sem inventar o commit HEAD.

## Correção de prontidão

“Pronto para flash” neste baseline significa uma imagem de diagnóstico de bancada, com atuação bloqueada. Não significa que tração, direção das quatro rodas, varredura do pescoço ou navegação estejam implementadas e validadas. A comunicação anterior que omitiu essa diferença foi imprecisa.

## Contratos reais

| Área | Evidência | Consequência para XR |
|---|---|---|
| Transporte | README e protocol.h: Serial JSON 115200, tars-alpha-serial-json/body-v0 | Não é o contrato HTTP do app. Não há ligação serial física nova neste pacote. |
| Atuação | main.cpp default: raw_actuation_disabled_body_v0; MOVE/STEER/PAN/TILT/HEAD_CENTER chegam a essa recusa | Não oferecer trajetórias/varredura como executáveis. |
| Prontidão física | body_config.h hardwareValidated=false; BODY_READY exige validação, pinmap e entrada E-stop | Preservar gates, não mudar true para cumprir uma demonstração. |
| Estado lógico | safety.h motionAllowed depende de ARMED/MOVING; telemetry status informa traction_available=false separadamente | motion_allowed=true não significa que o robô pode navegar ou que a tração está disponível. |
| Direção e pescoço | servos.h: quatro canais de direção + pan e tilt no PCA9685 | Não confundir os seis servos; necessidade de calibração por canal e coordenação com quatro motores de tração. |
| Feedback | writeDegrees retorna ACK de escrita I2C; sem leitura do ângulo mecânico | Não usar centro/ângulo solicitado como posição medida. |
| Encoders | encoders.h: single_channel_a_change_count, direction_available=false, sem PPR/roda calibrados | Pulsos não fornecem odometria métrica nem direção física confiável. |
| IMU | GET_IMU faz diagnóstico/scan e para as saídas; i2c_devices.h declara driver not_enabled/orientation_readout=false | Detecção de dispositivo I2C não é orientação. Não fazer polling GET_IMU como telemetria inofensiva. |
| Pisos/obstáculos | pinmap.h: QTR e ToF declarados, não utilizados no firmware inicial | Pinos definidos não equivalem a sensores operacionais. |
| Parada física | AUDIT_BODY_V0 e pinmap: ESTOP_IN não definido; KW12 desabilitado no build | Interface física permanece não validada; não redesenhar GPIO nesta entrega. |
| Relógio | mensagens usam uptime_ms uint32 | Exige relação com relógio XR e tratamento de rollover/reboot; não comparar diretamente com timestamp ARKit. |
| Correlação | parser lê seq/request_id; sendAck não os devolve | Não prometer confirmação de uma execução individual pelo identificador usando esse ACK. |

## Coordenação 4x4 e quatro rodas direcionais

Tração é 4x4: um motor por roda. Direção tem quatro servos independentes. Pescoço tem mais dois servos. O controlador deve calcular um único conjunto coerente de quatro ângulos e quatro velocidades para a intenção do corpo; velocidade de roda interna/externa geralmente difere em curva.

Foi adicionado no XR um cálculo cinemático PURO para simulação: vetor de velocidade em cada posição de roda, escolha de direção de rolamento, recusa de ângulos mecanicamente impossíveis e um fator comum de redução de velocidade. Não escreve PWM, não gera JSON de atuação e não altera o firmware. Os 345 testes usam geometria sintética explicitamente não atribuída ao TARS físico.

Esse cálculo não implementa dinâmica, controle de deslizamento, trajetória de esterçamento/velocidade em tempo real ou frenagem física. Quatro ângulos comandados não comprovam quatro rodas alinhadas. O teste de alinhamento só é para simulação e exige quatro medidas recentes. Giro no próprio eixo e movimento lateral dependem dos limites reais de cada roda e podem ser recusados; não são garantidos pelo fato de existir 4WS.

## Entrega possível sem mudar firmware

SpatialFirmwareEvidence interpreta mensagens status/capabilities/encoders Body V0 como registros históricos importados. Diferencia flags lógicas e físicas, uptime, ausência de feedback e capacidades indisponíveis. Mesmo registros com flags true não autorizam movimento; divergências exigem nova auditoria. O painel permite importar JSONL/JSON pequeno, sem serial, heartbeat, ARM ou qualquer comando.

Fixtures de integração geradas do setup/loop e serialização reais do firmware, com periféricos simulados do próprio repositório. Não são dados do aparelho físico.

## Pendências de fechamento 4D

- Auditoria do caminho de transporte XR/Core/serial e seu contrato, sem presumir conexão direta Lightning–ESP32.
- Calibração mecânica/geométrica dos referenciais e de cada servo; origem medida/estimada de ângulos explicitada.
- Estratégia de localização do corpo com câmera articulada e medições disponíveis, sem presumir sensores adicionais.
- Coordenação e limites de direção/tração por roda, transições, falhas e intertravamentos existentes.
- Validação física da parada e da interface antes da atuação.

O usuário originalmente determinou não alterar ESP32, GPIO, motores ou segurança. Essas restrições foram preservadas. Auditoria e simulação não equivalem a conclusão da integração física de 4D.

SHA-256 do ZIP recebido: `3a7e6a2d6bc9db878b374b0e934b0062ca88a6f0d2fac14981db6ad39c9c16bb`.


## Achado no teste de integração host

A emissão real de encoders em host de 64 bits, usando ArduinoJson 6.21.6 e o StaticJsonDocument<512> existente, omitiu counts.rr. A importação Swift recusou a mensagem por campo obrigatório ausente; não substituímos silenciosamente por zero. A fixture truncada foi preservada como teste negativo, e a transcrição válida contém status e capabilities emitidos pelo firmware real com I/O simulado.

Isso não comprova truncamento no ESP32 de 32 bits: o consumo por slot ArduinoJson difere entre arquiteturas. É necessário verificar overflow na origem e capturar a saída real no aparelho em futura revisão do firmware. Nenhum tamanho de documento ou fonte do firmware foi alterado nesta entrega. A suíte virtual existente valida o JSON recebido pelo teste, mas não detecta necessariamente campos omitidos por falta de memória na emissão.

## Critério de conclusão por etapa

4A–4C têm implementação inicial de bancada e verificações determinísticas; precisam de build iOS no Mac e aceitação do XR. Reconhecimento semântico de lugares/identidades, mapa completo de obstáculos e planejamento físico não estão concluídos. 4D tem auditoria de fonte e adaptação de registros históricos, não uma integração de atuação. Não declarar o bloco 4 completo por haver um pacote instalável.

## Contrato futuro de coordenação (proposta, não implementado no firmware)

1. Percepção estima câmera e, quando possível, corpo com incerteza explícita. Planejamento produz intenção de deslocamento do corpo e prazo, sem escrever motores.
2. Coordenador cinemático calcula quatro ângulos de direção e quatro velocidades como um único conjunto com geração/validade. Respeita reversões/centros/limites calibrados e a geometria medida. Intenções inviáveis retornam para replanejamento.
3. Supervisor de execução acompanha a transição de direção e tração, usando o tipo de feedback realmente disponível, e invalida o conjunto em falha/atraso. Alvos solicitados não são apresentados como medidos. O modelo cinemático sozinho não implementa esse supervisor.
4. Transporte versionado correlaciona recebimento/aceitação/conclusão sem misturar isso com confirmação mecânica. O protocolo Body V0 atual não oferece essa integração.
5. Firmware preserva supervisão e parada existentes. Nenhum valor de visão ou resposta da IA muda hardwareValidated ou libera automaticamente atuação.

A existência de E-stop físico no projeto não é negada pela ausência de GPIO de leitura: o que a fonte comprova é que este firmware não tem essa entrada configurada; o circuito de corte físico não foi testado nesta auditoria.


## Correção solicitada e implementada na origem

Após o achado, o usuário solicitou explicitamente corrigir o emissor. Foi criada uma cópia Git isolada do firmware para patch mínimo, preservando o ZIP original. src/encoders.h agora usa JSON_OBJECT_SIZE(9) + 2 * JSON_OBJECT_SIZE(4) e verifica overflow antes de serializar. O teste novo exige os quatro contadores e quatro pinos, usando INT32_MAX/INT32_MIN e valores distintos. Foi demonstrado: teste falha com a fonte anterior e passa com a correção, sem mudar valores ou desabilitar assertions.

A transcrição positiva agora inclui encoders completos emitidos pela fonte corrigida com periféricos simulados. A fixture truncada do baseline anterior permanece negativa. O patch separado inclui apenas a correção, o teste e sua documentação; nenhum gate, GPIO, motor, servo ou segurança é modificado. Isto substitui a decisão inicial de somente registrar o defeito sem corrigi-lo.


## Resultado da correção

Build ESP32 corrigido PASS: RAM 23.016 bytes, flash 310.537 bytes. Suítes host e virtual integradas PASS; regressão de emissão completa demonstrada antes/depois. Build final usa PLATFORMIO_SETTING_ENABLE_TELEMETRY=no: a revisão automática havia bloqueado o coletor de telemetria, e a configuração suportada foi verificada antes de executar a alternativa sem essa comunicação. Nenhum flash físico.

A interface de transporte direto XR–ESP32 ainda não está implementada neste pacote. Serial USB 115200 do firmware não equivale a conexão direta via Lightning ou ao contrato HTTP usado pelo app. Essa lacuna, o supervisor de atuação coordenada e a validação física impedem declarar “todos os comandos integrados”.
