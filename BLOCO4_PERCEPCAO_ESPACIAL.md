# Bloco 4 — percepção espacial (análise autorizada)

Registro de decisão: 16/10/2026, horário de São Paulo.

Decisão mais recente: pausar correções do bloco 3 e iniciar análise do bloco 4. Bloco 5 permanece futuro. Implementação espacial e integração física ainda não realizadas.

## Relação essencial entre câmera, pescoço e corpo

Virar o pescoço muda a orientação da câmera sem necessariamente mudar a orientação do corpo. “À frente da câmera” não equivale a “à frente das rodas”. A percepção deve relacionar os referenciais do mapa, corpo, pescoço e câmera, incluindo calibração de posição e orientação, pan/tilt, horário do quadro e horário da telemetria. Considerar também a posição da câmera em relação ao eixo do pescoço.

Um ângulo solicitado não comprova a posição física atingida. Distinguir comando, estimativa e medição. Com posição desconhecida, dados antigos ou rastreamento perdido, expor indisponibilidade; não afirmar caminho livre ou distância segura.

Primeiros incrementos: percepção em bancada com movimento manual do XR; lugares cadastrados e relocalização; planejamento de percurso simulado; integração física posterior, preservando os mecanismos de segurança existentes.

## Evidência disponível sobre o corpo

Inspeção do checkout local TARSXR-conversation em 17/10/2026 UTC:

- NativeBodyCore aceita MOVE, PAN, TILT, STEER, HEAD_CENTER e comandos de parada/recuperação, mas bloqueia comandos de atuação quando o estado do ESP32 não é VIRTUAL (PHYSICAL_TRANSPORT_NOT_VALIDATED).
- TARSTelemetry declara pan_deg, motion_active e campos de parada/recuperação; esse contrato não declara tilt, pose do corpo ou timestamp de aquisição. pan_deg não demonstra por si só feedback físico de servo.
- O firmware ESP32 não foi encontrado entre os arquivos disponíveis nesta inspeção. Não foi possível confirmar seu protocolo real, feedback de posição, sincronização, odometria ou comportamento físico.
- O registro histórico de baseline congelado/pronto para flash não equivale a validação de integração física.

Esta nota não altera firmware, GPIO, motores, segurança ou autoridade de movimento. Antes de integrar, auditar o firmware existente e os contratos; não redesenhar o hardware nem presumir necessidade de compras.


## Análise inicial e recomendação — 17/10/2026 UTC

### Achados no código existente

SequentialSessionCamera usa AVCaptureSession, VGA e solicita 5 fps quando suportado. SequentialVision seleciona amostras aproximadamente a cada três segundos, normaliza e guarda um quadro aprovado, mantendo os limites locais de qualidade, custo e temperatura. Não há implementação de ARKit, transformação câmera-corpo ou localização espacial neste checkout. Essa cadência não constitui rastreamento espacial para navegação.

### Escolha proposta (ainda sem benchmark no XR)

1. ARKit/ARWorldTrackingConfiguration como candidato inicial para pose da câmera, orientação, rastreamento e relocalização locais. Verificar isSupported e formatos no aparelho; não confundir pose relativa da sessão com localização absoluta na casa.
2. Um único proprietário da câmera. Modos explícitos de descrição econômica e percepção espacial; transição exclusiva entre AVCaptureSession e ARSession. No modo espacial, aproveitar ARFrame.capturedImage para consumidores secundários em vez de abrir outra captura traseira. Fotografia existente preservada mediante liberação/reaquisição e tratamento de cancelamento.
3. Captura/rastreamento na cadência suportada pelo ARKit; detecção e descrição com amostragem independente. Aumentar a amostragem do consumidor não reduz automaticamente custo da sessão. Medir aquecimento, memória, latência e consumo no XR com áudio ativo; não prometer navegação a 5 fps ou autonomia antes do benchmark.
4. Vision/Core ML com detector leve como experimento posterior para objetos/pessoas. Comparar modelo pequeno exportado para Core ML e exemplo nativo antes de escolher dependência. Classes detectadas não comprovam identidade da pessoa nem da Mel.
5. Lugares nomeados pelo operador e mapa topológico de pontos/conexões; persistência de world map e relocalização como experimentos separados. Mapa de pontos do ARKit não é grade completa de obstáculos nem prova de piso transitável.
6. Planejamento de percurso apenas simulado no primeiro ciclo; sem referência a transporte de comandos físicos no módulo de percepção.

### Opções pesquisadas

