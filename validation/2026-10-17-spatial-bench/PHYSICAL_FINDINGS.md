# Situação física

Sem teste físico deste incremento até esta entrega. Relatos anteriores de visão/voz não validam ARKit ou navegação.

Repositório identificado: guspisi-the-fuzz/tars-firmware (main); conteúdo recebido por ZIP e auditado em FIRMWARE_AUDIT.md; todos os bytes originais preservados. Transporte físico já bloqueado em NativeBodyCore por PHYSICAL_TRANSPORT_NOT_VALIDATED. Contrato TARSTelemetry atual contém pan_deg, mas não tilt ou timestamp de aquisição. Campo de ângulo não comprova feedback físico.

Mudanças deste pacote não alteram NativeBodyCore, NativeAIRuntime, TARSRuntime, GPIO, motores ou mecanismos de segurança. Após solicitação explícita, o patch de firmware altera somente dimensionamento/verificação da emissão de encoders e seu teste O painel 4D não consulta nem comanda o corpo e expõe a integração como não validada.

Body V0 não emite pan/tilt medidos; status.motion_allowed é estado lógico e traction_available permanece false. O novo parser é somente de registros importados, sem transporte ou autorização de atuação.

## Primeiro ensaio XR relatado — 17/10/2026

Usuário abriu Bancada espacial e Novo mapa: INITIALIZING → TRACKING; quadro disponível, coordenadas da câmera e trilha superior visíveis; corpo corretamente indisponível. Relatou giro do aparelho e desenho correspondente, sem referência métrica externa para avaliar precisão.

Após Parar, a trilha permaneceu visível como histórico. Nova tentativa de Novo mapa exibiu UNAVAILABLE, quadro indisponível e “Temperatura bloqueia percepção espacial”. Isso comprova bloqueio térmico exibido; não comprova falha de reinício ou limite de uma ativação. Temperatura inicial, duração, carga, bateria, iOS e estado térmico numérico não foram fornecidos; não atribuir causalidade exclusivamente ao ARKit ou à idade do XR.

Cadastro de Origem não executado: usuário não localizou o controle. A interface exige rolar até seção 4B, preencher o nome e acionar Marcar posição atual da câmera com tracking válido; não há botão predefinido Origem. Repetir após resfriamento e registrar restart, cadastro e relocalização. Sem calibração ou atuação física.

## Segundo ensaio XR e esclarecimento — 17/10/2026

Usuário iniciou em THERMAL FAIR, conectado à alimentação; relatou bateria em 95% ao final. Novo mapa chegou a TRACKING; houve atualização da trilha durante deslocamento manual. Parar seguido de Novo mapa retornou a TRACKING, confirmando reinício neste ensaio.

Esclarecimento explícito posterior do usuário: após a dificuldade inicial, clicou em Marcar posição atual da câmera e cadastrou Origem e Destino. Ambos apareceram como pontos no mapa. Portanto, cadastro de dois lugares e sua exibição estão confirmados pelo relato; a interpretação anterior de que não foram cadastrados estava incompleta.

Usuário avaliou o mapeamento visual como correto. Não houve referência métrica medida, cálculo de erro/drift ou confirmação explícita de Ponto próximo reconhecendo Origem no retorno. Não converter avaliação visual em precisão métrica ou navegação física validada.

Conversa por voz respondeu à narração durante o ensaio, inclusive com respostas de memória/conversa geral; isso não era retorno do cadastro espacial. Houve menção de câmera em thermal no encerramento, mas o estado térmico final falado não ficou inequívoco. Uso sustentado, save/load/relocalização e percurso simulado continuam pendentes.