- ARKit: caminho inicial proposto por integração nativa, pose e estados de rastreamento. Suporte e desempenho dependem de teste real. https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration
- Ultralytics YOLO iOS: candidato a benchmark para detecção local via Swift/Core ML; não integra localização ou navegação por si só. Repositório declara AGPL-3.0 e alternativa comercial; versão, pacote e pesos exigem revisão antes de adoção. Métricas anunciadas para iPhones recentes não demonstram desempenho no XR. https://github.com/ultralytics/yolo-ios-app
- Hugging Face Core ML examples: referências para classificação, segmentação e Depth Anything V2 small; não importar todos os modelos simultaneamente. Profundidade monocular inferida não será tratada como distância métrica calibrada. Conferir licenças dos pesos separadamente. https://github.com/huggingface/coreml-examples
- ORB-SLAM3: alternativa visual-inercial aberta, com custo de integração C++ e calibração a avaliar; não escolhida para primeiro incremento. https://github.com/UZ-SLAMLab/ORB_SLAM3
- RTAB-Map: referência de mapeamento; caminho iOS publicado requer LiDAR, não é substituto pronto para XR. https://introlab.github.io/rtabmap/
- sceneDepth do ARKit requer LiDAR e não será pressuposto disponível no XR. https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/scenedepth

### Contrato espacial mínimo

Snapshot com timestamp monotônico do quadro, identificador da sessão/mapa, pose da câmera e estado de tracking. Pose do corpo opcional: somente derivada quando calibração e pan/tilt contemporâneos são válidos. Identificar se ângulos são medidos, estimados ou apenas comandados. Transformações rígidas completas entre câmera, pescoço e corpo (posição e orientação); alinhar relógios antes de associar telemetria física aos quadros. Reinício/relocalização não pode misturar coordenadas entre mapas.

Estados de aplicação propostos: OFF, INITIALIZING, TRACKING, LIMITED, RELOCALIZING, LOST, THERMAL_UNAVAILABLE. Traduzir fielmente os estados do ARKit; não inventar confiança numérica a partir de normal/limited. Obstáculos e regiões não observadas permanecem desconhecidos. Modelos semânticos não concedem autorização de movimento.

### Primeiro incremento implementável

4A: ativação explícita de bancada, arbitragem exclusiva de câmera, pose apenas da câmera, estados e idade reais, trilha relativa e exportação de diagnóstico. Sem detector pesado, reconhecimento facial ou ESP32. Expor corpo como indisponível enquanto faltar a transformação; não apresentar trilha da câmera como trilha do chassi.

Testes determinísticos: composições/inversas de transformações; corpo imóvel com pan/tilt variável; câmera deslocada do eixo; quadro/telemetria antigos; ângulo apenas comandado; geração de sessão reiniciada; perda/relocalização; concorrência de câmera e cancelamento. Dados simulados verificam contratos, não precisão física.

Validação XR posterior: deslocamento manual com referência medida; retorno à origem; giro no lugar; baixa luz/parede lisa; obstrução e retomada; suspensão/reinício; alternância com foto/descrição; voz simultânea; relatório de drift e thermal em sessão com duração registrada. Critérios quantitativos serão fixados antes da aceitação conforme o uso proposto; não afirmar aprovação espacial a partir de build ou fixtures.

Próximos incrementos: 4B lugares/relocalização e detecção leve; 4C percurso simulado com espaço desconhecido explícito; 4D auditoria do firmware/protocolo e integração física separadamente autorizada. O firmware continua ausente desta inspeção; não concluir prontidão física.


## Checkpoint de implementação

Primeiro software de bancada implementado em SpatialModel, SpatialBenchRuntime e SpatialBenchView; 180 testes espaciais e regressões portáteis passaram. Build iOS e aceitação física ainda pendentes. Repositório do firmware recuperado no histórico: guspisi-the-fuzz/tars-firmware, main; clone ~/Documents/TARS/Software/TARS-RC3/tars-firmware. Conteúdo ainda não auditado: aguardando autenticação no navegador após 404 no conector. 4D permanece preparatório; nenhuma atuação foi liberada.


## Firmware recebido e coordenação das quatro rodas

ZIP recebido e fonte auditada. Body V0 foi preparado para diagnóstico/flash de bancada, NÃO para navegação: protocolo recusa atuação, hardwareValidated=false, tração e pan/tilt indisponíveis. A formulação anterior “ESP32 pronto” não comunicou essa distinção adequadamente. Ver validation/2026-10-17-spatial-bench/FIRMWARE_AUDIT.md.

São quatro motores de tração, quatro servos de direção e mais dois servos do pescoço. Implementado cálculo cinemático de simulação com conjunto coerente de quatro ângulos/velocidades, rejeição de limites inviáveis e redução comum de velocidade. Não conectado ao executor, não configura PWM e não altera firmware. O controle dinâmico e a integração física 4D continuam pendentes. Serviços externos (bloco 5) têm prioridade posterior ao bloco 4.


Correção posterior autorizada: emissão incompleta dos quatro encoders corrigida no firmware por dimensionamento JSON dependente da arquitetura e teste de contrato. Não altera GPIO, gates ou atuação. Patch e resultados em FIRMWARE_AUDIT.md.
